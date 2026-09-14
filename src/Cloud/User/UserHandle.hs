module Cloud.User.UserHandle

(
  UserHandle(..)
) where

import Data.Aeson
import Data.Binary
import Data.Text
import Share.Utils.IDs
import qualified Hasql.Interpolate as Hasql
import Servant

newtype UserHandle = UserHandle Text
  deriving stock (Eq, Ord)
  deriving (IsID, Binary, Hasql.EncodeValue, Hasql.DecodeValue) via Text
  deriving (FromHttpApiData, ToHttpApiData, ToJSON, FromJSON) via (UsingID UserHandle)

instance Show UserHandle where
  show (UserHandle h) = show h
