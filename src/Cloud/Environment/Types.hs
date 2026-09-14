{-# LANGUAGE RecordWildCards #-}

module Cloud.Environment.Types
  ( Environment (..),
    UserEnvironment (..),
  )
where

import Cloud.Prelude
import Data.Aeson
import Data.Time (UTCTime)
import Share.OAuth.Types (UserId)
import Cloud.Web.Types (EnvironmentId)
import qualified Hasql.Interpolate as PG

data Environment = Environment
  { environmentId :: EnvironmentId,
    environmentUserId :: UserId,
    environmentCreatedAt :: UTCTime
  }
  deriving (Show, Eq, Generic)

data UserEnvironment = UserEnvironment
  { userEnvironmentId :: EnvironmentId,
    userEnvironmentName :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON UserEnvironment where
  toJSON UserEnvironment {..} =
    object
      [ "id" .= userEnvironmentId,
        "name" .= userEnvironmentName
      ]

instance PG.DecodeRow UserEnvironment where
  decodeRow =
    PG.decodeRow <&> \(envId, envName) ->
      UserEnvironment
        { userEnvironmentId = envId,
          userEnvironmentName = envName
        }



