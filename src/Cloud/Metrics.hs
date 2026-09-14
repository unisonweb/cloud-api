{-# LANGUAGE RecordWildCards #-}

-- | Utilities for interacting with our metrics library.
--
-- If possible, try to keep details specific to our current metrics libraries isolated to
-- within this module so we can easily swap to new providers if needed.
module Cloud.Metrics
  ( serveMetricsMiddleware,
    requestMetricsMiddleware,
  )
where

import Cloud.Byoc.Env (ClusterId, envClusters)
import Cloud.Consul.API (CheckStatus (..), checkStatusToText)
import Cloud.Deployment qualified as Deployment
import Cloud.Env qualified as Env
import Cloud.Postgres qualified as PG
import Cloud.Postgres.Env (PostgresEnv (pgConnectionPool))
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.Utils.PathInfo
import Data.Int (Int64)
import Data.Map qualified as Map
import Data.Ratio ((%))
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding
import Data.Time qualified as Time
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Middleware.Prometheus qualified as Prom
import Prometheus qualified as Prom
import Prometheus.Metric.GHC qualified as Prom
import Servant
import Share.Utils.Show (tShow)
import System.Clock (Clock (..), diffTimeSpec, toNanoSecs)
import System.Clock qualified as Clock
import UnliftIO qualified
import Cloud.Cluster.Metrics (clusterConnectionCounts)

service :: Text
service = "cloud-api"

deployment :: Text
deployment = tShow Deployment.deployment

metricUpdateInterval :: Time.NominalDiffTime
metricUpdateInterval = 10 * 60 -- 10 mins

-- | Low resolution metrics that are updated rarely.
data SlowChangingMetrics = SlowChangingMetrics
  { deploymentsLastWeek :: Int64,
    servicesCreatedLastWeek :: Int64,
    serviceAssignmentsLastWeek :: Int64,
    storagePoolsCreatedLastWeek :: Int64,
    jobsRunLastWeek :: Int64,
    uniqueUsersLastWeek :: Int64,
    uniqueUsersLastMonth :: Int64,
    uniqueUsers :: Int64,
    everActiveUsers :: Int64,
    usersWithDeployments :: Int64,
    usersWithStorage :: Int64,
    usersWithJobs :: Int64,
    usersWithServices :: Int64,
    usersWithProjects :: Int64,
    usersWithJobsOrServicesLastWeek :: Int64,
    usersWithJobsOrServicesLastMonth :: Int64,
    usersWithDeploymentsNotProjectsLastWeek :: Int64,
    usersWithDeploymentsNotProjectsLastMonth :: Int64,
    activeSubscriptions :: Int64
  }

newtype OnDemandMetrics = OnDemandMetrics
  { clusterConnections :: Map (ClusterId, CheckStatus) Word
  }

-- | Serves the app's prometheus metrics at `/metrics`
serveMetricsMiddleware :: Env.Env x -> IO Wai.Middleware
serveMetricsMiddleware env = do
  Prom.register Prom.ghcMetrics
  getSlowMetrics <- atMostOnceEveryInterval metricUpdateInterval $ do
    runPG queryMetrics
  pure \app req handleResponse -> do
    refreshGauges getSlowMetrics getOnDemandMetrics
    Prom.prometheus prometheusSettings app req handleResponse
  where
    runPG = PG.runSessionWithPool ((pgConnectionPool . Env.postgresEnv) env) . PG.readTransaction
    prometheusSettings =
      Prom.def
        { Prom.prometheusEndPoint = ["metrics"],
          Prom.prometheusInstrumentApp = False,
          Prom.prometheusInstrumentPrometheus = False
        }
    getOnDemandMetrics = do
      clusterConnections <- UnliftIO.atomically $ clusterConnectionCounts env.clusterEnv.envClusters
      pure OnDemandMetrics {..}

-- | Record an event to the middleware metric.
requestMetricsMiddleware :: (HasPathInfo api) => Proxy api -> Wai.Middleware
requestMetricsMiddleware api app req handleResponse = do
  if recordRequest req
    then do
      start <- Clock.getTime Monotonic
      app req $ \resp ->
        do
          end <- Clock.getTime Monotonic
          let method = Just $ decodeUtf8 (Wai.requestMethod req)
          -- There's probably some nice way to do this with Servant.
          let path = Text.intercalate "/" <$> normalizePath api (Wai.pathInfo req)
          let status = Just $ Text.pack (show (HTTP.statusCode (Wai.responseStatus resp)))
          result <- handleResponse resp
          let latency :: Double
              latency = fromRational $ toRational (toNanoSecs (end `diffTimeSpec` start) % 1000000000)
          Prom.withLabel
            requestLatency
            (tShow Deployment.deployment, service, fromMaybe "" method, fromMaybe "" status, fromMaybe "unknown-path" path)
            (`Prom.observe` latency)
          pure result
    else app req handleResponse
  where
    ignoredPaths = Set.fromList [["health"], ["metrics"]]
    recordRequest req = Set.notMember (Wai.pathInfo req) ignoredPaths

{-# NOINLINE requestLatency #-}
requestLatency :: Prom.Vector Prom.Label5 Prom.Histogram
requestLatency =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service", "method", "status_code", "path") $
      Prom.histogram info Prom.defaultBuckets
  where
    info =
      Prom.Info
        "http_request_duration_seconds"
        "The HTTP request latencies in seconds."

{-# NOINLINE numClusterConnections #-}
numClusterConnections :: Prom.Vector Prom.Label4 Prom.Gauge
numClusterConnections =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service", "cluster", "health") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_cluster_connections"
        "The number of connections to a specific cluster from this cloud-api node"

--
-- This is useful for metrics that are expensive to compute and don't change often.
atMostOnceEveryInterval :: Time.NominalDiffTime -> IO a -> IO (IO a)
atMostOnceEveryInterval interval action = do
  lastRunRef <- UnliftIO.newMVar Nothing
  pure do
    now <- Time.getCurrentTime
    UnliftIO.modifyMVar lastRunRef \cached -> do
      case cached of
        Just (lastRunTime, result) ->
          if now `Time.diffUTCTime` lastRunTime < interval
            then pure (Just (lastRunTime, result), result)
            else refresh
        Nothing -> refresh
  where
    refresh = do
      result <- action
      now <- Time.getCurrentTime
      pure (Just (now, result), result)

-- | A collection of metrics that are expensive to compute and don't change often.
queryMetrics :: PG.Transaction e SlowChangingMetrics
queryMetrics = do
  deploymentsLastWeek <- Q.numDeploymentsLastWeek
  servicesCreatedLastWeek <- Q.numServicesCreatedLastWeek
  serviceAssignmentsLastWeek <- Q.numServiceAssignmentsLastWeek
  jobsRunLastWeek <- Q.numJobsRunLastWeek
  storagePoolsCreatedLastWeek <- Q.numStoragePoolsCreatedLastWeek
  uniqueUsersLastWeek <- Q.uniqueUsersLastWeek
  uniqueUsersLastMonth <- Q.uniqueUsersLastMonth
  uniqueUsers <- Q.uniqueUsers
  everActiveUsers <- Q.everActiveUsers
  usersWithDeployments <- Q.numUsersWithDeployments
  usersWithStorage <- Q.numUsersWithStorage
  usersWithJobs <- Q.numUsersWithJobs
  usersWithProjects <- Q.usersWithProjects
  usersWithServices <- Q.usersWithServices
  usersWithJobsOrServicesLastWeek <- Q.usersWithJobsOrServicesLastWeek
  usersWithJobsOrServicesLastMonth <- Q.usersWithJobsOrServicesLastMonth
  usersWithDeploymentsNotProjectsLastWeek <- Q.usersWithDeploymentsNotProjectsLastWeek
  usersWithDeploymentsNotProjectsLastMonth <- Q.userWithDeploymentsNotProjectsLastMonth
  activeSubscriptions <- Q.numActiveSubscriptions

  pure SlowChangingMetrics {..}

-- | Since some time-based metrics will change due to the passage of time rather than any
-- specific user action, we just refresh them whenever prometheus queries metrics for them.
-- Ensure that any queries here aren't too expensive since they'll be run often.
refreshGauges :: IO SlowChangingMetrics -> IO OnDemandMetrics -> IO ()
refreshGauges getSlowMetrics getOnDemandMetrics = do
  SlowChangingMetrics {..} <- getSlowMetrics
  Prom.withLabel numDeploymentsLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral deploymentsLastWeek)
  Prom.withLabel numServicesCreatedLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral servicesCreatedLastWeek)
  Prom.withLabel numServicesAssignedLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral serviceAssignmentsLastWeek)
  Prom.withLabel numStoragePoolsCreatedLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral storagePoolsCreatedLastWeek)
  Prom.withLabel numJobsRunLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral jobsRunLastWeek)
  Prom.withLabel numUniqueUsersLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral uniqueUsersLastWeek)
  Prom.withLabel numUniqueUsersLastMonth (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral uniqueUsersLastMonth)
  Prom.withLabel numUniqueUsers (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral uniqueUsers)
  Prom.withLabel numEverActiveUsers (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral everActiveUsers)
  Prom.withLabel numUsersWithDeployments (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithDeployments)
  Prom.withLabel numUsersWithStorage (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithStorage)
  Prom.withLabel numUsersWithJobs (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithJobs)
  Prom.withLabel numUsersWithProjects (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithProjects)
  Prom.withLabel numUsersWithServices (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithServices)
  Prom.withLabel numUsersWithJobsOrServicesLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithJobsOrServicesLastWeek)
  Prom.withLabel numUsersWithJobsOrServicesLastMonth (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithJobsOrServicesLastMonth)
  Prom.withLabel numUsersWithDeploymentsNotProjectsLastWeek (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithDeploymentsNotProjectsLastWeek)
  Prom.withLabel numUsersWithDeploymentsNotProjectsLastMonth (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral usersWithDeploymentsNotProjectsLastMonth)
  Prom.withLabel numActiveSubscriptions (deployment, service) \gauge -> Prom.setGauge gauge (fromIntegral activeSubscriptions)
  onDemandMetrics <- getOnDemandMetrics
  traverse_ (\((clusterId, status), count) -> tallyConnection clusterId status count) $ Map.toList onDemandMetrics.clusterConnections
  where
    tallyConnection clusterId status count =
      Prom.withLabel numClusterConnections (deployment, service, tShow clusterId, checkStatusToText status) \gauge ->
        Prom.setGauge gauge (fromIntegral count)

{-# NOINLINE numDeploymentsLastWeek #-}
numDeploymentsLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numDeploymentsLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_deployments_last_week"
        "The number of service deployments in the last week."

numServicesCreatedLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numServicesCreatedLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_services_created_last_week"
        "The number of services created in the last week."

numServicesAssignedLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numServicesAssignedLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_services_assigned_last_week"
        "The number of services assigned in the last week."

numJobsRunLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numJobsRunLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_jobs_run_last_week"
        "The number of jobs run in the last week."

numUniqueUsersLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numUniqueUsersLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_unique_users_last_week"
        "The number of unique users in the last week."

numUniqueUsersLastMonth :: Prom.Vector Prom.Label2 Prom.Gauge
numUniqueUsersLastMonth =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_unique_users_last_month"
        "The number of unique users in the last month."

numUniqueUsers :: Prom.Vector Prom.Label2 Prom.Gauge
numUniqueUsers =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_unique_users"
        "The number of unique users."

numEverActiveUsers :: Prom.Vector Prom.Label2 Prom.Gauge
numEverActiveUsers =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "num_ever_active_users"
        "The number of users who have ever hit the cloud API"

numUsersWithDeployments :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithDeployments =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info "num_users_with_deployments" "The number of users who have made a deployment."

numUsersWithStorage :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithStorage =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info "num_users_with_storage" "The number of users who have created a storage pool."

numUsersWithServices :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithServices =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_users_with_services" "The number of users who have created a service."

numUsersWithProjects :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithProjects =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_users_with_projects" "The number of users who have created a project."

numUsersWithJobs :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithJobs =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info "num_users_with_jobs" "The number of users who have launched a job."

numUsersWithJobsOrServicesLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithJobsOrServicesLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_users_with_jobs_or_services_last_week" "The number of users who have launched a job or created a service in the last week."

numUsersWithJobsOrServicesLastMonth :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithJobsOrServicesLastMonth =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_users_with_jobs_or_services_last_month" "The number of users who have launched a job or created a service in the last month."

numUsersWithDeploymentsNotProjectsLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithDeploymentsNotProjectsLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_users_with_deployments_not_projects_last_week" "The number of users who have made a deployment that is not a project in the last week."

numUsersWithDeploymentsNotProjectsLastMonth :: Prom.Vector Prom.Label2 Prom.Gauge
numUsersWithDeploymentsNotProjectsLastMonth =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_users_with_deployments_not_projects_last_month" "The number of users who have made a deployment that is not a project in the last month."

numActiveSubscriptions :: Prom.Vector Prom.Label2 Prom.Gauge
numActiveSubscriptions =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_active_subscriptions" "The number of active paid tier cloud subscriptions."

numStoragePoolsCreatedLastWeek :: Prom.Vector Prom.Label2 Prom.Gauge
numStoragePoolsCreatedLastWeek =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info = Prom.Info "num_storage_pools_created_last_week" "The number of storage pools created in the last week."
