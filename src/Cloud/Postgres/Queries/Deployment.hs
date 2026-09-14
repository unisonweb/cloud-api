module Cloud.Postgres.Queries.Deployment
  ( createDeployment,
    deleteDeployment,
    exposeDeployment,
    getAllDeploymentTags,
    getDeploymentDetails,
    getDeploymentLogTime,
    getDeploymentTags,
    getDeploymentsByTag,
    getUntaggedDeployments,
    listDeployments,
    listUnassignedDeployments,
    setDeploymentTag,
    unexposeDeployment,
    unsetDeploymentTag,
    deploymentByServiceId,
    deploymentByServiceName,
    verifyDeploymentOwnership,
    environmentByDeployment,
  )
where

import Cloud.Byoc.Env (ClusterId)
import Cloud.Deployment.DeploymentHash
import Cloud.Postgres qualified as PG
import Cloud.Postgres.Queries.User (userByUserId)
import Cloud.Prelude
import Cloud.Service.Types (ServiceId, ServiceName)
import Cloud.User.Types (User (..))
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Types (DeploymentDetails (..), EnvironmentId, HttpServiceVersion)
import Data.Maybe (catMaybes)
import Data.Time (UTCTime)
import Share.OAuth.Types (UserId)

createDeployment :: ClusterId -> UserId -> EnvironmentId -> DeploymentHash -> PG.Transaction e ()
createDeployment clusterId user env sha256 = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_deployments (user_id, environment, deployment_hash, cluster_id)
          VALUES (#{user}, #{env}, #{sha256}, #{clusterId})
          ON CONFLICT DO NOTHING
      |]

deleteDeployment :: ClusterId -> UserId -> DeploymentHash -> PG.Transaction e ()
deleteDeployment clusterId handle sha256 = do
  PG.execute_
    [PG.sql|
        UPDATE cloud_deployments
          SET undeployed_at = NOW()
          WHERE user_id = #{handle}
            AND deployment_hash = #{sha256}
            AND cluster_id = #{clusterId}
      |]

exposeDeployment :: ClusterId -> UserId -> DeploymentHash -> HttpServiceVersion -> PG.Transaction e ()
exposeDeployment clusterId handle deployment version = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_web_deployments (user_id, deployment_hash, services_version, cluster_id)
        VALUES (#{handle}, #{deployment}, #{version}, #{clusterId})
        ON CONFLICT DO NOTHING
      |]

unexposeDeployment :: ClusterId -> UserId -> DeploymentHash -> PG.Transaction e ()
unexposeDeployment clusterId userId deployment = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_web_deployments
          WHERE user_id = #{userId}
            AND deployment_hash = #{deployment}
            AND cluster_id = #{clusterId}
      |]

verifyDeploymentOwnership :: ClusterId -> UserId -> DeploymentHash -> PG.Transaction e Bool
verifyDeploymentOwnership clusterId userId deploymentHash = do
  result <-
    PG.query1Col
      [PG.sql|
        SELECT EXISTS (
          SELECT 1 FROM cloud_deployments cd
            WHERE cd.user_id = #{userId}
              AND cd.deployment_hash = #{deploymentHash}
              AND cd.cluster_id = #{clusterId}
          OR EXISTS (
            SELECT 1 FROM cloud_deployments cd
            JOIN org_members om ON om.organization_user_id = cd.user_id
              WHERE om.member_user_id = #{userId}
                AND cd.deployment_hash = #{deploymentHash}
                AND cd.cluster_id = #{clusterId}
          )
        )
      |]
  pure $ fromMaybe False result

setDeploymentTag :: ClusterId -> UserId -> DeploymentHash -> Text -> PG.Transaction e ()
setDeploymentTag clusterId userId deploymentHash tag = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_deployment_tags (user_id, deployment_hash, tag, cluster_id)
          VALUES (#{userId}, #{deploymentHash}, #{tag}, #{clusterId})
          ON CONFLICT DO NOTHING
      |]

unsetDeploymentTag :: ClusterId -> UserId -> DeploymentHash -> Text -> PG.Transaction e ()
unsetDeploymentTag clusterId userId deploymentHash tag = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_deployment_tags
          WHERE user_id = #{userId}
            AND deployment_hash = #{deploymentHash}
            AND LOWER(tag) = LOWER(#{tag})
            AND cluster_id = #{clusterId}
      |]

listDeployments :: ClusterId -> UserId -> PG.Transaction e [DeploymentDetails]
listDeployments clusterId userId = do
  hashes <-
    PG.queryListCol
      [PG.sql|
        SELECT deployment_hash
          FROM cloud_deployments
          WHERE user_id = #{userId}
          AND cluster_id = #{clusterId}
      |]
  fmap catMaybes (mapM (getDeploymentDetails clusterId) hashes)

deploymentByServiceId :: ClusterId -> ServiceId -> PG.Transaction e (Maybe DeploymentHash)
deploymentByServiceId clusterId serviceId = do
  PG.query1Col
    [PG.sql|
        SELECT csa.deployment_hash
          FROM cloud_service_assignments csa
          WHERE csa.service_id = #{serviceId}
            AND csa.unassignment_time IS NULL
            AND csa.cluster_id = #{clusterId}
      |]

deploymentByServiceName :: ClusterId -> UserHandle -> ServiceName -> PG.Transaction e (Maybe DeploymentHash)
deploymentByServiceName clusterId userHandle serviceName = do
  PG.query1Col
    [PG.sql|
        SELECT deployment_hash
          FROM cloud_service_assignments csa
          JOIN cloud_services cs
            ON cs.id = csa.service_id
          JOIN users u
            ON u.id = csa.user_id
          WHERE u.handle = #{userHandle}
            AND cs.service_name = #{serviceName}
            AND csa.unassignment_time IS NULL
            AND csa.cluster_id = #{clusterId}
          ORDER BY csa.assignment_time DESC
          LIMIT 1
      |]

listUnassignedDeployments :: ClusterId -> UserId -> PG.Transaction e [DeploymentDetails]
listUnassignedDeployments clusterId userId = do
  details <-
    PG.queryListRows
      [PG.sql|
        SELECT d.deployment_hash, d.deployed_at, d.undeployed_at, d.user_id, cwd.deployed_at as exposed_at, cwd.undeployed_at as unexposed_at, u.name, u.primary_email, u.avatar_url, u.handle, u.private
          FROM cloud_deployments d
          JOIN users u
            ON d.user_id = u.id
          LEFT JOIN cloud_web_deployments cwd
            ON d.deployment_hash = cwd.deployment_hash
          WHERE d.user_id = #{userId}
            AND d.cluster_id = #{clusterId}
            AND d.undeployed_at IS NULL
            AND NOT EXISTS (
              SELECT 1
              FROM cloud_service_assignments csa
              WHERE csa.deployment_hash = d.deployment_hash
            )
          ORDER BY d.deployed_at DESC
      |]
  pure (extract <$> details)
  where
    extract (deploymentDetailsHash, deploymentDetailsDeployedAt, deploymentDetailsUndeployedAt, user_id, deploymentDetailsExposureTime, deploymentDetailsUnexposureTime, user_name, user_email, avatar_url, handle, visibility) =
      DeploymentDetails {deploymentDetailsUser = User {..}, deploymentDetailsTags = [], ..}

getDeploymentsByTag :: ClusterId -> UserId -> Text -> PG.Transaction e [DeploymentHash]
getDeploymentsByTag clusterId userId tag = do
  PG.queryListCol
    [PG.sql|
        SELECT deployment_hash
          FROM cloud_deployment_tags
          WHERE user_id = #{userId}
            AND LOWER(tag) = LOWER(#{tag})
            AND cluster_id = #{clusterId}
      |]

getDeploymentTags :: ClusterId -> UserId -> DeploymentHash -> PG.Transaction e [Text]
getDeploymentTags clusterId userId deploymentHash = do
  PG.queryListCol
    [PG.sql|
        SELECT DISTINCT tag
          FROM cloud_deployment_tags
          WHERE user_id = #{userId}
            AND deployment_hash = #{deploymentHash}
            AND cluster_id = #{clusterId}
      |]

getUntaggedDeployments :: ClusterId -> UserId -> PG.Transaction e [DeploymentHash]
getUntaggedDeployments clusterId userId = do
  PG.queryListCol
    [PG.sql|
        SELECT deployment_hash
          FROM cloud_deployments
          WHERE user_id = #{userId}
            AND cluster_id = #{clusterId}
            AND deployment_hash NOT IN (
              SELECT deployment_hash
                FROM cloud_deployment_tags
                WHERE user_id = #{userId}
                AND cluster_id = #{clusterId}
            )
      |]

getAllDeploymentTags :: ClusterId -> UserId -> PG.Transaction e [Text]
getAllDeploymentTags clusterId userId = do
  PG.queryListCol
    [PG.sql|
        SELECT DISTINCT tag
          FROM cloud_deployment_tags
          WHERE user_id = #{userId}
            AND cluster_id = #{clusterId}
          ORDER BY tag ASC
      |]

getDeploymentDetails :: ClusterId -> DeploymentHash -> PG.Transaction e (Maybe DeploymentDetails)
getDeploymentDetails clusterId deploymentHash = do
  row <-
    PG.query1Row
      [PG.sql|
        SELECT deployment_hash, deployed_at, undeployed_at, user_id
          FROM cloud_deployments
          WHERE deployment_hash = #{deploymentHash}
          AND cluster_id = #{clusterId}
      |]
  case row of
    Nothing -> pure Nothing
    Just (hash, da, uda, userid) -> do
      meu <-
        PG.query1Row
          [PG.sql|
            SELECT deployed_at, undeployed_at
              FROM cloud_web_deployments
              WHERE deployment_hash = #{hash}
              AND cluster_id = #{clusterId}
          |]

      let (expose, unexpose) = case meu of
            Just (a, ua) -> (Just a, ua)
            Nothing -> (Nothing, Nothing)
      userm <- userByUserId userid
      user <- case userm of
        Nothing -> error "User not found"
        Just u -> pure u
      tags <- getDeploymentTags clusterId userid hash
      pure $ Just (DeploymentDetails hash da uda expose unexpose user tags)

getDeploymentLogTime :: ClusterId -> DeploymentHash -> PG.Transaction e (Maybe UTCTime)
getDeploymentLogTime clusterId deploymentHash = do
  PG.execute_
    [PG.sql|
        SELECT (deployed_at - Interval '1 day') as deployed_at
          INTO TEMP TABLE temp1
          FROM cloud_deployments
          WHERE deployment_hash = #{deploymentHash}
          AND cluster_id = #{clusterId}
      |]
  PG.execute_
    [PG.sql|
        INSERT INTO temp1 VALUES (now() - Interval '720 hours')
      |]
  t <-
    PG.query1Col
      [PG.sql|
        SELECT max (deployed_at) from temp1
      |]
  PG.execute_
    [PG.sql|
        DROP TABLE temp1;
      |]
  pure t

environmentByDeployment :: ClusterId -> DeploymentHash -> PG.Transaction e (Maybe EnvironmentId)
environmentByDeployment clusterId deploymentHash = do
  PG.query1Col
    [PG.sql|
        SELECT ce.id FROM cloud_environments ce
          JOIN cloud_deployments cd ON cd.environment= ce.id
          WHERE cd.deployment_hash = #{deploymentHash}
            AND ce.cluster_id = #{clusterId}
      |]
