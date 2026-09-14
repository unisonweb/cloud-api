module Cloud.Postgres.Ops.Service
  ( createService,
    deleteService,
    getServiceByName,
    getServiceHistory,
    getServiceHistoryByName,
    getServiceId,
    listAllServiceTags,
    listServiceTags,
    listServices,
    listServicesByHash,
    listServicesByTag,
    listUntaggedServices,
    setServiceId,
    setServiceTag,
    unassignService,
    unsetServiceTag,
    userAssignServiceByName,
    userDeleteServiceByName,
    userUnassignServiceByName,
    getServiceAssignmentsByDeployment,
  )
where

import Cloud.Byoc.Env (ClusterId)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Postgres qualified as PG
import Cloud.Postgres.App (postgresM)
import Cloud.Postgres.Ops.Internal (orRespondError)
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.Service.Types
import Cloud.User.Types (User(..))
import Cloud.User.UserHandle (UserHandle(..))
import Cloud.Web.App (WebApp)
import Cloud.Web.Errors (CloudWebError (..))
import Cloud.Web.Types (DeploymentDetails (..))
import Share.OAuth.Types (UserId)
import Cloud.Events (fireServiceIdInvalidationEvent, fireUserServiceInvalidationEvent)

setServiceTag :: ClusterId -> UserId -> ServiceId -> Text -> WebApp ()
setServiceTag cluster userId serviceId name =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyServiceOwnership cluster userId serviceId
      if own
        then do
          Q.setServiceTag cluster userId serviceId name
          pure $ Right ()
        else pure $ Left CloudNotAuthorized

listServicesByTag :: ClusterId -> UserId -> Maybe Text -> WebApp [ServiceDetail]
listServicesByTag cluster uid name =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if cloud
        then
          Right <$> case name of
            Nothing -> do
              serviceIds <- Q.getUntaggedServices cluster uid
              traverse (Q.getServiceDetails cluster) serviceIds
            Just name -> do
              serviceIds <- Q.getServicesByTag cluster uid name
              traverse (Q.getServiceDetails cluster) serviceIds
        else pure $ Left CloudNotCloudAccount

listAllServiceTags :: ClusterId -> UserId -> WebApp [Text]
listAllServiceTags cluster uid =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if cloud
        then Right <$> Q.getAllServiceTags cluster uid
        else pure $ Left CloudNotCloudAccount

unsetServiceTag :: ClusterId -> UserId -> ServiceId -> Text -> WebApp ()
unsetServiceTag cluster userId serviceId tag =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyServiceOwnership cluster userId serviceId
      if own then Right <$> Q.unsetServiceTag cluster userId serviceId tag else pure $ Left CloudNotAuthorized

setServiceId :: ClusterId -> UserId -> ServiceId -> DeploymentHash -> WebApp (User, ServiceName)
setServiceId clusterId uid serviceId deploymentHash = orRespondError =<< do

  us <- orRespondError =<< postgresM (PG.runTransaction tx)
  case us of
    (Just user, Just sn) -> do
      fireServiceIdInvalidationEvent clusterId serviceId
      fireUserServiceInvalidationEvent clusterId (handle user) sn
      pure $ Right (user, sn)
    (Nothing, _) -> pure $ Left CloudNotAuthenticated
    (_, Nothing) -> pure $ Left $ ServiceIdNotFound serviceId

  where
    tx = do
      own <- Q.verifyServiceOwnership clusterId uid serviceId
      if not own
        then pure $ Left CloudNotAuthorized
        else do
          user <- Q.userByUserId uid
          latest <- Q.currentDeploymentByService clusterId serviceId
          serviceName <- Q.getServiceName clusterId serviceId
          when ((deploymentDetailsHash <$> latest) /= Just deploymentHash) $ Q.assignServiceId clusterId uid serviceId deploymentHash
          pure $ Right (user, serviceName)

unassignService :: ClusterId -> UserId -> ServiceId -> WebApp ()
unassignService clusterId uid serviceId = orRespondError =<< do
  mu <- orRespondError =<< postgresM (PG.runTransaction tx)
  case mu of
    (Just user, Just sn) -> do
      fireServiceIdInvalidationEvent clusterId serviceId
      fireUserServiceInvalidationEvent clusterId user.handle sn
      pure $ Right ()
    (Nothing, _) -> pure $ Left CloudNotAuthenticated
    (_, Nothing) -> pure $ Left (ServiceIdNotFound serviceId)

  where
    tx = do
      own <- Q.verifyServiceOwnership clusterId uid serviceId
      if not own
        then pure $ Left CloudNotAuthorized
        else do
          user <- Q.userByUserId uid
          serviceName <- Q.getServiceName clusterId serviceId
          Q.unassignServiceId clusterId serviceId
          pure $ Right (user, serviceName)

createService :: ClusterId -> UserId -> UserId -> ServiceName -> WebApp ServiceId
createService cluster uid owner name =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      canAct <- Q.canUserActOnBehalf uid owner
      if cloud
        then
          if canAct
            then do
              id <- Q.createServiceId cluster owner name
              pure $ Right id
            else pure $ Left CloudNotAuthorized
        else pure $ Left CloudNotCloudAccount

deleteService :: ClusterId -> UserId -> ServiceId -> WebApp ()
deleteService cluster uid id = do
  r <- orRespondError =<< postgresM (PG.runTransaction tx)

  fireServiceIdInvalidationEvent cluster id
  case r of
    (Just user, Just sn) -> fireUserServiceInvalidationEvent cluster (handle user) sn
    _ -> pure ()

  where
    tx = do
      own <- Q.verifyServiceOwnership cluster uid id
      if own
        then do
          user <- Q.userByUserId uid
          serviceName <- Q.getServiceName cluster id
          Q.deleteService cluster id
          pure $ Right (user, serviceName)
        else pure $ Left (ServiceIdNotFound id)

getServiceId :: ClusterId -> UserId -> ServiceId -> WebApp ServiceDetail
getServiceId cluster uid serviceId = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyServiceOwnership cluster uid serviceId
      if not own
        then pure $ Left (ServiceIdNotFound serviceId)
        else do
          Right <$> Q.getServiceDetails cluster serviceId

getServiceHistory :: ClusterId -> UserId -> ServiceId -> WebApp [ServiceAssignment]
getServiceHistory cluster uid serviceId = do
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      own <- Q.verifyServiceOwnership cluster uid serviceId
      if not own
        then pure $ Left (ServiceIdNotFound serviceId)
        else do
          Right <$> Q.getServiceHistory cluster serviceId

getServiceAssignmentsByDeployment :: ClusterId -> DeploymentHash -> WebApp [ServiceId]
getServiceAssignmentsByDeployment clusterId deploymentHash =
  postgresM $ PG.runTransaction $ Q.getServiceAssignmentsByDeployment clusterId deploymentHash

listServiceTags :: ClusterId -> UserId -> ServiceId -> WebApp [Text]
listServiceTags cluster userId serviceId =
  orRespondError =<< postgresM (PG.runTransaction text)
  where
    text = do
      own <- Q.verifyServiceOwnership cluster userId serviceId
      if own
        then Right <$> Q.getServiceTags cluster userId serviceId
        else pure $ Left CloudNotAuthorized

listUntaggedServices :: ClusterId -> UserId -> WebApp [ServiceDetail]
listUntaggedServices cluster userId =
  orRespondError =<< postgresM (PG.runTransaction text)
  where
    text = do
      cloud <- Q.isUserCloudUser userId
      if cloud
        then do
          serviceIds <- Q.getUntaggedServices cluster userId
          Right <$> traverse (Q.getServiceDetails cluster) serviceIds
        else pure $ Left CloudNotCloudAccount

listServices :: ClusterId -> UserId -> WebApp [ServiceDetail]
listServices cluster uid =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if not cloud
        then pure $ Left CloudNotCloudAccount
        else do
          ids <- Q.listServices cluster uid
          Right <$> traverse (Q.getServiceDetails cluster) ids

listServicesByHash :: ClusterId -> UserId -> DeploymentHash -> WebApp [ServiceId]
listServicesByHash cluster uid deploymentHash =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if not cloud then pure $ Left CloudNotCloudAccount else Right <$> Q.listServicesByHash cluster deploymentHash

getServiceByName :: ClusterId -> UserId -> UserHandle -> ServiceName -> WebApp (Maybe ServiceDetail)
getServiceByName cluster userId userHandle serviceHandle = do
  postgresM $ PG.runTransaction do
    mServiceId <- Q.verifyServiceName cluster userId userHandle serviceHandle
    case mServiceId of
      Nothing -> pure Nothing
      Just serviceId -> Just <$> Q.getServiceDetails cluster serviceId

userUnassignServiceByName :: ClusterId -> UserId -> UserHandle -> ServiceName -> WebApp ()
userUnassignServiceByName cluster uid userHandle serviceHandle = do
  mServiceId <- postgresM $ PG.runTransaction do
    mServiceId <- Q.verifyServiceName cluster uid userHandle serviceHandle
    forM_ mServiceId (Q.unassignServiceId cluster)

    pure mServiceId
  mapM_ (fireServiceIdInvalidationEvent cluster) mServiceId
  fireUserServiceInvalidationEvent cluster userHandle serviceHandle

userAssignServiceByName :: ClusterId -> UserId -> UserHandle -> ServiceName -> DeploymentHash -> WebApp ()
userAssignServiceByName cluster uid userHandle serviceHandle deploymentHash = do
  serviceId <- orRespondError =<< postgresM (PG.runTransaction tx)
  fireServiceIdInvalidationEvent cluster serviceId
  fireUserServiceInvalidationEvent cluster userHandle serviceHandle

  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if cloud
        then do
          (serviceId, _user) <- Q.getOrCreateServiceName cluster uid userHandle serviceHandle
          Q.assignServiceId cluster uid serviceId deploymentHash
          pure $ Right serviceId
        else pure $ Left CloudNotCloudAccount



userDeleteServiceByName :: ClusterId -> UserId -> UserHandle -> ServiceName -> WebApp ()
userDeleteServiceByName cluster uid userHandle serviceHandle = do
  mServiceId <- postgresM $ PG.runTransaction do
    mServiceId <- Q.verifyServiceName cluster uid userHandle serviceHandle
    forM_ mServiceId (Q.deleteService cluster)
    pure mServiceId
  mapM_ (fireServiceIdInvalidationEvent cluster) mServiceId


getServiceHistoryByName :: ClusterId -> UserId -> UserHandle -> ServiceName -> WebApp [ServiceAssignment]
getServiceHistoryByName cluster userId userHandle serviceHandle = do
  postgresM $ PG.runTransaction do
    mServiceId <- Q.verifyServiceName cluster userId userHandle serviceHandle
    case mServiceId of
      Nothing -> pure []
      Just serviceId -> Q.getServiceHistory cluster serviceId
