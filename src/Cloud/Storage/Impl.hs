module Cloud.Storage.Impl
  ( storageEndpoint,
  )
where

import Cloud.Byoc.Env (ClusterConfig (..))
import Cloud.Postgres.Ops qualified as PGO
import Cloud.Storage.API
import Cloud.Storage.Types
import Cloud.Web.App (WebApp)
import Cloud.Web.Environment
import Cloud.Web.Types (EnvironmentId, CloudApiHost)
import Servant
import Share.OAuth.Types (UserId)
import Data.Maybe (fromMaybe)

storageEndpoint :: ServerT StoragePoolAPI WebApp
storageEndpoint =
  storagePoolCreateEndpoint
    :<|> storagePoolGetEndpoint
    :<|> storagePoolDeleteEndpoint
    :<|> storagePoolListEndpoint
    :<|> storagePoolAssignEnvEndpoint
    :<|> storagePoolUnassignEnvEndpoint

storagePoolCreateEndpoint :: UserId -> Maybe UserId -> CloudApiHost -> StoragePoolName -> WebApp StoragePoolId
storagePoolCreateEndpoint uid ownerId host name = do
  let ownerId' = fromMaybe uid ownerId
  clusterId <- PGO.clusterIdByHost host
  PGO.createStoragePool clusterId uid ownerId' name

storagePoolDeleteEndpoint :: UserId -> CloudApiHost -> StoragePoolId -> WebApp NoContent
storagePoolDeleteEndpoint uid host poolId = do
  clusterId <- PGO.clusterIdByHost host
  PGO.deleteStoragePool clusterId uid poolId >> pure NoContent

storagePoolListEndpoint :: UserId -> CloudApiHost -> WebApp [StoragePool]
storagePoolListEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listStoragePools clusterId uid

storagePoolGetEndpoint :: UserId -> CloudApiHost -> StoragePoolId -> WebApp (Maybe StoragePool)
storagePoolGetEndpoint uid host poolId = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getStoragePool clusterId uid poolId

storagePoolAssignEnvEndpoint ::
  UserId ->
  CloudApiHost ->
  StoragePoolId ->
  EnvironmentId ->
  WebApp NoContent
storagePoolAssignEnvEndpoint uid host poolId envId = do
  clusterConfig <- PGO.clusterConfigByHostname host
  PGO.assignStoragePoolToEnv clusterConfig.clusterId uid poolId envId
  storagePoolAssignEnv clusterConfig envId
  pure NoContent

storagePoolUnassignEnvEndpoint ::
  UserId ->
  CloudApiHost ->
  StoragePoolId ->
  EnvironmentId ->
  WebApp NoContent
storagePoolUnassignEnvEndpoint uid host poolId envId = do
  clusterConfig <- PGO.clusterConfigByHostname host
  PGO.unassignStoragePoolFromEnv clusterConfig.clusterId uid poolId envId
  storagePoolUnassignEnv clusterConfig envId
  pure NoContent
