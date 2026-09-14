module Cloud.Client.Types
  ( Client (..),
    ClientId,
    MessageType (..),
    NimbusConfig (..),
    NimbusConnection (..),
  )
where

import Control.Monad.Random
import Data.Aeson
import Data.Binary
import Data.Text (Text)
import Data.UUID
import Network.Socket
import Servant.Client (BaseUrl)
import Cloud.Consul.API (ConsulServiceInstance)

data Client = Client
  { clientTLSSocket :: Socket,
    clientID :: ClientId
  }

data NimbusConfig = NimbusConfig
  { consulBaseUrl :: BaseUrl,
    nimbusClientServiceName :: Text,
    nimbusHttpServiceName :: Text,
    envNimbusHost :: Maybe ConsulServiceInstance
  }

newtype NimbusConnection = NimbusConnection {nimbusSocket :: Socket}
  deriving (Show)


newtype MessageType = MessageType {messageTypeToWord :: Word32}
  deriving (Eq, Show)

newtype ClientId = ClientId UUID
  deriving stock (Eq, Ord)
  deriving newtype (Binary, Random)
  deriving (Show {- FromHttpApiData, ToHttpApiData, -}, ToJSON, FromJSON)
