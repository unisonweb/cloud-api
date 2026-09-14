module Cloud.Postgres.Ops.Byoc
  ( clusterConfigById,
    clusterConfigByHostname,
    clusterIdByHost,
    checkClusterAccess,
    clusterConfigByToken,
    checkClusterAccessM,
    checkClusterOwnerM,
    createCluster,
    setClusterURI,
    generateNewClusterToken,
    checkClusterOrgAccess
  )
where

import Cloud.Byoc.Env (ClusterEnv(..), ClusterId, ClusterConfig(..), ClusterToken, SchemeType, defaultClusterId)
import Cloud.Postgres qualified as PG
import Cloud.Postgres.App (postgresM)
import Cloud.Postgres.Queries.BYOC qualified as Q
import Cloud.Web.App (WebApp)
import Control.Monad.Reader (ask)
import Cloud.Env (Env(..))
import Share.OAuth.Types (UserId)
import Control.Monad (unless)
import Cloud.Errors (respondError)
import Cloud.Web.Errors (CloudWebError(..))
import Cloud.Web.Types (CloudApiHost, cloudApiHostname)
import Cloud.Prelude
import Cloud.Domain.Types (DomainName(DomainName))
import qualified Cloud.Postgres.Queries as Q
import Network.URI (URI)
import Cloud.Utils.Logging (logErrorText)

clusterConfigById :: ClusterId -> WebApp ClusterConfig
clusterConfigById clusterId = postgresM $ PG.runTransaction $ Q.clusterConfigById clusterId

clusterIdByHost :: CloudApiHost -> WebApp ClusterId
clusterIdByHost host = do
    clusterId <- postgresM $ PG.runTransaction $ Q.clusterIdByHostname (cloudApiHostname host)
--    _ <- logErrorText $ "Looking up cluster ID for host: " <> tshow (cloudApiHostname host) <> ", found cluster ID: " <> tshow clusterId
    case clusterId of
        Just cid -> pure cid
        Nothing ->
            respondError $ InvalidDomainName $ DomainName $ tshow $ cloudApiHostname host

clusterConfigByToken :: ClusterToken -> WebApp (Maybe ClusterConfig)
clusterConfigByToken token =
    postgresM $ PG.runTransaction $ Q.clusterConfigByToken token

clusterConfigByHostname :: CloudApiHost -> WebApp ClusterConfig
clusterConfigByHostname host = do
    maybeCluster <- postgresM $ PG.runTransaction $ Q.clusterConfigByHostname (cloudApiHostname host)
    case maybeCluster of
        Just config -> pure config
        Nothing -> respondError $ InvalidDomainName $ DomainName $ tshow $ cloudApiHostname host

createCluster :: Text -> SchemeType -> UserId -> UserId -> WebApp ClusterId
createCluster name schemeType userId ownerId = do
    Env { clusterEnv = ClusterEnv { envAPISuffix } } <- ask
    res <- postgresM $ PG.runTransaction $ tx envAPISuffix
    case res of
        Left e -> respondError e
        Right r -> pure r
    where
        tx envAPISuffix = do
                    oldCluster <- Q.clusterConfigByHostname (name <> "." <> envAPISuffix)
                    case oldCluster of
                        Just oldCluster ->
                            if oldCluster.clusterUserId /= userId
                                then pure $ Left CloudNotAuthorized
                                else do
                                    Q.updateClusterScheme oldCluster.clusterId schemeType
                                    pure $ Right oldCluster.clusterId
                        Nothing ->
                            if userId /= ownerId
                            then do
                                canAct <- Q.canUserActOnBehalf userId ownerId
                                if canAct
                                    then Right <$> Q.createCluster name (name <> "." <> envAPISuffix) schemeType userId ownerId
                                    else pure $ Left CloudNotAuthorized
                            else Right <$> Q.createCluster name (name <> "." <> envAPISuffix) schemeType userId ownerId

setClusterURI :: UserId -> ClusterId -> URI -> WebApp ()
setClusterURI userId clusterId uri = do
    checkClusterOwnerM clusterId userId
    postgresM $ PG.runTransaction $ Q.setClusterURI clusterId uri

checkClusterAccessM :: ClusterId -> UserId -> UserId -> WebApp ()
checkClusterAccessM clusterId userId ownerId = do
    access <- checkClusterOrgAccess clusterId userId ownerId
    unless access do 
        logErrorText 
            ( "Unauthorized cluster access attempt by user "
                <> tshow userId
                <> " on behalf of owner "
                <> tshow ownerId
                <> " for cluster "
                <> tshow clusterId
            )
        respondError CloudNotAuthorized

checkClusterOwnerM :: ClusterId -> UserId -> WebApp ()
checkClusterOwnerM clusterId userId = do
    access <- checkClusterOwner clusterId userId
    unless access $ do
        logErrorText ( "Unauthorized cluster owner access attempt by user "
                <> tshow userId
                <> " for cluster "
                <> tshow clusterId
            )
        respondError CloudNotAuthorized

checkClusterAccess :: ClusterId -> UserId -> WebApp Bool
checkClusterAccess clusterId userId = do
    -- If the clusterId is the default cluster, we allow access without checking
    -- Otherwise, we check access in the database
    if clusterId == defaultClusterId
        then pure True
        else postgresM $ PG.runTransaction $ Q.verifyClusterAccess clusterId userId

checkClusterOrgAccess :: ClusterId -> UserId -> UserId -> WebApp Bool
checkClusterOrgAccess clusterId userId ownerId = postgresM $ PG.runTransaction do
    -- If the clusterId is the default cluster, we allow access without checking
    -- Otherwise, we check access in the database
    if clusterId == defaultClusterId
        then Q.canUserActOnBehalf userId ownerId
        else do
            x <- Q.verifyClusterAccess clusterId userId
            y <- Q.canUserActOnBehalf userId ownerId 
            pure (x && y)

checkClusterOwner :: ClusterId -> UserId -> WebApp Bool
checkClusterOwner clusterId userId = do
    postgresM $ PG.runTransaction $ Q.verifyClusterManager clusterId userId

generateNewClusterToken :: UserId -> ClusterId -> WebApp ClusterToken
generateNewClusterToken userId clusterId = do
    checkClusterOwnerM clusterId userId
    postgresM $ PG.runTransaction $ Q.generateNewClusterToken userId clusterId
