{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

module Cloud.Web.Loki (NanosecondUnixEpoch (..), servicesLogQuery, nsFromUTCTime, userLogQuery) where

import Cloud.Byoc.Env (clusterLokiTaskName, clusterLokiClientEnv, Cluster(..), ClusterConfig)
import Cloud.Errors
import Cloud.Web.App
import Cloud.Web.Errors
import Data.Aeson hiding (Result, Value)
import Data.Aeson.Types
import Data.List (sort)
import Data.Text (pack, replace, unpack)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX as SYS
  ( utcTimeToPOSIXSeconds,
  )
import Data.Vector ((!))
import GHC.Generics
import Servant (Proxy (Proxy))
import Servant.API
import Servant.Client qualified as S
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Log.Types
import Share.OAuth.Types (UserId (UserId))
import Cloud.Prelude
import Data.UUID (toString)
import Network.HTTP.Client (responseTimeout, responseTimeoutMicro)
import Cloud.Utils.Logging (logInfoText)

newtype NanosecondUnixEpoch = NanosecondUnixEpoch Int
  deriving stock (Generic)
  deriving newtype (Show, Read, Eq, Ord, ToHttpApiData, FromHttpApiData)

instance FromJSON NanosecondUnixEpoch where
  parseJSON = withText "NanosecondUnixEpoch" $ \t ->
    case reads $ unpack t of
      [(i, "")] -> return $ NanosecondUnixEpoch i
      _ -> fail "Invalid NanosecondUnixEpoch"

nsFromUTCTime :: UTCTime -> NanosecondUnixEpoch
nsFromUTCTime = NanosecondUnixEpoch . (1_000_000_000 *) . round . utcTimeToPOSIXSeconds

data LokiResponse = LokiResponse
  { status :: Text,
    data' :: LokiData
  }
  deriving (Generic, Show)

newtype LogLine = LogLine (NanosecondUnixEpoch, Text)
  deriving (Generic, Show)

instance Eq LogLine where
  (==) (LogLine (t1, _)) (LogLine (t2, _)) = t1 == t2

instance Ord LogLine where
  compare (LogLine (t1, _)) (LogLine (t2, _)) = compare t1 t2

instance FromJSON LogLine where
  parseJSON = withArray "LogLine" $ \arr -> do
    t <- arr .! 0
    v <- arr .! 1
    return $ LogLine (t, v)

(.!) :: (FromJSON a) => Array -> Int -> Parser a
(.!) arr i = parseJSON $ arr ! i

instance FromJSON LokiResponse where
  parseJSON = withObject "LokiResponse" $ \v ->
    LokiResponse
      <$> v .: "status"
      <*> v .: "data"

lokiResponseSummary :: LokiResponse -> Text
lokiResponseSummary (LokiResponse status (LokiData streams)) =
  "LokiResponse Status: " <> status <> ", Streams: " <> pack (show (length streams))

newtype LokiStream = LokiStream [LogLine]
  deriving (Generic, Show)

newtype LokiData = LokiData [LokiStream]
  deriving (Generic, Show)

instance FromJSON LokiData where
  parseJSON = withObject "LokiData" $ \obj -> do
    results <- obj .: "result"
    return $ LokiData results

instance FromJSON LokiStream where
  parseJSON = withObject "LokiStream" $ \obj -> do
    values <- obj .: "values"
    return $ LokiStream values

type LokiAPI =
  "loki"
    :> "api"
    :> "v1"
    :> "query_range"
    :> QueryParam "query" Text
    :> QueryParam "limit" Int
    :> QueryParam "start" Text
    :> QueryParam "end" Text
    :> QueryParam "direction" Text
    :> Get '[JSON] LokiResponse

lokiApi :: Proxy LokiAPI
lokiApi = Proxy

lokiClient :: Maybe Text -> Maybe Int -> Maybe Text -> Maybe Text -> Maybe Text -> S.ClientM LokiResponse
lokiClient = S.client lokiApi

lokiQuery :: Cluster -> Maybe Text -> Maybe Int -> Maybe Text -> Maybe Text -> Maybe Text -> WebApp LokiResponse
lokiQuery cluster query limit start end directionRaw = do
  res <- liftIO $ S.runClientM (lokiClient query limit start end direction) (lokiClientEnv (clusterLokiClientEnv cluster))
  case res of
    Left err -> do
      logInfoText $ "Loki request failed: " <> tshow err
      respondError $ InternalError $ pack $ "Error querying Loki: " ++ show err
    Right r -> do
      logInfoText $ "Loki request successful: " <> lokiResponseSummary r
      return r
  where
    lokiClientEnv clientEnv = clientEnv
      { S.makeClientRequest = \url req -> do
          result <- S.makeClientRequest clientEnv url req
          return $ result {responseTimeout = responseTimeoutMicro 30000000}
      }
    -- old cloud client workaround for https://github.com/unisoncomputing/cloud-api/pull/586
    direction = case directionRaw of
                  Just "true" -> Just "backward"
                  Just "false" -> Just "forward"
                  s -> s

convertLokiResponse :: LokiResponse -> LogQueryResult
convertLokiResponse (LokiResponse _ (LokiData streams)) =
  LogQueryResult numLines lines
  where
    lines =
      map (\(LogLine (_, t)) -> t) $
        sort $
          concatMap (\(LokiStream s) -> s) streams
    numLines = length lines

userIdStr :: UserId -> Text
userIdStr (UserId i) = pack $ filter (/= '-') $ toString i

dropBackticks :: Text -> Text
dropBackticks = replace "`" ""

userLogQuery :: Cluster -> ClusterConfig -> UserId  -> Maybe Text -> Maybe Int -> Maybe Text -> Maybe Text -> Maybe Text -> WebApp LogQueryResult
userLogQuery cluster clusterConfig userId search limit start end direction = do
  let userText = maybe "" (\s -> "|= `" <> dropBackticks s <> "`") search
  let uid = userIdStr userId
  let query = "{job=`nomad_allocs`, namespace=`user`,task_name=`" <> clusterConfig.clusterLokiTaskName <>  "`} | userId=`" <> uid <> "`" <> userText
  convertLokiResponse <$> lokiQuery cluster (Just query) limit start end direction

servicesLogQuery :: Cluster -> ClusterConfig -> UserId -> DeploymentHash -> Maybe Text -> Maybe Int -> Maybe Text -> Maybe Text -> Maybe Text -> WebApp LogQueryResult
servicesLogQuery cluster clusterConfig userId hash search limit start end direction = do
  let text = maybe "" (\s -> "|= `" <> dropBackticks s <> "`") search
  let uid = userIdStr userId
  let query = "{job=`nomad_allocs`, namespace=`user`, task_name=`" <> clusterConfig.clusterLokiTaskName <>  "`} | userId=`" <> uid <> "` |=`" <> tshow hash <> "` " <> text
  convertLokiResponse <$> lokiQuery cluster (Just query) limit start end direction
