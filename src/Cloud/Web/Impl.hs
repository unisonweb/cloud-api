{-# LANGUAGE DataKinds #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

module Cloud.Web.Impl where

import Cloud.Byoc.Env (Cluster (..), ClusterConfig(..), ClusterId, defaultClusterId)
import Cloud.Byoc.Impl (clusterByHost, clusterById, clusterServiceURI)
import Cloud.Byoc.Impl qualified as Byoc
import Cloud.Daemon.Impl qualified as Daemon
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Deployment.Impl (deploymentsV1Endpoint, deploymentsV2Endpoint)
import Cloud.Web.Types
    ( DeploymentDetails(deploymentDetailsHash),
      EnvironmentId,
      IncompleteSubscription(..),
      StripeSignature(..),
      WithRawBody(..),
      CloudApiHost )
import Cloud.Domain.Impl qualified as Domain
import Cloud.Email.Client
  ( Email (Email),
    registerEmail,
  )
import Cloud.Env (Env (..))
import Cloud.Environment.Types
import Cloud.Errors (redirectToRoot, respondError)
import Cloud.Log.Types
import Cloud.Postgres qualified as PG
import Cloud.Postgres.App (postgresM)
import Cloud.Postgres.Ops (saveStripeEvent)
import Cloud.Postgres.Ops qualified as PGO
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.Service.Impl (servicesV1Endpoint, servicesV2Endpoint)
import Cloud.Service.Types
  ( ServiceAssignment,
    ServiceDetail,
    ServiceId,
    ServiceName,
    ServiceURI (..),
  )
import Cloud.Storage.Impl (storageEndpoint)
import Cloud.Stripe.API (StripeConfig (..))
import Cloud.Stripe.Subscriptions (SubscriptionWithClientSecret (SubscriptionWithClientSecret))
import Cloud.Stripe.Subscriptions qualified as Subscription (Subscription (subscriptionId))
import Cloud.Stripe.WebhookHandlers (handleEvent)
import Cloud.User.Env (AuthEnv (..))
import Cloud.User.Impl
import Cloud.User.Types (User (..))
import Cloud.User.UserHandle (UserHandle (..))
import Cloud.Web.Util (validDNSName)
import Cloud.Web.API (CreateSubscription (..))
import Cloud.Web.API qualified as Cloud
import Cloud.Web.App (WebApp, isCloudUILink)
import Cloud.Web.Cluster.Impl qualified as Cluster
import Cloud.Web.Environment qualified as Envs
import Cloud.Web.Errors
import Cloud.Web.Internal.Impl qualified as Internal
import Cloud.Web.Local.Impl qualified as Local
import Cloud.Web.Loki (nsFromUTCTime, servicesLogQuery, userLogQuery)
import Control.Monad.Reader (MonadTrans (lift), asks)
import Control.Monad.Trans.Maybe (MaybeT (..))
import Data.Aeson (Result (..), Value, fromJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Maybe (fromJust)
import Data.Text qualified as Text
import Hasql.Interpolate (Json (..))
import Network.URI qualified as URI
import Servant
import Share.OAuth.IdentityProvider.Types (IdentityProviderConfig)
import Share.OAuth.ServiceProvider (ServiceProviderConfig (..), SessionCallbackData (..))
import Share.OAuth.ServiceProvider qualified as Auth
import Share.OAuth.Session (Session (..))
import Share.OAuth.Types hiding (AuthenticationRequest (..), OAuthClientConfig (..))
import Share.Utils.Servant.Cookies qualified as Cookies
import Share.Utils.Show (tShow)
import Share.Utils.URI (URIParam)
import Stripe.Signature (isSigValid)
import UnliftIO (throwIO)

-- | A helper function for constructing URIs from constant strings.
unsafeURI :: (HasCallStack) => String -> URI.URI
unsafeURI = fromJust . URI.parseURI

data EnrollInCloud = None | Free | Paid
  deriving (Generic, Eq, Show)

instance Aeson.FromJSON EnrollInCloud where
  parseJSON = Aeson.withObject "EnrollInCloud" $ \o -> do
    enrollInCloud <- o Aeson..: "enrollInCloud"
    case enrollInCloud of
      "None" -> pure None
      "Free" -> pure Free
      "Paid" -> pure Paid
      _ -> fail $ "Invalid EnrollInCloud value: " <> Text.unpack enrollInCloud

instance Aeson.ToJSON EnrollInCloud where
  toJSON e =
    Aeson.object
      [ "enrollInCloud" Aeson..= show e
      ]

-- | A session callback which redirects the user to either an error page
-- or the authed handler endpoint depending on whether the oauth2 login succeeds.
mySessionCallback :: Either RedirectReceiverErr SessionCallbackData -> WebApp URI
mySessionCallback (Left _err) = pure . fromJust . URI.parseURI $ "https://app.unison.cloud/error?appError=UnspecifiedError" -- <> show err
mySessionCallback (Right (SessionCallbackData {returnToURI = unvalidatedReturnToURI, additionalData, session = Session {sessionUserId}})) = do
  let enrollInCloud = fromMaybe None $ do
        val <- additionalData
        case Aeson.fromJSON val of
          Aeson.Success enroll -> Just enroll
          Aeson.Error {} -> Nothing

  when (enrollInCloud == Free) $ do
    user <- PGO.expectUserById sessionUserId

    registerEmail (Email (user_email user) Nothing)
    PGO.addToFreeTier sessionUserId
  when (enrollInCloud == Paid) $ do
    user <- PGO.expectUserById sessionUserId

    registerEmail (Email (user_email user) Nothing)
    PGO.addToPaidTier user

  appURI <- asks envCloudUiOrigin
  mayReturnToURI <- runMaybeT do
    uri <- MaybeT . pure $ unvalidatedReturnToURI
    isValid <- lift $ isCloudUILink uri
    guard isValid
    pure uri
  pure $ fromMaybe appURI mayReturnToURI

server :: Env () -> ServerT Cloud.API WebApp
server Env {authEnv = AuthEnv {envSpConfig, envIdentityProvider}} =
  serviceProviderEndpoints
    :<|> ( accountEndpoints
             :<|> servicesV1Endpoint
             :<|> deploymentsV1Endpoint
             :<|> environment
             :<|> logs
             :<|> storageEndpoint
             :<|> userV1
         )
    :<|> ( accountEndpoints
             :<|> acceptTermsEndpoint
             :<|> unacceptTermsEndpoint
             :<|> servicesV2Endpoint
             :<|> deploymentsV2Endpoint
             :<|> environment
             :<|> logs
             :<|> storageEndpoint
             :<|> userV2
             :<|> stripeWebhookEndpoint
             :<|> Daemon.server
             :<|> Domain.server
             :<|> Byoc.server
             :<|> Cluster.server
         )
    :<|> Internal.server
    :<|> Local.server
    :<|> enrollFreeTierEndpoint envIdentityProvider envSpConfig
    :<|> jwksEndpoint
  where
    serviceProviderEndpoints = Auth.serviceProviderServer envIdentityProvider envSpConfig mySessionCallback

    accountEndpoints = userAccountInfo :<|> createSubscriptionEndpoint

    environment =
      createEnvironmentEndpoint
        :<|> setEnvironmentValueEndpoint
        :<|> deleteEnvironmentValueEndpoint
        :<|> deleteEnvironmentEndpoint
        :<|> listEnvironmentsEndpoint

    userV1 =
      userGetServiceEndpoint
        :<|> userGetServiceHistoryEnpoint
        :<|> currentDeploymentByServiceName
        :<|> userUnassignServiceEndpoint
        :<|> userAssignServiceEndpointV1
        :<|> userDeleteServiceEndpoint
        :<|> userServiceLogsEndpoint

    userV2 =
      userGetServiceEndpoint
        :<|> userGetServiceHistoryEnpoint
        :<|> currentDeploymentByServiceName
        :<|> userUnassignServiceEndpoint
        :<|> userAssignServiceEndpointV2
        :<|> userDeleteServiceEndpoint
        :<|> userServiceLogsEndpoint

    logs = logsByUserEndpoint :<|> logsByDeployementEndpoint :<|> logsByServiceEndpoint

sbtbEndpoint :: UserId -> WebApp NoContent
sbtbEndpoint userId = do
  PGO.addToFreeTier userId
  e <- redirectToRoot
  UnliftIO.throwIO e

enrollFreeTierEndpoint ::
  IdentityProviderConfig ->
  ServiceProviderConfig ->
  Maybe URIParam ->
  WebApp
    ( Headers
        '[Header "Set-Cookie" Cookies.SetCookie, Header "Location" String]
        NoContent
    )
enrollFreeTierEndpoint envIdentityProvider envSpConfig returnTo = do
  Auth.loginEndpointWithData envIdentityProvider envSpConfig (Just Free) returnTo

enrollPaidTierEndpoint ::
  IdentityProviderConfig ->
  ServiceProviderConfig ->
  Maybe URIParam ->
  WebApp
    ( Headers
        '[Header "Set-Cookie" Cookies.SetCookie, Header "Location" String]
        NoContent
    )
enrollPaidTierEndpoint envIdentityProvider envSpConfig returnTo = do
  Auth.loginEndpointWithData envIdentityProvider envSpConfig (Just Paid) returnTo

acceptTermsEndpoint :: UserId -> WebApp NoContent
acceptTermsEndpoint userId = do
  PGO.acceptTerms userId
  pure NoContent

unacceptTermsEndpoint :: UserId -> WebApp NoContent
unacceptTermsEndpoint userId = do
  PGO.unacceptTerms userId
  pure NoContent

{-
                        ▄████▄   ██▄████▄  ██▄  ▄██
                       ██▄▄▄▄██  ██▀   ██   ██  ██
                       ██▀▀▀▀▀▀  ██    ██   ▀█▄▄█▀
                       ▀██▄▄▄▄█  ██    ██    ████
                         ▀▀▀▀▀   ▀▀    ▀▀     ▀▀
-}

setEnvironmentValueEndpoint :: UserId -> EnvironmentId -> Text -> Text -> WebApp NoContent
setEnvironmentValueEndpoint uid envId name value = do
  postgresM $ PG.runTransaction $ Q.verifyEnvironmentAccess defaultClusterId uid envId
  Envs.setEnvironmentVariable envId name value
  pure NoContent

deleteEnvironmentValueEndpoint :: UserId -> EnvironmentId -> Text -> WebApp NoContent
deleteEnvironmentValueEndpoint uid envId name = do
  postgresM $ PG.runTransaction $ Q.verifyEnvironmentAccess defaultClusterId uid envId
  Envs.deleteEnvironmentVariable envId name
  pure NoContent

-- TODO can this just take a `ServiceName`?
createEnvironmentEndpoint :: UserId -> Text -> WebApp EnvironmentId
createEnvironmentEndpoint uid name' = do
  name <- validDNSName name'
  envId <- PGO.createEnvironment defaultClusterId uid uid name
  Envs.createEnvironment envId name
  pure envId

deleteEnvironmentEndpoint :: UserId -> EnvironmentId -> WebApp NoContent
deleteEnvironmentEndpoint uid envId = do
  PGO.deleteEnvironment defaultClusterId uid envId
  Envs.deleteEnvironment envId
  pure NoContent

listEnvironmentsEndpoint :: UserId -> CloudApiHost -> WebApp [UserEnvironment]
listEnvironmentsEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listEnvironments clusterId uid

{-
                 ▄▄▄▄
                 ▀▀██
                   ██       ▄████▄    ▄███▄██  ▄▄█████▄
                   ██      ██▀  ▀██  ██▀  ▀██  ██▄▄▄▄ ▀
                   ██      ██    ██  ██    ██   ▀▀▀▀██▄
                   ██▄▄▄   ▀██▄▄██▀  ▀██▄▄███  █▄▄▄▄▄██
                    ▀▀▀▀     ▀▀▀▀     ▄▀▀▀ ██   ▀▀▀▀▀▀
                                      ▀████▀▀
-}

checkLogString :: Text -> WebApp ()
checkLogString s = do
  when (Text.length s > 100) $ respondError $ InvalidSearchString s
  when (Text.isInfixOf "\\" s) $ respondError $ InvalidSearchString s
  when (Text.isInfixOf "\\" s) $ respondError $ InvalidSearchString s

logsByUserEndpoint ::
  UserId ->
  CloudApiHost ->
  Maybe Text ->
  Maybe Int ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  WebApp LogQueryResult
logsByUserEndpoint uid host search limit start end direction = do
  clusterConfig <- PGO.clusterConfigByHostname host
  cluster <- clusterById clusterConfig.clusterId
  userLogQuery cluster clusterConfig uid search limit start end direction

logsByDeployementEndpoint ::
  UserId ->
  CloudApiHost ->
  DeploymentHash ->
  Maybe Text ->
  Maybe Int ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  WebApp LogQueryResult
logsByDeployementEndpoint uid host deploymentHash search limit start end direction = do
  clusterConfig <- PGO.clusterConfigByHostname host
  cluster <- clusterById clusterConfig.clusterId
  postgresM $ PG.runTransaction $ Q.verifyDeploymentOwnership cluster.clusterId uid deploymentHash
  start' <- case start of
    Nothing -> fmap (tShow . nsFromUTCTime) <$> PGO.getDeploymentLogTime cluster.clusterId uid deploymentHash
    s -> pure s
  servicesLogQuery cluster clusterConfig uid deploymentHash search limit start' end direction

logsByServiceEndpoint ::
  UserId ->
  CloudApiHost ->
  ServiceId ->
  Maybe Text ->
  Maybe Int ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  WebApp LogQueryResult
logsByServiceEndpoint uid host service search limit start end direction = do
  clusterConfig <- PGO.clusterConfigByHostname host
  cluster <- clusterById clusterConfig.clusterId
  postgresM $ PG.runTransaction $ Q.verifyServiceOwnership cluster.clusterId uid service
  current <- PGO.getCurrentDeployment cluster.clusterId uid service
  case current of
    Nothing -> pure $ LogQueryResult 0 []
    Just deployment -> do
      let hash = deploymentDetailsHash deployment
      start' <- case start of
        Nothing -> fmap (tShow . nsFromUTCTime) <$> PGO.getDeploymentLogTime cluster.clusterId uid hash
        s -> pure s
      -- end' <- case end of
      --   Nothing -> do
      --     t <- liftIO getPOSIXTime
      --     pure $ Just $ NanosecondUnixEpoch (1000 * round t)
      --   e -> pure e
      servicesLogQuery cluster clusterConfig uid hash search limit start' end direction

userServiceLogsEndpoint :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> Maybe Text -> Maybe Int -> Maybe Text -> Maybe Text -> Maybe Text -> WebApp LogQueryResult
userServiceLogsEndpoint uid host handle serviceName search limit start end direction = do
  clusterConfig <- PGO.clusterConfigByHostname host
  cluster <- clusterById clusterConfig.clusterId
  maybeSid <- postgresM $ PG.runTransaction $ Q.verifyServiceName cluster.clusterId uid handle serviceName
  case maybeSid of
    Nothing -> respondError $ ServiceNameNotFound serviceName
    Just sid -> do
      current <- PGO.getCurrentDeployment cluster.clusterId uid sid
      case current of
        Nothing -> pure $ LogQueryResult 0 []
        Just deployment -> do
          let hash = deploymentDetailsHash deployment
          start' <- case start of
            Nothing -> fmap (tShow . nsFromUTCTime) <$> PGO.getDeploymentLogTime cluster.clusterId uid hash
            s -> pure s
          -- end' <- case end of
          --   Nothing -> do
          --     t <- liftIO getPOSIXTime
          --     pure $ Just $ NanosecondUnixEpoch (1000 * round t)
          --   e -> pure e
          servicesLogQuery cluster clusterConfig uid hash search limit start' end direction

{-
                         ██
             ▄▄█████▄  ███████    ▄████▄    ██▄████   ▄█████▄   ▄███▄██   ▄████▄
             ██▄▄▄▄ ▀    ██      ██▀  ▀██   ██▀       ▀ ▄▄▄██  ██▀  ▀██  ██▄▄▄▄██
              ▀▀▀▀██▄    ██      ██    ██   ██       ▄██▀▀▀██  ██    ██  ██▀▀▀▀▀▀
             █▄▄▄▄▄██    ██▄▄▄   ▀██▄▄██▀   ██       ██▄▄▄███  ▀██▄▄███  ▀██▄▄▄▄█
              ▀▀▀▀▀▀      ▀▀▀▀     ▀▀▀▀     ▀▀        ▀▀▀▀ ▀▀   ▄▀▀▀ ██    ▀▀▀▀▀
                                                                ▀████▀▀
-}

userGetServiceEndpoint :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> WebApp (Maybe ServiceDetail)
userGetServiceEndpoint uid host handle serviceName = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getServiceByName clusterId uid handle serviceName

currentDeploymentByServiceName :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> WebApp (Maybe DeploymentDetails)
currentDeploymentByServiceName uid host handle serviceName = do
  clusterId <- PGO.clusterIdByHost host
  PGO.currentDeploymentByServiceName clusterId uid handle serviceName

userUnassignServiceEndpoint :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> WebApp NoContent
userUnassignServiceEndpoint uid host handle serviceName = do
  cluster <- clusterByHost host
  PGO.userUnassignServiceByName cluster uid handle serviceName
  pure NoContent

userAssignServiceEndpoint_ :: ClusterId -> UserId -> UserHandle -> ServiceName -> DeploymentHash -> WebApp NoContent
userAssignServiceEndpoint_ cluster uid handle serviceName hash = do
  PGO.userAssignServiceByName cluster uid handle serviceName hash
  pure NoContent

userAssignServiceEndpointV1 :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> DeploymentHash -> WebApp NoContent
userAssignServiceEndpointV1 uid host handle service hash = do
  cluster <- clusterByHost host
  userAssignServiceEndpoint_ cluster uid handle service hash

userAssignServiceEndpointV2 :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> DeploymentHash -> WebApp ServiceURI
userAssignServiceEndpointV2 session host handle serviceName deployment = do
  clusterConfig <- PGO.clusterConfigByHostname host
  _ <- userAssignServiceEndpoint_ clusterConfig.clusterId session handle serviceName deployment
  ServiceURI <$> clusterServiceURI clusterConfig handle serviceName

userDeleteServiceEndpoint :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> WebApp NoContent
userDeleteServiceEndpoint uid host handle serviceName = do
  cluster <- clusterByHost host
  PGO.userDeleteServiceByName cluster uid handle serviceName
  pure NoContent

userGetServiceHistoryEnpoint :: UserId -> CloudApiHost -> UserHandle -> ServiceName -> WebApp [ServiceAssignment]
userGetServiceHistoryEnpoint uid host handle serviceName = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getServiceHistoryByName clusterId uid handle serviceName

-- Stripe

-- We use `WithRawBody Value` instead of `WithRawBody Stripe.Event` because we
-- want to keep the raw JSON to store in Postgres.
-- See https://stripe.com/docs/billing/subscriptions/webhooks
stripeWebhookEndpoint :: StripeSignature -> WithRawBody Value -> WebApp NoContent
stripeWebhookEndpoint (StripeSignature sig) body = do
  stripeWebhookSecret <- asks (stripeWebhookSecretKey . envStripeConfig)
  if isSigValid sig stripeWebhookSecret (BS.toStrict . rawBody $ body)
    then case value body of
      Left err ->
        respondError $ BadRequest $ "Invalid JSON body: " <> err
      Right json ->
        case fromJSON json of
          Aeson.Error err ->
            respondError $ BadRequest $ "Invalid Stripe event: " <> Text.pack err
          Success event -> do
            saveStripeEvent event (Json json)
            handleEvent event $> NoContent
    else respondError $ BadRequest "Invalid signature"

createSubscriptionEndpoint :: UserId -> CreateSubscription -> WebApp IncompleteSubscription
createSubscriptionEndpoint userId (CreateSubscription cloudTier coupon address) =
  toIncomplete <$> createSubscription userId address cloudTier coupon
  where
    toIncomplete (SubscriptionWithClientSecret sub secret) = IncompleteSubscription (Subscription.subscriptionId sub) secret
