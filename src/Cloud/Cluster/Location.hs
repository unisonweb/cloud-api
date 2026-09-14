module Cloud.Cluster.Location
  ( LocationId(..)
  , locationIdToText
  )
where
import Data.Hashable
import Data.Text
import Data.Aeson
import Servant (FromHttpApiData)


newtype LocationId = LocationId Text
  deriving newtype (Eq, FromHttpApiData, ToJSON, FromJSON, Hashable)

locationIdToText :: LocationId -> Text
locationIdToText (LocationId t) = t
