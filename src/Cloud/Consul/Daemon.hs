{-# LANGUAGE OverloadedRecordDot #-}

module Cloud.Consul.Daemon
  ( consulSetDaemonId,
    consulUnassignDaemonId,
    consulDeleteDaemon,
    consulWatchClusterDaemons,
  )
 where
import Cloud.Daemon.Types
import Cloud.Deployment qualified as Deployment
import Cloud.Prelude
import Share.OAuth.Types (UserId)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Web.App (WebApp)
import qualified Servant.Client as S
import qualified Data.Text as Text
import Cloud.Byoc.Env (isDefaultCluster, ClusterId)
import Share.Utils.Show (tShow)
import Cloud.Errors
import Cloud.Web.Errors (CloudWebError (InternalError))
import Cloud.Consul.API (deleteKey', updateKey', watchKeys, GetResponse, responseValue, responseKey, updateIndex)
import Data.Aeson
import qualified Data.ByteString.Lazy as BSL
import Conduit (ConduitT, (.|), mapMC)
import Data.Void
import Cloud.Utils.Logging
import Witherable (witherM)
import Data.Text.Encoding (encodeUtf8)
import Cloud.Utils.TextUtil (stripPrefix)
import qualified Data.UUID as UUID
import Network.HTTP.Client (responseTimeout, responseTimeoutMicro)
import Control.Concurrent (threadDelay)
import Cloud.Env (Env(..))
import Control.Monad.Reader (ask)

daemonIdKey :: ClusterId -> DaemonId -> Text
daemonIdKey cluster (DaemonId daemonId) =
  clusterDaemonPrefix cluster <> tShow daemonId

clusterDaemonPrefix :: ClusterId -> Text
clusterDaemonPrefix cluster =
  env <> clusterSlug <> "/daemonId/"
  where
    env = tShow Deployment.deployment
    clusterSlug = if isDefaultCluster cluster then "" else "/" <> tShow cluster

consulSetDaemonId :: ClusterId -> UserId -> DaemonId -> DeploymentHash -> WebApp ()
consulSetDaemonId cluster userId daemonId hash = do
  let key = daemonIdKey cluster daemonId
  let value = BSL.toStrict $ encode $ object ["owner" .= userId, "hash" .= hash]
  Env { consulClientEnv } <- ask
  res <- liftIO $ S.runClientM (updateKey' key value Nothing Nothing Nothing Nothing) consulClientEnv
  case res of
    Left err -> do
      respondError $ InternalError $ Text.pack $ "Error setting daemonId: " <> show err
    Right _ -> pure ()

-- Just used internally for JSON codecs
data DaemonSummary = DaemonSummary {
  owner :: UserId,
  hash :: DeploymentHash
}

instance FromJSON DaemonSummary where
  parseJSON = withObject "DaemonSummary" $ \o -> do
    owner <- o .: "owner"
    hash <- o .: "hash"
    pure $ DaemonSummary {..}

consulUnassignDaemonId :: ClusterId -> DaemonId -> WebApp ()
consulUnassignDaemonId cluster daemonId = do
  let key = daemonIdKey cluster daemonId
  Env { consulClientEnv } <- ask
  res <- liftIO $ S.runClientM (deleteKey' key Nothing Nothing) consulClientEnv
  case res of
    Left err -> do
      respondError $ InternalError $ Text.pack $ "Error deleting daemonId: " <> show err
    Right _ -> pure ()

consulDeleteDaemon :: ClusterId -> DaemonId -> WebApp ()
consulDeleteDaemon cluster daemonId = do
  let key = daemonIdKey cluster daemonId
  Env { consulClientEnv } <- ask
  res <- liftIO $ S.runClientM (deleteKey' key Nothing Nothing) consulClientEnv
  case res of
    Left err -> do
      respondError $ InternalError $ Text.pack $ "Error deleting daemonId: " <> show err
    Right _ -> pure ()

consulWatchClusterDaemons :: ClusterId -> ConduitT () [DaemonAssignmentSummary] WebApp ()
consulWatchClusterDaemons cluster = do
  Env { consulClientEnv } <- ask
  (watchKeys (runClient consulClientEnv) prefix True <&> absurd) .| mapMC (witherM decodeSummary)
  where
    prefix = clusterDaemonPrefix cluster
    daemonIdFromKey :: Text -> Maybe DaemonId
    daemonIdFromKey key = DaemonId <$> UUID.fromText (stripPrefix prefix key)
    decodeSummary :: GetResponse -> WebApp (Maybe DaemonAssignmentSummary)
    decodeSummary res = case eitherDecodeStrict (encodeUtf8 res.responseValue) of
      Left err -> do
        logErrorText $ "Error decoding Daemon summary: " <> tshow err
        pure Nothing
      Right (r :: DaemonSummary) -> case daemonIdFromKey res.responseKey of
        Just daemonId -> pure $ Just $ DaemonAssignmentSummary { daemonId, ownerId = r.owner, deploymentHash = r.hash, modifyIndex = res.updateIndex }
        Nothing -> do
          logErrorText $ "Error decoding Daemon ID: " <> res.responseKey
          pure Nothing
    consulEnv clientEnv = clientEnv
      { S.makeClientRequest = \url req ->
          S.makeClientRequest clientEnv url req <&> \r ->
            r {responseTimeout = responseTimeoutMicro 18000000000}
      }

    runClient consulClientEnv req = do
      res <- liftIO $ S.runClientM req (consulEnv consulClientEnv)
      case res of
        Right a -> pure $ Just a
        Left err -> do
          logErrorText $ "Error watching daemon keys: " <> tshow err
          liftIO $ threadDelay 3000000 -- TODO improve retry strategy
          pure Nothing
