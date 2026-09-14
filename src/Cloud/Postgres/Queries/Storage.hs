module Cloud.Postgres.Queries.Storage
  ( assignStoragePoolToEnv,
    createStoragePool,
    deleteStoragePool,
    getStoragePool,
    listStoragePools,
    unassignStoragePoolFromEnv,
    verifyStoragePoolOwnership,
    storageByEnvironmentId,
  )
where

import Cloud.Postgres qualified as PG
import Cloud.Prelude
import Cloud.Storage.Types
import Data.Traversable (for)
import Share.OAuth.Types (UserId)
import Cloud.Byoc.Env (ClusterId)
import Cloud.Web.Types (EnvironmentId)

storageByEnvironmentId :: ClusterId -> EnvironmentId -> PG.Transaction e [StoragePoolId]
storageByEnvironmentId clusterId envId = do
  PG.queryListCol
    [PG.sql|
        SELECT storage_pool_id
          FROM cloud_environment_storage_pool
          WHERE environment_id = #{envId}
            AND cluster_id = #{clusterId}
      |]

createStoragePool :: ClusterId -> UserId -> StoragePoolName -> PG.Transaction e StoragePoolId
createStoragePool clusterId userId name = do
  PG.queryExpect1Col
    [PG.sql|
        INSERT INTO cloud_storage_pools (user_id, name, cluster_id)
        VALUES (#{userId}, LOWER(#{name}), #{clusterId})
        ON CONFLICT (user_id, name, cluster_id) DO UPDATE
        SET name = EXCLUDED.name
        RETURNING id;
      |]

verifyStoragePoolOwnership :: ClusterId -> UserId -> StoragePoolId -> PG.Transaction e Bool
verifyStoragePoolOwnership clusterId userId poolId = do
  result <-
    PG.query1Col
      [PG.sql|
        SELECT EXISTS (
          SELECT 1 FROM cloud_storage_pools sp
            JOIN cloud_users cu ON cu.user_id = sp.user_id
            WHERE sp.user_id = #{userId}
              AND sp.id = #{poolId}
              AND sp.cluster_id = #{clusterId}
        ) OR EXISTS (
          SELECT 1 FROM cloud_storage_pools sp
          JOIN org_members om ON sp.user_id = om.organization_user_id
            WHERE om.member_user_id = #{userId}
              AND sp.id = #{poolId}
              AND sp.cluster_id = #{clusterId}
        )
      |]
  pure $ fromMaybe False result

deleteStoragePool :: ClusterId -> StoragePoolId -> PG.Transaction e ()
deleteStoragePool clusterId poolId = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_storage_pools
          WHERE id = #{poolId}
            AND cluster_id = #{clusterId}
      |]

listStoragePools :: ClusterId -> UserId -> PG.Transaction e [StoragePool]
listStoragePools clusterId userId = do
  ids <-
    PG.queryListRows
      [PG.sql|
        SELECT id, name
        FROM cloud_storage_pools
        WHERE user_id = #{userId}
          AND cluster_id = #{clusterId}
      |]
  for ids $ \(id, name) -> do
    envs <- getEnvs id
    pure $ StoragePool id name envs
  where
    getEnvs id =
      PG.queryListCol
        [PG.sql|
        SELECT environment_id
        FROM cloud_environment_storage_pool
        WHERE storage_pool_id = #{id}
          AND cluster_id = #{clusterId}
      |]

getStoragePool :: ClusterId -> StoragePoolId -> PG.Transaction e (Maybe StoragePool)
getStoragePool clusterId poolId = do
  ids <-
    PG.query1Row
      [PG.sql|
        SELECT id, name
        FROM cloud_storage_pools
        WHERE id = #{poolId}
          AND cluster_id = #{clusterId}
      |]
  for ids $ \(id, name) -> do
    envs <- getEnvs id
    pure $ StoragePool id name envs
  where
    getEnvs id =
      PG.queryListCol
        [PG.sql|
        SELECT environment_id
        FROM cloud_environment_storage_pool
        WHERE storage_pool_id = #{id}
          AND cluster_id = #{clusterId}
      |]

assignStoragePoolToEnv :: ClusterId -> StoragePoolId -> EnvironmentId -> PG.Transaction e ()
assignStoragePoolToEnv clusterId poolId envId = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_environment_storage_pool (storage_pool_id, environment_id, cluster_id)
          VALUES (#{poolId}, #{envId}, #{clusterId})
          ON CONFLICT DO NOTHING
      |]

unassignStoragePoolFromEnv :: ClusterId -> StoragePoolId -> EnvironmentId -> PG.Transaction e ()
unassignStoragePoolFromEnv clusterId poolId envId = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_environment_storage_pool
          WHERE storage_pool_id = #{poolId}
            AND environment_id = #{envId}
            AND cluster_id = #{clusterId}
      |]
