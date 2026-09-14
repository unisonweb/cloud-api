module Cloud.Postgres.Ops.Environment
  ( createEnvironment,
    deleteEnvironment,
    listEnvironments,
    checkEnvironmentAccess,
    checkOrgEnvironmentAccess,
  )
where

import Cloud.Byoc.Env (ClusterId)
import Cloud.Environment.Types
import Cloud.Errors (respondError)
import Cloud.Postgres qualified as PG
import Cloud.Postgres.App (postgresM)
import Cloud.Postgres.Ops.Byoc (checkClusterAccessM)
import Cloud.Postgres.Ops.Internal (orRespondError)
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.Utils.Logging (logErrorText)
import Cloud.Web.App (WebApp)
import Cloud.Web.Errors (CloudWebError (..))
import Cloud.Web.Types (EnvironmentId)
import Share.OAuth.Types (UserId)

createEnvironment :: ClusterId -> UserId -> UserId -> Text -> WebApp EnvironmentId
createEnvironment cluster uid ownerId name = do
  checkClusterAccessM cluster uid ownerId
  postgresM (PG.runTransaction (Q.createEnvironment cluster ownerId name))

deleteEnvironment :: ClusterId -> UserId -> EnvironmentId -> WebApp ()
deleteEnvironment cluster uid envId =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      access <- Q.verifyEnvironmentAccess cluster uid envId
      if access
        then Right <$> Q.deleteEnvironment cluster envId
        else pure $ Left CloudNotAuthorized

listEnvironments :: ClusterId -> UserId -> WebApp [UserEnvironment]
listEnvironments cluster uid =
  orRespondError =<< postgresM (PG.runTransaction tx)
  where
    tx = do
      cloud <- Q.isUserCloudUser uid
      if cloud
        then Right <$> Q.listEnvironments cluster uid
        else pure $ Left CloudNotCloudAccount

checkEnvironmentAccess :: ClusterId -> UserId -> EnvironmentId -> WebApp ()
checkEnvironmentAccess cluster uid envId = do
  access <- postgresM $ PG.runTransaction $ Q.verifyEnvironmentAccess cluster uid envId
  if access
    then pure ()
    else
      logErrorText
        ( "Unauthorized environment access attempt by user "
            <> tshow uid
            <> " for environment "
            <> tshow envId
            <> " for cluster "
            <> tshow cluster
        )
        >> respondError CloudNotAuthorized

checkOrgEnvironmentAccess :: ClusterId -> UserId -> UserId -> EnvironmentId -> WebApp ()
checkOrgEnvironmentAccess cluster uid ownerId envId = do
  access <- postgresM $ PG.runTransaction do
    x <- Q.verifyEnvironmentAccess cluster uid envId
    y <- Q.canUserActOnBehalf uid ownerId
    pure (x && y)
  if access
    then pure ()
    else 
      logErrorText
        ( "Unauthorized org environment access attempt by user "
            <> tshow uid
            <> " on behalf of owner "
            <> tshow ownerId
            <> " for environment "
            <> tshow envId
            <> " for cluster "
            <> tshow cluster
        )
        >>
      respondError CloudNotAuthorized