{-# LANGUAGE RecordWildCards #-}

module Cloud.Errors
  ( ErrorID (..),
    InternalServerError (..),
    internalServerError,
    reportError,
    respondError,
    ToServerError (..),
    redirectToRoot,
    leftToErrorResponse,
  )
where

import Cloud.Deployment qualified as Deployment
import Cloud.Prelude
import Cloud.Utils.Logging
import Cloud.Utils.Logging qualified as Logging
import Cloud.Stripe.API (StripeError (..))
import Cloud.Web.App
import Control.Monad.Reader
import Crypto.JWT hiding (Error)
import Crypto.JWT qualified as JWT
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as BSC
import Data.ByteString.Lazy qualified as BL
import Data.HashMap.Lazy qualified as HM
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Share.OAuth.Errors
import Share.OAuth.Scopes
import Share.OAuth.Types (AuthenticationRequest (..), RedirectReceiverErr (..))
import Share.Utils.Show (tShow)
import Share.Utils.URI
import GHC.Stack qualified as Stack
import Servant
import System.Log.Raven qualified as Sentry
import System.Log.Raven.Types qualified as Sentry
import UnliftIO
import Cloud.Env (Env(..))

newtype ErrorID = ErrorID Text
  deriving stock (Show)

class ToServerError e where
  toServerError :: e -> (ErrorID, ServerError)

instance ToServerError RedirectReceiverErr where
  toServerError = \case
    MismatchedState {} -> (ErrorID "oauth:mismatched-state", err400 {errBody = "Mismatched state parameter"})
    MissingOrExpiredPendingSession {} -> (ErrorID "oauth:no-pending-session", err404 {errBody = "Auth session has expired or is missing. Please try again."})
    MissingCode {} -> (ErrorID "oauth:missing-code", err404 {errBody = "'code' parameter is required"})
    MissingState {} -> (ErrorID "oauth:missing-code", err404 {errBody = "'state' parameter is required"})
    ErrorFromIdentityProvider {} -> (ErrorID "oauth:identity-provider-error", err400 {errBody = "Error from identity provider"})
    FailedToCreateSession {} -> (ErrorID "oauth:failed-to-create-session", err500 {errBody = "Failed to create session"})
    InvalidJWTFromIDP {} -> (ErrorID "oauth:invalid-jwt-from-idp", err400 {errBody = "Invalid JWT from identity provider"})

instance ToServerError OAuth2Error where
  toServerError err = case err of
    CodeMissingOrExpired {} -> (ErrorID "oauth:code-missing", err404 {errBody = "Session for code is missing or expired."})
    MismatchedClientId {} -> (ErrorID "oauth:mismatched-client-id", err400 {errBody = "Mismatched client_id"})
    MismatchedRedirectURI {} -> (ErrorID "oauth:mismatched-redirect-uri", err400 {errBody = "Mismatched redirect_uri"})
    UnregisteredRedirectURI {} -> (ErrorID "oauth:unregistered-redirect-uri", err400 {errBody = "Unregistered redirect_uri"})
    MismatchedClientSecret {} -> (ErrorID "oauth:mismatched-client-secret", err400 {errBody = "Mismatched client_secret"})
    UnknownClient {} -> (ErrorID "oauth:unknown-client", err400 {errBody = "Unregistered client_id"})
    OpenIDScopeRequired (AuthenticationRequest {..}) ->
      toServerError
        ( OAuth2ErrorRedirect
            { errCode = InvalidScope,
              errDescription = "openid must be a requested scope",
              state = Just state,
              redirectURI = Just redirectURI
            }
        )
    PKCEChallengeFailure -> (ErrorID "oauth:pkce-challenge-failure", err400 {errBody = "PKCE challenge failure."})

instance ToServerError OAuth2ErrorRedirect where
  toServerError (OAuth2ErrorRedirect {redirectURI = mayRedirectURI, errCode, errDescription, state = mayState}) =
    case mayRedirectURI of
      Nothing ->
        (ErrorID $ "oauth:" <> tShow errCode, err400 {errBody = BL.fromStrict $ Text.encodeUtf8 errDescription})
      Just (URIParam redirectURI) ->
        let errURI =
              redirectURI
                & addQueryParam "error" errCode
                & addQueryParam "error_description" errDescription
                & maybe id (addQueryParam "state") mayState
         in (ErrorID $ "oauth:" <> tShow errCode, err302 {errHeaders = [("Location", BSC.pack $ show errURI)]})

-- | Logs the error with a call stack, but doesn't abort the request or render an error to the client.
reportError_ :: (MonadIO m, HasCallStack, Loggable e, MonadLogger m) => Env ctx -> HM.HashMap String String -> HM.HashMap String Aeson.Value -> Text -> e -> m ()
reportError_ (Env {envSentryService = sentryService, envCommitHash}) tags extraTags errID e = do
  let errLog = withTag ("error-id", errID) $ toLog e
  logMsg (withSeverity Error errLog)
  let addSentryData sr =
        sr
          { Sentry.srEnvironment = Just (show Deployment.deployment),
            Sentry.srCulprit = Just (Text.unpack errID),
            Sentry.srLevel = Sentry.Error,
            Sentry.srTags =
              tags
                -- & HM.insert "host" (show @URI host)
                & HM.insert "errorID" (Text.unpack errID)
                & HM.insert "commitHash" (Text.unpack envCommitHash),
            Sentry.srExtra =
              extraTags
                <> (HM.fromList . fmap (bimap Text.unpack Aeson.String) . Map.toList $ Logging.tags errLog)
                <> HM.singleton "callstack" (Aeson.String . Text.pack $ Stack.prettyCallStack Stack.callStack)
          }
  liftIO $ Sentry.register sentryService "errors" Sentry.Error (Text.unpack $ Logging.msg errLog) addSentryData

-- | Logs the error with a call stack then aborts the request and renders the corresponding ServerError to the client.
respondError :: (HasCallStack, ToServerError e, Loggable e) => e -> WebApp a
respondError e = do
  let (_, serverErr) = toServerError e
  reportError e
  UnliftIO.throwIO serverErr

leftToErrorResponse :: (HasCallStack, ToServerError e, Loggable e) => Either e a -> WebApp a
leftToErrorResponse = either respondError pure

-- -- | Logs the error with a call stack then aborts the request and renders the corresponding ServerError to the client.
-- respondClientError :: (HasCallStack, Loggable e) => Error -> CloudApp a
-- respondClientError e = do
--   let (_, serverErr) = toServerError e
--   logMsg e
--   UnliftIO.throwIO serverErr

-- | Logs the error with a call stack, but doesn't abort the request or render an error to the client.
reportError :: (HasCallStack, ToServerError e, Loggable e) => e -> WebApp ()
reportError e = do
  let (ErrorID errID, serverErr) = toServerError e
  env <- ask
  RequestCtx {pathInfo, rawURI} <- asks envRequestCtx
  reqTags <- getTags
  let errLog = withTag ("error-id", errID) $ toLog e
  let coreTags = HM.singleton "path" (Text.unpack $ "/" <> Text.intercalate "/" pathInfo)
  let extraTags =
        HM.fromList . fmap (bimap Text.unpack Aeson.String) . Map.toList $
          reqTags <> maybe mempty (Map.singleton "url" . tShow @URI) rawURI
  case errHTTPCode serverErr of
    status
      | status >= 500 -> do
          reportError_ env coreTags extraTags errID e
          logMsg (withSeverity Error errLog)
      | status >= 400 ->
          logMsg (withSeverity UserFault errLog)
      | otherwise -> logMsg (withSeverity Info errLog)
  pure ()

data InternalServerError err = InternalServerError
  { errorId :: Text,
    err :: err
  }
  deriving stock (Show)

instance (Show err) => Loggable (InternalServerError err) where
  toLog = withSeverity Error . showLog

internalServerError :: ServerError
internalServerError = err500 {errBody = "Something went wrong, please try again later"}

redirectToRoot :: WebApp ServerError
redirectToRoot = do
  Env { envCloudUiOrigin } <- ask
  pure $ err302 {errHeaders = [("Location",  BSC.pack $ show envCloudUiOrigin)]}

instance ToServerError (InternalServerError a) where
  toServerError InternalServerError {errorId} = (ErrorID errorId, internalServerError)

data AuthenticationErr
  = JWTErr JWT.JWTError
  | TextIsNotAJWT
  | CustomError Text
  | MissingScopes Scopes
  deriving stock (Show)

instance Logging.Loggable AuthenticationErr where
  toLog = Logging.withSeverity Logging.UserFault . Logging.textLog . tShow

instance ToServerError AuthenticationErr where
  toServerError err =
    let (errID, serverErr) = case err of
          TextIsNotAJWT -> (ErrorID "authn:not-a-jwt", err401)
          CustomError {} -> (ErrorID "authn:custom", err401)
          MissingScopes {} -> (ErrorID "authn:missing-scopes", err403)
          JWTErr e -> case e of
            JWSError _ -> (ErrorID "authn:jwt:jws-error", err401)
            JWTClaimsSetDecodeError {} -> (ErrorID "authn:jwt:claims-set-decode-error", err401)
            JWTExpired -> (ErrorID "authn:jwt:expired", err401)
            JWTNotYetValid -> (ErrorID "authn:jwt:not-yet-valid", err401)
            JWTNotInIssuer -> (ErrorID "authn:jwt:not-in-issuer", err401)
            JWTNotInAudience -> (ErrorID "authn:jwt:not-in-audience", err401)
            JWTIssuedAtFuture -> (ErrorID "authn:jwt:issued-at-future", err401)
     in (errID, serverErr {errBody = BL.fromStrict . Text.encodeUtf8 $ authErrMsg err})

authErrMsg :: AuthenticationErr -> Text
authErrMsg = \case
  TextIsNotAJWT -> "Token is not a valid JWT"
  CustomError txt -> txt
  MissingScopes scopes -> "The following scopes are required: " <> Text.pack (show scopes)
  JWTErr e -> case e of
    JWSError _ -> "Invalid Token Signature"
    JWTClaimsSetDecodeError e -> "Invalid Token Claims, " <> Text.pack e
    JWTExpired -> "Token Expired"
    JWTNotYetValid -> "Token used before valid"
    JWTNotInIssuer -> "Invalid Issuer"
    JWTNotInAudience -> "Invalid Audience"
    JWTIssuedAtFuture -> "Token used before issued"

instance ToServerError StripeError where
  toServerError :: StripeError -> (ErrorID, ServerError)
  toServerError (StripeError _) = (ErrorID "stripe-error", err500 {errBody = "Error communicating with payment processor. You may want to try again."})
