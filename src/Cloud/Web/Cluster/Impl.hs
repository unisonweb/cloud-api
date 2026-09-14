{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Cloud.Web.Cluster.Impl
  ( joinCluster,
    consulRegistrationSelfCheck,
    getMemberList,
    invalidateSync,
    invalidateLocalForCluster,
    invalidationTimeoutMicros,
    invalidateClusterLocal,
    sendEventSync,
    stampSeq,
    NodeDelivery (..),
    server,
    MemberList (..),
    NimbusInstance (..),
    -- exported for protocol fixture tests
    ErrorMsg (..),
    HealthRequestMessage (..),
    IncomingMessage (..),
    LocationRegisteredMessage (..),
  )
where

import Cloud.App (CloudApp)

import Cloud.Byoc.App (clusterM)
import Cloud.Byoc.Env
  ( Cluster (..),
    ClusterConfig (..),
    ClusterEnv (..),
    ClusterId (..),
    ClusterToken,
    Connection (..),
    Event (..),
    Health (..),
    MonoTime (..),
    NodeDelivery (..),
    PeerNodeResult (..),
    currentMonoTime,

    getCluster,
    lastHealthRequest,
    lastKnownStatus,
    lastKnownStatusTime,
    monoTimeToNanos,
  )
import Cloud.Client.Types (NimbusConfig, nimbusHttpServiceName)
import Cloud.Cluster.Location (LocationId (..), locationIdToText)
import Cloud.Consul.API
  ( Check (..),
    CheckExec (..),
    CheckRegistration (..),
    CheckStatus (..),
    ConsulIndex,
    ConsulServiceInstance (ConsulServiceInstance),
    RegisterServiceRequest (..),
    ServiceInstanceId (..),
    checkStatusIsPassing,
    deregisterService',
    maybeResponseHeader,
    registerService',
    registerServiceRequestInstanceId,
    serviceHealth',
  )
import Cloud.Consul.API qualified as Consul
import Cloud.Consul.Daemon (consulWatchClusterDaemons)
import Cloud.Consul.Filtering
import Cloud.Deployment qualified

import Cloud.Env (Env (..))
import Cloud.Errors (respondError)
import Cloud.Postgres qualified as PG
import Cloud.Postgres.App (postgresM)
import Cloud.Postgres.Ops.Byoc qualified as PGO
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.User.Types (User (..))
import Cloud.User.UserHandle (UserHandle (..))
import Cloud.Utils.Logging (logErrorText, logDebugText)
import Cloud.Web.App (WebApp)
import Cloud.Web.Cluster.API (ClusterAPI, ProtocolVersion (..))
import Cloud.Web.Errors (BadRequest (..), CloudWebError (..), UnauthenticatedError (UnauthenticatedError))
import Cloud.Invalidation.Metrics qualified as InvalidationMetrics
import Cloud.Web.Internal.API (PeerInvalidateAPI)
import Cloud.Web.Internal.Types (DeploymentHashResult (..), StoragePoolIdResult (..), UserIdResult (UserIdResult))
import Cloud.Web.Types (EnvironmentId (..), ServiceId (..), ServiceName)
import Conduit (mapM_C, runConduit, (.|))
import Control.Concurrent (threadDelay)
import Control.Monad.RWS (MonadReader (ask), MonadTrans (lift))
import Control.Monad.STM (retry)
import Control.Monad.Trans.Resource (allocate_)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as BS
import Data.Hashable (Hashable)
import Data.List (partition)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)

import Data.Text qualified as Text

import Data.Time (secondsToNominalDiffTime)
import Data.UUID (toString)
import Data.Void (Void)
import DeferredFolds.UnfoldlM qualified as C
import GHC.Base (absurd)
import Network.HTTP.Client (Manager, defaultManagerSettings, managerResponseTimeout, newManager, responseTimeout, responseTimeoutMicro)
import Network.Simple.TCP qualified as TCP
import Network.URI (URIAuth (..), parseAbsoluteURI)
import Network.WebSockets
  ( PendingConnection,
    RejectRequest (..),
    defaultRejectRequest,
    receiveData,
  )
import Network.WebSockets qualified
import Network.WebSockets.Connection
  ( acceptRequest,
    rejectRequestWith,
    sendTextData, PendingConnection (pendingStream),
  )
import Servant
import Servant.Client qualified as S
import System.Environment (lookupEnv)
import Share.OAuth.Types (UserId (..))
import StmContainers.Map qualified as STM
import StmContainers.Map qualified as TMap
import UnliftIO
import UnliftIO.Concurrent (forkIO, killThread)
import UnliftIO.Resource
import qualified Network.WebSockets.Stream as Stream

authenticateClusterToken :: ClusterToken -> WebApp (Either UnauthenticatedError ClusterConfig)
authenticateClusterToken clusterToken = do
  maybeConfig <- PGO.clusterConfigByToken clusterToken
  case maybeConfig of
    Just clusterConfig -> clusterM $ do
      -- cluster <- getCluster clusterConfig
      pure (Right clusterConfig)
    Nothing -> pure $ Left UnauthenticatedError

authenticateClusterTokenM :: ClusterToken -> WebApp ClusterConfig
authenticateClusterTokenM clusterToken = do
  cluster <- authenticateClusterToken clusterToken
  case cluster of
    Left e -> respondError e
    Right c -> pure c

userIdByHandle :: ClusterToken -> UserHandle -> WebApp UserIdResult
userIdByHandle clusterToken handle = do
  cluster <- authenticateClusterTokenM clusterToken
  user <- postgresM $ PG.runTransaction $ Q.userByHandle handle
  case user of
    Nothing -> respondError $ UserNotFoundForHandle handle
    Just (User userId@(UserId id) _ _ _ _ _) -> do
      isInCluster <- PGO.checkClusterAccess cluster.clusterId userId
      if isInCluster
        then pure $ UserIdResult id
        else respondError $ UserNotFoundForHandle handle

storageByEnvironmentId :: ClusterToken -> EnvironmentId -> WebApp [StoragePoolIdResult]
storageByEnvironmentId clusterToken envId = do
  cluster <- authenticateClusterTokenM clusterToken
  postgresM $ PG.runTransaction $ fmap StoragePoolIdResult <$> Q.storageByEnvironmentId cluster.clusterId envId

deploymentByServiceId :: ClusterToken -> ServiceId -> WebApp DeploymentHashResult
deploymentByServiceId clusterToken serviceId = do
  cluster <- authenticateClusterTokenM clusterToken
  deployment <- postgresM $ PG.runTransaction (Q.deploymentByServiceId cluster.clusterId serviceId)
  case deployment of
    Nothing -> respondError $ ServiceIdNotFound serviceId
    Just deployment -> pure $ DeploymentHashResult deployment

deploymentByServiceName :: ClusterToken -> UserHandle -> ServiceName -> WebApp DeploymentHashResult
deploymentByServiceName clusterToken userHandle serviceName = do
  cluster <- authenticateClusterTokenM clusterToken
  deployment <- postgresM $ PG.runTransaction (Q.deploymentByServiceName cluster.clusterId userHandle serviceName)
  case deployment of
    Nothing -> respondError $ ServiceNameNotFound serviceName
    Just deployment -> pure $ DeploymentHashResult deployment

newtype RegisterMessage = RegisterMessage
  { node :: NimbusInstance
  }

newtype HealthRequestMessage = HealthRequestMessage MonoTime

newtype LocationRegisteredMessage = LocationRegisteredMessage ClusterId

instance ToJSON LocationRegisteredMessage where
  toJSON (LocationRegisteredMessage clusterId) =
    object
      [ "type" .= ("LocationRegistered" :: Text),
        "clusterId" .= clusterId
      ]

data IncomingMessage
  = HealthResponse !MonoTime !CheckStatus !(Maybe Text)
  | InvalidationAckMsg !Word !Integer

instance FromJSON IncomingMessage where
  parseJSON = withObject "Message" $ \o -> do
    t <- o .: "type"
    case t of
      "HealthResponse" -> do
        n <- o .: "n"
        status <- o .: "status"
        message <- o .:? "message"
        pure $ HealthResponse n status message
      "InvalidationAck" -> do
        s <- o .: "seq"
        applyNanos <- o .: "applyNanos"
        pure $ InvalidationAckMsg s applyNanos
      t -> fail $ "Unexpected message type: " <> t

instance ToJSON HealthRequestMessage where
  toJSON (HealthRequestMessage n) =
    object
      [ "type" .= ("HealthRequest" :: Text),
        "n" .= n
      ]

data NimbusInstance = NimbusInstance
  { locationId :: !LocationId,
    uri :: !URI,
    hostname :: !TCP.HostName,
    port :: !TCP.ServiceName,
    metadata :: !(Map Text Text),
    isHealthy :: !Bool
  }

-- TODO filter out non byoc values from metadata that we send back to the client
nimbusInstanceFromConsulServiceInstance :: ConsulServiceInstance -> Maybe NimbusInstance
nimbusInstanceFromConsulServiceInstance (ConsulServiceInstance _ _ consulMeta checks) = do
  locationId <- Map.lookup "instance_id" consulMeta
  uriString <- Map.lookup "http_uri" consulMeta
  hostname <- Map.lookup "hostname" consulMeta
  port <- Map.lookup "port" consulMeta
  uri <- parseAbsoluteURI (Text.unpack uriString)
  let isHealthy = all (checkStatusIsPassing . checkStatus) checks
  pure $ NimbusInstance (LocationId locationId) uri (Text.unpack hostname) (Text.unpack port) consulMeta isHealthy

instance ToJSON NimbusInstance where
  toJSON n =
    object
      [ "locationId" .= locationId n,
        "hostname" .= hostname n,
        "port" .= port n,
        "uri" .= uri n,
        "meta" .= metadata n
      ]

data MemberList = MemberList
  { healthyLocations :: [NimbusInstance],
    unhealthyLocations :: [NimbusInstance]
  }

instance ToJSON MemberList where
  toJSON l =
    object
      [ "type" .= ("MemberList" :: Text),
        "healthyLocations" .= healthyLocations l,
        "unhealthyLocations" .= unhealthyLocations l
      ]

newtype ErrorMsg = ErrorMsg Text

instance ToJSON ErrorMsg where
  toJSON (ErrorMsg errorText) =
    object
      [ "type" .= ("Error" :: Text),
        "msg" .= errorText
      ]

sendJsonMsg :: (ToJSON a) => Network.WebSockets.Connection -> a -> IO ()
sendJsonMsg conn =
  sendTextData conn . encode

-- | Serialize all writers to one websocket. The websockets library does not
-- guarantee thread-safe sends, and each cluster connection is written to
-- concurrently by the health checker, the member-list and daemon senders, and
-- every in-flight invalidation — interleaved frames would surface as undecodable
-- messages or silently lost acks.
lockedSendJson :: (ToJSON a) => MVar () -> Network.WebSockets.Connection -> a -> IO ()
lockedSendJson lock conn a = withMVar lock \_ -> sendJsonMsg conn a

receiveJsonMsg :: (FromJSON a) => Network.WebSockets.Connection -> WebApp a
receiveJsonMsg conn = do
  bytes <- liftIO $ receiveData conn
  case eitherDecode bytes of
    Left e ->
      let msg = "Failed to decode message: " <> Text.pack e
       in do
            liftIO $ BS.putStrLn $ "couldn't parse msg: " <> BS.toStrict bytes
            liftIO $ sendJsonMsg conn $ ErrorMsg msg
            respondError $ BadRequest msg
    Right a -> pure a

instance FromJSON RegisterMessage where
  parseJSON = withObject "RegisterMessage" $ \o -> do
    locationId <- o .: "locationId"
    uri <- o .: "uri"
    hostname <- o .: "hostname"
    port <- o .: "port"
    metadata <- o .: "meta"
    pure $ RegisterMessage NimbusInstance {isHealthy = True, ..}

localUriForPath :: WebApp (Text -> URI)
localUriForPath = do
  env <- ask
  pure $ \path -> URI "http:" (Just $ authority env) ("/" <> Text.unpack path) "" ""
  where
    authority env = URIAuth "" (envServerHostname env) (":" <> show (envServerPort env))

joinCluster :: ClusterToken -> ProtocolVersion -> PendingConnection -> WebApp ()
joinCluster clusterToken protocolVersion pendingConnection = do
  Env {envNimbusConfig} <- ask
  start <- liftIO currentMonoTime
  clusterConfig <- auth clusterToken
  cluster <- clusterM $ getCluster clusterConfig
  let clusterId = cluster.clusterId
      acksSupported = case protocolVersion of
        V2 -> True
        V1 -> False
  webSocket <- liftIO $ acceptRequest pendingConnection
  sendLock <- newMVar ()
  (registerMsg :: RegisterMessage) <- receiveJsonMsg webSocket
  localUri <- localUriForPath
  runResourceT do
    registerRes <- registerWithConsul localUri envNimbusConfig clusterId start registerMsg
    case registerRes of
      Right instanceId -> do
        (_, conn) <- newConnection (clusterConnections cluster) start instanceId acksSupported sendLock webSocket
        lift $ liftIO $ lockedSendJson sendLock webSocket $ LocationRegisteredMessage clusterConfig.clusterId
        runInIO <- askRunInIO
        _ <-
          allocate
            (forkIO $ runInIO $ absurd <$> lift (sendMemberListUpdates envNimbusConfig cluster.clusterId sendLock webSocket Nothing))
            killThread
        _ <-
          allocate
            (forkIO $ runInIO $ lift $ sendDaemonUpdates clusterId conn)
            killThread
        absurd <$> lift (receiveConnectionMessages webSocket (health conn) (ackWaiters conn))
      Left err -> do
        lift $ liftIO $ lockedSendJson sendLock webSocket $ ErrorMsg "Failed to register Unison Cloud node. Please try again or reach out to Unison Cloud support for details."
        logErrorText $ "Error registering BYOC nimbus node: " <> tshow err
  where
    auth clusterToken = do
      clusterOrErr <- authenticateClusterToken clusterToken
      case clusterOrErr of
        Left e -> do
          liftIO $ rejectRequestAndCloseWith pendingConnection rejection
          respondError e
          where
            rejection =
              defaultRejectRequest
                { rejectCode = 401,
                  rejectMessage = "Unauthenticated",
                  rejectBody = BS.toStrict $ encode $ ErrorMsg "Unauthenticated"
                }
        Right c -> pure c

-- | Send a rejection message to the client and close the underlying connection
-- | https://github.com/jaspervdj/websockets/pull/211
rejectRequestAndCloseWith
    :: PendingConnection -- ^ Connection to reject and close
    -> RejectRequest -- ^ Params on how to reject the request
    -> IO ()
rejectRequestAndCloseWith pc reject = do
  rejectRequestWith pc reject
  Stream.close $ pendingStream pc

registerRequest :: (Text -> URI) -> NimbusConfig -> ClusterId -> MonoTime -> RegisterMessage -> RegisterServiceRequest
registerRequest localUriForPath nimbusCfg (ClusterId clusterId) start msg =
  let nimbusInstance = node msg
      locationIdText = locationIdToText (locationId nimbusInstance)
      clusterIdText = Text.pack $ toString clusterId
      serviceName = nimbusHttpServiceName nimbusCfg
      instanceIdText = serviceName <> "-" <> clusterIdText <> "-" <> locationIdText <> "-" <> tshow (monoTimeToNanos start)
      serviceInstanceId = Just $ ServiceInstanceId instanceIdText
      serviceTags = []
      instanceUri = uri nimbusInstance
      p = port nimbusInstance
      serviceAddress = Nothing
      servicePort = Nothing
      -- TODO namespace user metadata
      serviceInstanceMetadata =
        metadata nimbusInstance
          <> Map.fromList
            [ ("instance_id", locationIdText),
              ("cluster_id", clusterIdText),
              ("http_uri", Text.pack $ show instanceUri),
              ("port", Text.pack p),
              ("hostname", Text.pack $ hostname nimbusInstance)
            ]
      serviceChecks =
        [ CheckRegistration
            { checkName = "nimbus-connection",
              checkId = Just $ "nimbus-connection-" <> instanceIdText,
              checkServiceId = serviceInstanceId,
              checkExec = Http $ localUriForPath $ "internal/byoc/health/" <> clusterIdText <> "/" <> instanceIdText,
              checkInterval = secondsToNominalDiffTime 30,
              checkTimeout = Just $ secondsToNominalDiffTime 10,
              checkInitialStatus = Just Passing,
              checkSuccessBeforePassing = Just 1,
              checkFailuresBeforeWarning = Just 1,
              checkFailuresBeforeCritical = Just 2,
              checkDeregisterCriticalServiceAFter = Just $ secondsToNominalDiffTime $ 60 * 60
            }
        ]
   in RegisterServiceRequest {..}

sendMemberListUpdates :: NimbusConfig -> ClusterId -> MVar () -> Network.WebSockets.Connection -> Maybe ConsulIndex -> WebApp Void
sendMemberListUpdates nimbusCfg cluster sendLock connection index = do
  Env {consulClientEnv} <- ask
  let consulEnv =
        consulClientEnv
          { S.makeClientRequest = \url req ->
              S.makeClientRequest consulClientEnv url req <&> \r ->
                r {responseTimeout = responseTimeoutMicro 18000000000}
          }
  let go prevIndex = do
        fetchedMembers <- liftIO $ S.runClientM (getMemberList nimbusCfg cluster prevIndex) consulEnv
        case fetchedMembers of
          Right (newIndex, members) -> do
            liftIO $ lockedSendJson sendLock connection members
            go newIndex
          Left err -> do
            logErrorText $ "Error fetching cluster members: " <> tshow err
            liftIO $ threadDelay 3000000 -- TODO improve retry strategy
            go prevIndex
   in go index

sendDaemonUpdates :: ClusterId -> Connection -> WebApp ()
sendDaemonUpdates cluster connection = runConduit $ consulWatchClusterDaemons cluster .| mapM_C sendList
  where
    sendList = liftIO . sendEvent connection . DaemonList cluster

clusterFilter :: ClusterId -> Filter
clusterFilter (ClusterId cid) = Match (Equals (Selector "Service" ["Meta", "cluster_id"]) (StringValue (Text.pack (toString cid))))

sendHealthCheckRequest :: MVar () -> Network.WebSockets.Connection -> MonoTime -> IO ()
sendHealthCheckRequest sendLock webSocket reqTime =
  lockedSendJson sendLock webSocket $ HealthRequestMessage reqTime

newConnection :: (Hashable k, MonadResource m, MonadUnliftIO m) => STM.Map k Connection -> MonoTime -> k -> Bool -> MVar () -> Network.WebSockets.Connection -> m (ReleaseKey, Connection)
newConnection connections start instanceId acksSupported sendLock websocket = do
  health <- liftIO $ UnliftIO.newTVarIO $ Health Critical start Nothing
  ackSeqVar <- liftIO $ UnliftIO.newTVarIO 0
  ackWaitersVar <- liftIO $ UnliftIO.newTVarIO Map.empty
  let connection = Connection health start (checkConnectionHealth sendLock websocket health) (lockedSendJson sendLock websocket) (lockedSendJson sendLock websocket) acksSupported ackSeqVar ackWaitersVar
  releaseKey <- allocate_ (UnliftIO.atomically $ STM.insert connection instanceId connections) releaseConnection
  pure (releaseKey, connection)
  where
    releaseConnection = UnliftIO.atomically $ STM.delete instanceId connections

registerWithConsul :: (MonadResource m, MonadReader (Env ctx) m) => (Text -> URI) -> NimbusConfig -> ClusterId -> MonoTime -> RegisterMessage -> m (Either S.ClientError ServiceInstanceId)
registerWithConsul localUri nimbusCfg cluster start registerMsg =
  let registerReq = registerRequest localUri nimbusCfg cluster start registerMsg
      instanceId = registerServiceRequestInstanceId registerReq
   in do
        Env {consulClientEnv} <- ask
        (_, res) <-
          allocate
            (liftIO $ S.runClientM (registerService' (Just True) registerReq) consulClientEnv)
            (const $ liftIO $ void $ S.runClientM (deregisterService' instanceId) consulClientEnv)
        pure $ instanceId <$ res

checkConnectionHealth :: MVar () -> Network.WebSockets.Connection -> TVar Health -> IO CheckStatus
checkConnectionHealth sendLock connection healthVar = do
  reqTime <- currentMonoTime
  UnliftIO.atomically $ modifyTVar healthVar (\h -> h {lastHealthRequest = Just reqTime})
  sendHealthCheckRequest sendLock connection reqTime
  UnliftIO.atomically do
    health <- readTVar healthVar
    case lastKnownStatusTime health of
      t | t >= reqTime -> pure $ lastKnownStatus health
      _ -> retry -- await response for pending request

receiveConnectionMessages :: Network.WebSockets.Connection -> TVar Health -> TVar (Map.Map Word (TMVar Integer)) -> WebApp Void
receiveConnectionMessages conn healthVar ackWaitersVar =
  go
  where
    go = do
      msg <- receiveJsonMsg conn
      case msg of
        HealthResponse n s _ -> do
          liftIO $ UnliftIO.atomically $ modifyTVar healthVar (\h -> h {lastKnownStatus = s, lastKnownStatusTime = n})
          go
        InvalidationAckMsg s applyNanos -> do
          liftIO $ UnliftIO.atomically $ do
            waiters <- readTVar ackWaitersVar
            case Map.lookup s waiters of
              Just slot -> do
                _ <- tryPutTMVar slot applyNanos
                modifyTVar' ackWaitersVar (Map.delete s)
              Nothing -> pure ()
          go

eventPrefix :: Text
eventPrefix = case Cloud.Deployment.deployment of
  Cloud.Deployment.Staging -> "staging-"
  _ -> ""

stmMapSnapshot :: STM.Map k v -> STM [(k, v)]
stmMapSnapshot = C.foldlM' (\l (k, v) -> pure ((k, v) : l)) [] . STM.unfoldlM

-- | Attach a correlation id to an invalidation event's JSON.
stampSeq :: Word -> Event -> Data.Aeson.Value
stampSeq s ev = case toJSON ev of
  Data.Aeson.Object o -> Data.Aeson.Object (KeyMap.insert "seq" (toJSON s) o)
  v -> v

-- | Push an invalidation to a single node and, for V2 nodes, block until it acks
-- it has applied the change (or the deadline elapses). V1 nodes are sent the
-- legacy fire-and-forget event.
sendEventSync :: Int -> Connection -> Event -> IO NodeDelivery
sendEventSync timeoutMicros conn ev
  | not (acksSupported conn) = do
      sendEvent conn ev
      pure NoAckSupport
  | otherwise = do
      slot <- newEmptyTMVarIO
      s <- UnliftIO.atomically $ do
        s <- readTVar (ackSeq conn)
        writeTVar (ackSeq conn) (s + 1)
        modifyTVar' (ackWaiters conn) (Map.insert s slot)
        pure s
      t0 <- currentMonoTime
      sendValue conn (stampSeq s ev)
      mApply <- UnliftIO.timeout timeoutMicros (UnliftIO.atomically (takeTMVar slot))
      t1 <- currentMonoTime
      UnliftIO.atomically $ modifyTVar' (ackWaiters conn) (Map.delete s)
      pure $ case mApply of
        Nothing -> AckTimedOut
        Just applyNanos -> Acked (monoTimeToNanos t1 - monoTimeToNanos t0) applyNanos

-- | Synchronously deliver an invalidation to every node of a cluster that is
-- connected to THIS cloud-api instance, gathering per-node results. Cross-instance
-- fan-out (to nodes held by other cloud-api instances) is layered on top separately.
invalidateClusterLocal :: Int -> Cluster -> Event -> IO [(ServiceInstanceId, NodeDelivery)]
invalidateClusterLocal timeoutMicros cluster ev = do
  conns <- UnliftIO.atomically $ stmMapSnapshot (clusterConnections cluster)
  forConcurrently conns $ \(nodeId, conn) -> do
    d <- sendEventSync timeoutMicros conn ev
    pure (nodeId, d)

-- | How long to wait for all connected nodes to ack an invalidation before
-- giving up on the stragglers (logged loudly — the deadline is an alarm, not a
-- silent giveup).
invalidationTimeoutMicros :: Int
invalidationTimeoutMicros = 30_000_000

-- | The Consul service name cloud-api registers itself under (via Nomad).
-- Environment-prefixed: "cloud-api-http" in prod, "cloud-api-staging-http" in
-- staging (overridable with CLOUD_API_CONSUL_SERVICE).
cloudApiServiceName :: Text
cloudApiServiceName = "cloud-api-" <> eventPrefix <> "http"

resolveCloudApiServiceName :: IO Text
resolveCloudApiServiceName = maybe cloudApiServiceName Text.pack <$> lookupEnv "CLOUD_API_CONSUL_SERVICE"

-- | Startup self-check: confirm this cloud-api deployment is discoverable in
-- Consul under the expected service name. A wrong name fails SILENTLY in
-- production — peer discovery returns no peers and invalidations quietly become
-- local-only, which only breaks once more than one instance is running. Retries
-- briefly to ride out the registration race at boot, then logs loudly.
consulRegistrationSelfCheck :: CloudApp ()
consulRegistrationSelfCheck = do
  Env {consulClientEnv} <- ask
  svc <- liftIO resolveCloudApiServiceName
  let go (n :: Int) = do
        res <- liftIO $ S.runClientM (serviceHealth' svc (Just True) Nothing Nothing True True) consulClientEnv
        case res of
          Right r
            | instances <- getResponse r,
              not (null instances) ->
                logDebugText $
                  "Consul self-check passed: found " <> tshow (length instances) <> " instance(s) of service \"" <> svc <> "\""
          _ ->
            if n <= 1
              then
                logErrorText $
                  "CONSUL SELF-CHECK FAILED: service \"" <> svc
                    <> "\" not found in the Consul catalog. Peer discovery will find no cloud-api peers, so"
                    <> " invalidations will be delivered LOCAL-ONLY — in a multi-instance deployment, nodes"
                    <> " attached to other instances will serve stale data. Check the Nomad service"
                    <> " registration or set CLOUD_API_CONSUL_SERVICE."
              else do
                liftIO $ threadDelay 10_000_000
                go (n - 1)
  go 12

-- | Invalidate only the connections for a cluster held by THIS instance.
invalidateLocalForCluster :: Int -> ClusterId -> Event -> WebApp [(ServiceInstanceId, NodeDelivery)]
invalidateLocalForCluster timeoutMicros clusterId ev = do
  Env {clusterEnv = ClusterEnv {envClusters}} <- ask
  mCluster <- liftIO $ UnliftIO.atomically $ TMap.lookup clusterId envClusters
  case mCluster of
    Nothing -> pure []
    Just cluster -> liftIO $ invalidateClusterLocal timeoutMicros cluster ev

-- | Peer cloud-api instances registered in Consul. Empty on error or when
-- cloud-api isn't registered (e.g. local integration tests) — callers then fall
-- back to local-only delivery. The Consul service name can be overridden with
-- the CLOUD_API_CONSUL_SERVICE env var (the registered service name may differ
-- per environment from the Nomad port label).
discoverCloudApiPeers :: WebApp [S.BaseUrl]
discoverCloudApiPeers = do
  Env {consulClientEnv} <- ask
  svc <- liftIO resolveCloudApiServiceName
  res <- liftIO $ S.runClientM (serviceHealth' svc (Just True) Nothing Nothing True True) consulClientEnv
  case res of
    Left err -> do
      logErrorText $ "cloud-api peer discovery (service \"" <> svc <> "\") failed: " <> tshow err
      liftIO $ InvalidationMetrics.recordPeersDiscovered 0
      pure []
    Right r -> do
      let peers = [S.BaseUrl S.Http i.address (fromIntegral p) "" | i <- getResponse r, Just p <- [i.port]]
      liftIO $ InvalidationMetrics.recordPeersDiscovered (length peers)
      logDebugText $
        "cloud-api peer discovery (service \"" <> svc <> "\"): found "
          <> tshow (length peers)
          <> " peer(s): "
          <> tshow [Text.pack (S.baseUrlHost b) <> ":" <> tshow (S.baseUrlPort b) | b <- peers]
      pure peers

peerInvalidateClient :: Maybe Text -> Event -> S.ClientM [PeerNodeResult]
peerInvalidateClient = S.client (Proxy @PeerInvalidateAPI)

-- | Shared secret for the internal peer RPC (unset in local/test environments).
internalAuthToken :: IO (Maybe Text)
internalAuthToken = fmap Text.pack <$> lookupEnv "CLOUD_INTERNAL_AUTH_TOKEN"

-- | Background retry for a failed peer invalidate RPC. The synchronous caller
-- has already returned (and logged the failure); this shrinks the staleness
-- window on that peer's nodes from "until the node cache TTL (~10 min)" to
-- seconds when the peer outage is transient. Idempotent: cache deletes can be
-- applied any number of times.
retryPeerInvalidate :: Manager -> S.BaseUrl -> Event -> WebApp ()
retryPeerInvalidate mgr base ev = void $ forkIO $ go (5 :: Int)
  where
    peer = Text.pack (S.baseUrlHost base) <> ":" <> tshow (S.baseUrlPort base)
    go 0 =
      logErrorText $
        "peer invalidate retry to " <> peer <> " EXHAUSTED (" <> tshow ev
          <> ") — that instance's nodes rely on the cache TTL floor (~10 min) until reconnect"
    go n = do
      liftIO $ threadDelay 5_000_000
      auth <- liftIO internalAuthToken
      res <- liftIO $ S.runClientM (peerInvalidateClient auth ev) (S.mkClientEnv mgr base)
      case res of
        Right rs -> do
          liftIO $ InvalidationMetrics.recordInvalidationResults (eventTypeLabel ev) [(prNodeId r, prDelivery r) | r <- rs]
          logDebugText $ "peer invalidate retry to " <> peer <> " succeeded (" <> tshow (length rs) <> " node(s))"
        Left _ -> go (n - 1)

eventTypeLabel :: Event -> Text
eventTypeLabel = \case
  EnvironmentInvalidation {} -> "environment"
  UserServiceInvalidation {} -> "user-service"
  ServiceIdInvalidation {} -> "service-id"
  ServiceHashInvalidation {} -> "service-hash"
  DaemonList {} -> "daemon-list"

-- | Synchronously deliver an invalidation across the whole cluster: this
-- instance's own connections directly, plus every peer cloud-api instance over
-- the internal RPC, gathering per-node latency. The discovered peer list also
-- includes this instance (reached over loopback), so results are deduped by node
-- id and each node is reported once. With no peers discovered (e.g. local tests)
-- this degrades to local-only delivery.
invalidateSync :: Int -> ClusterId -> Event -> WebApp [(ServiceInstanceId, NodeDelivery)]
invalidateSync timeoutMicros clusterId ev = do
  localResults <- invalidateLocalForCluster timeoutMicros clusterId ev
  peers <- discoverCloudApiPeers
  peerResults <-
    if null peers
      then do
        logDebugText "invalidateSync: no cloud-api peers discovered — delivering LOCAL-ONLY (cross-instance invalidation will be incomplete in a multi-instance deployment)"
        pure []
      else do
        mgr <-
          liftIO $
            newManager
              defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro (timeoutMicros + 5_000_000)}
        auth <- liftIO internalAuthToken
        responses <- liftIO $ forConcurrently peers $ \base -> do
          res <- S.runClientM (peerInvalidateClient auth ev) (S.mkClientEnv mgr base)
          pure (base, res)
        forM_ responses $ \(base, res) -> case res of
          Left err -> do
            logErrorText $ "peer invalidate RPC to " <> tshow (S.baseUrlHost base) <> " failed: " <> tshow err <> " — retrying in background"
            retryPeerInvalidate mgr base ev
          Right _ -> pure ()
        pure [(prNodeId r, prDelivery r) | (_, Right rs) <- responses, r <- rs]
  pure $ Map.toList (Map.fromListWith (\_new old -> old) (localResults <> peerResults))


getMemberList :: NimbusConfig -> ClusterId -> Maybe ConsulIndex -> S.ClientM (Maybe ConsulIndex, MemberList)
getMemberList nimbusCfg cluster stateIndex =
  let serviceName = nimbusHttpServiceName nimbusCfg
      passingOnly = Nothing
      filter = clusterFilter cluster
      cached = True
      stale = True
   in do
        res <- serviceHealth' serviceName passingOnly stateIndex (Just filter) cached stale
        let instances = mapMaybe nimbusInstanceFromConsulServiceInstance (getResponse res)
            (healthy, unhealthy) = partition isHealthy instances
            memberList = MemberList healthy unhealthy
            stateIndex = maybeResponseHeader $ lookupResponseHeader @"X-Consul-Index" res
        pure (stateIndex, memberList)

server :: ServerT ClusterAPI WebApp
server =
  joinCluster :<|> userIdByHandle :<|> storageByEnvironmentId :<|> deploymentByServiceId :<|> deploymentByServiceName
