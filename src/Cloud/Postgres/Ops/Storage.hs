module Cloud.Postgres.Ops.Storage
(
    assignStoragePoolToEnv,
    createStoragePool,
    deleteStoragePool,
    getStoragePool,
    listStoragePools,
    unassignStoragePoolFromEnv,

)

where
import Share.OAuth.Types (UserId)
import Cloud.Storage.Types
import qualified Cloud.Postgres as PG
import qualified Cloud.Postgres.Queries as Q
import Cloud.Web.App (WebApp)
import Cloud.Web.Errors (CloudWebError(..))
import Cloud.Postgres.Ops.Internal (orRespondError)
import Cloud.Byoc.Env (ClusterId)
import Cloud.Postgres.App (postgresM)
import Cloud.Web.Types (EnvironmentId)

createStoragePool :: ClusterId -> UserId -> UserId -> StoragePoolName -> WebApp StoragePoolId
createStoragePool cluster uid ownerId name = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      canAct <- Q.canUserActOnBehalf uid ownerId
      if not canAct
        then pure $ Left CloudNotAuthorized
        else
          if cloud
            then Right <$> Q.createStoragePool cluster ownerId name
            else pure $ Left CloudNotCloudAccount
deleteStoragePool :: ClusterId -> UserId -> StoragePoolId -> WebApp ()
deleteStoragePool cluster userId poolId = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyStoragePoolOwnership cluster userId poolId
      if own then Right <$> Q.deleteStoragePool cluster poolId else pure $ Left CloudNotAuthorized

listStoragePools :: ClusterId -> UserId -> WebApp [StoragePool]
listStoragePools cluster uid =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if cloud
        then Right <$> Q.listStoragePools cluster uid
        else pure $ Left CloudNotCloudAccount

getStoragePool :: ClusterId -> UserId -> StoragePoolId -> WebApp (Maybe StoragePool)
getStoragePool cluster uid poolId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyStoragePoolOwnership cluster uid poolId
      if own then Right <$> Q.getStoragePool cluster poolId else pure $ Left CloudNotAuthorized

assignStoragePoolToEnv :: ClusterId -> UserId -> StoragePoolId -> EnvironmentId -> WebApp ()
assignStoragePoolToEnv cluster userId poolId envId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own1 <- Q.verifyEnvironmentAccess cluster userId envId
      own2 <- Q.verifyStoragePoolOwnership cluster userId poolId
      if own1 && own2 then Right <$> Q.assignStoragePoolToEnv cluster poolId envId else pure $ Left CloudNotAuthorized

unassignStoragePoolFromEnv :: ClusterId -> UserId -> StoragePoolId -> EnvironmentId -> WebApp ()
unassignStoragePoolFromEnv cluster userId poolId envId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyStoragePoolOwnership cluster userId poolId
      if own then Right <$> Q.unassignStoragePoolFromEnv cluster poolId envId else pure $ Left CloudNotAuthorized
