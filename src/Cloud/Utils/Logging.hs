{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

module Cloud.Utils.Logging
  ( -- * Message builders
    Loggable (..),
    withCallstackIfUnset,
    withCurrentCallstackIfUnset,
    withTag,
    withSeverity,
    showLog,
    textLog,
    logDebugText,
    logInfoText,
    logUserFaultText,
    logErrorText,
    ioLogger,
    logFmtFormatter,

    -- * Logger Monads
    Logger,
    LoggerT (..),
    MonadLogger (..),
    runLoggerT,
    -- runLoggerTEnv,

    -- * Other
    module X,
  )
where

import Cloud.Deployment (deployment)
-- import Cloud.Env (Env (..))
import Cloud.Prelude
import Cloud.Utils.Logging.Types as X
import Control.Monad.Reader
import Data.Char qualified as Char
import Data.Coerce
import Data.Foldable qualified as F
import Data.Kind
import Data.List (intersperse)
import Data.Map qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as Text
import Share.Utils.Show (tShow)
import GHC.Base
import GHC.Stack (CallStack, callStack, prettyCallStack)
import Servant.Client qualified as Servant
import System.Log.FastLogger qualified as FL
import UnliftIO qualified as IO
import Prelude hiding (log)
import Cloud.Stripe.API (StripeError (..))
import Control.Monad.Trans.Resource (ResourceT)

type Logger = FL.LogStr -> IO ()

newtype LoggerT m a = LoggerT (ReaderT (Logger, IO FL.FormattedTime, Severity, Map Text Text) m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO)

type Representational m = (forall a b. (Coercible a b) => Coercible (m a) (m b) :: Constraint)

deriving instance (MonadUnliftIO m, Representational m) => MonadUnliftIO (LoggerT m)

instance (MonadIO m) => MonadLogger (LoggerT m) where
  logMsg msg = LoggerT $ do
    (logger, getTime, minSeverity, tags') <- ask
    when (severity msg >= minSeverity) . liftIO $ do
      timestamp <- getTime
      logger . logFmtFormatter timestamp $ msg {tags = tags msg `Map.union` tags'}

runLoggerT :: Severity -> Logger -> Map Text Text -> IO FL.FormattedTime -> LoggerT m a -> m a
runLoggerT minSeverity l reqTags ft (LoggerT m) = runReaderT m (l, ft, minSeverity, reqTags)

-- runLoggerTEnv :: Env reqCtx -> Map Text Text -> LoggerT m a -> m a
-- runLoggerTEnv Env {envMinLogSeverity, envLogger, envTimeCache} tags = runLoggerT envMinLogSeverity envLogger tags envTimeCache

class Loggable msg where
  toLog :: msg -> LogMsg

instance Loggable Servant.ClientError where
  toLog = withSeverity Error . showLog

instance Loggable StripeError where
  toLog (StripeError servantError) = withSeverity Error . showLog $ servantError

-- instance Loggable OAuth2Error where
--   toLog = withSeverity UserFault . showLog

class (Monad m) => MonadLogger m where
  logMsg :: LogMsg -> m ()

instance (MonadLogger m) => MonadLogger (ReaderT r m) where
  logMsg = lift . logMsg

instance (MonadLogger m) => MonadLogger (ResourceT m) where
  logMsg = lift . logMsg

whenM :: (Monoid a) => Bool -> a -> a
whenM True a = a
whenM False _ = mempty

-- List.intercalate extended to any monoid
-- "The type that intercalate should have had to begin with."
intercalateMap :: (Foldable t, Monoid a) => a -> (b -> a) -> t b -> a
intercalateMap separator renderer elements =
  mconcat $ intersperse separator (renderer <$> F.toList elements)

textLog :: Text -> LogMsg
textLog msg =
  LogMsg
    { severity = Info,
      callstack = Nothing,
      msg,
      tags = mempty
    }

showLog :: (Show a) => a -> LogMsg
showLog = textLog . tShow

withSeverity :: Severity -> LogMsg -> LogMsg
withSeverity newSeverity m = m {severity = newSeverity}

withCurrentCallstackIfUnset :: HasCallStack => LogMsg -> LogMsg
withCurrentCallstackIfUnset = withCallstackIfUnset callStack

withCallstackIfUnset :: CallStack -> LogMsg -> LogMsg
withCallstackIfUnset theCallstack m = m {callstack = callstack m <|> Just theCallstack}

withTag :: (Text, Text) -> LogMsg -> LogMsg
withTag (k, v) m = m {tags = Map.singleton k v <> tags m}

logDebugText :: (MonadLogger m) => Text -> m ()
logDebugText msg = logMsg . withSeverity Debug $ textLog msg

logInfoText :: (MonadLogger m) => Text -> m ()
logInfoText msg = logMsg . withSeverity Info $ textLog msg

logUserFaultText :: (MonadLogger m) => Text -> m ()
logUserFaultText msg = logMsg . withSeverity UserFault $ textLog msg

logErrorText :: (HasCallStack, MonadLogger m) => Text -> m ()
logErrorText msg = logMsg . withCurrentCallstackIfUnset . withSeverity Error $ textLog msg

-- | Formats a LogMsg in the popular logfmt format.
--
-- >>> logFmtFormatter (LogMsg{severity=Error, timestamp="26/Oct/2022:21:04:38", callstack=Nothing, msg="Something Happened!", tags=Map.fromList [("userID", "123456")]})
-- "time=\"26/Oct/2022:21:04:38\" level=\"Error\" userID=\"123456\" msg=\"Something Happened!\""
logFmtFormatter :: FL.FormattedTime -> LogMsg -> FL.LogStr
logFmtFormatter timestamp (LogMsg {severity, callstack, msg, tags}) =
  toLogFmt $
    [ ("time", Text.decodeUtf8 timestamp),
      ("level", Text.pack . show $ severity),
      ("deployment", Text.pack . show $ deployment)
    ]
      <> Map.toList tags
      <> whenM (not $ Text.null msg) [("msg", msg)]
      <> case callstack of
        Nothing -> []
        Just cs -> [("callstack", Text.pack $ prettyCallStack cs)]
  where
    keyify :: Text -> Text
    keyify = Text.map \case
      c
        | Char.isAlphaNum c || c `elem` ['_', '-'] -> c
        | otherwise -> '_'
    toLogFmt :: [(Text, Text)] -> FL.LogStr
    toLogFmt xs = intercalateMap " " FL.toLogStr do
      (k, v) <- xs
      -- Showing the text value will properly escape all contained quotes and wrap
      -- the resulting expression in quotes as is required by logfmt
      pure $ keyify k <> "=" <> Text.pack (show v)

ioLogger :: (MonadIO m) => IO.Handle -> (LogMsg -> Text) -> LogMsg -> m ()
ioLogger handle formatter msg = liftIO do
  Text.hPutStrLn handle (formatter msg)
