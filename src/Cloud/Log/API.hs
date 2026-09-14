{-# LANGUAGE DataKinds #-}

module Cloud.Log.API
  ( LogsAPI,
  )
where

import Cloud.Deployment.DeploymentHash
import Cloud.Log.Types
import Cloud.Prelude
import Cloud.Service.Types
import Share.OAuth.Session
import Servant
import Cloud.Web.Types (CloudApiHost)

type LogsAPI = "logs" :> (LogsByUserAPI :<|> LogsByDeploymentAPI :<|> LogsByServiceAPI)

type LogsByUserAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam "search" Text
    :> QueryParam "limit" Int
    :> QueryParam "start" Text
    :> QueryParam "end" Text
    :> QueryParam "direction" Text
    :> Get '[JSON] LogQueryResult

type LogsByDeploymentAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "deployment"
    :> Capture "hash" DeploymentHash
    :> QueryParam "search" Text
    :> QueryParam "limit" Int
    :> QueryParam "start" Text
    :> QueryParam "end" Text
    :> QueryParam "direction" Text
    :> Get '[JSON] LogQueryResult

type LogsByServiceAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "service"
    :> Capture "service" ServiceId
    :> QueryParam "search" Text
    :> QueryParam "limit" Int
    :> QueryParam "start" Text
    :> QueryParam "end" Text
    :> QueryParam "direction" Text
    :> Get '[JSON] LogQueryResult
