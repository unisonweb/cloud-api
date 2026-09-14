{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -fno-warn-orphans #-} -- YOLO

-- | Postgres helpers
module Cloud.Postgres
  ( -- * Types
    Transaction,
    Session,
    Mode (..),
    Interp.EncodeValue (..),
    Interp.EncodeRow (..),
    Interp.DecodeValue (..),
    Interp.DecodeRow (..),
    Only (..),
    (:.) (..),
    runTransaction,

    -- * query Helpers
    rollback,
    queryListRows,
    query1Row,
    queryExpect1Row,
    queryListCol,
    query1Col,
    queryExpect1Col,
    execute_,

    -- * Interpolation
    Interp.sql,
    Interp.toTable,
    Interp.Sql,
    readTransaction,
    runSessionWithPool,
  )
where

import Cloud.Prelude
import Control.Monad.Except
import Control.Monad.Reader
import Data.Maybe
import Data.Void
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Interpolate qualified as Interp
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Hasql
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Hasql
import Cloud.Postgres.App (PostgresM)
import Cloud.Postgres.Env (PostgresEnv(..))
import Cloud.Errors (ToServerError (..), ErrorID(..), internalServerError)
import Servant.Server (ServerError)
import qualified Cloud.Utils.Logging as Logging

newtype PostgresError = PoolError Pool.UsageError
  deriving newtype (Show)
  deriving anyclass (Exception)

instance ToServerError PostgresError where
  toServerError :: PostgresError -> (ErrorID, ServerError)
  toServerError (PoolError err) =
    let errId = case err of
          Pool.ConnectionUsageError {} -> "connection-usage-error"
          Pool.SessionUsageError {} -> "session-usage-error"
          Pool.AcquisitionTimeoutUsageError {} -> "acquisition-timeout-usage-error"
     in (ErrorID $ "postgres:pool:" <> errId, internalServerError)

instance Logging.Loggable PostgresError where
  toLog (PoolError err) =
    Logging.showLog err
      & Logging.withSeverity Logging.Error


-- | A transaction that may fail with an error 'e'
-- type Transaction e = ExceptT e Hasql.Transaction
newtype Transaction e a
  = Transaction (Hasql.Session (Either e a))
  deriving (Functor, Applicative, Monad, MonadError e) via ExceptT e Hasql.Session

-- | A session that may fail with an error 'e'
type Session e = ExceptT e Hasql.Session


defaultIsolationLevel :: IsolationLevel
defaultIsolationLevel = ReadCommitted

data Mode = Read | ReadWrite deriving stock (Eq, Show)

data IsolationLevel
  = ReadCommitted
  | RepeatableRead
  | Serializable
  deriving stock (Show, Eq)

-- transactionUnsafeIO :: IO a -> Transaction e a
-- transactionUnsafeIO io = Transaction (Right <$> liftIO io)

-- | Run a transaction in a session
transaction :: Mode -> Transaction e a -> Session e a
transaction mode (Transaction t) = do
  let loop = do
        beginTransaction defaultIsolationLevel mode
        res <- catchError (Just <$> t <* commit) \case
          Session.QueryError
            _
            _
            ( Session.ResultError
                (Session.ServerError errCode _ _ _ _)
              )
              -- retry on serialization failure or deadlock
              -- https://www.postgresql.org/docs/current/errcodes-appendix.html
              | errCode == "40001" || errCode == "40P01" -> pure Nothing
          err -> do
            -- Ensure our current connection is rolled back on exceptions
            rollbackSession
            throwError err
        case res of
          Nothing -> do
            rollbackSession
            loop
          Just res -> do
            case res of
              Left _ -> do
                rollbackSession
              Right _ -> pure ()
            pure res
  ExceptT loop

beginTransaction :: IsolationLevel -> Mode -> Hasql.Session ()
beginTransaction hiso hmode =
  Session.statement () (Interp.interp False [Interp.sql| BEGIN ISOLATION LEVEL ^{iso} ^{mode} |])
  where
    iso =
      case hiso of
        ReadCommitted -> [Interp.sql| READ COMMITTED |]
        RepeatableRead -> [Interp.sql| REPEATABLE READ |]
        Serializable -> [Interp.sql| SERIALIZABLE |]
    mode =
      case hmode of
        ReadWrite -> [Interp.sql| READ WRITE |]
        Read -> [Interp.sql| READ ONLY |]

commit :: Hasql.Session ()
commit = Session.statement () (Hasql.Statement "commit" Encoders.noParams Decoders.noResult True)

rollbackSession :: Hasql.Session ()
rollbackSession = Session.statement () (Hasql.Statement "rollback" Encoders.noParams Decoders.noResult True)

-- | Rollback the current transaction
rollback :: e -> Transaction e x
rollback e = Transaction do
  pure (Left e)

transactionStatement :: a -> Hasql.Statement a b -> Transaction e b
transactionStatement v stmt = Transaction do
  Right <$> Session.statement v stmt

-- | Run a write transaction within a session
writeTransaction :: Transaction e a -> Session e a
writeTransaction = transaction ReadWrite

-- | Run a read-only transaction within a session
readTransaction :: Transaction e a -> Session e a
readTransaction = transaction Read

-- | Run a transaction that doesn't throw errors in the App monad.
--
-- Uses a Write transaction for simplicity since there's not much
-- benefit in distinguishing transaction types.
runTransaction :: Transaction Void a -> PostgresM a
runTransaction t = runSession (writeTransaction t)

-- | Run a session in the App monad without any errors.
runSession :: HasCallStack => Session Void a -> PostgresM a
runSession t = either absurd id <$> tryRunSession t

-- | Run a session in the App monad, returning an Either error.
tryRunSession :: HasCallStack => Session e a -> PostgresM (Either e a)
tryRunSession s = do
  pool <- asks pgConnectionPool
  liftIO $ tryRunSessionWithPool pool s

-- | Manually run an unfailing session using a connection pool.
runSessionWithPool :: HasCallStack => Pool.Pool -> Session Void a -> IO a
runSessionWithPool pool s = either absurd id <$> tryRunSessionWithPool pool s

-- | Manually run a session using a connection pool, returning an Either error.
tryRunSessionWithPool :: HasCallStack => Pool.Pool -> Session e a -> IO (Either e a)
tryRunSessionWithPool pool s = do
  liftIO (Pool.use pool (runExceptT s)) >>= \case
    Left err -> throwIO (PoolError err)
    Right a -> pure a

-- | Represents any monad in which we can run a statement
class Monad m => QueryM m where
  statement :: q -> Hasql.Statement q r -> m r

instance QueryM (Transaction e) where
  statement = transactionStatement

instance QueryM (Session e) where
  statement q s = lift $ Session.statement q s

prepareStatements :: Bool
prepareStatements = True

queryListRows :: (Interp.DecodeRow r, QueryM m) => Interp.Sql -> m [r]
queryListRows sql = statement () (Interp.interp prepareStatements sql)

query1Row :: QueryM m => (Interp.DecodeRow r) => Interp.Sql -> m (Maybe r)
query1Row sql = listToMaybe <$> queryListRows sql

query1Col :: (QueryM m, Interp.DecodeField a) => Interp.Sql -> m (Maybe a)
query1Col sql = listToMaybe <$> queryListCol sql

queryListCol :: forall m a. QueryM m => (Interp.DecodeField a) => Interp.Sql -> m [a]
queryListCol sql = queryListRows @(Interp.OneColumn a) sql <&> coerce @[Interp.OneColumn a] @[a]

execute_ :: QueryM m => Interp.Sql -> m ()
execute_ sql = statement () (Interp.interp prepareStatements sql)

queryExpect1Row :: HasCallStack => (Interp.DecodeRow r, QueryM m) => Interp.Sql -> m r
queryExpect1Row sql =
  query1Row sql >>= \case
    Nothing -> error "queryExpect1Row: expected 1 row, got 0"
    Just r -> pure r

queryExpect1Col :: HasCallStack => (Interp.DecodeField a, QueryM m) => Interp.Sql -> m a
queryExpect1Col sql =
  query1Col sql >>= \case
    Nothing -> error "queryExpect1Col: expected 1 row, got 0"
    Just r -> pure r


-- | Helper for decoding a row which contains many types which each have their own DecodeRow
-- instance.
--
-- E.g. queryExpect1Row userAndProjectSql <&> \(user :. project) -> (user, project)
data a :. b = a :. b
  deriving (Show)

infixr 3 :.

instance (Interp.DecodeRow a, Interp.DecodeRow b) => Interp.DecodeRow (a :. b) where
  decodeRow :: (Interp.DecodeRow a, Interp.DecodeRow b) => Decoders.Row (a :. b)
  decodeRow = (:.) <$> Interp.decodeRow <*> Interp.decodeRow

-- | Helper for decoding a single column when using (:.), you shouldn't usually need it otherwise.
--
-- E.g. queryExpect1Col userAndProjectSql <&> \(user :. Only projectCount) -> (user, projectCount)
newtype Only a = Only {fromOnly :: a}
  deriving (Show, Eq, Ord)

-- | Decode a single field as part of a Row
decodeField :: Interp.DecodeField a => Decoders.Row a
decodeField = Decoders.column Interp.decodeField

instance Interp.DecodeField a => Interp.DecodeRow (Only a) where
  decodeRow = Only <$> decodeField

