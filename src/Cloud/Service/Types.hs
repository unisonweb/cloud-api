{-# LANGUAGE DeriveAnyClass #-}

module Cloud.Service.Types
  ( ServiceId (..),
    ServiceAssignment (..),
    ServiceDetail (..),
    ServiceName,
    ServiceURI (..),
    hashFromDigest,
  )
where

import Cloud.Deployment.DeploymentHash (DeploymentHash (..))
import Cloud.Prelude
import Cloud.User.Types (User)
import Crypto.Hash (Digest, SHA256)
import Data.Aeson
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (Base32), convertToBase)
import Data.ByteString.Char8 qualified as BS
import Data.Char (toLower)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Word (Word8)
import Hasql.Interpolate qualified as Hasql
import Servant
import Share.OAuth.Types (UserId)
import Cloud.Web.Types (ServiceId (..), ServiceName, DeploymentDetails)

data Service = Service
  { serviceUserId :: UserId,
    serviceId :: ServiceId,
    serviceDeploymentHash :: Maybe DeploymentHash,
    serviceDeployedAt :: UTCTime,
    serviceUndeployedAt :: Maybe UTCTime
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Hasql.DecodeRow)

newtype ServiceURI = ServiceURI URI

instance ToJSON ServiceURI where
  toJSON (ServiceURI uri) = object ["uri" .= show uri]

hashFromDigest :: Digest SHA256 -> DeploymentHash
hashFromDigest digest = DeploymentHash $ Text.pack $ stripAndDip $ BS.unpack $ convertToBase Base32 (convert digest :: BS.ByteString)
  where
    stripAndDip :: String -> String
    stripAndDip input = toLower <$> reverse (dropWhile (== '=') (reverse input))

newtype NativeServiceVersion = NativeServiceVersion Word8
  deriving stock (Eq, Generic)
  deriving newtype (Show, ToJSON)

data ServiceDetail = ServiceDetail
  { serviceId :: ServiceId,
    serviceName :: ServiceName,
    serviceUser :: Maybe User,
    serviceDeployment :: Maybe DeploymentDetails,
    serviceTags :: [Text]
  }
  deriving (Eq, Generic)

instance ToJSON ServiceDetail where
  toJSON ServiceDetail {..} =
    case serviceDeployment of
      Nothing -> object ["id" .= serviceId, "name" .= serviceName, "owner" .= serviceUser, "tags" .= serviceTags]
      Just serviceDeployment ->
        object
          [ "id" .= serviceId,
            "name" .= serviceName,
            "owner" .= serviceUser,
            "latestServiceDeploy" .= serviceDeployment,
            "tags" .= serviceTags
          ]

data ServiceAssignment = ServiceAssignment
  { serviceAssignmentHash :: DeploymentHash,
    serviceDeployedBy :: User,
    serviceDeployedAt :: UTCTime,
    serviceUndeployedAt :: Maybe UTCTime,
    serviceExposedTime :: Maybe UTCTime,
    serviceUnexposedTime :: Maybe UTCTime,
    serviceAssignmentTags :: [Text],
    serviceAssignmentUser :: User,
    serviceAssignmentTime :: UTCTime,
    serviceUnassignementTime :: Maybe UTCTime
  }
  deriving (Show, Eq, Generic)

instance ToJSON ServiceAssignment where
  toJSON ServiceAssignment {..} =
    object
      [ "hash" .= serviceAssignmentHash,
        "deployedBy" .= serviceDeployedBy,
        "deployedAt" .= serviceDeployedAt,
        "undeployedAt" .= serviceUndeployedAt,
        "exposedAt" .= serviceExposedTime,
        "unexposedAt" .= serviceUnexposedTime,
        "tags" .= serviceAssignmentTags,
        "assignedBy" .= serviceAssignmentUser,
        "assignedAt" .= serviceAssignmentTime,
        "unassignedAt" .= serviceUnassignementTime
      ]
