module Cloud.Cluster.Metrics (clusterConnectionCounts) where

import Cloud.Byoc.Env (Cluster (..), ClusterId, health, lastKnownStatus)
import Cloud.Consul.API (CheckStatus (..))
import Cloud.Prelude
import Control.Concurrent.STM (STM)
import Data.Map qualified as Map
import DeferredFolds.UnfoldlM (foldlM')
import StmContainers.Map qualified as TMap
import UnliftIO.STM (readTVar)

clusterConnectionCounts :: TMap.Map ClusterId Cluster -> STM (Map.Map (ClusterId, CheckStatus) Word)
clusterConnectionCounts clusters =
  foldlM' (\acc (_, cluster) -> tallyCluster acc cluster) Map.empty (TMap.unfoldlM clusters)
  where
    tallyCluster acc (Cluster {clusterId, clusterConnections}) =
      tallyClusterConnections clusterConnections <&> \conns ->
        Map.unionWith (+) acc (Map.mapKeys (clusterId,) conns)
    -- NOTE: It's important that we explicitly set all CheckStatus types to 0
    -- here as opposed to just using Map.empty. Our Prometheus metrics are
    -- stateful, so if we previously had a critical node but no longer have any
    -- critical nodes we need to ensure that we zero out the critical count
    -- instead of retaining its previous value.
    tallyInit = Map.fromList $ (,0 :: Word) <$> [Passing, Warning, Critical]
    tallyClusterConnections clusterConnections =
      foldlM' tallyConnection tallyInit (TMap.unfoldlM clusterConnections)
    tallyConnection acc (_, conn) =
      connectionHealth conn <&> \health -> Map.unionWith (+) acc (Map.singleton health 1)
    connectionHealth conn = lastKnownStatus <$> readTVar conn.health
