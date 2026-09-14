{-# LANGUAGE DeriveAnyClass #-}
module Cloud.Domain.Types
 (
    DomainName(..),
    DomainDetails(..)
 )
where
import Cloud.Prelude
import Cloud.Service.Types (ServiceName)
import Amazonka.Data
import Servant

newtype DomainName = DomainName Text
    deriving Generic
    deriving newtype (Show, Eq, FromJSON, ToJSON, ToHttpApiData, FromHttpApiData)

data DomainDetails = DomainDetails {
    domainName :: DomainName,
    serviceName :: ServiceName
} deriving (Generic, Eq, FromJSON, ToJSON)

