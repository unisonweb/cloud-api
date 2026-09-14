{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Cloud.Consul.API
  ( Check (..),
    CheckExec (..),
    checkStatusIsPassing,
    checkStatusToText,
    CheckRegistration (..),
    CheckStatus (..),
    ConsulIndex (..),
    ConsulServiceInstance (..),
    deleteKey',
    deregisterService',
    Event (..),
    fireEvent',
    GetResponse (..),
    ListResponse (..),
    listEvents',
    listKeys,
    maybeResponseHeader,
    nodesForService',
    readKeysWithPrefix,
    readKey,
    registerService',
    RegisterServiceRequest (..),
    registerServiceRequestInstanceId,
    serviceHealth',
    ServiceInstanceId (..),
    serviceInstanceIdToText,
    updateKey',
    watchEvents,
    watchKeys
  )
where

import Amazonka.Prelude (NominalDiffTime)
import Cloud.Prelude
import Control.Monad.Trans (lift)
import Data.Aeson
import Data.Aeson qualified as Aeson
import Data.Aeson.Types
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Maybe (listToMaybe)
import Data.Text.Encoding qualified as Text
import Data.Word (Word16, Word8)
import Network.Socket (HostName)
import Network.URI (URIAuth (..))
import Servant
import Servant.Client qualified as S
import Cloud.Consul.Filtering qualified as Filtering
import Data.Hashable (Hashable)
import Data.Traversable (for)
import Conduit (ConduitT, yieldMany, yield)
import Data.Void (Void)
import qualified Data.Set as Set
import Network.HTTP.Client (responseTimeoutMicro)
import Control.Monad.RWS (MonadReader(local))
import Cloud.Utils.ServantClientUtils (clientEnvWithTimeout)
import Control.Monad.Error.Class (tryError)
import Web.HttpApiData (parseHeaderMaybe)
import Network.HTTP.Types.Status (Status(..))

newtype Regex = Regex Text
  deriving newtype (FromJSON, ToJSON, ToHttpApiData, FromHttpApiData)

data Event = Event {
  eventId :: !Text,
  eventName :: !Text,
  eventPayload :: !(Maybe BS.ByteString)
}

instance FromJSON Event where
  parseJSON = withObject "Event" $ \e -> do
    eventId <- e .: "ID"
    eventName <- e .: "Name"
    base64Payload <- e .:? "Payload"
    eventPayload <- for base64Payload \payload -> case Base64.decode $ Text.encodeUtf8 payload of
      Left _ -> fail ("Invalid base64 encoding: " <> show base64Payload)
      Right bs -> pure bs
    pure $ Event {..}

type ConsulAPI = "v1" :> (CatalogAPI :<|> KVAPI :<|> EventAPI :<|> ServiceHealthApi :<|> AgentAPI)

type EventAPI = "event" :> (FireEventAPI :<|> ListEventsAPI)

type KVAPI = "kv" :> (ListKeysAPI :<|> ReadKeyAPI :<|> UpdateKeyAPI :<|> DeleteKeyAPI)

type AgentAPI = "agent" :> AgentServicesAPI

type CatalogAPI = "catalog" :> NodesForServiceAPI

type AgentServicesAPI = "service" :> (RegisterServiceAPI :<|> DeregisterServiceAPI)

type ServiceHealthApi =
  "health"
    :> "service"
    :> Capture "serviceName" Text
    :> QueryParam "passing" Bool
    :> QueryParam "index" ConsulIndex
    :> QueryParam "filter" Filtering.Filter
    :> QueryFlag "cached"
    :> QueryFlag "stale"
    :> Get '[JSON] (Headers '[Header "X-Consul-Index" ConsulIndex] [ConsulServiceInstance])

data Check = Check {
  checkName :: !Text,
  checkStatus :: !CheckStatus
}

instance FromJSON Check where
  parseJSON = withObject "Check" $ \c -> do
    checkName <- c .: "Name"
    checkStatus <- c .: "Status"
    pure $ Check {..}

data ConsulServiceInstance = ConsulServiceInstance {
  address :: !HostName,
  port :: !(Maybe Word16),
  metadata :: !(Map Text Text),
  checks :: ![Check]
}

instance FromJSON ConsulServiceInstance where
  parseJSON = withObject "ConsulServiceInstance" $ \n -> do
    checks <- n .: "Checks"
    s <- n .: "Service"
    address <- s .: "Address"
    port <- s .:? "Port"
    -- Meta is null/absent for services registered without metadata; treat as empty
    -- rather than failing the whole health-query decode.
    metadata <- s .:? "Meta" .!= mempty
    pure $ ConsulServiceInstance {..}

data GetResponse = GetResponse
  { responseKey :: Text,
    responseValue :: Text,
    updateIndex :: ConsulIndex
  }
  deriving (Generic, Show, Eq, Ord)

instance FromJSON GetResponse where
  parseJSON :: Value -> Parser GetResponse
  parseJSON (Object n) = do
    modifyIndex <- n .: "ModifyIndex"
    key <- n .: "Key"
    v <- n .: "Value"
    case Base64.decode $ Text.encodeUtf8 v of
      Left _ -> fail ("Invalid base64 encoding: " <> show v)
      Right bs -> pure $ GetResponse key (Text.decodeUtf8 bs) modifyIndex
  parseJSON _ = fail "Invalid response"

newtype ListResponse = ListResponse [Text]
  deriving (Generic, Show, Eq, Ord)
  deriving newtype (FromJSON, ToJSON)

type ReadKeyAPI =
  Capture "key" Text
    :> QueryParam "recurse" Bool
    :> QueryFlag "stale"
    :> QueryParam "index" ConsulIndex
    :> Get '[JSON] (Headers '[Header "X-Consul-Index" ConsulIndex] [GetResponse])

type ListKeysAPI =
  Capture "key" Text
    :> QueryParam "recurse" Bool
    :> QueryParam "keys" Bool
    :> QueryParam "index" ConsulIndex
    :> Get '[JSON] (Headers '[Header "X-Consul-Index" ConsulIndex] ListResponse)

type UpdateKeyAPI =
  Capture "key" Text
    :> ReqBody '[OctetStream] BS.ByteString
    :> QueryParam "flags" Int
    :> QueryParam "cas" ConsulIndex
    :> QueryParam "acquire" Text
    :> QueryParam "release" Text
    :> Put '[JSON] Bool

type DeleteKeyAPI =
  Capture "key" Text
    :> QueryParam "recurse" Bool
    :> QueryParam "cas" Int
    :> Delete '[JSON] NoContent

type FireEventAPI =
  "fire"
    :> Capture "name" Text
    :> QueryParam "service" Text
    :> ReqBody '[OctetStream] BS.ByteString
    :> Put '[JSON] Event

type ListEventsAPI =
  "list"
    :> QueryParam "name" Text
    :> QueryParam "index" ConsulIndex
    :> QueryParam "node" Regex
    :> QueryParam "service" Regex
    :> QueryParam "tag" Regex
    :> Get '[JSON] (Headers '[Header "X-Consul-Index" ConsulIndex] [Event])

type RegisterServiceAPI =
  "register"
    :> QueryParam "replace-existing-checks" Bool
    :> ReqBody '[JSON] RegisterServiceRequest
    :> Put '[JSON] NoContent

type DeregisterServiceAPI =
  "deregister"
    :> Capture "service_id" ServiceInstanceId
    :> Put '[JSON] NoContent

type NodesForServiceAPI =
  "service"
    :> Capture "service-name" Text
    :> QueryParam "index" ConsulIndex
    :> QueryParam "filter" Filtering.Filter
    :> QueryFlag "cached"
    :> QueryFlag "stale"
    :> Get '[JSON] (Headers '[Header "X-Consul-Index" ConsulIndex] [ConsulServiceInstance])

data CheckExec = Http !URI | Tcp !URIAuth

instance ToJSON CheckExec where
  toJSON (Http uri) = object ["HTTP" .= tshow uri]
  toJSON (Tcp auth) = object ["TCP" .= tshow auth]

data CheckStatus = Passing | Warning | Critical
  deriving (Eq, Ord)

checkStatusIsPassing :: CheckStatus -> Bool
checkStatusIsPassing Passing = True
checkStatusIsPassing _ = False

checkStatusToText :: CheckStatus -> Text
checkStatusToText Passing = "passing"
checkStatusToText Warning = "warning"
checkStatusToText Critical = "critical"

instance ToJSON CheckStatus where
  toJSON = Aeson.String . checkStatusToText

instance FromJSON CheckStatus where
  parseJSON = withText "CheckStatus" $ \t ->
    case t of
      "passing" -> pure Passing
      "warning" -> pure Warning
      "critical" -> pure Critical
      _ -> fail $ "parsing check status failed, unexpected " ++ show t

durationString :: NominalDiffTime -> Text
durationString = tshow

data CheckRegistration = CheckRegistration
  { checkName :: !Text,
    checkId :: !(Maybe Text),
    checkServiceId :: !(Maybe ServiceInstanceId),
    checkExec :: !CheckExec,
    checkInterval :: !NominalDiffTime,
    checkTimeout :: !(Maybe NominalDiffTime),
    checkInitialStatus :: !(Maybe CheckStatus),
    checkSuccessBeforePassing :: !(Maybe Word8),
    checkFailuresBeforeWarning :: !(Maybe Word8),
    checkFailuresBeforeCritical :: !(Maybe Word8),
    checkDeregisterCriticalServiceAFter :: !(Maybe NominalDiffTime)
  }

instance ToJSON CheckRegistration where
  toJSON CheckRegistration {..} =
    object $
      [ "Name" .= checkName,
        "CheckID" .= checkId,
        "ServiceId" .= checkServiceId,
        "Interval" .= durationString checkInterval,
        "Timeout" .= (durationString <$> checkTimeout),
        "Status" .= checkInitialStatus,
        "SuccessBeforePassing" .= checkSuccessBeforePassing,
        "FailuresBeforeWarning" .= checkFailuresBeforeWarning,
        "FailuresBeforeCritical" .= checkFailuresBeforeCritical,
        "DeregisterCriticalServiceAfter" .= (durationString <$> checkDeregisterCriticalServiceAFter)
      ]
        ++ checkExecFields checkExec
    where
      checkExecFields (Http uri) = ["HTTP" .= tshow uri]
      checkExecFields (Tcp auth) = ["TCP" .= tshow auth]

data RegisterServiceRequest = RegisterServiceRequest
  { serviceName :: !Text,
    serviceInstanceId :: !(Maybe ServiceInstanceId),
    serviceTags :: ![Text],
    serviceAddress :: !(Maybe HostName),
    servicePort :: !(Maybe Word16),
    serviceInstanceMetadata :: !(Map Text Text),
    serviceChecks :: ![CheckRegistration]
  }

registerServiceRequestInstanceId :: RegisterServiceRequest -> ServiceInstanceId
registerServiceRequestInstanceId (RegisterServiceRequest {serviceInstanceId, serviceName}) =
  fromMaybe (ServiceInstanceId serviceName) serviceInstanceId

instance ToJSON RegisterServiceRequest where
  toJSON RegisterServiceRequest {..} =
    object
      [ "Name" .= serviceName,
        "ID" .= serviceInstanceId,
        "Tags" .= serviceTags,
        "Address" .= serviceAddress,
        "Port" .= servicePort,
        "Meta" .= serviceInstanceMetadata,
        "Checks" .= serviceChecks
      ]

newtype ConsulIndex = ConsulIndex Word
  deriving newtype (Eq, Ord, FromJSON, ToJSON, FromHttpApiData, Show, ToHttpApiData)

newtype ServiceInstanceId = ServiceInstanceId Text
  deriving newtype (Eq, FromHttpApiData, FromJSON, Hashable, Ord, Show, ToHttpApiData, ToJSON)

serviceInstanceIdToText :: ServiceInstanceId -> Text
serviceInstanceIdToText (ServiceInstanceId t) = t

consulAPI :: Proxy ConsulAPI
consulAPI = Proxy

nodesForService' :: Text -> Maybe ConsulIndex -> Maybe Filtering.Filter -> Bool -> Bool -> S.ClientM (Headers '[Header "X-Consul-Index" ConsulIndex] [ConsulServiceInstance])
readKey' :: Text -> Maybe Bool -> Bool -> Maybe ConsulIndex -> S.ClientM (Headers '[Header "X-Consul-Index" ConsulIndex] [GetResponse])
listKeys' :: Text -> Maybe Bool -> Maybe Bool -> Maybe ConsulIndex -> S.ClientM (Headers '[Header "X-Consul-Index" ConsulIndex] ListResponse)
updateKey' :: Text -> BS.ByteString -> Maybe Int -> Maybe ConsulIndex -> Maybe Text -> Maybe Text -> S.ClientM Bool
deleteKey' :: Text -> Maybe Bool -> Maybe Int -> S.ClientM NoContent
fireEvent' :: Text -> Maybe Text -> BS.ByteString -> S.ClientM Event
listEvents' :: Maybe Text -> Maybe ConsulIndex -> Maybe Regex -> Maybe Regex -> Maybe Regex -> S.ClientM (Headers '[Header "X-Consul-Index" ConsulIndex] [Event])
serviceHealth' :: Text -> Maybe Bool -> Maybe ConsulIndex -> Maybe Filtering.Filter -> Bool -> Bool -> S.ClientM (Headers '[Header "X-Consul-Index" ConsulIndex] [ConsulServiceInstance])
registerService' :: Maybe Bool -> RegisterServiceRequest -> S.ClientM NoContent
deregisterService' :: ServiceInstanceId -> S.ClientM NoContent
nodesForService' :<|> (listKeys' :<|> readKey' :<|> updateKey' :<|> deleteKey') :<|> (fireEvent' :<|> listEvents') :<|> serviceHealth' :<|> (registerService' :<|> deregisterService') = S.client consulAPI

readKeysWithPrefix :: Bool -> Text -> Maybe ConsulIndex -> S.ClientM (Maybe ConsulIndex, [GetResponse])
readKeysWithPrefix allowStale key index = do
  response <- tryError $ readKey' key (Just True) allowStale index
  case response of
    Right response ->
      pure (newIndex, getResponse response)
      where newIndex = maybeResponseHeader $ lookupResponseHeader @"X-Consul-Index" response
    Left (S.FailureResponse _ (S.Response (Status 404 _) headers _ _)) ->
      pure (currentIndex, [])
      where currentIndex = find (\h -> fst h == "X-Consul-Index") headers >>= (parseHeaderMaybe . snd)
    Left e -> throwError e

readKey :: Bool -> Text -> S.ClientM (Maybe GetResponse)
readKey allowStale key = listToMaybe . getResponse <$> readKey' key Nothing allowStale Nothing

listKeys :: Text -> Maybe ConsulIndex -> S.ClientM (Maybe ConsulIndex, ListResponse)
listKeys key consulIndex = do
  response <- listKeys' key (Just True) (Just True) consulIndex
  let newIndex = maybeResponseHeader $ lookupResponseHeader @"X-Consul-Index" response
  pure (newIndex, getResponse response)

maybeResponseHeader :: ResponseHeader h a -> Maybe a
maybeResponseHeader (Header a) = Just a
maybeResponseHeader _ = Nothing

watchEvents :: forall m. (Monad m) => (forall i. S.ClientM i -> m (Maybe i)) -> Maybe Text -> Maybe Regex -> Maybe Regex -> Maybe Regex -> ConduitT () Event m Void
watchEvents runClient eventName node service tag = go Nothing Set.empty
  where
    -- These are using Consul blocking queries https://developer.hashicorp.com/consul/api-docs/features/blocking
    -- which default to blocking for 5+ minutes until changes are available.
    runPatiently = local (clientEnvWithTimeout (responseTimeoutMicro 600000000))
    go :: Maybe ConsulIndex -> Set.Set Text -> ConduitT () Event m Void
    go prevIndex prevIds = do
      response <- lift $ runClient $ runPatiently (listEvents' eventName prevIndex node service tag)
      case response of
        Just response -> do
          yieldMany newEvents
          go newIndex batchIds
          where
            newIndex = maybeResponseHeader $ lookupResponseHeader @"X-Consul-Index" response
            batchEvents = getResponse response
            batchIds = Set.fromList $ eventId <$> newEvents
            newEvents = filter (not . \e -> Set.member (eventId e) prevIds) batchEvents
        Nothing -> go prevIndex prevIds

watchKeys :: forall m. (Monad m) => (forall i. S.ClientM i -> m (Maybe i)) -> Text -> Bool -> ConduitT () [GetResponse] m Void
watchKeys runClient keyPrefix allowStale = go Nothing
  where
    -- These are using Consul blocking queries https://developer.hashicorp.com/consul/api-docs/features/blocking
    -- which default to blocking for 5+ minutes until changes are available.
    runPatiently = local (clientEnvWithTimeout (responseTimeoutMicro 600000000))
    go :: Maybe ConsulIndex -> ConduitT () [GetResponse] m Void
    go prevIndex = do
      response <- lift $ runClient $ runPatiently (readKeysWithPrefix allowStale keyPrefix prevIndex)
      case response of
        Just (newIndex, values) -> do
          yield values
          go $ Just $ safeNewIndex prevIndex newIndex
        Nothing -> go prevIndex
    -- https://developer.hashicorp.com/consul/api-docs/features/blocking#implementation-details
    safeNewIndex _ (Just (ConsulIndex 0)) = index1
    safeNewIndex _ Nothing = index1
    safeNewIndex (Just old) (Just new) = if new < old then index1 else new
    safeNewIndex Nothing (Just new) = new
    index1 = ConsulIndex 1
