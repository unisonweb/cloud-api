-- |
-- This is the message format we will use for all messages that are going to be
-- shared between unison and haskell, which includes the unison.cloud clients
-- talking to enlil, and enlil talking to nodes in unison.cloud.
--
-- Messages will consist of an 8 byte header followed by a payload. The header
-- consists of two 4 byte, big endian unsigned integers:
--
-- msgType: A number representin the type of payload msgSize: The number of bytes
-- in the payload
--
--   0  1  2  3  4  5  6  7
-- +--+--+--+--+--+--+--+--+
-- |  msgType  |  msgSize  |
-- +--+--+--+--+--+--+--+--+
-- |                       |
-- /        PAYLOAD        /
-- /                       /
-- +--+--+--+--+--+--+--+--+
--
-- +---------------------+-----+-----------------------+--------------------------------+
-- | MessageType         |     | Payload               |Format                          |
-- +=====================|=====|=======================|================================+
-- | `ClientFork`        | 101 |  accessToken, Thunk   | 2 byte token length,           |
-- |                     |     |                       | ascii token,                   |
-- |                     |     |                       | Unison serialized thunk        |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `ClientTerms`       | 102 |  [(Link.Term, Bytes)] | Unison serialized              |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `ClientFork2`       | 103 |  accessToken,         | 2 byte token length,           |
-- |                     |     |                       | ascii token                    |
-- |                     |     |  environmentId,       | 2 byte envId length,           |
-- |                     |     |                       | ascii envId,                   |
-- |                     |     |  Thunk                | Unison serialized thunk        |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `ClientFork3`       | 104 |  accessToken,         | 2 byte token length,           |
-- |                     |     |                       | ascii token                    |
-- |  jobId response     |     |  environmentId,       | 2 byte envId length,           |
-- |  expected           |     |                       | ascii envId,                   |
-- |                     |     |  Thunk                | Unison serialized thunk        |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `TermRequest`       | 201 |  [Link.Term]          | Unison serialized              |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `TaskResult`        | 202 |  Either Failure Bytes | Unison serialized              |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `FailureReply`      | 203 |  Text                 | UTF-8 bytes                    |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `ForkRequest`       | 206 |  uuid, Thunk          | 16 bytes BE, Unison serialized |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `TermReply`         | 207 |  [(Link.Term, Bytes)] | Unison serialized              |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `NimbusTermRequest` | 208 |  [Link.Term]          | Unison serialized              |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `NimbusTaskResult`  | 209 |  Either Failure Bytes | Unison serialized              |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `ForkRequest2`      | 210 |  uuid, uuid, Thunk    | 16 bytes BE user ID            |
-- |                     |     |                       | 16 bytes BE environment ID     |
-- |                     |     |                       | Unison serialized thunk        |
-- |---------------------+-----+-----------------------+--------------------------------+
-- | `ForkRequest3    `  | 211 | byte                  | flags                          |
-- |                     |     |                       |   6 unused 0 bits for now      |
-- |                     |     |                       |   1 if job ID is provided      |
-- |                     |     |                       |     otherwise 0                |
-- |                     |     |                       |   1 if env ID is provided      |
-- |                     |     |                       |     otherwise 0                |
-- |                     |     | uuid (maybe)          | 16 bytes BE job ID             |
-- |                     |     |                       |   or empty if job ID flag is 0 |
-- |                     |     | uuid                  | 16 bytes BE user ID            |
-- |                     |     | uuid (maybe)          | 16 bytes BE environment ID     |
-- |                     |     |                       |   or empty if env ID flag is 0 |
-- |                     |     | Thunk                 | Unison serialized thunk        |
-- +---------------------+-----+-----------------------+--------------------------------+
-- | `JobStarted`        | 212 |  uuid                 | 16 bytes BE job id             |
-- +---------------------+-----+-----------------------+--------------------------------+

--
-- Notes:
--
-- * CloudAuthSuccess has no payload, it will send 0 as msgSize
-- * the Thunk in CloudForkRequest will be (msgSize - 16) bytes long
module Cloud.Client.Messages
  ( accessTokenBase64,
    clientForkEnvironment,
    clientTermsBytes,
    clientThunk,
    FailureReply (..),
    ForkRequest (..),
    getClientFork,
    getClientTerms,
    getMessageHeader,
    getNimbusResponse,
    JobId (..),
    MessageHeader (..),
    messageTypeClientForkWithEnv,
    messageTypeClientForkWantsJobId,
    messageTypeClientForkWithoutEnv,
    messageTypeClientTerms,
    NimbusResponse (..),
    putFailureReply,
    putForkRequest,
    putTaskResult,
    putTermReply,
    putTermRequest,
    receiveMessage,
    receiveMessageForHeader,
    TaskResult (..),
    TermReply (..),
    JobStarted (..),
    TermRequest (..),
    unexpectedMessageType,
    putJobStarted,
  )
where

import Cloud.Client.Errors
import Cloud.Client.Types (MessageType (..))
import Cloud.Utils.Logging
import Data.Binary (put, Binary)
import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString.Lazy qualified as LBS
import Data.Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.UUID qualified as UUID
import Share.OAuth.Types
import Share.Utils.Show
import GHC.Word (Word32, Word8)
import UnliftIO
import Data.UUID
import Data.Bits ((.|.))
import Servant (FromHttpApiData, ToHttpApiData)
import Data.Aeson (ToJSON)
import Cloud.Postgres (EncodeValue, DecodeValue)
import Cloud.Web.Types (EnvironmentId (..))
import Data.Aeson.Types (FromJSON)

data MessageHeader = MessageHeader
  { messageType :: !MessageType,
    messageLength :: !Word32
  }
  deriving (Show)

getMessageType :: Get MessageType
getMessageType = MessageType <$> getWord32be

getMessageHeader :: Get MessageHeader
getMessageHeader =
  label "MessageHeader" $ MessageHeader <$> getMessageType <*> getWord32be

data ClientFork = ClientFork
  { accessTokenBase64 :: !Text,
    clientForkEnvironment :: !(Maybe EnvironmentId),
    clientThunk :: !LBS.ByteString
  }

messageTypeClientForkWithoutEnv :: MessageType
messageTypeClientForkWithoutEnv = MessageType 101

messageTypeClientForkWithEnv :: MessageType
messageTypeClientForkWithEnv = MessageType 103

messageTypeClientForkWantsJobId :: MessageType
messageTypeClientForkWantsJobId = MessageType 104

getTextEnvironmentId :: Get EnvironmentId
getTextEnvironmentId = do
  envIdLength <- getWord16be
  envIdText <- decodeUtf8 <$> getByteString (fromIntegral envIdLength)
  case UUID.fromText envIdText of
    Just uuid -> pure $ EnvironmentId uuid
    Nothing -> fail $ "Invalid environment id: " <> show envIdText

getClientFork :: Bool -> Get ClientFork
getClientFork withEnv = do
  accessTokenLength <- getWord16be
  accessToken <- decodeUtf8 <$> getByteString (fromIntegral accessTokenLength)
  envId <- if withEnv then Just <$> getTextEnvironmentId else pure Nothing
  ClientFork accessToken envId <$> getRemainingLazyByteString

newtype JobId = JobId UUID
  deriving (Show)
  deriving newtype (FromHttpApiData, ToHttpApiData, Binary, FromJSON, ToJSON, EncodeValue, DecodeValue)

data ForkRequest = ForkRequest
  { forkRequestJobId :: !(Maybe JobId),
    userId :: !UserId,
    forkRequestEnvironment :: !(Maybe EnvironmentId),
    thunk :: !LBS.ByteString
  }

messageTypeForkRequest :: MessageType
messageTypeForkRequest = MessageType 211

putForkRequest :: ForkRequest -> Put
putForkRequest req =
  let encode (ForkRequest jobId userId environment thunk) =
        putWord8 flags <> putJobId jobId <> put userId <> putEnv environment <> putLazyByteString thunk
   in putMessage messageTypeForkRequest encode req
  where
    flags :: Word8
    flags = maybe 0 (const 2) (forkRequestJobId req) .|. maybe 0 (const 1) (forkRequestEnvironment req)
    putEnv = maybe (pure ()) put
    putJobId = maybe (pure ()) put

newtype TermRequest = TermRequest LBS.ByteString
  deriving (Show)

messageTypeTermRequest :: MessageType
messageTypeTermRequest = MessageType 201

putTermRequest :: TermRequest -> Put
putTermRequest =
  let encode (TermRequest bytes) = putLazyByteString bytes
   in putMessage messageTypeTermRequest encode


newtype JobStarted = JobStarted JobId
  deriving (Show)

messageJobStarted :: MessageType
messageJobStarted = MessageType 212

putJobStarted :: JobStarted -> Put
putJobStarted =
  let encode (JobStarted jobId) = put jobId
   in putMessage messageJobStarted encode

newtype ClientTerms = ClientTerms {clientTermsBytes :: LBS.ByteString}
  deriving (Show) via (Censored LBS.ByteString)

getClientTerms :: Get ClientTerms
getClientTerms = ClientTerms <$> getRemainingLazyByteString

messageTypeClientTerms :: MessageType
messageTypeClientTerms = MessageType 102

newtype TaskResult = TaskResult LBS.ByteString
  deriving (Show) via (Censored LBS.ByteString)

messageTypeTaskResult :: MessageType
messageTypeTaskResult = MessageType 202

putTaskResult :: TaskResult -> Put
putTaskResult =
  let encode (TaskResult bytes) = putLazyByteString bytes
   in putMessage messageTypeTaskResult encode

data NimbusResponse
  = NimbusTermRequest !LBS.ByteString
  | NimbusTaskResult !LBS.ByteString

getNimbusResponse :: Get NimbusResponse
getNimbusResponse = do
  header <- getMessageHeader
  isolate (fromIntegral $ messageLength header) (getBody $ messageType header)
  where
    getBody (MessageType 208) = NimbusTermRequest <$> getRemainingLazyByteString
    getBody (MessageType 209) = NimbusTaskResult <$> getRemainingLazyByteString
    getBody otherMsgType = fail $ "unexpected nimbus response message type: " <> show otherMsgType

newtype TermReply = TermReply {termDefinitions :: LBS.ByteString}
  deriving (Show) via (Censored LBS.ByteString)

messageTypeTermReply :: MessageType
messageTypeTermReply = MessageType 207

putTermReply :: TermReply -> Put
putTermReply =
  let encode (TermReply termBytes) = putLazyByteString termBytes
   in putMessage messageTypeTermReply encode

newtype FailureReply = FailureReply {failureReplyMessage :: Text}
  deriving (Show)

messageTypeFailureReply :: MessageType
messageTypeFailureReply = MessageType 203

putFailureReply :: FailureReply -> Put
putFailureReply =
  let encode (FailureReply msg) = putByteString (encodeUtf8 msg)
   in putMessage messageTypeFailureReply encode

putMessage :: MessageType -> (a -> Put) -> a -> Put
putMessage messageType encodePayload payload =
  let payloadBytes = runPut $ encodePayload payload
      payloadSize = LBS.length payloadBytes
   in putWord32be (messageTypeToWord messageType)
        <> putWord32be (fromIntegral payloadSize)
        <> putLazyByteString payloadBytes

-- | Clients send a 4 byte integer that specifies the length of the message
-- payload. We don't want them to be able to say that they have a 4GB message
-- and then consume a lot of server resources loading it. Instead, we reject
-- message sizes above a certain threshold. If we start seeing this error come
-- up for reasonable requests, then we might need to bump this threshold.
maxPermittedMessageSize :: Word32
maxPermittedMessageSize = 50_000_000

unexpectedMessageType :: (MonadIO m, MonadLogger m) => MessageType -> m a
unexpectedMessageType receivedMessageType =
  respondErrorM $ ProtocolError $ "Failed to decode message of type " <> tShow (messageTypeToWord receivedMessageType)

-- TODO I should probably be distinguishing between client decoding failures and nimbus decoding failures
receiveMessageForHeader :: (MonadIO m, MonadLogger m) => MessageType -> Get a -> MessageHeader -> LBS.ByteString -> m (LBS.ByteString, a)
receiveMessageForHeader expectedMessageType rawDecoder header inputStream =
  let receivedMessageType = messageType header
      msgLength = messageLength header
      decoder = isolate (fromIntegral msgLength) rawDecoder
   in do
        if receivedMessageType == expectedMessageType
          then pure ()
          else unexpectedMessageType receivedMessageType
        if msgLength <= maxPermittedMessageSize
          then pure ()
          else respondErrorM $ ProtocolError ("The message that the client sent to the server was larger than is supported. The message was " <> tShow msgLength <> " bytes.")
        runGetOrErr decoder inputStream

receiveMessage :: (MonadIO m, MonadLogger m) => MessageType -> Get a -> LBS.ByteString -> m (LBS.ByteString, a)
receiveMessage expectedMessageType decoder inputStream = do
  (inputStream, header) <- runGetOrErr getMessageHeader inputStream
  receiveMessageForHeader expectedMessageType decoder header inputStream
