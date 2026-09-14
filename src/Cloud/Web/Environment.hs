{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Cloud.Web.Environment
  ( createEnvironment,
    deleteEnvironmentVariable,
    deleteEnvironment,
    Env (..),
    setEnvironmentVariable,
    storagePoolAssignEnv,
    storagePoolUnassignEnv,
  )
where

import Cloud.Byoc.Env (ClusterConfig(..), defaultClusterId)
import Cloud.Env
import Cloud.Errors (respondError)
import Cloud.Prelude
import Cloud.Utils.Logging
import Cloud.Web.App (WebApp)
import Cloud.Web.Errors
import Cloud.Web.Types (EnvironmentId (..), JsonMergePatch)
import Control.Monad.Reader (ask)
import Data.Aeson qualified as JS
import Data.Map qualified as Map
import Data.Text (pack, unpack)
import Network.HTTP.Types (Status (statusCode))
import Servant
import Servant.Client (ClientError (FailureResponse))
import Servant.Client qualified as S
import Cloud.Events (fireEnvironmentInvalidationEvent)

-- API definition
-- API definition
type VaultAPI =
  Capture "mount" Text :> "data" :> Header "X-Vault-Token" Text :> Capture "path" Text :> DeleteNoContent
    :<|> Capture "mount" Text :> "data" :> Header "X-Vault-Token" Text :> Capture "path" Text :> ReqBody '[JsonMergePatch] SecretPatch :> PatchNoContent
    :<|> Capture "mount" Text :> "data" :> Header "X-Vault-Token" Text :> Capture "path" Text :> ReqBody '[JSON] SecretRequest :> PostNoContent

vaultApi :: Proxy VaultAPI
vaultApi = Proxy

deleteSecret' :: Text -> Maybe Text -> Text -> S.ClientM NoContent
patchSecret' :: Text -> Maybe Text -> Text -> SecretPatch -> S.ClientM NoContent
storeSecret' :: Text -> Maybe Text -> Text -> SecretRequest -> S.ClientM NoContent
deleteSecret' :<|> patchSecret' :<|> storeSecret' = S.client vaultApi

-- Data types

data SecretRequest = SecretRequest
  { options :: Maybe Options,
    data_ :: Map String String
  }
  deriving (Generic)

instance JS.ToJSON SecretRequest where
  toJSON (SecretRequest options data_) = JS.object ["options" JS..= options, "data" JS..= data_]

newtype Options = Options
  { cas :: Int
  }
  deriving (Generic)

instance JS.ToJSON Options

newtype SecretData = SecretData (Map String String)

data SecretPatch = SecretPatch !(Maybe Options) !(Map String (Maybe String))

instance MimeRender JsonMergePatch SecretPatch where
  mimeRender _ (SecretPatch options data_) = JS.encode $ JS.object ["options" JS..= options, "data" JS..= data_]

instance JS.ToJSON SecretData where
  toJSON (SecretData data_) = JS.object ["data" JS..= data_]


-- Functions
createEnvironment :: EnvironmentId -> Text -> WebApp ()
createEnvironment envId name = do
  Env {envEnvironmentsMount, envVaultToken, envVaultClientEnv} <- ask
  -- we don't want to overwrite the environment if it already exists, so we supply a cas value of 0
  let req = SecretRequest (Just (Options {cas = 0})) (Map.singleton "environment" (unpack name))
  res <- liftIO $ S.runClientM (storeSecret' envEnvironmentsMount (Just envVaultToken) (pack $ show envId) req) envVaultClientEnv
  case res of
    Right _ -> return ()
    -- the environment already exists
    Left (FailureResponse _ err) | statusCode (S.responseStatusCode err) == 400 -> return ()
    Left err -> do
      respondError $ InternalError $ pack $ "Error creating environment: " ++ show err


-- deprecated this is just to support old clients
setEnvironmentVariable :: EnvironmentId -> Text -> Text -> WebApp ()
setEnvironmentVariable envId key value = do
  Env {envEnvironmentsMount, envNimbusConfig, envVaultToken, envVaultClientEnv } <- ask

  let newData = Map.singleton (unpack key) (Just $ unpack value)
  res <- liftIO $ S.runClientM (patchSecret' envEnvironmentsMount (Just envVaultToken) (pack $ show envId) (SecretPatch Nothing newData)) envVaultClientEnv
  case res of
    Left err -> logErrorText $ pack $ "Error storing environment: " ++ show err
    Right _ -> fireEnvironmentInvalidationEvent envNimbusConfig defaultClusterId envId

-- deprecated this is just to support old clients
deleteEnvironmentVariable :: EnvironmentId -> Text -> WebApp ()
deleteEnvironmentVariable envId key = do
  Env {envEnvironmentsMount, envNimbusConfig, envVaultToken, envVaultClientEnv } <- ask
  let newData = Map.singleton (unpack key) Nothing
  res <- liftIO $ S.runClientM (patchSecret' envEnvironmentsMount (Just envVaultToken) (pack $ show envId) (SecretPatch Nothing newData)) envVaultClientEnv
  case res of
    Left err -> do
      respondError $ InternalError $ pack $ "Error deleting environment variable: " ++ show err
    Right _ -> fireEnvironmentInvalidationEvent envNimbusConfig defaultClusterId envId
-- deprecated this is just to support old clients
deleteEnvironment :: EnvironmentId -> WebApp ()
deleteEnvironment envId = do
  Env {envEnvironmentsMount, envNimbusConfig, envVaultToken, envVaultClientEnv } <- ask
  res <- liftIO $ S.runClientM (deleteSecret' envEnvironmentsMount (Just envVaultToken) (pack $ show envId)) envVaultClientEnv
  case res of
    Left err -> do
      respondError $ InternalError $ pack $ "Error deleting environment: " ++ show err
    Right _ -> fireEnvironmentInvalidationEvent envNimbusConfig defaultClusterId envId

storagePoolAssignEnv :: ClusterConfig -> EnvironmentId -> WebApp ()
storagePoolAssignEnv cluster envId = do
  Env {envNimbusConfig} <- ask
  fireEnvironmentInvalidationEvent envNimbusConfig cluster.clusterId envId
storagePoolUnassignEnv :: ClusterConfig -> EnvironmentId -> WebApp ()
storagePoolUnassignEnv cluster envId = do
  Env {envNimbusConfig} <- ask
  fireEnvironmentInvalidationEvent envNimbusConfig cluster.clusterId envId