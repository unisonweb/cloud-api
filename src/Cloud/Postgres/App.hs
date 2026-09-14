module Cloud.Postgres.App
  ( PostgresM (..),
    postgresM,
  )
where

import Cloud.App (AppM (..))
import Cloud.Postgres.Env
import Cloud.Env (Env (postgresEnv))
import Cloud.Prelude
import Control.Monad.Reader (MonadReader, ReaderT, withReaderT)

newtype PostgresM a = PostgresM {unPostgresM :: ReaderT PostgresEnv IO a}
  deriving newtype (Functor, Applicative, Monad, MonadReader PostgresEnv, MonadIO, MonadUnliftIO)

postgresM :: PostgresM a -> AppM ctx a
postgresM a = AppM $ withReaderT postgresEnv (unPostgresM a)
