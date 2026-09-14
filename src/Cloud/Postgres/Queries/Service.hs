{-# LANGUAGE DeriveAnyClass #-}

module Cloud.Postgres.Queries.Service
  ( assignServiceId,
    createServiceId,
    currentDeploymentByService,
    deleteService,
    getAllServiceTags,
    getOrCreateServiceName,
    getServiceDetails,
    getServiceHistory,
    getServiceName,
    getServiceTags,
    getServicesByTag,
    getUntaggedServices,
    listServices,
    listServicesByHash,
    setServiceTag,
    unassignServiceId,
    unsetServiceTag,
    verifyServiceName,
    verifyServiceOwnership,
    getServiceAssignmentsByDeployment,
  )
where

import Cloud.Byoc.Env (ClusterId)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Postgres qualified as PG
import Cloud.Postgres.Queries.Deployment (getDeploymentDetails, getDeploymentTags)
import Cloud.Postgres.Queries.Internal (validateCloudUserHandle)
import Cloud.Postgres.Queries.User (userByUserId)
import Cloud.Prelude
import Cloud.Service.Types
import Cloud.User.Types (User (..), UserVisibility)
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Types (DeploymentDetails (..))
import Data.Time (UTCTime)
import Share.OAuth.Types (UserId)
import Share.Utils.URI (URIParam)

getServiceTags :: ClusterId -> UserId -> ServiceId -> PG.Transaction e [Text]
getServiceTags clusterId userId serviceId = do
  PG.queryListCol
    [PG.sql|
        SELECT DISTINCT tag
          FROM cloud_service_tags
          WHERE user_id = #{userId}
            AND service_id = #{serviceId}
            AND cluster_id = #{clusterId}
      |]

setServiceTag :: ClusterId -> UserId -> ServiceId -> Text -> PG.Transaction e ()
setServiceTag clusterId userId serviceId tag = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_service_tags (user_id, service_id, tag, cluster_id)
          VALUES (#{userId}, #{serviceId}, #{tag}, #{clusterId})
          ON CONFLICT DO NOTHING
      |]

unsetServiceTag :: ClusterId -> UserId -> ServiceId -> Text -> PG.Transaction e ()
unsetServiceTag clusterId userId serviceId tag = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_service_tags
          WHERE user_id = #{userId}
            AND service_id = #{serviceId}
            AND LOWER(tag) = LOWER(#{tag})
            AND cluster_id = #{clusterId}
      |]

getAllServiceTags :: ClusterId -> UserId -> PG.Transaction e [Text]
getAllServiceTags clusterId userId = do
  PG.queryListCol
    [PG.sql|
        SELECT DISTINCT tag
          FROM cloud_service_tags
          WHERE user_id = #{userId}
          AND cluster_id = #{clusterId}
      |]

getServicesByTag :: ClusterId -> UserId -> Text -> PG.Transaction e [ServiceId]
getServicesByTag clusterId userId tag = do
  PG.queryListCol
    [PG.sql|
        SELECT service_id
          FROM cloud_service_tags
          WHERE user_id = #{userId}
            AND LOWER(tag) = LOWER(#{tag})
            AND cluster_id = #{clusterId}
      |]

getUntaggedServices :: ClusterId -> UserId -> PG.Transaction e [ServiceId]
getUntaggedServices clusterId userId = do
  PG.queryListCol
    [PG.sql|
        SELECT id
          FROM cloud_services
          WHERE user_id = #{userId}
            AND id NOT IN (
              SELECT service_id
                FROM cloud_service_tags
                WHERE user_id = #{userId}
                  AND cluster_id = #{clusterId}
            )
      |]

verifyServiceOwnership :: ClusterId -> UserId -> ServiceId -> PG.Transaction e Bool
verifyServiceOwnership clusterId userId serviceId = do
  result <-
    PG.query1Col
      [PG.sql|
        SELECT EXISTS (
          SELECT 1 FROM cloud_services cs
            JOIN cloud_users cu ON cu.user_id = cs.user_id
            WHERE cs.user_id = #{userId}
              AND cs.id = #{serviceId}
              AND cs.cluster_id = #{clusterId}
        ) OR EXISTS (
          SELECT 1 FROM cloud_services cs
          JOIN org_members om ON om.organization_user_id = cs.user_id
            WHERE om.member_user_id = #{userId}
              AND cs.id = #{serviceId}
              AND cs.cluster_id = #{clusterId}
        )
      |]
  pure $ fromMaybe False result

verifyServiceName :: ClusterId -> UserId -> UserHandle -> ServiceName -> PG.Transaction e (Maybe ServiceId)
verifyServiceName clusterId userId userHandle name = do
  PG.query1Col
    [PG.sql|
        SELECT cs.id
          FROM cloud_services cs
          JOIN cloud_users cu ON cu.user_id = cs.user_id
          JOIN users u ON u.id = cu.user_id
          WHERE cs.user_id = #{userId}
            AND cs.service_name = LOWER(#{name})
            AND LOWER(u.handle) = LOWER(#{userHandle})
            AND cs.cluster_id = #{clusterId}
      |]

getOrCreateServiceName :: ClusterId -> UserId -> UserHandle -> ServiceName -> PG.Transaction e (ServiceId, User)
getOrCreateServiceName clusterId userId userHandle name = do
  mbUser <- validateCloudUserHandle userId userHandle
  case mbUser of
    Just user -> do
      id <-
        PG.queryExpect1Col
          [PG.sql|
            INSERT INTO cloud_services (user_id, service_name, cluster_id)
            VALUES (#{userId}, LOWER(#{name}), #{clusterId})
            ON CONFLICT (user_id, service_name, cluster_id) DO UPDATE
            SET service_name = EXCLUDED.service_name
            RETURNING id;
          |]
      pure (id, user)
    Nothing -> error "Invalid user handle"

createServiceId :: ClusterId -> UserId -> ServiceName -> PG.Transaction e ServiceId
createServiceId clusterId userId name = do
  PG.queryExpect1Col
    [PG.sql|
        INSERT INTO cloud_services (user_id, service_name, cluster_id)
        VALUES (#{userId}, LOWER(#{name}), #{clusterId})
        ON CONFLICT (user_id, service_name, cluster_id) DO UPDATE
        SET service_name = EXCLUDED.service_name
        RETURNING id;
      |]

getServiceName :: ClusterId -> ServiceId -> PG.Transaction e (Maybe ServiceName)
getServiceName clusterId serviceId = do
  PG.query1Col
    [PG.sql|
        SELECT service_name
          FROM cloud_services
          WHERE id = #{serviceId}
            AND cluster_id = #{clusterId}
      |]

assignServiceId :: ClusterId -> UserId -> ServiceId -> DeploymentHash -> PG.Transaction e ()
assignServiceId clusterId userId serviceId serviceHash = do
  PG.execute_
    [PG.sql|
        UPDATE cloud_service_assignments
          SET unassignment_time = NOW()
          WHERE service_id = #{serviceId}
            AND unassignment_time IS NULL
            AND cluster_id = #{clusterId}
      |]
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_service_assignments (user_id, service_id, deployment_hash, cluster_id)
          VALUES (#{userId}, #{serviceId}, #{serviceHash}, #{clusterId})
      |]

unassignServiceId :: ClusterId -> ServiceId -> PG.Transaction e ()
unassignServiceId clusterId serviceId = do
  PG.execute_
    [PG.sql|
        UPDATE cloud_service_assignments
          SET unassignment_time = NOW()
          WHERE service_id = #{serviceId}
            AND unassignment_time IS NULL
            AND cluster_id = #{clusterId}
      |]

getServiceAssignmentsByDeployment :: ClusterId -> DeploymentHash -> PG.Transaction e [ServiceId]
getServiceAssignmentsByDeployment clusterId deploymentHash =
  PG.queryListCol
    [PG.sql|
        SELECT distinct service_id
          FROM cloud_service_assignments
          WHERE deployment_hash = #{deploymentHash}
            AND cluster_id = #{clusterId}
            AND unassignment_time IS NULL
      |]

currentDeploymentByService :: ClusterId -> ServiceId -> PG.Transaction e (Maybe DeploymentDetails)
currentDeploymentByService clusterId serviceId = do
  row <-
    PG.query1Row
      [PG.sql|
        SELECT csa.deployment_hash, csa.assignment_time, csa.unassignment_time, csa.user_id, cd.environment
        FROM cloud_service_assignments csa
        LEFT JOIN cloud_deployments cd
          ON csa.deployment_hash = cd.deployment_hash

        WHERE csa.service_id = #{serviceId}
          AND csa.unassignment_time IS NULL
          AND csa.cluster_id = #{clusterId}
        ORDER BY assignment_time DESC
        LIMIT 1
      |]
  case row of
    Nothing -> pure Nothing
    Just (hash, da, uda, userid) -> do
      ea <-
        PG.query1Row
          [PG.sql|
          SELECT deployed_at, undeployed_at
          FROM cloud_web_deployments
          WHERE deployment_hash = #{hash}
            AND cluster_id = #{clusterId}
        |]
      let (expose, unexpose) = case ea of
            Nothing -> (Nothing, Nothing)
            Just (a, ua) -> (Just a, ua)

      userm <- userByUserId userid
      user <- case userm of
        Nothing -> error "User not found"
        Just u -> pure u
      tags <- getDeploymentTags clusterId userid hash
      pure $ Just (DeploymentDetails hash da uda expose unexpose user tags)

data ServiceAssignmentRow = ServiceAssignmentRow
  { serviceAssignmentHash :: DeploymentHash,
    serviceDeployedAt :: UTCTime,
    serviceUndeployedAt :: Maybe UTCTime,
    serviceAssignmentTime :: UTCTime,
    serviceUnassignementTime :: Maybe UTCTime,
    serviceExposedTime :: Maybe UTCTime,
    serviceUnexposedTime :: Maybe UTCTime,
    serviceDeployedByUserId :: UserId,
    serviceDeployedByUserName :: Maybe Text,
    serviceDeployedByUserEmail :: Text,
    serviceDeployedByAvatarUrl :: URIParam,
    serviceDeployedByHandle :: UserHandle,
    serviceDeployedByVisibility :: UserVisibility,
    serviceAssignedByUserId :: UserId,
    serviceAssignedByUserName :: Maybe Text,
    serviceAssignedByUserEmail :: Text,
    serviceAssignedByAvatarUrl :: URIParam,
    serviceAssignedByHandle :: UserHandle,
    serviceAssignedByVisibility :: UserVisibility
  }
  deriving stock (Generic)
  deriving anyclass (PG.DecodeRow)

serviceAssignmentFromRow :: ServiceAssignmentRow -> ServiceAssignment
serviceAssignmentFromRow ServiceAssignmentRow {..} =
  ServiceAssignment {serviceAssignmentTags = [], ..}
  where
    serviceDeployedBy =
      User
        { user_id = serviceDeployedByUserId,
          user_name = serviceDeployedByUserName,
          user_email = serviceDeployedByUserEmail,
          avatar_url = serviceDeployedByAvatarUrl,
          handle = serviceDeployedByHandle,
          visibility = serviceDeployedByVisibility
        }
    serviceAssignmentUser =
      User
        { user_id = serviceAssignedByUserId,
          user_name = serviceAssignedByUserName,
          user_email = serviceAssignedByUserEmail,
          avatar_url = serviceAssignedByAvatarUrl,
          handle = serviceAssignedByHandle,
          visibility = serviceAssignedByVisibility
        }

getServiceHistory :: ClusterId -> ServiceId -> PG.Transaction e [ServiceAssignment]
getServiceHistory clusterId serviceId = do
  rows <-
    PG.queryListRows
      [PG.sql|
        SELECT d.deployment_hash, d.deployed_at, d.undeployed_at, csa.assignment_time, csa.unassignment_time, cwd.deployed_at as exposed_at, cwd.undeployed_at as unexposed_at, du.id, du.name, du.primary_email, du.avatar_url, du.handle, du.private, su.id, su.name, su.primary_email, su.avatar_url, su.handle, su.private
        FROM cloud_deployments d
        JOIN cloud_service_assignments csa
          ON d.deployment_hash = csa.deployment_hash
        JOIN users du
          ON d.user_id = du.id
        JOIN users su
          ON csa.user_id = su.id
        LEFT JOIN cloud_web_deployments cwd
          ON d.deployment_hash = cwd.deployment_hash
        WHERE csa.service_id = #{serviceId}
          AND csa.cluster_id = #{clusterId}
        ORDER BY csa.assignment_time DESC
      |]
  pure (serviceAssignmentFromRow <$> rows)

deleteService :: ClusterId -> ServiceId -> PG.Transaction e ()
deleteService clusterId serviceId = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_services
          WHERE id = #{serviceId}
            AND cluster_id = #{clusterId}
      |]

getServiceDetails :: ClusterId -> ServiceId -> PG.Transaction e ServiceDetail
getServiceDetails clusterId serviceId = do
  (id, name, user_id) <-
    PG.queryExpect1Row
      [PG.sql|
        SELECT id, service_name, user_id
          FROM cloud_services
          WHERE id = #{serviceId}
            AND cluster_id = #{clusterId}
      |]
  user <- userByUserId user_id
  assignments <- getServiceHistory clusterId serviceId
  tags <-
    PG.queryListCol
      [PG.sql|
        SELECT tag
        FROM cloud_service_tags
        WHERE service_id = #{serviceId}
          AND cluster_id = #{clusterId}
      |]
  case assignments of
    (ServiceAssignment h _ _ _ _ _ _ _ _ Nothing) : _ -> do
      dd <- getDeploymentDetails clusterId h
      pure $ ServiceDetail id name user dd tags
    _ -> pure $ ServiceDetail id name user Nothing tags

listServices :: ClusterId -> UserId -> PG.Transaction e [ServiceId]
listServices clusterId userId = do
  PG.queryListCol
    [PG.sql|
        SELECT id
        FROM cloud_services
        WHERE user_id = #{userId}
          AND cluster_id = #{clusterId}
      |]

listServicesByHash :: ClusterId -> DeploymentHash -> PG.Transaction e [ServiceId]
listServicesByHash clusterId serviceHash = do
  PG.queryListCol
    [PG.sql|
        SELECT service_id
        FROM cloud_service_assignments
        WHERE deployment_hash = #{serviceHash}
          AND unassignment_time IS NULL
          AND cluster_id = #{clusterId}
      |]
