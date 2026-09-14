module Cloud.Postgres.Queries
  ( 
    recordJobRun,
    module Cloud.Postgres.Queries.Daemon,
    module Cloud.Postgres.Queries.Deployment,
    module Cloud.Postgres.Queries.Environment,
    module Cloud.Postgres.Queries.Metrics,
    module Cloud.Postgres.Queries.Service,
    module Cloud.Postgres.Queries.Storage,
    module Cloud.Postgres.Queries.Stripe,
    module Cloud.Postgres.Queries.User,
  )
where

import Cloud.Client.Messages (JobId)
import Cloud.Postgres qualified as PG
import Share.OAuth.Types (UserId)
import Cloud.Postgres.Queries.Daemon
import Cloud.Postgres.Queries.Deployment
import Cloud.Postgres.Queries.Environment
import Cloud.Postgres.Queries.Metrics
import Cloud.Postgres.Queries.Service
import Cloud.Postgres.Queries.Storage
import Cloud.Postgres.Queries.Stripe
import Cloud.Postgres.Queries.User
import Cloud.Byoc.Env (ClusterId)


recordJobRun :: ClusterId -> UserId -> PG.Transaction e JobId
recordJobRun clusterId userId = do
  PG.queryExpect1Col
    [PG.sql|
        INSERT INTO cloud_jobs (user_id, cluster_id)
          VALUES (#{userId}, #{clusterId})
          RETURNING id
      |]
