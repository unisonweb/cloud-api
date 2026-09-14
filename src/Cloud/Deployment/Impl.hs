module Cloud.Deployment.Impl
  ( deploymentsV1Endpoint,
    deploymentsV2Endpoint,
  )
where

import Amazonka (ToBody (toBody))
import Amazonka qualified as S3
import Amazonka.S3 qualified as S3
import Amazonka.S3.Lens qualified as S3
import Cloud.Byoc.Env
  ( ClusterConfig(..),
    defaultClusterId
  )
import Cloud.Byoc.Impl (clusterDeploymentURI, clusterByHost)
import Cloud.Deployment.API
import Cloud.Deployment.DeploymentHash ( DeploymentHash(..) )
import Cloud.Errors
import Cloud.Postgres.Ops qualified as PGO
import Cloud.Prelude
import Cloud.Service.Types
import Cloud.User.Types (User (..))
import Cloud.Utils.Logging (logErrorText)
import Cloud.Web.App (WebApp)
import Cloud.Web.Environment (Env (..))
import Cloud.Web.Errors (CloudWebError (..))
import Cloud.Web.Types (DeploymentURI, EnvironmentId (..), HttpServiceVersion (..), CloudApiHost, DeploymentDetails)
import Conduit
import Control.Exception.Base (SomeException)
import Control.Lens ((^.))
import Control.Monad.Reader (ask)
import Crypto.Hash (hash)
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Servant
import Share.OAuth.Types
import Share.Utils.Show (tShow)
import UnliftIO (catchAny)

deploymentsV1Endpoint :: ServerT DeploymentV1API WebApp
deploymentsV1Endpoint =
  deploymentsListUnassignedEndpoint
    :<|> deploymentUntaggedEndpoint
    :<|> deploymentAllTagsEndpoint
    :<|> deployEndpoint
    :<|> deploymentGetEndpoint
    :<|> deploymentsListEndpoint
    :<|> undeployEndpoint
    :<|> exposeEndpointV1
    :<|> unexposeEndpoint
    :<|> deploymentTagsEndpoint
    :<|> deploymentByTagEndpoint
    :<|> deploymentSetTagEndpoint
    :<|> deploymentDeleteTagEndpoint

deploymentsV2Endpoint :: ServerT DeploymentV2API WebApp
deploymentsV2Endpoint =
  deploymentsListUnassignedEndpoint
    :<|> deploymentUntaggedEndpoint
    :<|> deploymentAllTagsEndpoint
    :<|> deployEndpoint
    :<|> deploymentGetEndpoint
    :<|> deploymentsListEndpoint
    :<|> undeployEndpoint
    :<|> exposeEndpointV2
    :<|> unexposeEndpoint
    :<|> deploymentTagsEndpoint
    :<|> deploymentByTagEndpoint
    :<|> deploymentSetTagEndpoint
    :<|> deploymentDeleteTagEndpoint

nativeServiceKey :: DeploymentHash -> S3.ObjectKey
nativeServiceKey (DeploymentHash hash) =
  S3.ObjectKey $ Text.pack "native/" <> hash

httpServiceKey :: DeploymentHash -> S3.ObjectKey
httpServiceKey (DeploymentHash hash) =
  S3.ObjectKey $ Text.pack "http/" <> hash

deploymentGetEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp DeploymentDetails
deploymentGetEndpoint uid host hash = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getDeployment clusterId uid hash

deploymentsListEndpoint :: UserId -> CloudApiHost -> WebApp [DeploymentDetails]
deploymentsListEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listDeployments clusterId uid

deploymentsListUnassignedEndpoint :: UserId -> CloudApiHost -> WebApp [DeploymentDetails]
deploymentsListUnassignedEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listUnassignedDeployments clusterId uid

-- Deprecated: this is just to support old clients
undeployEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NoContent
undeployEndpoint uid host deploymentHash = do
  cluster <- clusterByHost host
  Env {cloudServicesBucket, s3Env} <- ask
  let httpKey = httpServiceKey deploymentHash
      httpDeleteReq = S3.newDeleteObject cloudServicesBucket httpKey

      deleteS3Web :: WebApp ()
      deleteS3Web = void $ liftIO $ S3.runResourceT $ S3.send s3Env httpDeleteReq

      serviceKey = nativeServiceKey deploymentHash
      serviceDeleteReq = S3.newDeleteObject cloudServicesBucket serviceKey

      deleteS3Service = void $ liftIO $ S3.runResourceT $ S3.send s3Env serviceDeleteReq

      logException :: SomeException -> WebApp ()
      logException e = logErrorText $ "Error undeploying service: " <> tShow e

      safelyDeleteS3 :: WebApp () -> WebApp ()
      safelyDeleteS3 action = catchAny action logException

  PGO.unexposeDeployment cluster uid deploymentHash
  PGO.deleteDeployment cluster uid deploymentHash

  safelyDeleteS3 deleteS3Web
  safelyDeleteS3 deleteS3Service

  pure NoContent

exposeEndpoint_ :: ClusterConfig -> UserId -> DeploymentHash -> Maybe HttpServiceVersion -> WebApp User
exposeEndpoint_ _ _ _ Nothing = respondError $ MissingParameter "httpServicesVersion"
exposeEndpoint_ cluster uid deploymentHash (Just v@(HttpServiceVersion version)) | version <= 1 = do
  Env {cloudServicesBucket, s3Env} <- ask

  -- Persist the binary blob in S3
  user <- PGO.exposeDeployment cluster.clusterId uid deploymentHash v
  liftIO $ S3.runResourceT $ awsStuff cloudServicesBucket s3Env nativeServiceKey httpServiceKey
  pure user
  where
    awsStuff cloudServicesBucket s3Env nsk hsk = do
      let nativeKey = nsk deploymentHash
      let httpKey = hsk deploymentHash
      rs <- S3.send s3Env $ S3.newGetObject cloudServicesBucket nativeKey
      combinedBody <- (rs ^. S3.getObjectResponse_body) `S3.sinkBody` sinkLazy
      let finalBody = BS.fromStrict metadataBytes <> combinedBody
      let putReq = S3.newPutObject cloudServicesBucket httpKey (toBody finalBody)
      S3.send s3Env putReq
    metadataBytes =
      BS.concat
        [ BS.singleton $ toEnum 0,
          BS.singleton $ toEnum $ fromIntegral version
        ]
exposeEndpoint_ _ _ _ (Just (HttpServiceVersion v)) = respondError (InvalidServicesVersion v)

exposeEndpointV1 :: UserId -> CloudApiHost -> DeploymentHash -> Maybe HttpServiceVersion -> WebApp NoContent
exposeEndpointV1 session host hash version = do
  cluster <- PGO.clusterConfigByHostname host
  exposeEndpoint_ cluster session hash version $> NoContent

exposeEndpointV2 :: UserId -> CloudApiHost -> DeploymentHash -> Maybe HttpServiceVersion -> WebApp DeploymentURI
exposeEndpointV2 session host hash version = do
  cluster <- PGO.clusterConfigByHostname host
  User _ _ _ _ userHandle _ <- exposeEndpoint_ cluster session hash version
  clusterDeploymentURI userHandle cluster hash

-- Deprecated: this is just to support old clients
unexposeEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp NoContent
unexposeEndpoint uid host deploymentHash = do
  Env {cloudServicesBucket, s3Env } <- ask
  cluster <- clusterByHost host

  PGO.deleteDeployment cluster uid deploymentHash
  PGO.unexposeDeployment cluster uid deploymentHash

  let objectKey = httpServiceKey deploymentHash
  let deleteReq = S3.newDeleteObject cloudServicesBucket objectKey
      logException :: SomeException -> WebApp ()
      logException e = logErrorText $ "Error undeploying service: " <> tShow e

      safelyDeleteS3 :: WebApp () -> WebApp ()
      safelyDeleteS3 action = catchAny action logException

  safelyDeleteS3 $ void $ liftIO $ S3.runResourceT $ S3.send s3Env deleteReq

  pure NoContent

-- Deprecated: this is just to support old clients
-- returns either the DeploymentHash or the a json document containing a DeploymentURI
-- depending on whether or not there is an Accept Header present specifying application/json
deployEndpoint :: UserId -> EnvironmentId -> BS.ByteString -> WebApp DeploymentHash
deployEndpoint uid envId payload = do
  Env {cloudServicesBucket, s3Env} <- ask
  when (BS.length payload > 52_428_800) $ respondError ServiceTooLarge
  PGO.createDeployment defaultClusterId uid envId objectHash
  sendToS3 s3Env cloudServicesBucket objectHash

  pure objectHash
  where
    binaryBlob = createBinaryBlob envId uid payload
    objectHash = hashFromDigest (hash binaryBlob)

    sendToS3 s3 bucket objectHash = do
      let objectKey = nativeServiceKey objectHash
      let putReq = S3.newPutObject bucket objectKey (toBody binaryBlob)

      _ <- liftIO $ putStrLn $ "Uploading to S3: " <> show putReq

      liftIO $ S3.runResourceT $ S3.send s3 putReq

    createBinaryBlob :: EnvironmentId -> UserId -> BS.ByteString -> BS.ByteString
    createBinaryBlob (EnvironmentId envId) (UserId uid) payload =
      BS.concat
        [ BS.singleton $ toEnum 0,
          BSL.toStrict $ UUID.toByteString envId,
          BSL.toStrict $ UUID.toByteString uid,
          payload
        ]

-- eventPrefix :: Text
-- eventPrefix = case Cloud.Deployment.deployment of
--   Cloud.Deployment.Staging -> "staging-"
--   _ -> ""

deploymentTagsEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> WebApp [Text]
deploymentTagsEndpoint uid host deploymentHash = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listDeploymentTags clusterId uid deploymentHash

deploymentAllTagsEndpoint :: UserId -> CloudApiHost -> WebApp [Text]
deploymentAllTagsEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listAllDeploymentTags clusterId uid

deploymentByTagEndpoint :: UserId -> CloudApiHost -> Text -> WebApp [DeploymentDetails]
deploymentByTagEndpoint uid host tag = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listDeploymentsByTag clusterId uid tag

deploymentSetTagEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> Text -> WebApp NoContent
deploymentSetTagEndpoint uid host deploymentHash tags = do
  clusterId <- PGO.clusterIdByHost host
  PGO.setDeploymentTag clusterId uid deploymentHash tags
  pure NoContent

deploymentDeleteTagEndpoint :: UserId -> CloudApiHost -> DeploymentHash -> Text -> WebApp NoContent
deploymentDeleteTagEndpoint uid host deploymentHash tags = do
  clusterId <- PGO.clusterIdByHost host
  PGO.unsetDeploymentTag clusterId uid deploymentHash tags
  pure NoContent

deploymentUntaggedEndpoint :: UserId -> CloudApiHost -> WebApp [DeploymentDetails]
deploymentUntaggedEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listUntaggedDeploymnets clusterId uid
