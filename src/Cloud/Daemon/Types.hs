module Cloud.Daemon.Types (DaemonId(..), DaemonName(..), DaemonDetails(..), DaemonAssignment(..), DaemonAssignmentSummary (..)) where

import Data.UUID (UUID)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Cloud.Prelude
import Servant
import Data.Binary (Binary)
import Data.Aeson (ToJSON, FromJSON, Options (fieldLabelModifier), genericToJSON, defaultOptions, object, (.=))
import Cloud.User.Types (User)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Data.Time (UTCTime)
import Amazonka.Data.JSON (ToJSON(..))
import Share.OAuth.Types (UserId)
import Cloud.Consul.API (ConsulIndex)
import Cloud.Web.Types (EnvironmentId)
import Data.Char (toLower)

newtype DaemonId = DaemonId UUID
  deriving stock (Eq, Generic)
  deriving newtype (FromHttpApiData, ToHttpApiData, Binary, Show, ToJSON)

instance MimeRender PlainText DaemonId where
  mimeRender :: Proxy PlainText -> DaemonId -> BL.ByteString
  mimeRender _ (DaemonId uuid) = BL.fromStrict . encodeUtf8 . Text.pack . show $ uuid

newtype DaemonName = DaemonName Text
  deriving stock (Eq, Generic)
  deriving newtype (Show, ToJSON, FromJSON, FromHttpApiData)

data DaemonDetails = DaemonDetails
    { daemonId :: DaemonId,
      daemonName :: DaemonName,
      daemonUser :: User,
      daemonAssignment :: Maybe DaemonAssignment,
      daemonTags :: [Text]
    }
    deriving (Show, Eq, Generic)

instance ToJSON DaemonDetails where
  toJSON = genericToJSON defaultOptions {fieldLabelModifier = lowerFirstCharOfString . drop 6 }

data DaemonAssignment = DaemonAssignment
  { daemonAssignmentHash :: DeploymentHash,
    daemonAssignmentDeploymentTime :: UTCTime,
    daemonAssignmentAssignmentTime :: UTCTime,
    daemonAssignmentUnassignmentTime :: Maybe UTCTime,
    daemonAssignmentEnvironment :: EnvironmentId
  }
  deriving (Show, Eq, Generic)

instance ToJSON DaemonAssignment where
  toJSON = genericToJSON defaultOptions {fieldLabelModifier = lowerFirstCharOfString . drop 16 }

lowerFirstCharOfString :: String -> String
lowerFirstCharOfString [] = []
lowerFirstCharOfString (x : xs) = toLower x : xs

data DaemonAssignmentSummary = DaemonAssignmentSummary
  { daemonId :: DaemonId,
    ownerId :: UserId,
    deploymentHash :: DeploymentHash,
    modifyIndex :: ConsulIndex
  }
  deriving (Eq)

instance Show DaemonAssignmentSummary where
  show (DaemonAssignmentSummary { daemonId, ownerId, deploymentHash, modifyIndex }) =
    "DaemonAssignmentSummary { daemonId = " ++ show daemonId ++
    ", ownerId = " ++ show ownerId ++
    ", deploymentHash = " ++ show deploymentHash ++
    ", modifyIndex = " ++ show modifyIndex ++ " }"

instance ToJSON DaemonAssignmentSummary where
  toJSON (DaemonAssignmentSummary { daemonId, ownerId, deploymentHash, modifyIndex }) = object [
      "id" .= daemonId,
      "owner" .= ownerId,
      "hash" .= deploymentHash,
      "modifyIndex" .= modifyIndex
    ]
