module Cloud.User.App (
    AuthM(..),
    authM,
) where


import Cloud.App ( AppM(AppM) )
import Cloud.User.Env
import Cloud.Env (authEnv)
import Cloud.Prelude
import Control.Monad.Reader (MonadReader, ReaderT, withReaderT)

newtype AuthM a = AuthM {unAuthM :: ReaderT AuthEnv IO a}
  deriving newtype
    ( Functor,
      Applicative,
      Monad,
      MonadReader AuthEnv,
      MonadIO,
      MonadUnliftIO
    )

authM :: AuthM a -> AppM ctx a
authM a = AppM $ withReaderT authEnv (unAuthM a)