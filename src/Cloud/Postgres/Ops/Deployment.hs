module Cloud.Postgres.Ops.Deployment
(
    createDeployment,
    deleteDeployment,
    currentDeploymentByServiceName,
    exposeDeployment,
    getCurrentDeployment,
    getDeployment,
    getDeploymentLogTime,
    listAllDeploymentTags,
    listDeploymentTags,
    listDeployments,
    listDeploymentsByTag,
    listUnassignedDeployments,
    listUntaggedDeploymnets,
    setDeploymentTag,
    unexposeDeployment,
    unsetDeploymentTag,
    environmentByDeployment,
    verifyDeploymentOwnership,
)
where
import Share.OAuth.Types (UserId)
import qualified Cloud.Postgres as PG
import qualified Cloud.Postgres.Queries as Q
import Cloud.Deployment.DeploymentHash
import Cloud.Web.App (WebApp)
import Cloud.Service.Types
import Cloud.User.Types (User)
import Data.Time (UTCTime)
import Cloud.Prelude
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Errors (CloudWebError(..))
import Cloud.Postgres.Ops.Internal (orRespondError)
import Data.Maybe (catMaybes)
import Cloud.Postgres.Ops.User (expectUserById_)
import Cloud.Byoc.Env (ClusterId)
import Cloud.Postgres.App (postgresM)
import Cloud.Web.Types (EnvironmentId, HttpServiceVersion, DeploymentDetails)
import Cloud.Postgres.Ops.Environment (checkEnvironmentAccess)
import Cloud.Events (fireDeploymentHashInvalidationEvent)

createDeployment :: ClusterId -> UserId -> EnvironmentId -> DeploymentHash -> WebApp ()
createDeployment cluster uid envId deploymentHash =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      me <- Q.verifyEnvironmentAccess cluster uid envId
      if me
        then Right <$> Q.createDeployment cluster uid envId deploymentHash
        else pure $ Left CloudNotAuthorized

deleteDeployment :: ClusterId -> UserId -> DeploymentHash -> WebApp ()
deleteDeployment cluster uid deploymentHash = do 
  orRespondError =<< postgresM (PG.runTransaction tx)
  fireDeploymentHashInvalidationEvent cluster deploymentHash

  where
    tx = do
      me <- Q.verifyDeploymentOwnership cluster uid deploymentHash
      if me
        then Right <$> Q.deleteDeployment cluster uid deploymentHash
        else pure $ Left CloudNotAuthorized

exposeDeployment :: ClusterId -> UserId -> DeploymentHash -> HttpServiceVersion -> WebApp User
exposeDeployment cluster uid deploymentHash version =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      me <- Q.verifyDeploymentOwnership cluster uid deploymentHash
      if not me
        then pure $ Left CloudNotAuthorized
        else do
          userOrError <- expectUserById_ uid
          mapM (\user -> Q.exposeDeployment cluster uid deploymentHash version $> user) userOrError

unexposeDeployment :: ClusterId -> UserId -> DeploymentHash -> WebApp ()
unexposeDeployment cluster uid deploymentHash =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      me <- Q.verifyDeploymentOwnership cluster uid deploymentHash
      if me
        then Right <$> Q.unexposeDeployment cluster uid deploymentHash
        else pure $ Left CloudNotAuthorized

getDeployment :: ClusterId -> UserId -> DeploymentHash -> WebApp DeploymentDetails
getDeployment cluster userId hash = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDeploymentOwnership cluster userId hash
      if not own
        then pure $ Left CloudNotAuthorized
        else do
          deploy <- Q.getDeploymentDetails cluster hash
          case deploy of
            Nothing -> pure $ Left (InvalidDeployment hash)
            Just d -> pure $ Right d


getDeploymentLogTime :: ClusterId -> UserId -> DeploymentHash -> WebApp (Maybe UTCTime)
getDeploymentLogTime cluster userId hash = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDeploymentOwnership cluster userId hash
      if not own
        then pure $ Left CloudNotAuthorized
        else do
          Right <$> Q.getDeploymentLogTime cluster hash

listDeployments :: ClusterId -> UserId -> WebApp [DeploymentDetails]
listDeployments cluster uid = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if not cloud
        then pure $ Left CloudNotCloudAccount
        else do
          Right <$> Q.listDeployments cluster uid

listUnassignedDeployments :: ClusterId -> UserId -> WebApp [DeploymentDetails]
listUnassignedDeployments cluster uid = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if not cloud
        then pure $ Left CloudNotCloudAccount
        else do
          Right <$> Q.listUnassignedDeployments cluster uid

listDeploymentTags :: ClusterId -> UserId -> DeploymentHash -> WebApp [Text]
listDeploymentTags cluster uid deploymentHash = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyDeploymentOwnership cluster uid deploymentHash
      if not own
        then pure $ Left CloudNotAuthorized
        else do
          Right <$> Q.getDeploymentTags cluster uid deploymentHash

listAllDeploymentTags :: ClusterId -> UserId -> WebApp [Text]
listAllDeploymentTags cluster uid = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if not cloud
        then pure $ Left CloudNotCloudAccount
        else do
          Right <$> Q.getAllDeploymentTags cluster  uid

listDeploymentsByTag :: ClusterId -> UserId -> Text -> WebApp [DeploymentDetails]
listDeploymentsByTag cluster userId tag =
  orRespondError =<< postgresM (PG.runTransaction text)
  where
    text = do
      cloud <- Q.isUserCloudUser userId
      if cloud
        then Right <$> do
          hashs <- Q.getDeploymentsByTag cluster userId tag
          catMaybes <$> traverse (Q.getDeploymentDetails cluster) hashs
        else pure $ Left CloudNotCloudAccount

setDeploymentTag :: ClusterId -> UserId -> DeploymentHash -> Text -> WebApp ()
setDeploymentTag cluster userId deploymentHash tag =
  orRespondError =<< postgresM (PG.runTransaction text)
  where
    text = do
      cloud <- Q.isUserCloudUser userId
      if cloud
        then do
          Q.setDeploymentTag cluster userId deploymentHash tag
          pure $ Right ()
        else pure $ Left CloudNotCloudAccount

unsetDeploymentTag :: ClusterId -> UserId -> DeploymentHash -> Text -> WebApp ()
unsetDeploymentTag cluster userId deploymentHash tag =
  orRespondError =<< postgresM (PG.runTransaction text)
  where
    text = do
      own <- Q.verifyDeploymentOwnership cluster userId deploymentHash
      if own
        then do
          Q.unsetDeploymentTag cluster userId deploymentHash tag
          pure $ Right ()
        else pure $ Left CloudNotAuthorized

listUntaggedDeploymnets :: ClusterId -> UserId -> WebApp [DeploymentDetails]
listUntaggedDeploymnets cluster userId =
  orRespondError =<< postgresM (PG.runTransaction text)
  where
    text = do
      cloud <- Q.isUserCloudUser userId
      if cloud
        then Right <$> do
          hashs <- Q.getUntaggedDeployments cluster userId
          catMaybes <$> traverse (Q.getDeploymentDetails cluster) hashs

        else pure $ Left CloudNotCloudAccount

getCurrentDeployment :: ClusterId -> UserId -> ServiceId -> WebApp (Maybe DeploymentDetails)
getCurrentDeployment cluster uid serviceId = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyServiceOwnership cluster uid serviceId
      if not own
        then pure $ Left (ServiceIdNotFound serviceId)
        else do
          Right <$> Q.currentDeploymentByService cluster  serviceId

currentDeploymentByServiceName :: ClusterId -> UserId -> UserHandle -> ServiceName -> WebApp (Maybe DeploymentDetails)
currentDeploymentByServiceName cluster userId userHandle serviceHandle = do
  postgresM $ PG.runTransaction do
    mServiceId <- Q.verifyServiceName cluster userId userHandle serviceHandle
    case mServiceId of
      Nothing -> pure Nothing
      Just serviceId -> Q.currentDeploymentByService cluster serviceId

environmentByDeployment :: ClusterId -> UserId -> DeploymentHash -> WebApp (Maybe EnvironmentId)
environmentByDeployment cluster uid hash = do
  envId <- postgresM $ PG.runTransaction (Q.environmentByDeployment cluster hash)
  case envId of
    Nothing -> pure Nothing
    Just eid -> do
      checkEnvironmentAccess cluster uid eid
      pure (Just eid)

verifyDeploymentOwnership :: ClusterId -> UserId -> DeploymentHash -> WebApp ()
verifyDeploymentOwnership cluster userId deploymentHash =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      me <- Q.verifyDeploymentOwnership cluster userId deploymentHash
      if me
        then pure (Right ())
        else pure $ Left CloudNotAuthorized
