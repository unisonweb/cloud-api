{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

module Cloud.Client where

import Cloud.App (CloudApp)

import Cloud.Byoc.Env ( defaultClusterId )
import Cloud.Client.Errors
import Cloud.Client.Messages
import Cloud.Client.Nimbus (withNimbusConnection)
import Cloud.Client.Types
  ( NimbusConnection (nimbusSocket),
  )
import Cloud.Env ( Env(..), envClientPort )
import Cloud.Postgres qualified as PG
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude (MonadIO (..), MonadUnliftIO)
import Cloud.Utils.Logging
    ( Severity(Error),
      MonadLogger(..),
      showLog,
      withSeverity,
      logDebugText,
      logInfoText )
import Control.Monad.Reader (MonadReader (ask))
import Data.Binary.Get
import Data.Binary.Put
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Share.JWT
import Share.OAuth.ServiceProvider
import Share.OAuth.Session (Session (..))
import Share.OAuth.Types
import Share.Utils.Show (tShow)
import Network.Simple.TCP
import Network.Socket.ByteString.Lazy qualified as Net
import UnliftIO
  ( MonadUnliftIO (withRunInIO),
    bracket,
    catchAny,
    fromExceptionUnwrap,
  )
import UnliftIO.Concurrent (ThreadId)
import Control.Monad (when)
import Cloud.Postgres.App (postgresM)
import Cloud.User.Env (AuthEnv(..))

data ClientConnection = ClientConnection
  { clientSocket :: Socket,
    clientAddress :: SockAddr
  }
  deriving (Show)

handleIncomingConnection :: ClientConnection -> CloudApp ()
handleIncomingConnection clientConnection =
  catchAny handleConnection handleError
  where
    handleConnection :: CloudApp ()
    handleConnection = do
      clientInputStream <- liftIO $ Net.getContents (clientSocket clientConnection)
      case runGetOrFail getMessageHeader clientInputStream of
        Left (_, 0, _) -> pure () -- health check
        -- TODO improve error message
        Left (_, received, _) -> respondErrorM $ expectedMoreBytes received
        Right (clientInputStream, _, header) -> handleClientConnection clientConnection clientInputStream header
    handleError e = do
      case fromExceptionUnwrap e of
        (Just (e :: ClientError)) ->
          -- these have generally already been logged if necessary
          sendClientError $ clientErrorToText e
        Nothing -> do
          -- unknown error
          -- TODO use request IDs
          logMsg . withSeverity Error . showLog $ e
          sendClientError "Internal error"
    sendClientError msg = sendToClient clientConnection putFailureReply (FailureReply msg)

handleClientConnection :: ClientConnection -> LBS.ByteString -> MessageHeader -> CloudApp ()
handleClientConnection clientConnection clientInputStream initialHeader = do
  Env { envNimbusConfig } <- ask
  logDebugText $ "incoming connection from " <> tShow (clientAddress clientConnection)
  let msgType = messageType initialHeader
  (withEnv, wantsJobId) <- case msgType of
    t | t == messageTypeClientForkWithEnv -> pure (True, False)
    t | t == messageTypeClientForkWantsJobId -> pure (True, True)
    t | t == messageTypeClientForkWithoutEnv -> pure (False, False)
    _ -> unexpectedMessageType messageTypeClientForkWithEnv
  (clientInputStream, clientFork) <- receiveMessageForHeader msgType (getClientFork withEnv) initialHeader clientInputStream
  Env { authEnv = AuthEnv { envSpConfig }  } <- ask
  token <- case textToSignedJWT (accessTokenBase64 clientFork) of
    Left e -> do
      respondErrorM (AuthFailure $ tShow e)
    Right jwt -> pure $ AccessToken $ JWTParam jwt
  sesh <- verifySessionToken envSpConfig token
  userId <- case sesh of
    Left e -> do
      respondErrorM (AuthFailure $ tShow e)
    Right session -> pure $ sessionUserId session

  envId <- case clientForkEnvironment clientFork of
    Nothing -> pure Nothing
    Just envId -> do
      postgresM $ PG.runTransaction $ Q.verifyEnvironmentAccess defaultClusterId userId envId
      pure $ Just envId
  jobId <- postgresM $ PG.runTransaction $ Q.recordJobRun defaultClusterId userId

  when wantsJobId $ sendToClient clientConnection putJobStarted (JobStarted  jobId)
  let forkRequest = ForkRequest (Just jobId) userId envId (clientThunk clientFork)
  withNimbusConnection envNimbusConfig (clientNimbusExchange clientConnection forkRequest clientInputStream)

-- TODO more type safety around client vs Nimbus byte strings
clientNimbusExchange :: (MonadIO m, MonadLogger m) => ClientConnection -> ForkRequest -> LBS.ByteString -> NimbusConnection -> m ()
clientNimbusExchange clientConnection initialForkRequest clientInputStream nimbus = do
  sendNimbus putForkRequest initialForkRequest
  nimbusResponseStream <- liftIO $ Net.getContents (nimbusSocket nimbus)
  loopUntilResult clientInputStream nimbusResponseStream
  where
    sendNimbus = sendToNimbus nimbus
    sendClient = sendToClient clientConnection
    loopUntilResult clientInputStream nimbusResponseStream = do
      (nimbusResponseStream, nimbusResponse) <- runGetOrErr getNimbusResponse nimbusResponseStream
      case nimbusResponse of
        NimbusTaskResult bytes -> do
          sendClient putTaskResult $ TaskResult bytes
        NimbusTermRequest bytes -> do
          sendClient putTermRequest (TermRequest bytes)
          (clientInputStream, clientTerms) <- receiveMessage messageTypeClientTerms getClientTerms clientInputStream
          sendNimbus putTermReply $ TermReply (clientTermsBytes clientTerms)
          loopUntilResult clientInputStream nimbusResponseStream

sendToNimbus :: (MonadIO m) => NimbusConnection -> (a -> Put) -> a -> m ()
sendToNimbus nimbus encode message =
  liftIO $ Net.sendAll (nimbusSocket nimbus) $ runPut (encode message)

sendToClient :: (MonadIO m) => ClientConnection -> (a -> Put) -> a -> m ()
sendToClient client encode message =
  liftIO $ Net.sendAll (clientSocket client) $ runPut (encode message)

listenThread :: CloudApp ()
listenThread = do
  Env { envServerHostname, envClientPort } <- ask
  logInfoText ("starting TCP server on " <> Text.pack envServerHostname <> ":" <> Text.pack envClientPort)
  withSocket envClientPort $ \sock -> do
    listenSock sock 2048
    acceptThread sock \(sock, addr) -> handleIncomingConnection (ClientConnection sock addr)
  where
    acceptThread sock client = acceptForkU sock client >> acceptThread sock client

withSocket :: MonadUnliftIO m => ServiceName -> (Socket -> m a) -> m a
withSocket port =
  UnliftIO.bracket
    (fst <$> bindSock HostAny port)
    closeSock

-- | Like `acceptFork` but generalized from IO to any m with a MonadUnliftIO instance
acceptForkU :: MonadUnliftIO m => Socket -> ((Socket, SockAddr) -> m ()) -> m ThreadId
acceptForkU socket f =
  withRunInIO $ \runInIO ->
    acceptFork socket (runInIO . f)
