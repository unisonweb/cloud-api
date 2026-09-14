module Cloud.Client.Errors
  ( ClientError (..),
    clientErrorToText,
    expectedMoreBytes,
    orRespondErrorM,
    respondErrorM,
    runGetOrErr,
  )
where

import Cloud.App
import Cloud.Errors
import Cloud.Prelude
import Cloud.Utils.Logging
import Data.Binary.Get
import Data.ByteString.Lazy qualified as LBS
import Data.Data
import Share.Utils.Show (tShow)

data ClientError
  = ProtocolError Text
  | ServiceUnavailable Text
  | AuthFailure Text
  deriving (Show, Typeable)

instance Loggable ClientError where
  toLog = withSeverity Error . showLog

instance Exception ClientError

instance ToServerError ClientError where
  toServerError _err =
    (ErrorID "unknown-client-error", internalServerError)

clientErrorToText :: ClientError -> Text
clientErrorToText = \case
  ProtocolError msg -> "Protocol Error: " <> msg
  ServiceUnavailable msg -> "Service Unavailable: " <> msg
  AuthFailure msg -> "Authentication Failure: " <> msg

expectedMoreBytes :: ByteOffset -> ClientError
expectedMoreBytes received = ProtocolError $ "expected more bytes at offset " <> tShow received

orRespondErrorM :: HasCallStack => Either ClientError a -> CloudApp a
orRespondErrorM = either respondErrorM pure

-- | Logs the error with a call stack and throws an error that will eventually
-- result in an error message to the client.
respondErrorM :: (HasCallStack, MonadIO m, MonadLogger m) => ClientError -> m a
respondErrorM e = do
  logMsg . withCurrentCallstackIfUnset $ toLog e
  throwIO e

runGetOrErr :: (MonadIO m, MonadLogger m) => Get a -> LBS.ByteString -> m (LBS.ByteString, a)
runGetOrErr g bs =
  either failure success (runGetOrFail g bs)
  where
    failure (_, _, _) = respondErrorM $ ProtocolError "Failed to decode message."
    success (remaining, _, a) = pure (remaining, a)
