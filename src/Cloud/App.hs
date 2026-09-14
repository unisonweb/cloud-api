module Cloud.App
  ( CloudApp,
    AppM(..),
    runAppM
  )
where

import Cloud.Prelude
import Cloud.Env (Env (..))
import Cloud.Utils.Logging
import Control.Monad.Random.Strict (MonadRandom)
import Control.Monad.Reader
  ( MonadReader,
    ReaderT (..),
    asks,
  )
import Crypto.JWT qualified as JWT
import Crypto.Random.Types qualified as Cryptonite
import Database.Redis qualified as R

newtype AppM reqCtx a = AppM {unAppM :: ReaderT (Env reqCtx) IO a}
  deriving newtype (Functor, Applicative, Monad, MonadReader (Env reqCtx), MonadRandom, MonadIO, MonadUnliftIO)

type CloudApp = AppM ()

instance MonadLogger CloudApp where
  logMsg msg = do
    log <- asks envLogger
    minSeverity <- asks envMinLogSeverity
    when (severity msg >= minSeverity) $ do
      timestamp <- asks envTimeCache >>= liftIO
      liftIO . log . logFmtFormatter timestamp $ msg

instance Cryptonite.MonadRandom (AppM reqCtx) where
  getRandomBytes =
    liftIO . Cryptonite.getRandomBytes

runAppM :: Env reqCtx -> AppM reqCtx a -> IO a
runAppM env (AppM m) = runReaderT m env

instance R.MonadRedis (AppM reqCtx) where
  liftRedis m = do
    redis <- asks envRedisConnection
    liftIO $ R.runRedis redis m

instance R.RedisCtx (AppM reqCtx) (Either R.Reply) where
  returnDecode r = do
    R.liftRedis $ R.returnDecode r

