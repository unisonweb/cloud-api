{-# LANGUAGE InstanceSigs #-}

{- This module allows checking which deployment of cloud we're operating in.
    This can be useful for adjusting logging/debug levels or providing tools
    which are specific to a given environment.
-}
module Cloud.Deployment (Deployment (..), deployment, onLocal) where

import Cloud.Prelude
import System.IO.Unsafe (unsafePerformIO)
import UnliftIO.Environment (lookupEnv)

data Deployment
  = Local
  | Staging
  | Production
  deriving (Eq, Ord)

instance Show Deployment where
  show :: Deployment -> String
  show = \case
    Local -> "local"
    Staging -> "staging"
    Production -> "production"

onLocal :: Bool
onLocal = deployment == Local

deployment :: HasCallStack => Deployment
deployment =
  case unsafePerformIO (lookupEnv "CLOUD_DEPLOYMENT") of
    Just "local" -> Local
    Just "staging" -> Staging
    Just "production" -> Production
    Just "prod" -> Production
    depl -> error $ "Unknown deployment type: " <> show depl
{-# NOINLINE deployment #-}
