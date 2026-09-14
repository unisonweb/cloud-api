-- | Prometheus metrics for the synchronous invalidation path.
--
-- These complement (never replace) the per-node log lines in "Cloud.Events" —
-- metrics drive dashboards/alerts, the logs carry the request ids and full node
-- ids needed for after-the-fact debugging.
module Cloud.Invalidation.Metrics
  ( recordInvalidationResults,
    recordPeersDiscovered,
  )
where

import Cloud.Byoc.Env (NodeDelivery (..))
import Cloud.Consul.API (ServiceInstanceId, serviceInstanceIdToText)
import Cloud.Deployment qualified as Deployment
import Cloud.Prelude
import Data.Char (isDigit)
import Data.Text qualified as Text
import Prometheus qualified as Prom

service :: Text
service = "cloud-api"

deployment :: Text
deployment = tshow Deployment.deployment

-- | Record the per-node outcome of one synchronous invalidation.
recordInvalidationResults :: Text -> [(ServiceInstanceId, NodeDelivery)] -> IO ()
recordInvalidationResults eventType results =
  forM_ results $ \(nodeId, delivery) -> do
    let node = nodeLabel nodeId
    Prom.withLabel invalidationDeliveries (deployment, service, eventType, node, outcome delivery) Prom.incCounter
    case delivery of
      Acked rttNanos applyNanos -> do
        Prom.withLabel invalidationRtt (deployment, service, eventType, node) (`Prom.observe` nanosToSeconds rttNanos)
        Prom.withLabel invalidationApply (deployment, service, eventType, node) (`Prom.observe` nanosToSeconds applyNanos)
      _ -> pure ()
  where
    outcome = \case
      Acked _ _ -> "acked"
      AckTimedOut -> "timeout"
      NoAckSupport -> "no_ack"
    nanosToSeconds n = fromIntegral n / 1e9

-- | Record how many cloud-api peers Consul discovery returned (0 on failure).
-- In a multi-instance deployment this dropping below the instance count means
-- invalidations are no longer reaching the whole fleet — alert on it.
recordPeersDiscovered :: Int -> IO ()
recordPeersDiscovered n =
  Prom.withLabel peersDiscovered (deployment, service) (`Prom.setGauge` fromIntegral n)

-- | A stable per-node metric label: the ServiceInstanceId minus its trailing
-- connect-timestamp, so a node keeps the same label across reconnects and the
-- label cardinality stays bounded by the fleet size.
nodeLabel :: ServiceInstanceId -> Text
nodeLabel sid =
  let t = serviceInstanceIdToText sid
      stripped = Text.dropWhileEnd (== '-') (Text.dropWhileEnd isDigit t)
   in if Text.null stripped then t else stripped

latencyBuckets :: [Double]
latencyBuckets = Prom.exponentialBuckets 0.001 2 16 -- 1ms .. ~32s (spans the 30s ack deadline)

{-# NOINLINE invalidationRtt #-}
invalidationRtt :: Prom.Vector Prom.Label4 Prom.Histogram
invalidationRtt =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service", "event_type", "node") $
      Prom.histogram info latencyBuckets
  where
    info =
      Prom.Info
        "invalidation_node_rtt_seconds"
        "Cloud-api-measured round-trip of a synchronous invalidation to one nimbus node (send to ack)."

{-# NOINLINE invalidationApply #-}
invalidationApply :: Prom.Vector Prom.Label4 Prom.Histogram
invalidationApply =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service", "event_type", "node") $
      Prom.histogram info latencyBuckets
  where
    info =
      Prom.Info
        "invalidation_node_apply_seconds"
        "Node-reported time taken to apply an invalidation (cache clear) on a nimbus node."

{-# NOINLINE invalidationDeliveries #-}
invalidationDeliveries :: Prom.Vector Prom.Label5 Prom.Counter
invalidationDeliveries =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service", "event_type", "node", "outcome") $
      Prom.counter info
  where
    info =
      Prom.Info
        "invalidation_node_deliveries_total"
        "Per-node delivery outcomes of synchronous invalidations (acked | timeout | no_ack)."

{-# NOINLINE peersDiscovered #-}
peersDiscovered :: Prom.Vector Prom.Label2 Prom.Gauge
peersDiscovered =
  Prom.unsafeRegister $
    Prom.vector ("deployment", "service") $
      Prom.gauge info
  where
    info =
      Prom.Info
        "cloud_api_peers_discovered"
        "Number of cloud-api instances found in Consul during peer discovery for invalidation fan-out."
