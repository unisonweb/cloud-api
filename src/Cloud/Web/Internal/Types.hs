{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

module Cloud.Web.Internal.Types
  ( UserIdResult (..),
    StoragePoolIdResult (..),
    DeploymentHashResult (..),
  )
where

import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Prelude
import Cloud.Storage.Types (StoragePoolId (..))
import Data.Aeson
import Data.UUID (UUID)

newtype UserIdResult = UserIdResult {userId :: UUID}
  deriving stock (Generic)
  deriving anyclass (ToJSON)

newtype StoragePoolIdResult = StoragePoolIdResult {storagePoolId :: StoragePoolId}
  deriving stock (Generic)
  deriving anyclass (ToJSON)

newtype DeploymentHashResult = DeploymentHashResult {deploymentHash :: DeploymentHash}
  deriving stock (Generic)
  deriving anyclass (ToJSON)
