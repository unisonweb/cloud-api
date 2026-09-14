{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE InstanceSigs #-}

module Cloud.Storage.Types
  ( StoragePoolName (..),
    StoragePool (..),
    StoragePoolId (..),
  )
where

import Cloud.Prelude
import Data.Aeson
import Data.Binary (Binary)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.UUID (UUID)
import Hasql.Interpolate (DecodeValue, EncodeValue)
import Hasql.Interpolate qualified as Hasql
import Servant
import Cloud.Web.Types (EnvironmentId)

newtype StoragePoolId = StoragePoolId UUID
  deriving stock (Eq, Generic)
  deriving newtype (Binary, Show, ToJSON, EncodeValue, DecodeValue)

instance MimeRender PlainText StoragePoolId where
  mimeRender :: Proxy PlainText -> StoragePoolId -> BL.ByteString
  mimeRender _ (StoragePoolId uuid) = BL.fromStrict . encodeUtf8 . Text.pack . show $ uuid

newtype StoragePoolName = StoragePoolName Text.Text
  deriving stock (Eq, Generic)
  deriving newtype (Binary, Show, ToJSON, EncodeValue, DecodeValue, FromHttpApiData)

data StoragePool = StoragePool StoragePoolId StoragePoolName [EnvironmentId]
  deriving (Show, Eq, Generic)
  deriving anyclass (Hasql.DecodeRow)

instance FromHttpApiData StoragePoolId where
  parseUrlPiece :: Text -> Either Text StoragePoolId
  parseUrlPiece t = case readMaybe $ Text.unpack t of
    Nothing -> Left "Invalid UUID format"
    Just uuid -> Right $ StoragePoolId uuid

instance ToJSON StoragePool where
  toJSON (StoragePool (StoragePoolId poolId) (StoragePoolName poolName) envIds) =
    object
      [ "id" .= poolId,
        "name" .= poolName,
        "environments" .= envIds
      ]
