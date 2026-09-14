module Cloud.Postgres.Queries.BYOC
  ( clusterConfigById,
    clusterConfigByHostname,
    clusterIdByHostname,
    verifyClusterAccess,
    clusterConfigByToken,
    createCluster,
    setClusterURI,
    generateNewClusterToken,
    updateClusterScheme,
    verifyClusterManager,
  )
where

import Cloud.Byoc.Env (ClusterConfig, ClusterId, ClusterToken (..), SchemeType)
import Cloud.Postgres qualified as PG
import Cloud.Prelude
import Crypto.Hash (Digest, SHA512, hash)
import Data.Text.Encoding (encodeUtf8)
import Network.URI (URI)
import Share.OAuth.Types (UserId)

clusterConfigById :: ClusterId -> PG.Transaction e ClusterConfig
clusterConfigById clusterId =
  PG.queryExpect1Row
    [PG.sql|
       SELECT id,
              name,
              hostname,
              service_uri_type,
              service_uri,
              cluster_uri,
              loki_uri,
              loki_task_name,
              user_id
        FROM cloud_clusters WHERE id = #{clusterId}
    |]

clusterIdByHostname :: Text -> PG.Transaction e (Maybe ClusterId)
clusterIdByHostname hostname = do
  PG.query1Col
    [PG.sql|
          SELECT id FROM cloud_clusters WHERE hostname = #{hostname}
        |]

clusterConfigByHostname :: Text -> PG.Transaction e (Maybe ClusterConfig)
clusterConfigByHostname hostname =
  PG.query1Row
    [PG.sql|
       SELECT id,
              name,
              hostname,
              service_uri_type,
              service_uri,
              cluster_uri,
              loki_uri,
              loki_task_name,
              user_id
        FROM cloud_clusters WHERE hostname = #{hostname}
    |]

updateClusterScheme :: ClusterId -> SchemeType -> PG.Transaction e ()
updateClusterScheme clusterId schemeType =
  PG.execute_
    [PG.sql|
        UPDATE cloud_clusters SET service_uri_type = #{schemeType} :: uri_type WHERE id = #{clusterId}
    |]

createCluster :: Text -> Text -> SchemeType -> UserId -> UserId -> PG.Transaction e ClusterId
createCluster name hostname schemeType userId ownerId = do
  PG.queryExpect1Col
    [PG.sql|
       INSERT INTO cloud_clusters (name, hostname, service_uri_type, loki_task_name, user_id, created_by)
       VALUES (#{name}, #{hostname}, #{schemeType} :: uri_type, #{name}, #{userId}, #{ownerId})
       RETURNING id
    |]

setClusterURI :: ClusterId -> URI -> PG.Transaction e ()
setClusterURI clusterId uri = do
  let uriText = tshow uri
  PG.execute_
    [PG.sql|
       UPDATE cloud_clusters SET cluster_uri = #{uriText}, service_uri = #{uriText} WHERE id = #{clusterId}
    |]

clusterConfigByToken :: ClusterToken -> PG.Transaction e (Maybe ClusterConfig)
clusterConfigByToken (ClusterToken token) =
  let hashed :: Digest SHA512
      hashed = hash $ encodeUtf8 token
      hashedText = tshow hashed
   in PG.query1Row
        [PG.sql|
         SELECT cc.id,
                cc.name,
                cc.hostname,
                cc.service_uri_type,
                cc.service_uri,
                cc.cluster_uri,
                cc.loki_uri,
                cc.loki_task_name,
                cct.created_by AS user_id
          FROM cloud_cluster_tokens cct
          JOIN cloud_clusters cc ON cct.cluster_id = cc.id
          WHERE cct.token_hash = #{hashedText}
      |]

verifyClusterAccess :: ClusterId -> UserId -> PG.Transaction e Bool
verifyClusterAccess clusterId userId =
  PG.queryExpect1Col
    [PG.sql|
       SELECT EXISTS (
         SELECT 1 FROM cloud_clusters cc
         WHERE cc.id = #{clusterId}
           AND (cc.created_by = #{userId} OR cc.user_id = #{userId})
             OR EXISTS (
             SELECT 1 FROM org_members om
             JOIN cloud_clusters cc2 ON om.organization_user_id = cc2.user_id
             WHERE cc2.id = #{clusterId}
               AND om.member_user_id = #{userId}
             )
       )
    |]

verifyClusterManager :: ClusterId -> UserId -> PG.Transaction e Bool
verifyClusterManager clusterId userId =
  PG.queryExpect1Col
    [PG.sql|
       SELECT EXISTS (
         (SELECT 1 FROM cloud_clusters cc
         WHERE cc.id = #{clusterId}
           AND (cc.created_by = #{userId} OR cc.user_id = #{userId})
             OR (SELECT user_has_org_permission(#{userId}::uuid, (SELECT user_id FROM cloud_clusters WHERE id = #{clusterId}), 'org:manage'))
       ))
    |]

generateNewClusterToken :: UserId -> ClusterId -> PG.Transaction e ClusterToken
generateNewClusterToken userId clusterId = do
  tokenText <-
    PG.queryExpect1Col
      [PG.sql|
      WITH new_token AS (
        SELECT gen_random_uuid()::text AS token
      )
      INSERT INTO cloud_cluster_tokens (cluster_id, created_by, token_hash, expires_at)
      SELECT #{clusterId},
             #{userId},
             encode(sha512(token :: bytea), 'hex'),
             NOW() + INTERVAL '1 year'
      FROM new_token
      RETURNING (SELECT token FROM new_token)
    |]
  pure $ ClusterToken tokenText
