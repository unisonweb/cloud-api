{-# LANGUAGE DataKinds #-}

module Cloud.Web.Cluster.API
  ( ClusterAPI,
    JoinAPI,
    ProtocolVersion (..),
  )
where

import Cloud.Byoc.Env (ClusterToken)
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Internal.Types
import Cloud.Web.Types (EnvironmentId, ServiceId, ServiceName)
import Servant
import Servant.API.WebSocket (WebSocketPending)

data ProtocolVersion = V1 | V2

instance FromHttpApiData ProtocolVersion where
  parseQueryParam "1" = Right V1
  parseQueryParam "2" = Right V2
  parseQueryParam o = Left $ "Unsupported protocol version: " <> o

type JoinAPI =
  QueryParam' [Required, Strict] "protocolVersion" ProtocolVersion
    :> WebSocketPending

type ClusterAPI =
  ( Header' [Required, Strict] "Authorization" ClusterToken
      :> "join"
      :> JoinAPI
  )
    :<|> ( Header' [Required, Strict] "Authorization" ClusterToken
             :> "userByHandle"
             :> Capture "user" UserHandle
             :> Get '[JSON] UserIdResult
         )
    :<|> ( Header' [Required, Strict] "Authorization" ClusterToken
             :> "storageByEnvironmentId"
             :> Capture "environment" EnvironmentId
             :> Get '[JSON] [StoragePoolIdResult]
         )
    :<|> ( Header' [Required, Strict] "Authorization" ClusterToken
             :> "deploymentByServiceId"
             :> Capture "serviceId" ServiceId
             :> Get '[JSON] DeploymentHashResult
         )
    :<|> ( Header' [Required, Strict] "Authorization" ClusterToken
             :> "deploymentByServiceName"
             :> Capture "userHandle" UserHandle
             :> Capture "serviceName" ServiceName
             :> Get '[JSON] DeploymentHashResult
         )
