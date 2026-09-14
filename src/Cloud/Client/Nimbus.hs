{-# LANGUAGE DataKinds #-}

module Cloud.Client.Nimbus
  (withNimbusConnection)
where

import Cloud.Client.Errors
import Cloud.Client.Types
import Cloud.Consul.API (ConsulServiceInstance (..), serviceHealth')
import Cloud.Prelude
import Cloud.Utils.Logging ( MonadLogger )
import Control.Monad.Random.Strict
import Debug.Trace
import Network.HTTP.Client (newManager)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.Simple.TCP
import Servant
import Servant.Client
import UnliftIO

serviceHealthClient :: NimbusConfig -> ClientM [ConsulServiceInstance]
serviceHealthClient config =
  getResponse <$> serviceHealth' (nimbusClientServiceName config) (Just True) Nothing Nothing cached stale
  where
    cached = True
    stale = True

consulContext :: NimbusConfig -> IO ClientEnv
consulContext config = do
  manager' <- newManager tlsManagerSettings
  return $ mkClientEnv manager' (consulBaseUrl config)

nimbusNode :: (MonadIO m, MonadLogger m, MonadRandom m) => NimbusConfig -> m ConsulServiceInstance
nimbusNode config = do
  env <- liftIO $ consulContext config
  nodes <- liftIO $ runClientM (serviceHealthClient config) env
  case nodes of
    Left e -> traceShow e $ UnliftIO.throwIO err500
    Right [] -> respondErrorM $ AuthFailure "Temporary server error. Please try again later."
    Right available -> uniform available

withNimbusConnection :: (MonadUnliftIO m, MonadLogger m, MonadRandom m) => NimbusConfig -> (NimbusConnection -> m a) -> m a
withNimbusConnection cfg useSocket = do
  node <- case envNimbusHost cfg of
    Nothing -> nimbusNode cfg
    Just n -> return n
  case node of
    ConsulServiceInstance host portMaybe _ _ ->
      bracket (NimbusConnection . fst <$> connectSock host portString) (closeSock . nimbusSocket) useSocket
      where portString = maybe "0" show portMaybe
