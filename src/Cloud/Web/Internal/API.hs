{-# LANGUAGE DataKinds #-}

module Cloud.Web.Internal.API where

import Cloud.Service.Types (ServiceId, ServiceName)
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Internal.Types
import Servant
import Cloud.Consul.API (ServiceInstanceId)
import Cloud.Byoc.Env (ClusterId, Event, PeerNodeResult)
import Cloud.Web.Types (EnvironmentId, CloudApiHost)
import Data.Text (Text)

type API =
  ( "userByHandle"
      :> Capture "user" UserHandle
      :> Get '[JSON] UserIdResult
  )
    :<|> ("storageByEnvironmentId")
      :> Header' [Required, Strict] "Host" CloudApiHost
      :> Capture "environment" EnvironmentId
      :> Get '[JSON] [StoragePoolIdResult]
    :<|> ("deploymentByServiceId")
      :> Header' [Required, Strict] "Host" CloudApiHost
      :> Capture "serviceId" ServiceId
      :> Get '[JSON] DeploymentHashResult
    :<|> ("deploymentByServiceName")
      :> Header' [Required, Strict] "Host" CloudApiHost
      :> Capture "userHandle" UserHandle
      :> Capture "serviceName" ServiceName
      :> Get '[JSON] DeploymentHashResult
    :<|> ("byoc"
        :> "health"
        :> Capture "clusterId" ClusterId
        :> Capture "instanceId" ServiceInstanceId
        :> Get '[JSON] NoContent)
    :<|> InvalidateRoute

-- | Internal cloud-api-to-cloud-api RPC: deliver an invalidation to the nodes
-- connected to the receiving instance, returning per-node results. Guarded by a
-- shared-secret header when CLOUD_INTERNAL_AUTH_TOKEN is set (optional so local
-- test environments without the secret keep working).
type InvalidateRoute =
  "invalidate"
    :> Header "X-Cloud-Internal-Auth" Text
    :> ReqBody '[JSON] Event
    :> Post '[JSON] [PeerNodeResult]

-- | The same route addressed from the server root (the internal API is mounted
-- under "internal"), used to derive the peer client.
type PeerInvalidateAPI = "internal" :> InvalidateRoute
