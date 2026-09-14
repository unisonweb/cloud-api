{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant bracket" #-}

module Env
  ( withEnv,
  )
where

import Amazonka qualified as AWS
import Amazonka.S3 qualified as S3
import Cloud.Byoc.Env (ClusterEnv (..))
import Cloud.Client.Types
import Cloud.Consul.API (ConsulServiceInstance (..))
import Cloud.Deployment qualified
import Cloud.Deployment qualified as Deployment
import Cloud.Env
import Cloud.Postgres.Env (PostgresEnv (..))
import Cloud.Prelude
import Cloud.Stripe.API (StripeConfig (..))
import Cloud.User.Env (AuthEnv (..))
import Cloud.Utils.Logging qualified as Logging
import Control.Lens ((.~))
import Data.ByteString.Char8 qualified as BS
import Data.Char (toUpper)
import Data.Either.Combinators (maybeToRight)
import Data.HashMap.Strict qualified as HM
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time qualified as Time
import Database.Redis qualified as Redis
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.URI
import Servant.Auth.Server qualified as ServantAuth
import Servant.Client
import Share.JWT qualified as JWT
import Share.OAuth.IdentityProvider.Share
import Share.OAuth.Scopes
import Share.OAuth.Scopes qualified as Scopes
import Share.OAuth.ServiceProvider
import Share.OAuth.Types
import Share.Utils.Deployment qualified as Share.Deployment
import Share.Utils.Servant.Cookies qualified as Cookies
import StmContainers.Map qualified as TMap
import Stripe.Concepts (ApiSecretKey (..), WebhookSecretKey (WebhookSecretKey))
import System.Environment (lookupEnv)
import System.Exit
import System.Log.FastLogger qualified as FL
import System.Log.Raven qualified as Sentry
import System.Log.Raven.Transport.HttpConduit qualified as Sentry
import System.Log.Raven.Types qualified as Sentry
import UnliftIO

withEnv :: (Env () -> IO a) -> IO a
withEnv action = do
  envApiOrigin <- fromEnv "CLOUD_API_ORIGIN" (pure . maybeToEither "Invalid CLOUD_API_ORIGIN" . parseURI)
  envShareOrigin <- fromEnv "SHARE_API_ORIGIN" (pure . maybeToEither "Invalid SHARE_API_ORIGIN" . parseURI)
  envServerPort <- fromEnv "NOMAD_ALLOC_PORT_cloud_http" readPort
  envServerHostname <- fromEnv "NOMAD_HOST_IP_cloud_tcp" readHostname
  envClientPort <- fromEnv "NOMAD_ALLOC_PORT_cloud_tcp" readHostname
  --  redisCert <- fromEnv "CLOUD_REDIS_CERT" readCertStore
  envPostgresConfig <- fromEnv "CLOUD_POSTGRES" (pure . Right . Text.pack)
  postgresConnMax <- fromEnv "CLOUD_POSTGRES_CONN_MAX" (pure . maybeToEither "Invalid CLOUD_POSTGRES_CONN_MAX" . readMaybe)
  shareOAuthClientID <- fromEnv "CLOUD_SHARE_OAUTH_CLIENT_ID" (pure . Right . Text.pack)
  shareOAuthClientSecret <- fromEnv "CLOUD_SHARE_OAUTH_CLIENT_SECRET" (pure . Right . Text.pack)
  hs256Key <- fromEnv "CLOUD_HMAC_KEY" (pure . Right . BS.pack)
  envVaultToken <- fromEnv "VAULT_TOKEN" (pure . Right . Text.pack)
  envEnvironmentsMount <- fromEnv "CLOUD_ENVIRONMENTS_MOUNT" (pure . Right . Text.pack)
  s3Env <-
    if Deployment.onLocal
      then do
        AWS.newEnv AWS.discover
          <&> AWS.configureService
            ( AWS.setEndpoint
                True
                "unison-test-s3"
                9000
                ( S3.defaultService
                    & AWS.service_s3AddressingStyle
                    .~ AWS.S3AddressingStylePath
                )
            )
      else do
        AWS.newEnv AWS.discover
  -- awsCredentialUrl <- fromEnv "CLOUD_AWS_CREDENTIAL_URL" (pure . Right . Text.pack)
  -- AWS.newEnv (AWSAuth.fromContainer awsCredentialUrl)
  cloudServicesBucket <- fromEnv "CLOUD_CLOUD_SERVICE_BUCKET" (pure . Right . S3.BucketName . Text.pack)
  cloudEddsaKey <- fromEnv "CLOUD_EDDSA_KEY" (pure . Right . BS.pack)
  shareEddsaKey <- fromEnv "SHARE_EDDSA_KEY" (pure . Right . BS.pack)
  manager <- newManager tlsManagerSettings
  vaultHost <- fromEnv "VAULT_HOST" parseBaseUrl
  let envVaultClientEnv = mkClientEnv manager vaultHost
  consulHost <- fromEnv "CONSUL_HOST" parseBaseUrl
  let consulClientEnv = mkClientEnv manager consulHost
  zendeskAPIUser <- fromEnv "CLOUD_ZENDESK_API_USER" (pure . Right . BS.pack)
  zendeskAPIToken <- fromEnv "CLOUD_ZENDESK_API_TOKEN" (pure . Right . BS.pack)
  let envZendeskAuth = ServantAuth.BasicAuthData zendeskAPIUser zendeskAPIToken
  envCommitHash <- fromEnv "CLOUD_COMMIT" (pure . Right . Text.pack)
  envMinLogSeverity <-
    lookupEnv "CLOUD_LOG_LEVEL" >>= \case
      Nothing -> pure Logging.Info
      Just (map toUpper -> "DEBUG") -> pure Logging.Debug
      Just (map toUpper -> "INFO") -> pure Logging.Info
      Just (map toUpper -> "ERROR") -> pure Logging.Error
      Just (map toUpper -> "USERERROR") -> pure Logging.UserFault
      Just x -> putStrLn ("Unknown logging level: " <> x) >> exitWith (ExitFailure 1)
  envCloudUiOrigin <- fromEnv "CLOUD_CLOUD_UI_ORIGIN" (pure . maybeToEither "Invalid CLOUD_CLOUD_UI_ORIGIN" . parseURI)
  envCloudHomepageOrigin <- fromEnv "CLOUD_CLOUD_HOMEPAGE_ORIGIN" (pure . maybeToEither "Invalid CLOUD_CLOUD_HOMEPAGE_ORIGIN" . parseURI)
  envSentryService <-
    lookupEnv "CLOUD_SENTRY_DSN" >>= \case
      Nothing -> do
        putStrLn "No Sentry configuration detected."
        Sentry.disabledRaven
      Just dsn -> do
        let defaultTags = HM.fromList [("deployment", show Deployment.deployment), ("service", "share")]
        let sentryTags r = r {Sentry.srTags = defaultTags `HM.union` Sentry.srTags r}
        Sentry.initRaven dsn sentryTags Sentry.sendRecord Sentry.stderrFallback

  --  certs <- fromEnv "CLOUD_CERT" readCerts
  --  privKey <- fromEnv "CLOUD_PRIV_KEY" readPrivKey
  -- privateKey <- fromEnv "CLOUD_PRIV_KEY" readPrivateKey
  envRedisConfig <-
    fromEnv "CLOUD_REDIS" (pure . Redis.parseConnectInfo) <&> \r ->
      let tlsParams
            | Deployment.onLocal = Nothing
            | otherwise = Nothing
       in --                Just
          --                  ( (TLS.defaultParamsClient (Redis.connectHost r) (BS.pack ""))
          --                      { TLS.clientSupported = def {TLS.supportedCiphers = ciphersuite_strong},
          --                        TLS.clientShared = def {TLS.sharedCAStore = redisCert}
          --                      }
          --                  )
          r {Redis.connectTLSParams = tlsParams}

  let shareDeployment = case Cloud.Deployment.deployment of
        Cloud.Deployment.Production -> Share.Deployment.Production
        Cloud.Deployment.Staging -> Share.Deployment.Staging
        Cloud.Deployment.Local -> Share.Deployment.Local
  let envIdentityProvider = shareIdentityProviderForDeployment shareDeployment
  let serviceAudience = envApiOrigin
  let acceptedAudiences = Set.fromList [envApiOrigin, envShareOrigin]
  let shareIssuer = if Deployment.onLocal then envApiOrigin else envShareOrigin
  let acceptedIssuers = Set.fromList [envApiOrigin, shareIssuer]
  let cookieDefaultTTL = Just $ Time.secondsToDiffTime (60 * 60 * 24 * 30) -- 1 month
  let envSessionCookieName = "cloud-session"
  let envCookieSettings = Cookies.defaultCookieSettings Deployment.onLocal cookieDefaultTTL
  let legacyKey = JWT.KeyDescription {JWT.key = hs256Key, JWT.alg = JWT.HS256}
  let cloudEddsaKeyDesc = JWT.KeyDescription {JWT.key = cloudEddsaKey, JWT.alg = JWT.Ed25519}
  let shareEddsaKeyDesc = JWT.KeyDescription {JWT.key = shareEddsaKey, JWT.alg = JWT.Ed25519}
  let verificationKeys = Set.fromList [cloudEddsaKeyDesc, shareEddsaKeyDesc, legacyKey]
  let signingKey = cloudEddsaKeyDesc
  envJwtSettings <- case JWT.defaultJWTSettings signingKey (Just legacyKey) verificationKeys acceptedAudiences acceptedIssuers of
    Left cryptoError -> throwIO cryptoError
    Right settings -> pure settings
  -- if Deployment.onLocal then
  --   ServantAuth.defaultCookieSettings {

  --     ServantAuth.cookieMaxAge = Just (realToFrac $ 30000 * nominalDay),
  --     ServantAuth.cookieIsSecure = if Deployment.onLocal then ServantAuth.NotSecure else ServantAuth.Secure,
  --     ServantAuth.cookieDomain =
  --       if Deployment.onLocal
  --         then Nothing
  --         else Just . BS.pack $ show envCookieDomain,
  --     ServantAuth.cookieXsrfSetting =
  --       -- Servant's XSRF cookies change the token with every request.
  --       -- Not only is this a big pain to handle in the ui; but it also means
  --       -- that browsing with multiple tabs might cause some POST requests to fail.
  --       -- We should eventually find some compromise which allows us to turn this back
  --       -- on, but for now we've got strict CORS headers anyways, so users on a
  --       -- sufficiently modern browser should be safe, even without CSRF tokens.
  --       Nothing
  --   }
  -- else
  --     defaultCookieSettings envCookieDomain Deployment.onLocal

  (envEmailClientEnv, envEmailServiceToken) <- case Deployment.deployment of
    Deployment.Production -> do
      emailServiceURL <- fromEnv "CLOUD_EMAIL_SERVICE_URL" (pure . Right)
      clientEnv <- parseBaseUrl emailServiceURL >>= exitErrOnLeft <&> mkClientEnv manager
      serviceToken <- fromEnv "CLOUD_EMAIL_SERVICE_TOKEN" (pure . Right . Text.pack)
      pure (Just clientEnv, Just serviceToken)
    Deployment.Staging -> pure (Nothing, Nothing)
    Deployment.Local -> pure (Nothing, Nothing)

  envRedisConnection <- Redis.checkedConnect envRedisConfig
  -- Set some very conservative defaults
  let pgConnectionAcquisitionTimeout = Time.secondsToDiffTime 60 -- 1 minute
  -- Helps prevent leaking connections if they somehow get forgotten about.
  let pgConnectionMaxIdleTime = Time.secondsToDiffTime (60 * 5) -- 5 minutes
  -- Limiting max lifetime helps cycle connections which may have accumulated memory cruft.
  let pgConnectionMaxLifetime = Time.secondsToDiffTime (60 * 60) -- 1 hour
  let pgSettings = Pool.settings [Pool.staticConnectionSettings (Text.encodeUtf8 envPostgresConfig), Pool.size postgresConnMax, Pool.acquisitionTimeout pgConnectionAcquisitionTimeout, Pool.idlenessTimeout pgConnectionMaxIdleTime, Pool.agingTimeout pgConnectionMaxLifetime]
  pgConnectionPool <- Pool.acquire pgSettings

  envClients <- newTVarIO mempty
  envTimeCache <- FL.newTimeCache "%a, %d %b %Y %H:%M:%S %Z" -- RFC1123, e.g. Mon, 02 Jan 2006 15:04:05 MST
  nimbusHostStr <- lookupEnv "CLOUD_NIMBUS_HOST"
  let nimbusHost = (\host -> ConsulServiceInstance host (Just 17010) mempty []) <$> nimbusHostStr
  let nimbusClientServiceName = if Deployment.deployment == Deployment.Staging then "nimbus-client-staging" else "nimbus-client"
  let nimbusHttpServiceName = if Deployment.deployment == Deployment.Staging then "byoc-nimbus-http-staging" else "byoc-nimbus-http"
  let envNimbusConfig = NimbusConfig consulHost nimbusClientServiceName nimbusHttpServiceName nimbusHost

  let envSpConfig =
        ServiceProviderConfig
          { cookieSettings = envCookieSettings,
            jwtSettings = envJwtSettings,
            redirectAfterLogout = envCloudUiOrigin,
            oauthClientID = OAuthClientId shareOAuthClientID,
            oauthClientSecret = OAuthClientSecret shareOAuthClientSecret,
            scopes = Scopes (Set.fromList [Scopes.OpenId, Scopes.Cloud]),
            baseServiceURI = envApiOrigin,
            serviceAudience,
            sessionCookieKey = envSessionCookieName
          }
  envStripeConfig <- do
    stripeApiSecretKey <- fromEnv "CLOUD_STRIPE_API_SECRET_KEY" (pure . Right . ApiSecretKey . BS.pack)
    stripeClientEnv <- parseBaseUrl "https://api.stripe.com" >>= exitErrOnLeft <&> mkClientEnv manager
    stripeWebhookSecretKey <- fromEnv "CLOUD_STRIPE_WEBHOOK_SECRET_KEY" (pure . Right . WebhookSecretKey . BS.pack)
    pure StripeConfig {..}
  let envRequestCtx = ()
  -- We use a zero-width-space to separate log-lines on ingestion, this allows us to use newlines for
  -- formatting, but without affecting log-grouping.
  let zeroWidthSpace = "\x200B"
  envClusterHosts <- TMap.newIO
  -- let servicesUri = fromJust $ parseURI (servicesScheme <> "://" <> servicesHost <> ":" <> servicesPort)
  -- let clusterServiceURIScheme = case Deployment.deployment of
  --                                         Deployment.Production -> HostBased servicesUri
  --                                         Deployment.Staging -> HostBased servicesUri
  --                                         Deployment.Local -> LocalHostBased servicesUri

  envClusters <- TMap.newIO
  envAPISuffix <- fromEnv "CLOUD_API_SUFFIX" (pure . Right . Text.pack)

  let postgresEnv = PostgresEnv {..}
  let clusterEnv = ClusterEnv {..}
  let authEnv = AuthEnv {..}

  FL.withFastLogger (FL.LogStderr FL.defaultBufSize) $ \logger -> do
    action $ Env {envLogger = (logger . (\msg -> zeroWidthSpace <> msg <> "\n")), ..}
  where
    readHostname h = pure $ Right h
    readPort p = pure $ maybeToRight "CLOUD_PORT was not a number" (readMaybe p)

    parseBaseUrl str = do
      u <- Servant.Client.parseBaseUrl str
      pure $ Right u

fromEnv :: String -> (String -> IO (Either String a)) -> IO a
fromEnv var from = do
  val <- lookupEnv var
  case val of
    Nothing -> exitErr (Left "Variable not set")
    Just val' -> do
      v <- from val'
      exitErr v
  where
    exitErr = exitErrOnLeft . first (\err -> "'" <> var <> "': " <> err)

exitErrOnLeft :: Either String a -> IO a
exitErrOnLeft (Right a) = pure a
exitErrOnLeft (Left err) = putStrLn ("Error: " <> err) >> exitWith (ExitFailure 1)
