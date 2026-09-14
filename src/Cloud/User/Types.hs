module Cloud.User.Types
  ( pattern MaybeAuthedUserID,
    CloudTier (..),
    UserVisibility (..),
    User (..),
    UserAccountInfo (..),
    CloudTierDetails(..),
  )
where

import Cloud.Prelude
import Cloud.User.UserHandle (UserHandle)
import Data.Aeson
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Share.OAuth.Session
import Share.OAuth.Types
import Share.Utils.IDs ( fromId )
import Share.Utils.URI (URIParam)
import Hasql.Decoders qualified as HasqlD
import Hasql.Encoders qualified as HasqlE
import Share.Utils.Show (tShow)
import Stripe.Concepts (ProductId)
import Cloud.Stripe.Types (PriceId)

import Hasql.Interpolate qualified as Interp
import qualified Hasql.Decoders as Decoders
import Data.Functor.Contravariant (contramap)


-- | Decode a single field as part of a Row
decodeField :: Interp.DecodeField a => Decoders.Row a
decodeField = Decoders.column Interp.decodeField

data CloudTier = Free | Starter | Pro
  deriving (Read, Show, Eq, Ord, Generic)

cloudTierToText :: CloudTier -> Text
cloudTierToText = tShow

textToCloudTier :: Text -> Maybe CloudTier
textToCloudTier = readMaybe . Text.unpack

instance Interp.DecodeValue CloudTier where
  decodeValue :: HasqlD.Value CloudTier
  decodeValue = HasqlD.enum textToCloudTier

instance Interp.EncodeValue CloudTier where
  encodeValue = HasqlE.enum cloudTierToText

instance ToJSON CloudTier where
  toJSON = Aeson.String . cloudTierToText

instance FromJSON CloudTier where
  parseJSON = Aeson.withText "CloudTier" $ \t ->
    case textToCloudTier t of
      Nothing -> fail "Invalid CloudTier"
      Just ct -> pure ct

data UserVisibility = UserPrivate | UserPublic
  deriving (Show, Eq, Ord)

instance Interp.DecodeValue UserVisibility where
  decodeValue =
    Interp.decodeValue
      <&> \case
        True -> UserPrivate
        False -> UserPublic

instance Interp.EncodeValue UserVisibility where
  encodeValue =
    Interp.encodeValue
      & contramap \case
        UserPrivate -> True
        UserPublic -> False

data CloudTierDetails = CloudTierDetails
  { cloudTier :: CloudTier
  , stripeProductId :: ProductId
  , defaultStripePrice :: PriceId
  }

data User = User
  { user_id :: UserId,
    user_name :: Maybe Text,
    user_email :: Text,
    avatar_url :: URIParam,
    handle :: UserHandle,
    visibility :: UserVisibility
  }
  deriving (Show, Eq, Ord, Generic)

instance ToJSON User where
  toJSON User {..} =
    object
      [ "id" .= user_id,
        "name" .= user_name,
        "email" .= user_email,
        "avatarUrl" .= avatar_url,
        "handle" .= handle
      ]

instance Interp.DecodeRow User where
  decodeRow = do
    user_id <- decodeField 
    user_name <- decodeField 
    user_email <- decodeField 
    avatar_url <- decodeField
    handle <- decodeField
    visibility <- decodeField
    pure $ User {..}


data UserAccountInfo = UserAccountInfo
  { handle :: UserHandle,
    name :: Maybe Text,
    avatarUrl :: URIParam,
    userId :: UserId,
    primaryEmail :: Text,
    organizationMemberships :: [UserHandle],
    completedTours :: [Text],
    cloudTier :: CloudTier
  }
  deriving (Show)

instance ToJSON UserAccountInfo where
  toJSON UserAccountInfo {..} =
    Aeson.object
      [ "handle" .= fromId @UserHandle @Text handle,
        "name" .= name,
        "avatarUrl" .= show avatarUrl,
        "primaryEmail" .= primaryEmail,
        "userId" .= userId,
        "organizationMemberships" .= organizationMemberships,
        "completedTours" .= completedTours,
        "cloudTier" .= cloudTier
      ]
