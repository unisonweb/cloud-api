{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Avoid lambda" #-}

module Cloud
  ( startApp,
  )
where

import Cloud.App
import Cloud.Client (listenThread)
import Cloud.Deployment qualified as Deployment
import Cloud.Env
import Cloud.Errors (respondError)
import Cloud.Metrics
import Cloud.Prelude
import Cloud.User.Env (AuthEnv (..))
import Cloud.Utils.Logging (LogMsg (..), Loggable, Severity (Error), logErrorText, withSeverity)
import Cloud.Utils.Logging qualified as Logging
import Cloud.Web.API (api)
import Cloud.Web.API qualified as Web
import Cloud.Web.App (RequestId, WebApp, localRequestCtx)
import Cloud.Web.App qualified as WebApp
import Cloud.Web.Cluster.Impl (consulRegistrationSelfCheck)
import Cloud.Web.Errors
import Cloud.Web.Impl qualified as Web
import Cloud.Web.RawRequest (RawRequest)
import Control.Concurrent
import Control.Concurrent.STM (TVar)
import Control.Concurrent.STM qualified as STM
import Control.Monad.Except
import Control.Monad.Random (randomIO)
import Control.Monad.Reader
import Data.Binary.Builder qualified as Builder
import Data.Bool (bool)
import Data.ByteString qualified as BSL
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Map qualified as Map
import Data.Maybe qualified as Maybe
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (NominalDiffTime, getCurrentTime)
import Data.Time.Clock (diffUTCTime)
import Data.Typeable qualified as Typeable
import Data.UUID (UUID)
import Data.Vault.Lazy as Vault
import Network.HTTP.Types (HeaderName, statusCode)
import Network.HTTP.Types qualified as HTTP
import Network.Wai
import Network.Wai qualified as WAI
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (run)
import Network.Wai.Internal qualified as WAI
import Network.Wai.Middleware.Cors
import Network.Wai.Middleware.Gzip qualified as Gzip
import Network.Wai.Middleware.RealIp (realIp)
import Network.Wai.Middleware.RequestLogger (logStdoutDev)
import Network.Wai.Middleware.Routed (routedMiddleware)
import Servant
import Share.JWT qualified as JWT
import Share.OAuth.Session (AuthCheckCtx, MaybeAuthenticatedUserId, addAuthCheckCtx)
import Share.OAuth.Types
import Share.Utils.IDs qualified as IDs
import Share.Utils.Servant.Cookies (CookieVal)
import Share.Utils.Servant.Cookies qualified as Cookies
import Share.Utils.Show
import System.Log.FastLogger (FastLogger, FormattedTime, LogStr)
import System.Log.Raven qualified as Sentry
import System.Log.Raven.Types qualified as Sentry
import UnliftIO qualified
import Data.ByteString.Char8 (split)

startApp :: Env () -> IO ()
startApp env = do
  -- Loop tcp handler forever, logging any exceptions.
  forkIO . void . forever . runAppM env $ UnliftIO.catchAny listenThread (Logging.logErrorText . tShow)
  forkIO . void . runAppM env $ UnliftIO.catchAny consulRegistrationSelfCheck (Logging.logErrorText . tShow)
  app <- mkApp env
  run (envServerPort env) app

newtype UncaughtException err = UncaughtException err
  deriving stock (Show)

instance (Show err) => Logging.Loggable (UncaughtException err) where
  toLog = Logging.withSeverity Logging.UserFault . Logging.showLog

instance ToServerError (UncaughtException a) where
  toServerError _ = (ErrorID "uncaught-exception", internalServerError)

data Timeout = Timeout Text NominalDiffTime

instance Loggable Timeout where
  toLog (Timeout ctx n) =
    withSeverity Error . Logging.textLog $ ctx <> " request Timeout, took longer than " <> Text.pack (show n)

instance ToServerError Timeout where
  toServerError Timeout {} =
    (ErrorID "timeout", err504 {errReasonPhrase = "Request Timeout.", errBody = "Request Timeout."})

withTimeoutSeconds :: Text -> NominalDiffTime -> WebApp a -> WebApp a
withTimeoutSeconds ctx diffTime m = do
  let (seconds, _fractional) = properFraction diffTime
  UnliftIO.timeout (seconds * 1000_000) m >>= \case
    Nothing -> respondError (Timeout ctx diffTime)
    Just a -> pure a

-- | Converts every exception into a ServerError to ensure users always get a reasonable
-- response even if it's a 500.
toServantHandler :: Env () -> WebApp a -> Handler a
toServantHandler env appM =
  let catchErrors m = do
        UnliftIO.tryAny m >>= \case
          Left (UnliftIO.SomeException (Typeable.cast @_ @ServerError -> Just serverErr)) -> do
            pure $ Left serverErr
          Left (UnliftIO.SomeException err) -> do
            let addSentryData sr =
                  sr
                    { Sentry.srEnvironment = Just (show Deployment.deployment),
                      Sentry.srCulprit = Just "critical-uncaught-exception",
                      Sentry.srLevel = Sentry.Fatal
                    }
            sentryService <- asks envSentryService
            liftIO $ Sentry.register sentryService "errors" Sentry.Error (show err) addSentryData
            logErrorText ("Uncaught exception: " <> tShow err)
            pure $ Left err500
          Right a -> pure (Right a)
   in Handler . ExceptT $ do
        -- fresh request ctx for each request.
        reqCtx <- WebApp.freshRequestCtx
        runReaderT (unAppM $ catchErrors appM) (env {envRequestCtx = reqCtx})

-- | Uses context from the request to set up an appropriate RequestCtx
type WrapperAPI = (RawRequest :> Header "X-NO-CACHE" Text :> Cookies.Cookie "NO-CACHE" Text :> Header "X-RequestID" RequestId :> MaybeAuthenticatedUserId :> Web.API)

mkApp :: Env () -> IO Application
mkApp env = do
  reqTagsKey <- Vault.newKey
  reqLoggerMiddleware <- mkReqLogger (envLogger env) (envTimeCache env) reqTagsKey
  metricsMiddleware <- serveMetricsMiddleware env
  let ctx :: (Context (AuthCheckCtx .++ '[Cookies.CookieSettings, JWT.JWTSettings]))
      ctx = addAuthCheckCtx envCookieSettings envJwtSettings ((envSessionCookieName . authEnv) env) (envCookieSettings :. envJwtSettings :. EmptyContext)
  let waiApp =
        appServer reqTagsKey
          & hoistServerWithContext appAPI ctxType (toServantHandler env)
          & serveWithContext appAPI ctx
          & reqLoggerMiddleware
          & requestIDMiddleware
          & metricsMiddleware
          & realIp
          & requestMetricsMiddleware api
          & skipOnLocal corsMiddleware
          & gzipMiddleware
  pure waiApp
  where
    Env {authEnv = AuthEnv {envCookieSettings, envJwtSettings}} = env

    ctxType :: Proxy (AuthCheckCtx .++ '[Cookies.CookieSettings, JWT.JWTSettings])
    ctxType = Proxy
    uriFromReq req =
      (envApiOrigin env)
        { uriPath = BSC.unpack $ rawPathInfo req,
          uriQuery = BSC.unpack $ rawQueryString req
        }
    -- Add some global context to the request.
    appServer :: (Vault.Key (TVar (Map Text Text))) -> Wai.Request -> Maybe Text -> Maybe (CookieVal "NO-CACHE" Text) -> Maybe RequestId -> Maybe UserId -> ServerT Web.API WebApp
    appServer reqTagsKey req noCacheHeader (Cookies.cookieVal -> noCacheCookie) mayRequestID mayUserId =
      let reqMethod = Wai.requestMethod req
          addReqCtx m = do
            let isSet = \case
                  Nothing -> False
                  Just v
                    | lower <- Text.toLower v, lower == "false" -> False
                    | otherwise -> True
            let useCaching = not Deployment.onLocal && not (isSet noCacheHeader) && not (isSet noCacheCookie)
            let reqTags =
                  Map.fromList
                    [ ("caching-disabled", bool "true" "false" $ not useCaching),
                      ("request-id", maybe "<none>" (coerce @_ @Text) mayRequestID),
                      ("authenticated-user-id", maybe "<unauthenticated>" IDs.toText mayUserId),
                      ("path", Text.intercalate "/" $ pathInfo req),
                      ("commit", tShow (envCommitHash env))
                    ]
            localRequestCtx
              ( \reqCtx ->
                  reqCtx
                    { WebApp.useCaching = not Deployment.onLocal && Maybe.isNothing noCacheHeader && Maybe.isNothing noCacheCookie,
                      WebApp.requestId = mayRequestID,
                      WebApp.authenticatedUser = mayUserId,
                      WebApp.pathInfo = pathInfo req,
                      WebApp.rawURI = Just $ uriFromReq req,
                      -- If there's a request tags var set on the request's vault via middleware, use that.
                      WebApp.reqTagsVar = fromMaybe (WebApp.reqTagsVar reqCtx) . Vault.lookup reqTagsKey . Wai.vault $ req
                    }
              )
              do
                reqTagsVar <- asks (WebApp.reqTagsVar . envRequestCtx)
                liftIO . STM.atomically $ STM.modifyTVar' reqTagsVar (<> reqTags)
                m
          -- Individual endpoints my specify a shorter timeout if they like, but we
          -- shouldn't compromise our global limit.
          -- Admin/local endpoints have a longer timeout to accomodate things like migrations.
          withGlobalTimeout =
            withTimeoutSeconds (tShow path) (timeoutSeconds path)
            where
              path = split '/' $ BSL.drop 1 $ Wai.rawPathInfo req
              timeoutSeconds path = case path of
                -- Persistent connection between nimbus and cloud-api. Doubtful it will last a year but why not.
                ["v2", "cluster", "join"] -> 365 * 24 * 60 * 60
                ("v2" : "logs" : _) -> 60
                ("v2" : "users" : _ : "logs" : _) -> 60
                ("admin" : _) -> 24 * 60 * 60
                ("local" : _) -> 24 * 60 * 60
                -- Get requests shouldn't be doing much hard-work.
                -- Usually if they take a long time it's due to something like an infinite loop
                -- in a doc render and we want to shut it down before it consumes too many
                -- resources.
                _ | reqMethod == HTTP.methodGet -> 10
                _ -> 60
       in hoistServerWithContext Web.api ctxType (addReqCtx . reportExceptions . withGlobalTimeout) (Web.server env)
    -- Ensure we log and report all non-server-error exceptions
    reportExceptions :: WebApp a -> WebApp a
    reportExceptions m =
      UnliftIO.tryAny m >>= \case
        Left (UnliftIO.SomeException (Typeable.cast @_ @ServerError -> Just serverErr)) -> do
          UnliftIO.throwIO serverErr
        Left (UnliftIO.SomeException err) -> do
          respondError $ UncaughtException err
        Right a -> pure a
    appAPI :: Proxy WrapperAPI
    appAPI = Proxy
    skipOnLocal :: Middleware -> Middleware
    skipOnLocal m = if Deployment.onLocal then id else m
    gzipMiddleware =
      -- Only apply gzipping on subsections of the api which tend to have sufficiently
      -- large payloads. Gzipping small payloads is a waste of time and might actually
      -- inflate them.
      -- Normally this would be done by looking at Content-Length headers, but Wai sends
      -- responses in the 'chunked' format and doesn't usually provide a Content-Length.
      flip routedMiddleware (Gzip.gzip Gzip.def) \case
        ("codebases" : _) -> True
        ("search" : _) -> True
        ("sync" : _) -> True
        _ -> False
    corsPolicy :: CorsResourcePolicy
    corsPolicy =
      simpleCorsResourcePolicy
        { corsOrigins = Just ([BSC.pack . show @URI $ envCloudUiOrigin env, BSC.pack . show @URI $ envCloudHomepageOrigin env], True {- allow receiving cookies in requests made from these origins -}),
          corsRequestHeaders = "X-XSRF-TOKEN" : simpleHeaders,
          corsMethods = ["PATCH", "DELETE", "PUT"] <> simpleMethods
        }
    corsMiddleware :: Middleware
    corsMiddleware = cors (const $ Just corsPolicy)

mkReqLogger :: FastLogger -> IO FormattedTime -> Vault.Key (TVar (Map Text Text)) -> IO Middleware
mkReqLogger logger timeCache reqTagsKey = do
  pure $ \app req responder -> do
    -- Stash a request specific TVar in the vault so we can add tags to it during the
    -- request, but can still access it when formatting logs for the request.
    reqTagsV <- STM.newTVarIO mempty
    let newVault = Vault.insert reqTagsKey reqTagsV (Wai.vault req)
    let req' = req {Wai.vault = newVault}
    let hasDebugHeader = any (\(headerName, _) -> headerName == "X-DEBUG") (WAI.requestHeaders req)
    if Deployment.onLocal || hasDebugHeader
      then verboseRequestResponseLogger app req' responder
      else standardReqLoggingMiddleware app req responder
  where
    formatter :: FormattedTime -> Request -> HTTP.Status -> NominalDiffTime -> Map Text Text -> LogStr
    formatter timestamp req (statusCode -> respStatus) responseTimeSeconds reqTags =
      Logging.logFmtFormatter timestamp $
        LogMsg
          { severity = statusSeverity respStatus,
            callstack = Nothing,
            msg = "",
            tags =
              Map.fromList
                [ ("status", tShow respStatus),
                  ("response-time-ms", tShow (realToFrac @NominalDiffTime @Double responseTimeSeconds * 1000)),
                  ("user-agent", maybe "" Text.decodeUtf8 $ requestHeaderUserAgent req),
                  ("method", Text.decodeUtf8 $ requestMethod req),
                  ("path", Text.decodeUtf8 $ rawPathInfo req),
                  ("request-id", Text.decodeUtf8 . fromMaybe "" . Prelude.lookup requestIDHeader . Wai.requestHeaders $ req),
                  ("ip", tShow $ remoteHost req)
                ]
                <> reqTags
          }
    statusSeverity :: Int -> Logging.Severity
    statusSeverity = \case
      status
        | status >= 500 -> Logging.Error
        | status >= 400 -> Logging.UserFault
        | otherwise -> Logging.Info
    standardReqLoggingMiddleware :: Middleware
    standardReqLoggingMiddleware app req responder = do
      t0 <- getCurrentTime
      -- Stash a request specific TVar in the vault so we can add tags to it during the
      -- request, but can still access it when formatting logs for the request.
      reqTagsV <- STM.newTVarIO mempty
      let newVault = Vault.insert reqTagsKey reqTagsV (Wai.vault req)
      let req' = req {Wai.vault = newVault}
      app req' $ \res -> do
        t1 <- getCurrentTime
        date <- liftIO timeCache
        rspRcv <- responder res
        let status = responseStatus res
            duration = t1 `diffUTCTime` t0
        reqTags <- STM.readTVarIO reqTagsV
        liftIO . logger $ formatter date req status duration reqTags
        return rspRcv

requestIDHeader :: HeaderName
requestIDHeader = "X-RequestID"

-- Middleware that generates a random UUID for each request, and modifies both the request and response headers to
-- include it.
requestIDMiddleware :: Middleware
requestIDMiddleware app req responder = do
  reqID <- randomIO @UUID
  let header = (requestIDHeader, Text.encodeUtf8 . tShow $ reqID)
  app
    req {requestHeaders = header : requestHeaders req}
    \response -> responder (WAI.mapResponseHeaders (header :) response)

verboseRequestResponseLogger :: Middleware
verboseRequestResponseLogger app req responder = do
  case requestBodyLength req of
    ChunkedBody -> putStrLn "Request Body: Unknown Size"
    KnownLength wo -> putStrLn $ "Request Body: " <> show wo <> " bytes"
  logStdoutDev app req $ \resp -> do
    BL.putStr "Response Body: "
    case resp of
      WAI.ResponseFile _ _ filePath _ -> putStrLn $ "<ResponseFile: " <> filePath <> ">"
      WAI.ResponseBuilder _ _ builder -> do
        let bytes = Builder.toLazyByteString builder
        putStrLn $ show (BL.length bytes) <> " bytes ("
        BL.putStrLn $ Builder.toLazyByteString builder
        BL.putStrLn ")"
      WAI.ResponseStream {} -> putStrLn "<ResponseStream>"
      WAI.ResponseRaw {} -> putStrLn "<ResponseRaw>"
    responder resp
