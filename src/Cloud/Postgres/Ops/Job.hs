module Cloud.Postgres.Ops.Job
( recordJobRun
)
where
import Share.OAuth.Types (UserId)
import Cloud.Web.App (WebApp)
import qualified Cloud.Postgres as PG
import qualified Cloud.Postgres.Queries as Q
import Cloud.Byoc.Env (ClusterId)
import Cloud.Postgres.App (postgresM)
import Cloud.Client.Messages (JobId)
import Cloud.Postgres.Ops.Environment (checkEnvironmentAccess)
import Cloud.Web.Types (EnvironmentId)

recordJobRun :: ClusterId -> UserId -> EnvironmentId -> WebApp JobId
recordJobRun cluster userId envId = do
  checkEnvironmentAccess cluster userId envId
  postgresM (PG.runTransaction tx)
  where
    tx = Q.recordJobRun cluster userId
