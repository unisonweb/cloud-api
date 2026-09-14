{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

{-# HLINT ignore "Redundant bracket" #-}

module Cloud.Byoc.Impl
  ( byocDeploymentEndpoint,
    clusterByHost,
    clusterById,
    clusterDeploymentURI,
    server,
    verifyClusterJWT,
    authenticateClusterToken,
    clusterServiceURI,
  )
where

import Cloud.Byoc.API (ByocAPI)
import Cloud.Byoc.App (clusterM)
import Cloud.Byoc.Env (Cluster (..), ClusterConfig (..), ClusterEnv (..), ClusterId, ClusterToken, SchemeType (..), ServiceURIScheme (..), getCluster)
import Cloud.Byoc.Types (ByocUserClaims (..), DaemonHashClaims (..), DeploymentClaims (..), EnvironmentClaims (..), JobSubmitClaims (..), UserLogsClaims (..), DeploymentLogsClaims (..))
import Cloud.Consul.Daemon (consulUnassignDaemonId)
import Cloud.Deployment.DeploymentHash (DeploymentHash (..))
import Cloud.Env (Env (..))
import Cloud.Errors (respondError)
import Cloud.JWT qualified as CloudJWT
import Cloud.Postgres.Ops (checkOrgEnvironmentAccess)
import Cloud.Postgres.Ops qualified as PGO
import Cloud.Prelude
import Cloud.User.App (authM)
import Cloud.User.Env (AuthEnv (..))
import Cloud.User.Types (User (..))
import Cloud.User.UserHandle (UserHandle (..))
import Cloud.Utils.Logging (logErrorText)
import Cloud.Web.App (WebApp)
import Cloud.Web.Cluster.Impl (MemberList (..), NimbusInstance (..), getMemberList)
import Cloud.Web.Errors (CloudWebError (..), UnauthenticatedError (..))
import Cloud.Web.Types
    ( ByocUserJWT(..),
      CloudApiHost,
      DeploymentURI(..),
      EnvironmentId(..),
      HttpServiceVersion,
      NimbusRedirect(..),
      ServiceName,
      cloudApiHostname,
      DeploymentDetails(..), serviceNameToText )
import Control.Concurrent.STM (atomically)
import Control.Monad.Reader (ask)
import Crypto.JWT qualified as JWT
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Time.Clock
import Network.URI (URIAuth (..), parseURI)
import Servant
import Servant.Client qualified as S
import Share.JWT qualified as JWT
import Share.JWT qualified as ShareJWT
import Share.OAuth.Types (UserId)
import StmContainers.Map qualified as StmMap
import StmContainers.Map qualified as TMap
import System.Random
import Cloud.Service.Types (ServiceId)
import Share.Utils.Show (tShow)
import Cloud.Web.Loki (nsFromUTCTime)
import Cloud.Events (fireDeploymentHashInvalidationEvent, fireEnvironmentInvalidationEvent)

server :: ServerT ByocAPI WebApp
server =
  ( \jwt ->
      nimbusExposeEndpoint jwt
        :<|> nimbusUnexposeEndpoint jwt
        :<|> nimbusDeploymentEndpoint jwt
        :<|> nimbusUndeployEndpoint jwt
        :<|> ( nimbusUploadedDaemonEndpoint jwt
                 :<|> nimbusDeletedDaemonHashEndpoint jwt
             )
        :<|> nimbusDeleteEnvEndpoint jwt
        :<|> nimbusDeleteEnvValueEndpoint jwt
  )
    :<|> ( \uid ->
             ( byocDeploymentEndpoint uid
                 :<|> byocUndeployEndpoint uid
                 :<|> byocExposeEndpoint uid
                 :<|> byocUnexposeEndpoint uid
             )
               :<|> ( byocDaemonHashCreateEndpoint uid
                        :<|> byocDaemonHashDeleteEndpoint uid
                    )
               :<|> ( createEnvironmentEndpoint uid
                        :<|> setEnvironmentValueEndpoint uid
                        :<|> deleteEnvironmentValueEndpoint uid
                        :<|> deleteEnvironmentEndpoint uid
                    )
               :<|> byocJobSubmitEndpoint uid
               :<|> (byocQueryUserLogsEndpoint uid
                        :<|> byocQueryDeploymentLogsEndpoint uid
                        :<|> byocQueryServiceLogsEndpoint uid
                    )
               :<|> ( createClusterEndpoint uid
                        :<|> clusterSetClusterURIEndpoint uid
                        :<|> clusterGetClusterTokenEndpoint uid
                    )
         )

-- A token that is only meant to be used for a single request can be short-lived.
singleRequestJWTTTL :: NominalDiffTime
singleRequestJWTTTL = secondsToNominalDiffTime $ 60 * 10

-- A single logs token can be requested and reused repeatedly to effectively tail logs.
logQueryJWTTTL :: NominalDiffTime
logQueryJWTTTL = nominalDay

-- | NOTE: this does NOT check environment access. It assumes that has already been done.
getClusterJWT :: (ShareJWT.AsJWTClaims c) => (ShareJWT.StandardClaims -> c) -> NominalDiffTime -> UserId -> WebApp ByocUserJWT
getClusterJWT makeClaims ttl userId = do
  Env {authEnv = AuthEnv {envJwtSettings}} <- ask
  jti <- liftIO randomIO
  standardClaims <- CloudJWT.newStandardClaims userId ttl jti
  let claims = makeClaims standardClaims
  result <- ShareJWT.signJWT envJwtSettings claims
  case result of
    Left err -> respondError $ InternalError $ tshow err
    Right jwt -> pure $ ByocUserJWT (JWT.JWTParam jwt)

verifyClusterJWT :: (ShareJWT.AsJWTClaims c) => ByocUserJWT -> WebApp (Either JWT.JWTError c)
verifyClusterJWT (ByocUserJWT (ShareJWT.JWTParam jwt)) = authM $ do
  AuthEnv {envJwtSettings} <- ask
  ShareJWT.verifyJWT envJwtSettings jwt

clusterURI :: ClusterConfig -> Text -> WebApp URI
clusterURI clusterConfig path = do
  case clusterConfig.clusterServiceURIScheme of
    HostBased _ ->
      pure $ appendPath (Text.unpack path) (clusterUri clusterConfig)
    LocalHostBased _ ->
      pure $ appendPath (Text.unpack path) (clusterUri clusterConfig)
    IPBased -> do
      uri <- getRandomClusterEndpoint clusterConfig.clusterId
      pure $ appendPath (Text.unpack path) uri

clusterServiceURI :: ClusterConfig -> UserHandle -> ServiceName -> WebApp URI
clusterServiceURI clusterConfig (UserHandle userHandle) serviceName = case clusterConfig.clusterServiceURIScheme of
  HostBased uri ->
    let updatedUri = case uriAuthority uri of
          Just auth -> uri { uriAuthority = Just auth { uriRegName = Text.unpack userHandle <> "." <> uriRegName auth } }
          Nothing -> uri
    in pure $ appendPath ("/s/" <> Text.unpack (serviceNameToText serviceName) <> "/") updatedUri
  LocalHostBased uri ->
    pure $ appendPath ("/services/s/" <> Text.unpack (userHandle <> "/" <> serviceNameToText serviceName) <> "/") uri
  IPBased -> do
    uri <- getRandomClusterEndpoint clusterConfig.clusterId
    pure $ appendPath (Text.unpack $ "/services/s/" <> userHandle <> "/" <> serviceNameToText serviceName <> "/") uri

getRandomClusterEndpoint :: ClusterId -> WebApp URI
getRandomClusterEndpoint cluster = do
  NimbusInstance {uri, metadata} <- getRandomClusterMember cluster
  host <- case Map.lookup "publicHttpHost" metadata of
    Just hostname -> pure hostname
    Nothing -> do
      respondError $ InternalError $ "Cluster member missing publicHttpHost metadata: " <> tshow (Map.keys metadata)

  port <- case Map.lookup "publicHttpPort" metadata of
    Just portText -> pure portText
    Nothing -> do
      respondError $ InternalError $ "Cluster member missing publicHttpPort metadata: " <> tshow (Map.keys metadata)
  pure $ uri {uriAuthority = Just $ URIAuth "" (Text.unpack host) (":" <> Text.unpack port)}

clusterDeploymentURI :: UserHandle -> ClusterConfig -> DeploymentHash -> WebApp DeploymentURI
clusterDeploymentURI (UserHandle userHandle) cluster (DeploymentHash digest) = case cluster.clusterServiceURIScheme of
  HostBased uri ->
    let updatedUri = case uriAuthority uri of
          Just auth -> uri { uriAuthority = Just auth { uriRegName = Text.unpack userHandle <> "." <> uriRegName auth } }
          Nothing -> uri
     in
      pure $
        DeploymentURI $
          appendPath ("/h/" <> Text.unpack digest <> "/") updatedUri
  LocalHostBased uri ->
    pure $
      DeploymentURI $
        appendPath ("/services/h2/" <> Text.unpack userHandle <> "/" <> Text.unpack digest <> "/") uri
  IPBased -> do
    uri <- getRandomClusterEndpoint cluster.clusterId
    pure $ DeploymentURI $ appendPath ("/services/h2/" <> Text.unpack userHandle <> "/" <> Text.unpack digest <> "/") uri

appendPath :: String -> URI -> URI
appendPath path uri =
  case (uriPath uri) of
    [] -> uri {uriPath = path}
    p | last p == '/' -> uri {uriPath = uriPath uri <> (drop 1 path)}
    _ -> uri {uriPath = uriPath uri <> path}

nimbusDeploymentEndpoint ::
  ByocUserJWT ->
  DeploymentHash ->
  WebApp NoContent
nimbusDeploymentEndpoint jwt deploymentHash = do
  claims <- verifyClusterJWT jwt
  case claims of
    Left e -> do
      logErrorText $ "Failed to verify JWT: " <> tshow e
      respondError UnauthenticatedError
    Right (EnvironmentClaims {environmentId, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      PGO.createDeployment clusterId userId environmentId deploymentHash
      pure NoContent

nimbusUploadedDaemonEndpoint ::
  ByocUserJWT ->
  DeploymentHash ->
  WebApp NoContent
nimbusUploadedDaemonEndpoint jwt daemonhash = do
  claims <- verifyClusterJWT jwt
  case claims of
    Left e -> do
      logErrorText $ "Failed to verify JWT: " <> tshow e
      respondError UnauthenticatedError
    Right (EnvironmentClaims {environmentId, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      PGO.createNimbusDaemon clusterId userId environmentId daemonhash
      pure NoContent

nimbusExposeEndpoint ::
  ByocUserJWT ->
  HttpServiceVersion ->
  WebApp DeploymentURI
nimbusExposeEndpoint jwt v = do
  claims <- verifyClusterJWT jwt
  case claims of
    Left e -> do
      logErrorText $ "Failed to verify JWT: " <> tshow e
      respondError UnauthenticatedError
    Right (DeploymentClaims {deploymentHash, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      cluster <- PGO.clusterConfigById clusterId
      User _ _ _ _ userHandle _ <- PGO.exposeDeployment clusterId userId deploymentHash v
      clusterDeploymentURI userHandle cluster deploymentHash

nimbusUndeployEndpoint :: ByocUserJWT -> WebApp NoContent
nimbusUndeployEndpoint jwt = do
  claims <- verifyClusterJWT jwt
  case claims of
    Left _ -> respondError UnauthenticatedError
    Right (DeploymentClaims {deploymentHash, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      traverse_ (PGO.unassignService clusterId userId) =<< PGO.getServiceAssignmentsByDeployment clusterId deploymentHash
      PGO.deleteDeployment clusterId userId deploymentHash
      PGO.unexposeDeployment clusterId userId deploymentHash
      pure NoContent

nimbusDeletedDaemonHashEndpoint :: ByocUserJWT -> WebApp NoContent
nimbusDeletedDaemonHashEndpoint jwt = do
  claims <- verifyClusterJWT jwt
  case claims of
    Left _ -> respondError UnauthenticatedError
    Right (DaemonHashClaims {daemonHash, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      daemonIds <- PGO.getDaemonAssignmentsByHash clusterId userId daemonHash
      PGO.deleteDaemon clusterId userId daemonHash
      forM_ daemonIds $ \did -> do
          consulUnassignDaemonId clusterId did
      pure NoContent

nimbusUnexposeEndpoint :: ByocUserJWT -> WebApp NoContent
nimbusUnexposeEndpoint jwt = do
  claims <- verifyClusterJWT jwt
  case claims of
    Left _ -> respondError UnauthenticatedError
    Right (DeploymentClaims {deploymentHash, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      PGO.unexposeDeployment clusterId userId deploymentHash
      fireDeploymentHashInvalidationEvent clusterId deploymentHash
      pure NoContent

nimbusDeleteEnvEndpoint :: ByocUserJWT -> WebApp NoContent
nimbusDeleteEnvEndpoint jwt = do
  Env {envNimbusConfig} <- ask
  claims <- verifyClusterJWT jwt
  case claims of
    Left _ -> respondError UnauthenticatedError
    Right (EnvironmentClaims {environmentId, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      PGO.checkEnvironmentAccess clusterId userId environmentId
      PGO.deleteEnvironment clusterId userId environmentId
      fireEnvironmentInvalidationEvent envNimbusConfig clusterId environmentId
      pure NoContent

nimbusDeleteEnvValueEndpoint :: ByocUserJWT -> WebApp NoContent
nimbusDeleteEnvValueEndpoint jwt = do
  claims <- verifyClusterJWT jwt
  case claims of
    Left _ -> respondError UnauthenticatedError
    Right (EnvironmentClaims {environmentId, userClaims = ByocUserClaims {clusterId, userId}}) -> do
      Env {envNimbusConfig} <- ask
      PGO.checkEnvironmentAccess clusterId userId environmentId
      fireEnvironmentInvalidationEvent envNimbusConfig clusterId environmentId
      pure NoContent

getRandomClusterMember :: ClusterId -> WebApp NimbusInstance
getRandomClusterMember cluster = do
  Env {envNimbusConfig, consulClientEnv} <- ask
  res <- liftIO $ S.runClientM (getMemberList envNimbusConfig cluster Nothing) consulClientEnv
  case res of
    Left err -> do
      logErrorText $ "Error fetching cluster members: " <> tshow err
      respondError $ InternalError "Failed to fetch cluster members"
    Right (Just _, MemberList {healthyLocations}) -> do
      let healthyLocationsCount = length healthyLocations
      if healthyLocationsCount > 0
        then do
          randomIndex <- liftIO $ randomRIO (0, healthyLocationsCount - 1)
          pure $ healthyLocations !! randomIndex
        else do
          logErrorText $ "No healthy locations found for cluster: " <> tshow cluster
          respondError $ InternalError "No healthy locations found"
    Right (_, _) -> do
      logErrorText $ "No members found for cluster: " <> tshow cluster
      respondError $ InternalError "No members found"

nimbusRedirect :: ClusterId -> ByocUserJWT -> Text -> WebApp NimbusRedirect
nimbusRedirect cluster redirectToken path = do
  clusterConfig <- PGO.clusterConfigById cluster
  redirectURI' <- clusterURI clusterConfig path
  let redirectURI = tshow redirectURI'
  pure NimbusRedirect {..}

byocDeploymentEndpoint :: UserId -> CloudApiHost -> Maybe UserId   -> EnvironmentId -> WebApp NimbusRedirect
byocDeploymentEndpoint userId  hostname maybeOwnerId environmentId = do
  let ownerId = fromMaybe userId maybeOwnerId
  clusterId <- PGO.clusterIdByHost hostname
  checkOrgEnvironmentAccess clusterId userId ownerId environmentId
  token <- getClusterJWT (\standardClaims -> EnvironmentClaims environmentId (ByocUserClaims {..})) singleRequestJWTTTL ownerId
  nimbusRedirect clusterId token "/v2/deployments/create"

byocDaemonHashCreateEndpoint :: UserId -> CloudApiHost -> Maybe UserId -> EnvironmentId -> WebApp NimbusRedirect
byocDaemonHashCreateEndpoint userId  hostname maybeOwnerId environmentId = do
  let ownerId = fromMaybe userId maybeOwnerId
  clusterId <- PGO.clusterIdByHost hostname
  checkOrgEnvironmentAccess clusterId userId ownerId environmentId
  token <- getClusterJWT (\standardClaims -> EnvironmentClaims environmentId (ByocUserClaims {..})) singleRequestJWTTTL ownerId
  nimbusRedirect clusterId token "/v2/daemon-hashes/create"

byocExposeEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NimbusRedirect
byocExposeEndpoint userId hostname deploymentHash = do
  clusterId <- PGO.clusterIdByHost hostname
  environmentId <- PGO.environmentByDeployment clusterId userId deploymentHash
  case environmentId of
    Nothing -> respondError $ InvalidDeployment deploymentHash
    Just environmentId -> do
      PGO.checkEnvironmentAccess clusterId userId environmentId
      token <- getClusterJWT (\standardClaims -> DeploymentClaims deploymentHash (ByocUserClaims {..})) singleRequestJWTTTL userId
      nimbusRedirect clusterId token "/v2/deployments/expose"

byocUnexposeEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NimbusRedirect
byocUnexposeEndpoint userId hostname deploymentHash = do
  clusterId <- PGO.clusterIdByHost hostname
  environmentId <- PGO.environmentByDeployment clusterId userId deploymentHash
  case environmentId of
    Nothing -> respondError $ InvalidDeployment deploymentHash
    Just environmentId -> do
      PGO.checkEnvironmentAccess clusterId userId environmentId
      token <- getClusterJWT (\standardClaims -> DeploymentClaims deploymentHash (ByocUserClaims {..})) singleRequestJWTTTL userId
      nimbusRedirect clusterId token "/v2/deployments/unexpose"

byocUndeployEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NimbusRedirect
byocUndeployEndpoint userId hostname deploymentHash = do
  clusterId <- PGO.clusterIdByHost hostname
  environmentId <- PGO.environmentByDeployment clusterId userId deploymentHash
  case environmentId of
    Nothing -> respondError $ InvalidDeployment deploymentHash
    Just environmentId -> do
      PGO.checkEnvironmentAccess clusterId userId environmentId
      token <- getClusterJWT (\standardClaims -> DeploymentClaims deploymentHash (ByocUserClaims {..})) singleRequestJWTTTL userId
      nimbusRedirect clusterId token "/v2/deployments/undeploy"

byocDaemonHashDeleteEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NimbusRedirect
byocDaemonHashDeleteEndpoint userId hostname deploymentHash = do
  clusterId <- PGO.clusterIdByHost hostname
  environmentId <- PGO.environmentByDaemonHash clusterId userId deploymentHash
  PGO.checkEnvironmentAccess clusterId userId environmentId
  token <- getClusterJWT (\standardClaims -> DaemonHashClaims deploymentHash (ByocUserClaims {..})) singleRequestJWTTTL userId
  nimbusRedirect clusterId token "/v2/daemon-hashes/delete"

byocJobSubmitEndpoint :: UserId -> CloudApiHost -> Maybe UserId -> EnvironmentId -> WebApp NimbusRedirect
byocJobSubmitEndpoint userId hostname mOwnerId environmentId = do
  let ownerId = fromMaybe userId mOwnerId
  clusterId <- PGO.clusterIdByHost hostname
  PGO.checkOrgEnvironmentAccess clusterId userId ownerId environmentId
  jobId <- PGO.recordJobRun clusterId userId environmentId
  token <- getClusterJWT (\standardClaims -> JobSubmitClaims environmentId jobId (ByocUserClaims {..})) singleRequestJWTTTL ownerId
  nimbusRedirect clusterId token "/v2/jobs/submit"

-- Todo: We need to think about how to handle org access here
byocQueryUserLogsEndpoint :: UserId -> CloudApiHost -> Maybe UserId -> WebApp NimbusRedirect
byocQueryUserLogsEndpoint userId hostname mOwnerId = do
  let ownerId = fromMaybe userId mOwnerId
  clusterId <- PGO.clusterIdByHost hostname
  PGO.checkClusterAccessM clusterId userId ownerId
  token <- getClusterJWT (\standardClaims -> UserLogsClaims (ByocUserClaims {..})) logQueryJWTTTL ownerId
  nimbusRedirect clusterId token "/v2/logs"

byocQueryDeploymentLogsEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NimbusRedirect
byocQueryDeploymentLogsEndpoint userId hostname deploymentHash = do
  clusterId <- PGO.clusterIdByHost hostname
  PGO.verifyDeploymentOwnership clusterId userId deploymentHash
  token <- getClusterJWT (\standardClaims -> DeploymentLogsClaims deploymentHash Nothing (ByocUserClaims {..})) logQueryJWTTTL userId
  nimbusRedirect clusterId token "/v2/logs/deployment"

byocQueryServiceLogsEndpoint :: UserId -> CloudApiHost -> ServiceId -> WebApp NimbusRedirect
byocQueryServiceLogsEndpoint userId hostname serviceId = do
  clusterId <- PGO.clusterIdByHost hostname
  current <- PGO.getCurrentDeployment clusterId userId serviceId
  case current of
    Nothing -> respondError $ NoCurrentDeploymentForService serviceId
    Just deployment -> do
      let deploymentHash = deploymentDetailsHash deployment
      start <- fmap (tShow . nsFromUTCTime) <$> PGO.getDeploymentLogTime clusterId userId deploymentHash
      token <- getClusterJWT (\standardClaims -> DeploymentLogsClaims deploymentHash start (ByocUserClaims {..})) logQueryJWTTTL userId
      nimbusRedirect clusterId token "/v2/logs/deployment"

createEnvironmentEndpoint :: UserId -> CloudApiHost -> Maybe UserId -> Text -> WebApp NimbusRedirect
createEnvironmentEndpoint userId hostname maybeOwnerId envName = do
  let ownerId = fromMaybe userId maybeOwnerId
  clusterId <- PGO.clusterIdByHost hostname
  environmentId <- PGO.createEnvironment clusterId userId ownerId envName
  token <- getClusterJWT (\standardClaims -> EnvironmentClaims environmentId (ByocUserClaims {..})) singleRequestJWTTTL userId
  nimbusRedirect clusterId token $ "/v2/environments/" <> envName

setEnvironmentValueEndpoint :: UserId -> CloudApiHost -> EnvironmentId -> WebApp NimbusRedirect
setEnvironmentValueEndpoint userId hostname environmentId = do
  clusterId <- PGO.clusterIdByHost hostname
  PGO.checkEnvironmentAccess clusterId userId environmentId
  token <- getClusterJWT (\standardClaims -> EnvironmentClaims environmentId (ByocUserClaims {..})) singleRequestJWTTTL userId
  nimbusRedirect clusterId token "/v2/environments"

deleteEnvironmentValueEndpoint :: UserId -> CloudApiHost -> EnvironmentId -> Text -> WebApp NimbusRedirect
deleteEnvironmentValueEndpoint userId hostname environmentId key = do
  clusterId <- PGO.clusterIdByHost hostname
  PGO.checkEnvironmentAccess clusterId userId environmentId
  token <- getClusterJWT (\standardClaims -> EnvironmentClaims environmentId (ByocUserClaims {..})) singleRequestJWTTTL userId
  nimbusRedirect clusterId token $ "/v2/environments/" <> key

deleteEnvironmentEndpoint :: UserId -> CloudApiHost -> EnvironmentId -> WebApp NimbusRedirect
deleteEnvironmentEndpoint userId hostname environmentId = do
  clusterId <- PGO.clusterIdByHost hostname
  PGO.checkEnvironmentAccess clusterId userId environmentId
  token <- getClusterJWT (\standardClaims -> EnvironmentClaims environmentId (ByocUserClaims {..})) singleRequestJWTTTL userId
  nimbusRedirect clusterId token "/v2/environments"

clusterById :: ClusterId -> WebApp Cluster
clusterById id = do
  Env {clusterEnv = ClusterEnv {envClusters}} <- ask
  maybeCluster <- liftIO $ atomically $ StmMap.lookup id envClusters

  case maybeCluster of
    Nothing -> do
      clusterConfig <- PGO.clusterConfigById id
      clusterM $ getCluster clusterConfig
    Just cluster -> pure cluster

clusterByHost :: CloudApiHost -> WebApp ClusterId
clusterByHost host = do
  ClusterEnv {envClusterHosts} <- clusterM ask
  let hostname = Text.unpack $ cloudApiHostname host
  maybeCluster <- liftIO $ atomically $ TMap.lookup hostname envClusterHosts
  case maybeCluster of
    Just cluster -> pure cluster
    Nothing -> PGO.clusterIdByHost host

authenticateClusterToken :: ClusterToken -> WebApp (Either UnauthenticatedError Cluster)
authenticateClusterToken clusterToken = do
  maybeConfig <- PGO.clusterConfigByToken clusterToken
  case maybeConfig of
    Just clusterConfig -> clusterM $ do
      cluster <- getCluster clusterConfig
      pure (Right cluster)
    Nothing -> pure $ Left UnauthenticatedError

createClusterEndpoint :: UserId -> Text -> Maybe UserId -> Maybe Text -> Maybe SchemeType -> WebApp ClusterId
createClusterEndpoint userId name owner clusterUri schemeType = do
  let schemeType' = fromMaybe Path schemeType

  clusterId <- case owner of
    Nothing ->
      PGO.createCluster name schemeType' userId userId
    Just ownerId ->
      PGO.createCluster name schemeType' userId ownerId
  case clusterUri of
    Nothing -> pure ()
    Just uriText ->
      case parseURI (Text.unpack uriText) of
        Nothing -> respondError $ InvalidURI uriText
        Just uri -> do
          PGO.setClusterURI userId clusterId uri
  pure clusterId

clusterSetClusterURIEndpoint :: UserId -> ClusterId -> Text -> WebApp NoContent
clusterSetClusterURIEndpoint userId clusterId uriText = do
  case parseURI (Text.unpack uriText) of
    Nothing -> respondError $ InvalidURI uriText
    Just uri -> do
      PGO.setClusterURI userId clusterId uri
      pure NoContent

clusterGetClusterTokenEndpoint :: UserId -> ClusterId -> WebApp ClusterToken
clusterGetClusterTokenEndpoint = PGO.generateNewClusterToken
