module Cloud.Events
  ( fireUserServiceInvalidationEvent,
    fireServiceIdInvalidationEvent,
    fireEnvironmentInvalidationEvent,
    fireDeploymentHashInvalidationEvent,
  )
where

import Cloud.Byoc.Env (ClusterId (..), Event (..), NodeDelivery (..))
import Cloud.Client.Types (NimbusConfig)
import Cloud.Consul.API (serviceInstanceIdToText)
import Cloud.Invalidation.Metrics qualified as InvalidationMetrics
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Prelude
import Cloud.User.UserHandle (UserHandle)
import Cloud.Utils.Logging (logDebugText, logErrorText)
import Cloud.Web.App (WebApp)
import Cloud.Web.Cluster.Impl (invalidateSync, invalidationTimeoutMicros)
import Cloud.Web.Types (EnvironmentId, ServiceId, ServiceName)

fireEnvironmentInvalidationEvent :: NimbusConfig -> ClusterId -> EnvironmentId -> WebApp ()
fireEnvironmentInvalidationEvent _nimbusConfig clusterId envId =
  runInvalidation "environment" clusterId (EnvironmentInvalidation clusterId envId)

fireUserServiceInvalidationEvent :: ClusterId -> UserHandle -> ServiceName -> WebApp ()
fireUserServiceInvalidationEvent clusterId user serviceName =
  runInvalidation "user-service" clusterId (UserServiceInvalidation clusterId user serviceName)

fireServiceIdInvalidationEvent :: ClusterId -> ServiceId -> WebApp ()
fireServiceIdInvalidationEvent clusterId serviceId =
  runInvalidation "service-id" clusterId (ServiceIdInvalidation clusterId serviceId)

fireDeploymentHashInvalidationEvent :: ClusterId -> DeploymentHash -> WebApp ()
fireDeploymentHashInvalidationEvent clusterId deploymentHash =
  runInvalidation "service-hash" clusterId (ServiceHashInvalidation clusterId deploymentHash)

-- | Synchronously push an invalidation to all connected nodes and log per-node
-- delivery latency (the data used to hunt slow nodes).
runInvalidation :: Text -> ClusterId -> Event -> WebApp ()
runInvalidation label clusterId ev = do
  results <- invalidateSync invalidationTimeoutMicros clusterId ev
  liftIO $ InvalidationMetrics.recordInvalidationResults label results
  forM_ results $ \(nodeId, delivery) ->
    let node = serviceInstanceIdToText nodeId
        ms n = tshow (n `div` 1_000_000) <> "ms"
     in case delivery of
          Acked rttNanos applyNanos ->
            logDebugText $
              "Invalidation (" <> label <> ") acked by " <> node
                <> " rtt=" <> ms rttNanos <> " apply=" <> ms applyNanos
          AckTimedOut ->
            logErrorText $
              "Invalidation (" <> label <> ") TIMED OUT waiting for node " <> node
          NoAckSupport ->
            logDebugText $
              "Invalidation (" <> label <> ") sent to legacy (no-ack) node " <> node
