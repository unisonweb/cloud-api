module Cloud.Deployment.DeploymentHash

(
  DeploymentHash(..),
)

where
import Hasql.Interpolate (EncodeValue, DecodeValue)
import Data.Aeson
import Data.Text qualified as Text
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant

newtype DeploymentHash = DeploymentHash Text
  deriving  (Eq, Generic)
  deriving newtype (ToJSON, FromJSON, EncodeValue, DecodeValue, FromHttpApiData, MimeRender PlainText)  

instance Show DeploymentHash where
  show :: DeploymentHash -> String
  show (DeploymentHash hash) = Text.unpack hash

instance Read DeploymentHash where
  readsPrec :: Int -> String -> [(DeploymentHash, String)]
  readsPrec _ input = [(DeploymentHash $ Text.pack input, "")]
