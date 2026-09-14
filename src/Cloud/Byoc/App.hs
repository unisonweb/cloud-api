module Cloud.Byoc.App
where

import Cloud.App
import Cloud.Byoc.Env
import Cloud.Env (clusterEnv)
import Cloud.Prelude
import Control.Monad.Reader (MonadReader, ReaderT, withReaderT)

newtype ClusterM a = ClusterM {unClusterM :: ReaderT ClusterEnv IO a}
  deriving newtype
    ( Functor,
      Applicative,
      Monad,
      MonadReader ClusterEnv,
      MonadIO,
      MonadUnliftIO
    )

clusterM :: ClusterM a -> AppM ctx a
clusterM a = AppM $ withReaderT clusterEnv (unClusterM a)
