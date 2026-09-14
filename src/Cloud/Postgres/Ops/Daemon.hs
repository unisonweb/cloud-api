module Cloud.Postgres.Ops.Daemon
  ( createDaemon,
    deleteDaemon,
    createDaemonName,
    deleteDaemonName,
    environmentByDaemonHash,
    listDaemons,
    getDaemon,
    getDaemonHistory,
    getDaemonTags,
    getAllDaemonTags,
    getDaemonsByTag,
    getDaemonsWithoutTag,
    setDaemonTag,
    deleteDaemonTag,
    assignDaemon,
    unassignDaemon,
    getDaemonAssignmentsByHash,
    createNimbusDaemon,
  )
where

import Cloud.Byoc.Env (ClusterId)
import Cloud.Daemon.Types
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Postgres qualified as PG
import Cloud.Postgres.App (postgresM)
import Cloud.Postgres.Ops.Environment (checkEnvironmentAccess)
import Cloud.Postgres.Ops.Internal (orRespondError)
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.Web.App (WebApp)
import Cloud.Web.Errors (CloudWebError (..))
import Cloud.Web.Types (EnvironmentId)
import Share.OAuth.Types (UserId)

createDaemonName :: ClusterId -> UserId -> UserId -> DaemonName -> WebApp DaemonId
createDaemonName clusterId userId ownerId name = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      daemonAccess <- Q.daemonAccess userId
      canAct <- Q.canUserActOnBehalf userId ownerId
      if daemonAccess
        then
          if canAct
            then Right <$> Q.getOrCreateDaemonName clusterId ownerId name
            else pure $ Left CloudNotAuthorized
        else pure $ Left (CloudRequiresSubscription userId)

deleteDaemonName :: ClusterId -> UserId -> DaemonId -> WebApp ()
deleteDaemonName cluster userId daemonId = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if own
        then do
          Q.deleteDaemonName cluster userId daemonId
          pure $ Right ()
        else pure $ Left CloudNotAuthorized

createDaemon :: ClusterId -> UserId -> UserId -> EnvironmentId -> DeploymentHash -> WebApp ()
createDaemon cluster uid ownerId envId deploymentHash =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      me <- Q.verifyEnvironmentAccess cluster uid envId
      daemonAccess <- Q.daemonAccess uid
      if not daemonAccess
        then pure $ Left (CloudRequiresSubscription uid)
        else
          if not me
            then pure $ Left CloudNotAuthorized
            else do
              canAct <- Q.canUserActOnBehalf uid ownerId
              if not canAct
                then pure $ Left CloudNotAuthorized
                else Right <$> Q.createDaemon cluster uid envId deploymentHash

createNimbusDaemon :: ClusterId -> UserId -> EnvironmentId -> DeploymentHash -> WebApp ()
createNimbusDaemon cluster uid envId deploymentHash =
  postgresM $ PG.runTransaction $ Q.createDaemon cluster uid envId deploymentHash

deleteDaemon :: ClusterId -> UserId -> DeploymentHash -> WebApp ()
deleteDaemon cluster userId hash = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser userId
      if cloud
        then do
          Q.deleteDaemon cluster userId hash
          pure $ Right ()
        else pure $ Left CloudNotAuthorized

getDaemonAssignmentsByHash :: ClusterId -> UserId -> DeploymentHash -> WebApp [DaemonId]
getDaemonAssignmentsByHash cluster userId hash =
  postgresM $ PG.runTransaction $ Q.getDaemonAssignmentsByHash cluster userId hash

listDaemons :: ClusterId -> UserId -> WebApp [DaemonDetails]
listDaemons cluster userId = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser userId
      if cloud
        then Right <$> Q.listDaemons cluster userId
        else pure $ Left CloudNotAuthorized

getDaemon :: ClusterId -> UserId -> DaemonId -> WebApp DaemonDetails
getDaemon cluster userId daemonId = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if own
        then Right <$> Q.getDaemon cluster daemonId
        else pure $ Left CloudNotAuthorized

getDaemonHistory :: ClusterId -> UserId -> DaemonId -> WebApp [DaemonAssignment]
getDaemonHistory cluster userId daemonId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if own
        then Right <$> Q.getDaemonHistory cluster daemonId
        else pure $ Left CloudNotAuthorized

getDaemonTags :: ClusterId -> UserId -> DaemonId -> WebApp [Text]
getDaemonTags cluster userId daemonId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if own
        then Right <$> Q.getDaemonTags cluster daemonId
        else pure $ Left CloudNotAuthorized

getAllDaemonTags :: ClusterId -> UserId -> WebApp [Text]
getAllDaemonTags cluster userId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser userId
      if cloud
        then Right <$> Q.getAllDaemonTags cluster userId
        else pure $ Left CloudNotAuthorized

getDaemonsByTag :: ClusterId -> UserId -> Text -> WebApp [DaemonDetails]
getDaemonsByTag cluster userId tag =
  postgresM $ PG.runTransaction $ Q.getDaemonsByTag cluster userId tag

getDaemonsWithoutTag :: ClusterId -> UserId -> WebApp [DaemonDetails]
getDaemonsWithoutTag cluster userId =
  postgresM $ PG.runTransaction $ Q.getDaemonsWithoutTag cluster userId

setDaemonTag :: ClusterId -> UserId -> DaemonId -> Text -> WebApp ()
setDaemonTag cluster userId daemonId name =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if own
        then do
          Q.setDaemonTag cluster userId daemonId name
          pure $ Right ()
        else pure $ Left CloudNotAuthorized

deleteDaemonTag :: ClusterId -> UserId -> DaemonId -> Text -> WebApp ()
deleteDaemonTag cluster userId daemonId name =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if own
        then do
          Q.deleteDaemonTag cluster userId daemonId name
          pure $ Right ()
        else pure $ Left CloudNotAuthorized

assignDaemon :: ClusterId -> UserId -> DaemonId -> DeploymentHash -> WebApp ()
assignDaemon cluster userId daemonId hash =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      daemonAccess <- Q.daemonAccess userId
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if not daemonAccess
        then pure $ Left (CloudRequiresSubscription userId)
        else
          if not own
            then pure $ Left CloudNotAuthorized
            else do
              Q.assignDaemon cluster daemonId hash
              pure $ Right ()

unassignDaemon :: ClusterId -> UserId -> DaemonId -> WebApp ()
unassignDaemon cluster userId daemonId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDaemonOwnership cluster userId daemonId
      if own
        then do
          Q.unassignDaemon cluster daemonId
          pure $ Right ()
        else pure $ Left CloudNotAuthorized

environmentByDaemonHash :: ClusterId -> UserId -> DeploymentHash -> WebApp EnvironmentId
environmentByDaemonHash cluster uid hash = do
  envId <- postgresM $ PG.runTransaction (Q.environmentByDaemonHash cluster hash)
  checkEnvironmentAccess cluster uid envId
  pure envId
