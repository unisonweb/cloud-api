{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use fewer imports" #-}
module Cloud.Web.Internal.Impl where


import Servant
import Cloud.Web.Internal.API
import Cloud.Web.App (WebApp)
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Types ( ServiceId, ServiceName, CloudApiHost )
import Cloud.Postgres qualified as PG
import Cloud.Postgres.Queries qualified as Q
import Cloud.User.Types (User(..))
import Cloud.Web.Errors
import Cloud.Errors
import Cloud.Web.Internal.Types
import Share.OAuth.Types
import Cloud.Prelude
import Cloud.Byoc.Env (ClusterEnv (..), Connection (..), ClusterId)
import Control.Monad.RWS
import StmContainers.Map qualified as TMap
import Control.Concurrent.STM (atomically)
import Cloud.Consul.API (CheckStatus(..), ServiceInstanceId)
import Cloud.Web.Environment (Env(..))
import Cloud.Postgres.App (postgresM)
import Cloud.Byoc.Env (Cluster(..))
import Cloud.Web.Types (EnvironmentId)
import qualified Cloud.Postgres.Ops.Byoc as PGO
import Cloud.Byoc.Env (Event, eventCluster, PeerNodeResult (..))
import Cloud.Web.Cluster.Impl (invalidateLocalForCluster, invalidationTimeoutMicros)
import Data.Text qualified as Text
import System.Environment (lookupEnv)

server :: ServerT API WebApp
server = do
    userIdByHandle
        :<|> storageByEnvironmentId
        :<|> deploymentByServiceId
        :<|> deploymentByServiceName
        :<|> byocHealth
        :<|> invalidatePeer

userIdByHandle :: UserHandle -> WebApp UserIdResult
userIdByHandle handle = do
   user <- postgresM $ PG.runTransaction $ Q.userByHandle handle
   case user of
      Nothing -> respondError $ UserNotFoundForHandle handle
      Just (User (UserId id) _ _ _ _ _) -> pure $ UserIdResult id

storageByEnvironmentId :: CloudApiHost -> EnvironmentId -> WebApp [StoragePoolIdResult]
storageByEnvironmentId host envId = do
    clusterId <- PGO.clusterIdByHost host
    postgresM $ PG.runTransaction $ fmap StoragePoolIdResult <$> Q.storageByEnvironmentId clusterId envId

deploymentByServiceId :: CloudApiHost -> ServiceId -> WebApp DeploymentHashResult
deploymentByServiceId host serviceId = do
    clusterId <- PGO.clusterIdByHost host
    deployment <- postgresM $ PG.runTransaction (Q.deploymentByServiceId clusterId serviceId)
    case deployment of
        Nothing -> respondError $ ServiceIdNotFound serviceId
        Just deployment -> pure $ DeploymentHashResult deployment

deploymentByServiceName :: CloudApiHost -> UserHandle -> ServiceName -> WebApp DeploymentHashResult
deploymentByServiceName host userHandle serviceName = do
    clusterId <- PGO.clusterIdByHost host
    deployment <- postgresM $ PG.runTransaction (Q.deploymentByServiceName clusterId userHandle serviceName)
    case deployment of
        Nothing -> respondError $ ServiceNameNotFound serviceName
        Just deployment -> pure $ DeploymentHashResult deployment

err429 :: ServerError
err429 = ServerError { errHTTPCode = 429
                    , errReasonPhrase = "Too Many Requests"
                    , errBody = ""
                    , errHeaders = []
                    }

checkStatusToResponse :: CheckStatus -> Maybe ServerError
checkStatusToResponse Passing = Nothing
checkStatusToResponse Warning = Just $ err429 {errBody = "Warning: service is not ready to handle more requests"}
checkStatusToResponse Critical = Just $ err503 {errBody = "Error: service is critical"}

byocHealth :: ClusterId -> ServiceInstanceId -> WebApp NoContent
byocHealth clusterId instanceId = do
  Env { clusterEnv = ClusterEnv { envClusters } } <- ask
  maybeConnection <- liftIO $ atomically $ getConnection envClusters
  case maybeConnection of
    Nothing -> respondError $ UnknownServiceInstance clusterId instanceId
    Just connection -> responseFromConnection connection

  where
    getConnection envClusters= do
      cluster <- TMap.lookup clusterId envClusters
      case cluster of
        Nothing -> pure Nothing
        Just cluster -> TMap.lookup instanceId (clusterConnections cluster)
    responseFromConnection connection = liftIO $ do
      status <- checkHealth connection
      case status of
        Passing -> pure NoContent
        Warning -> throwIO $ err429 {errBody = "Warning: service is not ready to handle more requests"}
        Critical -> throwIO $ err503 {errBody = "Error: service is critical"}

-- | Internal peer RPC: apply an invalidation to the nodes connected to THIS
-- instance and return per-node results. (Local-only — the fan-out across peers
-- is driven by 'invalidateSync' on the originating instance.) When
-- CLOUD_INTERNAL_AUTH_TOKEN is set, callers must present it in
-- X-Cloud-Internal-Auth; this route triggers work across every connected node,
-- so it gets a stronger guard than the read-only internal routes.
invalidatePeer :: Maybe Text -> Event -> WebApp [PeerNodeResult]
invalidatePeer auth ev = do
  expected <- liftIO $ lookupEnv "CLOUD_INTERNAL_AUTH_TOKEN"
  case expected of
    Just secret | auth /= Just (Text.pack secret) -> throwIO err403 {errBody = "missing or invalid X-Cloud-Internal-Auth"}
    _ -> pure ()
  results <- invalidateLocalForCluster invalidationTimeoutMicros (eventCluster ev) ev
  pure [PeerNodeResult nid d | (nid, d) <- results]
