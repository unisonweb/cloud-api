module Cloud.Daemon.Impl where

import Amazonka (toBody)
import Amazonka qualified as S3
import Amazonka.Prelude hiding (hash)
import Amazonka.S3 qualified as S3
import Cloud.Consul.Daemon
import Cloud.Daemon.API
import Cloud.Daemon.Types (DaemonAssignment, DaemonDetails, DaemonId, DaemonName)
import Cloud.Deployment.DeploymentHash
import Cloud.Errors (respondError)
import Cloud.Postgres.Ops qualified as PGO
import Cloud.Service.Types (hashFromDigest)
import Cloud.Utils.Logging (logErrorText)
import Cloud.Web.App (WebApp)
import Cloud.Web.Errors (CloudWebError (..))
import Crypto.Hash (hash)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Servant
import Share.OAuth.Types (UserId (..))
import UnliftIO (catchAny)
import Cloud.Byoc.Impl (clusterByHost)
import Cloud.Web.Types (EnvironmentId (..), CloudApiHost)
import Cloud.Web.Environment (Env(..))
import Control.Monad.RWS (ask)

server :: ServerT DaemonAPI WebApp
server = daemonHashesImpl :<|> daemonsImpl
  where
    daemonHashesImpl = createDaemon :<|> deleteDaemon
    daemonsImpl =
      listDaemons
        :<|> getDaemon
        :<|> createDaemonName
        :<|> deleteDaemonName
        :<|> assignDaemon
        :<|> unassignDaemon
        :<|> getDaemonHistory
        :<|> getDaemonTags
        :<|> getAllDaemonTags
        :<|> getDaemonsByTag
        :<|> getDaemonsWithoutTag
        :<|> setDaemonTag
        :<|> deleteDaemonTag

getDaemon :: UserId -> CloudApiHost -> DaemonId -> WebApp DaemonDetails
getDaemon uid host did = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getDaemon clusterId uid did

listDaemons :: UserId -> CloudApiHost -> WebApp [DaemonDetails]
listDaemons uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listDaemons clusterId uid

getDaemonHistory :: UserId -> CloudApiHost -> DaemonId -> WebApp [DaemonAssignment]
getDaemonHistory uid host did = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getDaemonHistory clusterId uid did

getDaemonTags :: UserId -> CloudApiHost -> DaemonId -> WebApp [Text]
getDaemonTags uid host did = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getDaemonTags clusterId uid did

getAllDaemonTags :: UserId -> CloudApiHost -> WebApp [Text]
getAllDaemonTags uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getAllDaemonTags clusterId uid

getDaemonsByTag :: UserId -> CloudApiHost -> Text -> WebApp [DaemonDetails]
getDaemonsByTag uid host tag = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getDaemonsByTag clusterId uid tag

daemonKey :: DeploymentHash -> S3.ObjectKey
daemonKey (DeploymentHash hash) =
  S3.ObjectKey $ Text.pack "daemon/" <> hash

getDaemonsWithoutTag :: UserId -> CloudApiHost -> WebApp [DaemonDetails]
getDaemonsWithoutTag uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getDaemonsWithoutTag clusterId uid


-- Deprecated: this is just to support olde clients
createDaemon :: UserId -> CloudApiHost -> EnvironmentId -> BS.ByteString -> WebApp DeploymentHash
createDaemon uid host envId payload = do
  Env {cloudServicesBucket, s3Env } <- ask
  clusterId <- PGO.clusterIdByHost host
  when (BS.length payload > 10_000_000) $ respondError ServiceTooLarge
  PGO.createDaemon clusterId uid uid envId objectHash
  sendToS3 s3Env cloudServicesBucket objectHash
  pure objectHash
  where
    binaryBlob = createBinaryBlob envId uid payload
    objectHash = hashFromDigest (hash binaryBlob)

    sendToS3 env bucket objectHash = do

      let objectKey = daemonKey objectHash
      let putReq = S3.newPutObject bucket objectKey (toBody binaryBlob)

      _ <- liftIO $ putStrLn $ "Uploading to S3: " <> show putReq

      liftIO $ S3.runResourceT $ S3.send env putReq
    createBinaryBlob :: EnvironmentId -> UserId -> BS.ByteString -> BS.ByteString
    createBinaryBlob (EnvironmentId envId) (UserId uid) payload =
      BS.concat
        [ BS.singleton $ toEnum 0,
          BSL.toStrict $ UUID.toByteString envId,
          BSL.toStrict $ UUID.toByteString uid,
          payload
        ]

-- Deprecated: this is just to support olde clients
-- TODO this should delete from S3
-- TODO we should handle the case where the daemon hash is assigned to a daemon name
deleteDaemon :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NoContent
deleteDaemon userId host hash = do
    Env {cloudServicesBucket, s3Env} <- ask
    cluster <- clusterByHost host
    let objectKey = daemonKey hash
    let deleteReq = S3.newDeleteObject cloudServicesBucket objectKey
        logException :: SomeException -> WebApp ()
        logException e = logErrorText $ Text.pack $  "Error undeploying daemon: " <>  show e

        safelyDeleteS3 :: WebApp () -> WebApp ()
        safelyDeleteS3 action = catchAny action logException
    safelyDeleteS3 $ void $ liftIO $ S3.runResourceT $ S3.send s3Env deleteReq

    ids <- PGO.getDaemonAssignmentsByHash cluster userId hash
    PGO.deleteDaemon cluster userId hash
    forM_ ids $ \did -> do
        consulUnassignDaemonId cluster did
    pure NoContent

assignDaemon :: UserId -> CloudApiHost -> DaemonId -> DeploymentHash -> WebApp NoContent
assignDaemon userId host daemonId hash = do
    cluster <- clusterByHost host
    PGO.assignDaemon cluster userId daemonId hash
    consulSetDaemonId cluster userId daemonId hash
    pure NoContent

unassignDaemon :: UserId -> CloudApiHost ->  DaemonId -> WebApp NoContent
unassignDaemon userId host daemonId = do
    cluster <- clusterByHost host
    PGO.unassignDaemon cluster userId daemonId
    consulUnassignDaemonId cluster daemonId
    pure NoContent

setDaemonTag :: UserId -> CloudApiHost -> DaemonId -> Text -> WebApp NoContent
setDaemonTag uid host did tag = do
  clusterId <- PGO.clusterIdByHost host
  PGO.setDaemonTag clusterId uid did tag
  pure NoContent

deleteDaemonTag :: UserId -> CloudApiHost -> DaemonId -> Text -> WebApp NoContent
deleteDaemonTag uid host did tag = do
  clusterId <- PGO.clusterIdByHost host
  PGO.deleteDaemonTag clusterId uid did tag
  pure NoContent

createDaemonName :: UserId -> CloudApiHost -> Maybe UserId -> DaemonName -> WebApp DaemonId
createDaemonName uid host mOwnerId dn = do
  let ownerId = fromMaybe uid mOwnerId
  clusterId <- PGO.clusterIdByHost host
  PGO.createDaemonName clusterId uid ownerId dn

deleteDaemonName :: UserId -> CloudApiHost -> DaemonId -> WebApp NoContent
deleteDaemonName  uid host did = do
  cluster <- clusterByHost host
  PGO.deleteDaemonName cluster uid did
  consulDeleteDaemon cluster did
  pure NoContent
