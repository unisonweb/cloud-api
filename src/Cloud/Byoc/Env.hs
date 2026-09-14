{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Cloud.Byoc.Env
  ( Cluster (..),
    ClusterId (..),
    ClusterEnv (..),
    ClusterConfig (..),
    ClusterName (..),
    ClusterToken (..),
    Connection (..),
    Event (..),
    NodeDelivery (..),
    PeerNodeResult (..),
    Health (..),
    MonoTime (..),
    ServiceURIScheme (..),
    SchemeType (..),
    clusterNameToText,
    defaultClusterId,
    isDefaultCluster,
    eventCluster,
    monoTimeToNanos,
    currentMonoTime,
    newCluster,
    getCluster,
  )
where

import Cloud.Consul.API (CheckStatus, ServiceInstanceId)
import Cloud.Daemon.Types (DaemonAssignmentSummary)
import Cloud.Deployment (Deployment (..), deployment)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Prelude
import Cloud.Service.Types (ServiceId)
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Types (EnvironmentId (..), ServiceId (..), serviceNameToText)
import Cloud.Web.Types qualified as Cloud
import Control.Arrow (left)
import Control.Monad.RWS.Lazy (MonadReader (..))
import Control.Monad.Random (Random)
import Data.Aeson.Types
import Data.Hashable (Hashable)
import Data.Maybe (fromJust)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Data.UUID (UUID, fromString)
import Control.Concurrent.STM (TMVar)
import GHC.Conc (TVar)
import GHC.Conc.Sync (atomically)
import Hasql.Interpolate (DecodeValue, EncodeValue)
import Hasql.Interpolate qualified as Hasql
import Network.HTTP.Client (ManagerSettings (..), defaultManagerSettings, responseTimeoutMicro)
import Network.HTTP.Client.TLS (newTlsManagerWith)
import Network.Socket (HostName)
import Network.URI (URI, parseURI)
import Servant (FromHttpApiData (..))
import Servant qualified as S
import Servant.API (ToHttpApiData)
import Servant.Client (BaseUrl, parseBaseUrl)
import Servant.Client qualified as S
import Share.Utils.Show (Censored (..))
import StmContainers.Map qualified as STM
import StmContainers.Map qualified as TMap
import System.Clock (TimeSpec, fromNanoSecs, getTime, toNanoSecs)
import System.Clock.Seconds (Clock (..))
import qualified Hasql.Interpolate as Interp
import Data.Functor.Contravariant (contramap)
import qualified Data.ByteString.Lazy as BL
import Share.OAuth.Types (UserId)

newtype ClusterId = ClusterId UUID
  deriving stock (Eq, Ord)
  deriving newtype (Hashable, Random, Show, FromHttpApiData, ToHttpApiData, FromJSON, ToJSON, Hasql.EncodeValue, Hasql.DecodeValue)

instance S.MimeRender S.PlainText ClusterId where
  mimeRender :: S.Proxy S.PlainText -> ClusterId -> BL.ByteString
  mimeRender _ (ClusterId uuid) = BL.fromStrict . encodeUtf8 . Text.pack . show $ uuid


data ServiceURIScheme
  = HostBased URI
  | LocalHostBased URI
  | IPBased

data SchemeType = VirtualHost | Path | IP
  deriving (Eq, Show, Generic)

instance ToHttpApiData SchemeType where
  toUrlPiece = \case
    VirtualHost -> "virtualhost"
    Path -> "path"
    IP -> "ip"

instance FromHttpApiData SchemeType where
  parseUrlPiece t
    | Text.toLower t == "virtualhost" = Right VirtualHost
    | Text.toLower t == "path" = Right Path
    | Text.toLower t == "ip" = Right IP
    | otherwise = Left $ "Unknown SchemeType: " <> t

instance DecodeValue SchemeType where
  decodeValue =
    fmap
      ( \(t :: Text) ->
          if t == "host"
            then VirtualHost
            else
              if t == "local"
                then Path
                else
                  if t == "ip"
                    then IP
                    else error $ "Unknown SchemeType: " <> show t
      )
      Hasql.decodeValue

instance EncodeValue SchemeType where
  encodeValue =
    Interp.encodeValue
      & contramap encode
    where
      encode = \case
        VirtualHost -> "host" :: Text
        Path -> "local" :: Text
        IP -> "ip" :: Text

data ClusterConfig = ClusterConfig
  { clusterId :: ClusterId,
    clusterName :: ClusterName,
    clusterHostname :: HostName,
    clusterServiceURIScheme :: ServiceURIScheme,
    clusterUri :: URI,
    lokiUri :: BaseUrl,
    clusterLokiTaskName :: Text,
    clusterUserId :: UserId
  }

instance Hasql.DecodeRow ClusterConfig where
  decodeRow =
    Hasql.decodeRow
      <&> \( clusterId :: ClusterId,
             clusterName :: ClusterName,
             hostname :: Text,
             serviceUriType :: SchemeType,
             serviceUri :: Text,
             clusterUriText :: Text,
             lokiUriText :: Text,
             clusterLokiTaskName :: Text,
             clusterUserId :: UserId
             ) ->
          let clusterServiceURIScheme = schemeFromRow serviceUriType $ fromJust $ parseURI (Text.unpack serviceUri)
              clusterHostname = Text.unpack hostname
              clusterUri = fromJust $ parseURI (Text.unpack clusterUriText)
              lokiUri = fromJust $ parseBaseUrl (Text.unpack lokiUriText)
           in ClusterConfig {..}
    where
      schemeFromRow :: SchemeType -> URI -> ServiceURIScheme
      schemeFromRow scheme uri = case scheme of
        VirtualHost -> HostBased uri
        Path -> LocalHostBased uri
        IP -> IPBased

data Cluster = Cluster
  { clusterId :: ClusterId,
    clusterLokiClientEnv :: S.ClientEnv,
    clusterConnections :: STM.Map ServiceInstanceId Connection
  }

newCluster :: (MonadIO m) => ClusterConfig -> m Cluster
newCluster clusterConfig = do
  clusterConnections <- liftIO TMap.newIO
  let clusterId = clusterConfig.clusterId

  let lokiHost = clusterConfig.lokiUri
  lokiManager <-
    liftIO $
      newTlsManagerWith $
        defaultManagerSettings
          { managerResponseTimeout = responseTimeoutMicro (60 * 1000000) -- 60 seconds
          }

  let clusterLokiClientEnv = S.mkClientEnv lokiManager lokiHost
  pure Cluster {..}

defaultClusterId :: ClusterId
defaultClusterId =
  ClusterId $ fromJust $ fromString txt
  where
    txt = case deployment of
      Cloud.Deployment.Local -> "ae35ed12-93f9-4915-92d5-4144e804b013"
      Cloud.Deployment.Staging -> "08b3e317-f738-4a88-a59b-00190c9ca6f4"
      Cloud.Deployment.Production -> "d3ee426c-c252-4910-a861-08fccf85fb66"

isDefaultCluster :: ClusterId -> Bool
isDefaultCluster clusterId = defaultClusterId == clusterId

newtype ClusterToken = ClusterToken Text
  deriving (Show) via (Censored Text)
  deriving (Eq, Ord)
  deriving newtype (FromJSON, ToJSON, EncodeValue, DecodeValue)

instance FromHttpApiData ClusterToken where
  parseUrlPiece :: Text -> Either Text ClusterToken
  parseUrlPiece = Right . ClusterToken
  parseHeader :: ByteString -> Either Text ClusterToken
  parseHeader bytes = do
    text <- left (Text.pack . show) (decodeUtf8' bytes)
    S.parseUrlPiece $ fromMaybe text (Text.stripPrefix "Bearer " text)

instance S.MimeRender S.PlainText ClusterToken where
  mimeRender :: S.Proxy S.PlainText -> ClusterToken -> BL.ByteString
  mimeRender _ (ClusterToken token) = BL.fromStrict $ encodeUtf8 token


newtype ClusterName = ClusterName Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, EncodeValue, DecodeValue, FromHttpApiData, ToJSON, FromJSON)
  deriving (Show)

clusterNameToText :: ClusterName -> Text
clusterNameToText (ClusterName t) = t

data ClusterEnv = ClusterEnv
  { envClusters :: TMap.Map ClusterId Cluster,
    envClusterHosts :: TMap.Map HostName ClusterId,
    -- envDefaultClusterConfig :: ClusterConfig,
    envAPISuffix :: Text
  }

data Event
  = EnvironmentInvalidation ClusterId EnvironmentId
  | UserServiceInvalidation ClusterId UserHandle Cloud.ServiceName
  | ServiceIdInvalidation ClusterId ServiceId
  | ServiceHashInvalidation ClusterId DeploymentHash
  | DaemonList ClusterId [DaemonAssignmentSummary]
  deriving (Eq)

instance Show Event where
  show (EnvironmentInvalidation clusterId envId) =
    "EnvironmentInvalidation: " <> show clusterId <> ", " <> show envId
  show (UserServiceInvalidation clusterId userHandle serviceName) =
    "UserServiceInvalidation: " <> show clusterId <> ", " <> show userHandle <> ", " <> Text.unpack (serviceNameToText serviceName)
  show (ServiceIdInvalidation clusterId (ServiceId serviceId)) =
    "ServiceIdInvalidation: " <> show clusterId <> ", " <> show serviceId
  show (ServiceHashInvalidation clusterId serviceHash) =
    "ServiceHashInvalidation: " <> show clusterId <> ", " <> show serviceHash
  show (DaemonList clusterId daemons) =
    "DaemonList: " <> show clusterId <> ", Daemons: " <> show daemons

eventCluster :: Event -> ClusterId
eventCluster (EnvironmentInvalidation clusterId _) = clusterId
eventCluster (UserServiceInvalidation clusterId _ _) = clusterId
eventCluster (ServiceIdInvalidation clusterId _) = clusterId
eventCluster (ServiceHashInvalidation clusterId _) = clusterId
eventCluster (DaemonList clusterId _) = clusterId

instance ToJSON Event where
  toJSON (EnvironmentInvalidation clusterId envId) =
    object
      [ "type" .= ("EnvironmentInvalidation" :: Text),
        "clusterId" .= clusterId,
        "environmentId" .= envId
      ]
  toJSON (UserServiceInvalidation clusterId userHandle serviceName) =
    object
      [ "type" .= ("UserServiceInvalidation" :: Text),
        "clusterId" .= clusterId,
        "userHandle" .= userHandle,
        "serviceName" .= serviceName
      ]
  toJSON (ServiceIdInvalidation clusterId serviceId) =
    object
      [ "type" .= ("ServiceIdInvalidation" :: Text),
        "clusterId" .= clusterId,
        "serviceId" .= serviceId
      ]
  toJSON (ServiceHashInvalidation clusterId serviceHash) =
    object
      [ "type" .= ("ServiceHashInvalidation" :: Text),
        "clusterId" .= clusterId,
        "serviceHash" .= serviceHash
      ]
  toJSON (DaemonList clusterId daemons) =
    object
      [ "type" .= ("DaemonList" :: Text),
        "clusterId" .= clusterId,
        "daemons" .= daemons
      ]

instance FromJSON Event where
  parseJSON = withObject "Event" $ \o -> do
    t <- o .: "type"
    case (t :: Text) of
      "EnvironmentInvalidation" ->
        EnvironmentInvalidation <$> o .: "clusterId" <*> o .: "environmentId"
      "UserServiceInvalidation" ->
        UserServiceInvalidation <$> o .: "clusterId" <*> o .: "userHandle" <*> o .: "serviceName"
      "ServiceIdInvalidation" ->
        ServiceIdInvalidation <$> o .: "clusterId" <*> o .: "serviceId"
      "ServiceHashInvalidation" ->
        ServiceHashInvalidation <$> o .: "clusterId" <*> o .: "serviceHash"
      other -> fail $ "Unsupported invalidation event type: " <> Text.unpack other

-- | The outcome of delivering one invalidation to one node.
data NodeDelivery
  = -- | Legacy (V1) node: sent fire-and-forget, no ack expected.
    NoAckSupport
  | -- | V2 node did not ack within the deadline.
    AckTimedOut
  | -- | V2 node acked. Fields: cloud-api-measured round-trip nanos, node-reported apply nanos.
    Acked !Integer !Integer
  deriving (Show)

instance ToJSON NodeDelivery where
  toJSON NoAckSupport = object ["status" .= ("noAck" :: Text)]
  toJSON AckTimedOut = object ["status" .= ("timeout" :: Text)]
  toJSON (Acked rttNanos applyNanos) =
    object ["status" .= ("acked" :: Text), "rttNanos" .= rttNanos, "applyNanos" .= applyNanos]

instance FromJSON NodeDelivery where
  parseJSON = withObject "NodeDelivery" $ \o -> do
    s <- o .: "status"
    case (s :: Text) of
      "noAck" -> pure NoAckSupport
      "timeout" -> pure AckTimedOut
      "acked" -> Acked <$> o .: "rttNanos" <*> o .: "applyNanos"
      other -> fail $ "Unknown NodeDelivery status: " <> Text.unpack other

-- | Per-node invalidation result carried over the cloud-api peer RPC.
data PeerNodeResult = PeerNodeResult
  { prNodeId :: ServiceInstanceId,
    prDelivery :: NodeDelivery
  }

instance ToJSON PeerNodeResult where
  toJSON (PeerNodeResult nid d) = object ["nodeId" .= nid, "delivery" .= d]

instance FromJSON PeerNodeResult where
  parseJSON = withObject "PeerNodeResult" $ \o ->
    PeerNodeResult <$> o .: "nodeId" <*> o .: "delivery"

data Health = Health
  { lastKnownStatus :: CheckStatus,
    lastKnownStatusTime :: MonoTime,
    lastHealthRequest :: Maybe MonoTime
  }

data Connection = Connection
  { health :: TVar Health,
    start :: MonoTime,
    checkHealth :: IO CheckStatus,
    sendEvent :: Event -> IO (),
    -- | Send a raw JSON value over the websocket. Used to stamp a correlation
    -- id onto an invalidation for the synchronous, ack'd path.
    sendValue :: Value -> IO (),
    -- | Whether this node speaks protocol V2 and will ack invalidations.
    acksSupported :: Bool,
    -- | Next correlation id to hand out for this connection.
    ackSeq :: TVar Word,
    -- | Outstanding invalidation acks: seq -> slot the receive loop fills with
    -- the node-reported apply duration (nanoseconds).
    ackWaiters :: TVar (Map Word (TMVar Integer))
  }

newtype MonoTime = MonoTime TimeSpec
  deriving newtype (Eq, Ord)

instance FromJSON MonoTime where
  parseJSON t = MonoTime . fromNanoSecs <$> parseJSON t

instance ToJSON MonoTime where
  toJSON (MonoTime t) = toJSON $ toNanoSecs t

monoTimeToNanos :: MonoTime -> Integer
monoTimeToNanos (MonoTime t) = toNanoSecs t

currentMonoTime :: IO MonoTime
currentMonoTime = MonoTime <$> getTime Monotonic

getCluster :: (MonadIO m, MonadReader ClusterEnv m) => ClusterConfig -> m Cluster
getCluster clusterConfig = do
  ClusterEnv {envClusters, envClusterHosts} <- ask
  new <- newCluster clusterConfig
  liftIO $ atomically $ do
    maybeCluster <- TMap.lookup clusterConfig.clusterId envClusters
    case maybeCluster of
      Just cluster -> pure cluster
      Nothing -> do
        TMap.insert new clusterConfig.clusterId envClusters
        TMap.insert clusterConfig.clusterId clusterConfig.clusterHostname envClusterHosts
        pure new
