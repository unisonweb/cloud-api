{-# LANGUAGE StandaloneDeriving #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- YOLO

module Cloud.Postgres.Queries.Daemon
(
    getOrCreateDaemonName,
    deleteDaemon,
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
    verifyDaemonOwnership,
    assignDaemon,
    unassignDaemon,
    deleteDaemonName,
    createDaemon,
    daemonAccess,
    getDaemonAssignmentsByHash,

) where
import Share.OAuth.Types (UserId)
import Cloud.Daemon.Types
import Data.Text
import qualified Cloud.Postgres as PG
import Cloud.Prelude
import Cloud.Postgres.Queries.User (userByUserId)
import Data.Traversable (for)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Byoc.Env (ClusterId)
import Cloud.Web.Types (EnvironmentId)


daemonAccess :: UserId -> PG.Transaction e Bool
daemonAccess userId = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT EXISTS (SELECT 1 from cloud_daemon_users where id = #{userId})
      |]


getOrCreateDaemonName :: ClusterId -> UserId -> DaemonName -> PG.Transaction e DaemonId
getOrCreateDaemonName clusterId userId name = do
  PG.queryExpect1Col
    [PG.sql|
        INSERT INTO cloud_daemon_names (user_id, daemon_name, cluster_id)
        VALUES (#{userId}, #{name}, #{clusterId})
        ON CONFLICT (user_id, daemon_name, cluster_id) DO UPDATE
        SET daemon_name = EXCLUDED.daemon_name
        RETURNING id
      |]

deleteDaemonName :: ClusterId -> UserId -> DaemonId -> PG.Transaction e ()
deleteDaemonName clusterId userId daemonId = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_daemon_names
          WHERE user_id = #{userId}
            AND id = #{daemonId}
            AND cluster_id = #{clusterId}
      |]

createDaemon :: ClusterId -> UserId -> EnvironmentId -> DeploymentHash -> PG.Transaction e ()
createDaemon clusterId user env sha256 = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_daemons (user_id, environment, daemon_hash, cluster_id)
          VALUES (#{user}, #{env}, #{sha256}, #{clusterId})
          ON CONFLICT DO NOTHING
      |]

deleteDaemon :: ClusterId -> UserId -> DeploymentHash -> PG.Transaction e ()
deleteDaemon clusterId userId sha256 = do
  PG.execute_
    [PG.sql|
        UPDATE cloud_daemon_assignments AS cda
          SET unassignment_time = NOW()
          FROM cloud_daemon_names AS cdn
          WHERE cda.daemon_hash = #{sha256}
          AND cda.cluster_id = #{clusterId}
          AND cdn.cluster_id = #{clusterId}
          AND cda.daemon_id = cdn.id
      |]
  PG.execute_
    [PG.sql|
        UPDATE cloud_daemons
          SET undeployed_at = NOW()
          WHERE user_id = #{userId}
            AND daemon_hash = #{sha256}
            AND cluster_id = #{clusterId}
      |]

listDaemons :: ClusterId -> UserId -> PG.Transaction e [DaemonDetails]
listDaemons clusterId userId = do
  rows <-
    PG.queryListRows
      [PG.sql|
        SELECT cd.id, cd.daemon_name, cd.user_id
          FROM cloud_daemon_names cd
          WHERE cd.user_id = #{userId}
            AND cd.cluster_id = #{clusterId}
      |]
  for rows $ \(id, name, user) -> do
    userm <- userByUserId user
    user <- case userm of
      Nothing -> error "User not found"
      Just u -> pure u
    tags <- getDaemonTags clusterId id
    assignment <- getCurrentDaemonAssignment clusterId id
    pure $ DaemonDetails id name user assignment tags

getDaemon :: ClusterId -> DaemonId -> PG.Transaction e DaemonDetails
getDaemon clusterId daemonId = do
  (name, user) <-
    PG.queryExpect1Row
      [PG.sql|
        SELECT cd.daemon_name, cd.user_id
          FROM cloud_daemon_names cd
          WHERE cd.id = #{daemonId}
          AND cd.cluster_id = #{clusterId}
      |]
  userm <- userByUserId user
  user <- case userm of
    Nothing -> error "User not found"
    Just u -> pure u
  tags <- getDaemonTags clusterId daemonId
  assignment <- getCurrentDaemonAssignment clusterId daemonId
  pure $ DaemonDetails daemonId name user assignment tags

getDaemonAssignmentsByHash:: ClusterId -> UserId -> DeploymentHash -> PG.Transaction e [DaemonId]
getDaemonAssignmentsByHash clusterId userId hash = do
    PG.queryListCol
      [PG.sql|
        SELECT cda.daemon_id
          FROM cloud_daemon_assignments cda
          JOIN cloud_daemons cd
            ON cd.daemon_hash = cda.daemon_hash
          WHERE cda.daemon_hash = #{hash}
          AND cd.user_id = #{userId}
          AND cda.unassignment_time IS NULL
          AND cd.cluster_id = #{clusterId}
      |]

getDaemonHistory :: ClusterId -> DaemonId -> PG.Transaction e [DaemonAssignment]
getDaemonHistory clusterId daemonId = do
  rows <-
    PG.queryListRows
      [PG.sql|
        SELECT cda.daemon_hash, cd.deployed_at, cda.assignment_time, cda.unassignment_time, cd.environment
          FROM cloud_daemon_assignments cda
          JOIN cloud_daemons cd
            ON cd.daemon_hash = cda.daemon_hash
          WHERE cda.daemon_id = #{daemonId}
          AND cd.cluster_id = #{clusterId}
          ORDER BY assignment_time DESC
      |]
  pure $ (\(daemonAssignmentHash, daemonAssignmentDeploymentTime, daemonAssignmentAssignmentTime, daemonAssignmentUnassignmentTime, daemonAssignmentEnvironment) -> DaemonAssignment { .. }) <$> rows

getAllDaemonTags :: ClusterId -> UserId -> PG.Transaction e [Text]
getAllDaemonTags clusterId userId = do
  PG.queryListCol
    [PG.sql|
        SELECT DISTINCT tag
          FROM cloud_daemon_tags
          WHERE user_id = #{userId}
            AND cluster_id = #{clusterId}
      |]

getDaemonsByTag :: ClusterId -> UserId -> Text -> PG.Transaction e [DaemonDetails]
getDaemonsByTag clusterId userId tag = do
  rows <-
    PG.queryListRows
      [PG.sql|
        SELECT cd.id, cd.daemon_name, cd.user_id
          FROM cloud_daemon_names cd
          JOIN cloud_daemon_tags cdt ON cdt.daemon_id = cd.id
          WHERE cdt.user_id = #{userId}
            AND cdt.tag = #{tag}
            AND cd.cluster_id = #{clusterId}
      |]
  for rows $ \(id, name, user) -> do
    userm <- userByUserId user
    user <- case userm of
      Nothing -> error "User not found"
      Just u -> pure u
    tags <- getDaemonTags clusterId id
    assignment <- getCurrentDaemonAssignment clusterId id
    pure $ DaemonDetails id name user assignment tags

setDaemonTag :: ClusterId -> UserId -> DaemonId -> Text -> PG.Transaction e ()
setDaemonTag clusterId userId daemonId tag = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_daemon_tags (user_id, daemon_id, tag, cluster_id)
          VALUES (#{userId}, #{daemonId}, #{tag}, #{clusterId})
          ON CONFLICT DO NOTHING
      |]

deleteDaemonTag :: ClusterId -> UserId -> DaemonId -> Text -> PG.Transaction e ()
deleteDaemonTag clusterId userId daemonId tag = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_daemon_tags
          WHERE user_id = #{userId}
            AND daemon_id = #{daemonId}
            AND tag = #{tag}
            AND cluster_id = #{clusterId}
      |]

getDaemonsWithoutTag :: ClusterId -> UserId -> PG.Transaction e [DaemonDetails]
getDaemonsWithoutTag clusterId userId = do
  rows <-
    PG.queryListRows
      [PG.sql|
        SELECT cd.id, cd.daemon_name, cd.user_id
          FROM cloud_daemon_names cd
          WHERE cd.user_id = #{userId}
            AND cd.id NOT IN (
              SELECT daemon_id
                FROM cloud_daemon_tags
                WHERE user_id = #{userId}
                  AND cluster_id = #{clusterId}
            )
      |]
  for rows $ \(id, name, user) -> do
    userm <- userByUserId user
    user <- case userm of
      Nothing -> error "User not found"
      Just u -> pure u
    assignment <- getCurrentDaemonAssignment clusterId id
    pure $ DaemonDetails id name user assignment []

getCurrentDaemonAssignment :: ClusterId -> DaemonId -> PG.Transaction e (Maybe DaemonAssignment)
getCurrentDaemonAssignment clusterId daemonId = do
  res <-
    PG.query1Row
      [PG.sql|
        SELECT cda.daemon_hash, cd.deployed_at, cda.assignment_time, cda.unassignment_time, cd.environment
          FROM cloud_daemon_assignments cda
          JOIN cloud_daemons cd
            ON cd.daemon_hash = cda.daemon_hash
          WHERE cda.daemon_id = #{daemonId}
          AND cda.unassignment_time IS NULL
          AND cd.cluster_id = #{clusterId}
          ORDER BY assignment_time DESC
          LIMIT 1
      |]
  pure $ (\(daemonAssignmentHash, daemonAssignmentDeploymentTime, daemonAssignmentAssignmentTime, daemonAssignmentUnassignmentTime, daemonAssignmentEnvironment) -> DaemonAssignment { .. }) <$> res


getDaemonTags :: ClusterId -> DaemonId -> PG.Transaction e [Text]
getDaemonTags clusterId daemonId = do
  PG.queryListCol
    [PG.sql|
        SELECT tag
          FROM cloud_daemon_tags
          WHERE daemon_id = #{daemonId}
            AND cluster_id = #{clusterId}
      |]

verifyDaemonOwnership :: ClusterId -> UserId -> DaemonId -> PG.Transaction e Bool
verifyDaemonOwnership clusterId userId daemonId = do
  result <-
    PG.query1Col
      [PG.sql|
        SELECT EXISTS (
          SELECT 1 FROM cloud_daemon_names cd
          JOIN cloud_users cu ON cu.user_id = cd.user_id
            WHERE cd.user_id = #{userId}
              AND cd.id = #{daemonId}
              AND cd.cluster_id = #{clusterId}
        ) OR EXISTS (
          SELECT 1 FROM cloud_daemon_names cd
          JOIN org_members om ON om.organization_user_id = cd.user_id
            WHERE om.member_user_id = #{userId}
              AND cd.id = #{daemonId}
              AND cd.cluster_id = #{clusterId}
        )
      |]
  pure $ fromMaybe False result

assignDaemon :: ClusterId -> DaemonId -> DeploymentHash -> PG.Transaction e ()
assignDaemon clusterId daemonId hash = do

  PG.execute_
    [PG.sql|
        UPDATE cloud_daemon_assignments
          SET unassignment_time = now()
          WHERE daemon_id = #{daemonId}
            AND unassignment_time IS NULL
            AND cluster_id = #{clusterId}
      |]
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_daemon_assignments (daemon_id, daemon_hash, cluster_id)
          VALUES (#{daemonId}, #{hash}, #{clusterId})
      |]

unassignDaemon :: ClusterId -> DaemonId -> PG.Transaction e ()
unassignDaemon clusterId daemonId = do
  PG.execute_
    [PG.sql|
        UPDATE cloud_daemon_assignments
          SET unassignment_time = now()
          WHERE daemon_id = #{daemonId}
            AND unassignment_time IS NULL
            AND cluster_id = #{clusterId}
      |]

environmentByDaemonHash :: ClusterId -> DeploymentHash -> PG.Transaction e EnvironmentId
environmentByDaemonHash clusterId daemonHash = do
  PG.queryExpect1Col
    [PG.sql|
        SELECT ce.id FROM cloud_environments ce
          JOIN cloud_daemons cd ON cd.environment = ce.id
          WHERE cd.daemon_hash = #{daemonHash}
            AND ce.cluster_id = #{clusterId}
      |]

deriving instance PG.EncodeValue DaemonId
deriving instance PG.DecodeValue DaemonId

deriving instance PG.EncodeValue DaemonName
deriving instance PG.DecodeValue DaemonName
