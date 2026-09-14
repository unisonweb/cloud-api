module Cloud.Postgres.Queries.Environment
(
    createEnvironment,
    deleteEnvironment,
    listEnvironments,

    verifyEnvironmentAccess,

) where
import Share.OAuth.Types (UserId)
import Cloud.Environment.Types
import qualified Cloud.Postgres as PG
import Cloud.Prelude
import Cloud.Byoc.Env (ClusterId)
import Cloud.Web.Types (EnvironmentId (..))

verifyEnvironmentAccess :: ClusterId -> UserId -> EnvironmentId -> PG.Transaction e Bool
verifyEnvironmentAccess clusterId userId (EnvironmentId envId) = do
  result <-
    PG.query1Col
      [PG.sql|
        SELECT EXISTS (
          SELECT 1 FROM cloud_environments ce
            WHERE ce.user_id = #{userId}
              AND ce.id = #{envId}
              AND ce.cluster_id = #{clusterId}
          OR EXISTS (
            SELECT 1 FROM cloud_environments ce
            JOIN org_members om ON ce.user_id=om.organization_user_id
              WHERE om.member_user_id = #{userId}
                AND ce.id = #{envId}
                AND ce.cluster_id = #{clusterId}
          )
          OR EXISTS (
            SELECT 1 FROM cloud_supremes WHERE user_id = #{userId}
          )
    )
      |]
  pure $ fromMaybe False result

createEnvironment :: ClusterId -> UserId -> Text -> PG.Transaction e EnvironmentId
createEnvironment clusterId userId name = do
  PG.queryExpect1Col
    [PG.sql|
        INSERT INTO cloud_environments (user_id, name, cluster_id)
        VALUES (#{userId}, LOWER(#{name}), #{clusterId})
        ON CONFLICT (user_id, name, cluster_id) DO UPDATE
        SET name = EXCLUDED.name
        RETURNING id;
      |]

deleteEnvironment :: ClusterId -> EnvironmentId -> PG.Transaction e ()
deleteEnvironment clusterId envId = do
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_environments
          WHERE id = #{envId}
            AND cluster_id = #{clusterId}
      |]

listEnvironments :: ClusterId -> UserId -> PG.Transaction e [UserEnvironment]
listEnvironments clusterId userId = do
  PG.queryListRows
    [PG.sql|
        SELECT id, name FROM cloud_environments
          WHERE user_id = #{userId}
            AND cluster_id = #{clusterId}
      |]

