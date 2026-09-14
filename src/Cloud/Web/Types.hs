{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Cloud.Web.Types
  ( CloudTier (..),
    CloudApiHost (..),
    DeploymentDetails (..),
    DeploymentURI (..),
    EnvironmentId (..),
    environmentUUID,
    serviceNameFromText,
    serviceNameFromTextMaybe,
    serviceNameToText,
    HttpServiceVersion (..),
    IncompleteSubscription (..),
    JsonMergePatch,
    NimbusRedirect (..),
    ServiceId (..),
    ServiceName,
    ServiceURI (..),
    StoragePoolId (..),
    StoragePoolName (..),
    StripeSignature (..),
    ByocUserJWT (..),
    WithRawBody (..),
  )
where

import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Prelude
import Cloud.User.Types (CloudTier (..), User)
import Data.Aeson
import Data.Binary (Binary, Word8)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as Text
import Data.Text.Encoding
import Data.Time
import Data.UUID (UUID)
import GHC.Int (Int32)
import Hasql.Interpolate (DecodeValue, EncodeValue)
import Hasql.Decoders qualified as HasqlD
import Network.HTTP.Media ((//))
import Servant
import Stripe.Concepts (SubscriptionId (SubscriptionId))
import Stripe.Signature (Sig, parseSig)
import qualified Hasql.Interpolate as PG
import Share.JWT.Types (JWTParam)
import Cloud.Utils (isValidDNSName)
import Hasql.Decoders (refine)

newtype EnvironmentId = EnvironmentId UUID
  deriving stock (Eq, Generic)
  deriving newtype (Binary, Show, ToJSON, FromJSON, PG.EncodeValue, PG.DecodeValue)

instance FromHttpApiData EnvironmentId where
  parseUrlPiece :: Text -> Either Text EnvironmentId
  parseUrlPiece t = case readMaybe $ Text.unpack t of
    Nothing -> Left "Invalid UUID format"
    Just uuid -> Right $ EnvironmentId uuid

environmentUUID :: EnvironmentId -> UUID
environmentUUID (EnvironmentId uuid) = uuid

instance MimeRender PlainText EnvironmentId where
  mimeRender :: Proxy PlainText -> EnvironmentId -> BL.ByteString
  mimeRender _ (EnvironmentId uuid) = BL.fromStrict . encodeUtf8 . Text.pack . show $ uuid

newtype ByocUserJWT = ByocUserJWT JWTParam
  deriving (Show, FromHttpApiData, ToHttpApiData, ToJSON, FromJSON) via JWTParam

newtype ServiceId = ServiceId UUID
  deriving stock (Show, Eq, Generic)
  deriving newtype (FromHttpApiData, ToHttpApiData, Binary, ToJSON, FromJSON, EncodeValue, DecodeValue)

instance MimeRender PlainText ServiceId where
  mimeRender :: Proxy PlainText -> ServiceId -> BL.ByteString
  mimeRender _ (ServiceId uuid) = BL.fromStrict . encodeUtf8 . Text.pack . show $ uuid

newtype HttpServiceVersion = HttpServiceVersion Int32
  deriving stock (Eq, Generic)
  deriving newtype (Show, ToJSON, FromJSON, EncodeValue)


-- newtype DeploymentHash = DeploymentHash Text
--   deriving (Eq, Generic)
--   deriving newtype (ToJSON, FromJSON, EncodeValue, DecodeValue, FromHttpApiData, MimeRender PlainText)

-- instance Show DeploymentHash where
--   show :: DeploymentHash -> String
--   show (DeploymentHash hash) = Text.unpack hash

-- instance Read DeploymentHash where
--   readsPrec :: Int -> String -> [(DeploymentHash, String)]
--   readsPrec _ input = [(DeploymentHash $ Text.pack input, "")]

newtype DeploymentURI = DeploymentURI URI

instance ToJSON DeploymentURI where
  toJSON (DeploymentURI uri) = object ["uri" .= show uri]

newtype ServiceURI = ServiceURI URI

instance ToJSON ServiceURI where
  toJSON (ServiceURI uri) = object ["uri" .= show uri]

-- hashFromDigest :: Digest SHA256 -> DeploymentHash
-- hashFromDigest digest = DeploymentHash $ Text.pack $ stripAndDip $ BS8.unpack $ convertToBase Base32 (convert digest :: BS.ByteString)
--   where
--     stripAndDip input = toLower <$> reverse (dropWhile (== '=') (reverse input))

newtype NativeServiceVersion = NativeServiceVersion Word8
  deriving stock (Eq, Generic)
  deriving newtype (Show, ToJSON)

instance FromHttpApiData HttpServiceVersion where
  parseUrlPiece :: Text -> Either Text HttpServiceVersion
  parseUrlPiece t = case readMaybe (Text.unpack t) of
    Nothing -> Left "Failed to parse HTTP service version."
    Just version -> Right $ HttpServiceVersion version

data DeploymentDetails = DeploymentDetails
  { deploymentDetailsHash :: DeploymentHash,
    deploymentDetailsDeployedAt :: UTCTime,
    deploymentDetailsUndeployedAt :: Maybe UTCTime,
    deploymentDetailsExposureTime :: Maybe UTCTime,
    deploymentDetailsUnexposureTime :: Maybe UTCTime,
    deploymentDetailsUser :: User,
    deploymentDetailsTags :: [Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON DeploymentDetails where
  toJSON DeploymentDetails {..} =
    object
      [ "hash" .= deploymentDetailsHash,
        "deployedAt" .= deploymentDetailsDeployedAt,
        "undeployedAt" .= deploymentDetailsUndeployedAt,
        "exposedAt" .= deploymentDetailsExposureTime,
        "unexposedAt" .= deploymentDetailsUnexposureTime,
        "deployedBy" .= deploymentDetailsUser,
        "tags" .= deploymentDetailsTags
      ]

newtype ServiceName = ServiceName Text
  deriving stock (Eq, Generic)
  deriving newtype (ToJSON, EncodeValue)

instance DecodeValue ServiceName where
  decodeValue :: HasqlD.Value ServiceName
  decodeValue = refine serviceNameFromText HasqlD.text

instance FromJSON ServiceName where
  parseJSON = withText "ServiceName" (either (fail . Text.unpack) pure . serviceNameFromText)

instance FromHttpApiData ServiceName where
  parseUrlPiece = serviceNameFromText

serviceNameToText :: ServiceName -> Text
serviceNameToText (ServiceName sn) = sn

serviceNameFromTextMaybe :: Text -> Maybe ServiceName
serviceNameFromTextMaybe t = if isValidDNSName t then Just (ServiceName t) else Nothing

serviceNameFromText :: Text -> Either Text ServiceName
serviceNameFromText t = maybe (Left $ "Invalid service name (must be a valid DNS name): " <> t) Right (serviceNameFromTextMaybe t)

newtype StoragePoolId = StoragePoolId UUID
  deriving stock (Eq, Generic)
  deriving newtype (Binary, Show, ToJSON, EncodeValue, DecodeValue)

instance MimeRender PlainText StoragePoolId where
  mimeRender :: Proxy PlainText -> StoragePoolId -> BL.ByteString
  mimeRender _ (StoragePoolId uuid) = BL.fromStrict . encodeUtf8 . Text.pack . show $ uuid

newtype StoragePoolName = StoragePoolName Text
  deriving stock (Eq, Generic)
  deriving newtype (Binary, Show, ToJSON, EncodeValue, DecodeValue, FromHttpApiData)

instance FromHttpApiData StoragePoolId where
  parseUrlPiece :: Text -> Either Text StoragePoolId
  parseUrlPiece t = case readMaybe $ Text.unpack t of
    Nothing -> Left "Invalid UUID format"
    Just uuid -> Right $ StoragePoolId uuid

data JsonMergePatch

instance Accept JsonMergePatch where
  contentType _ = "application" // "merge-patch+json"

data IncompleteSubscription = IncompleteSubscription
  { subscriptionId :: SubscriptionId,
    clientSecret :: Maybe Text
  }
  deriving (Generic)

instance ToJSON IncompleteSubscription where
  toJSON (IncompleteSubscription (SubscriptionId subscriptionId) clientSecret) =
    object
      [ "id" .= subscriptionId,
        "client_secret" .= clientSecret
      ]

-- Our wrapper type to avoid orphan instances
newtype StripeSignature = StripeSignature Sig

instance FromHttpApiData StripeSignature where
  parseUrlPiece :: Text -> Either Text StripeSignature
  parseUrlPiece t = case parseSig t of
    Nothing -> Left "Invalid Stripe signature"
    Just sig -> Right $ StripeSignature sig

data WithRawBody a = WithRawBody
  { rawBody :: BL.ByteString,
    value :: Either Text a
  }
  deriving (Generic)

-- this overlaps but it's fine

instance {-# OVERLAPS #-} (FromJSON a) => MimeUnrender JSON (WithRawBody a) where
  mimeUnrender _ bs = Right $ WithRawBody bs (first Text.pack (eitherDecode bs))

data NimbusRedirect = NimbusRedirect
  { redirectURI :: Text,
    redirectToken :: ByocUserJWT
  }
  deriving (Show, Generic, ToJSON, FromJSON)

data CloudApiHost = CloudApiHost {
  cloudApiHostname :: Text,
  cloudApiPort :: Maybe Text
}

instance FromHttpApiData CloudApiHost where
  parseUrlPiece s = case Text.splitOn ":" s of
    [host, port] -> Right $ CloudApiHost host (Just port)
    [host] -> Right $ CloudApiHost host Nothing
    _ -> Left $ "Invalid cloud host: '" <> s <> "'"
