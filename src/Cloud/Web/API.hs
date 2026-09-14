{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

module Cloud.Web.API
  ( API,
    AccountAPI,
    api,
    CreateSubscription (..),
    CustomerInfo (..),
  )
where

import Cloud.Byoc.API (ByocAPI)
import Cloud.Daemon.API (DaemonAPI)
import Cloud.Deployment.API (DeploymentV1API, DeploymentV2API)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Domain.API (DomainAPI)
import Cloud.Environment.API
import Cloud.Log.API (LogsAPI)
import Cloud.Log.Types
import Cloud.Service.API (ServiceV1API, ServiceV2API)
import Cloud.Service.Types (ServiceAssignment, ServiceDetail, ServiceName, ServiceURI)
import Cloud.Storage.API (StoragePoolAPI)
import Cloud.Stripe.Types (Address, couponIdFromJSON)
import Cloud.User.Types
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.Internal.API qualified as Internal
import Cloud.Web.Local.API qualified as Local
import Cloud.Web.Types (IncompleteSubscription, StripeSignature, WithRawBody, CloudApiHost, DeploymentDetails)
import Crypto.JOSE.JWK qualified as JWK
import Data.Aeson.Types (FromJSON, Value, explicitParseFieldMaybe, parseJSON, withObject, (.:), (.:?))
import Data.Text
import Servant
import Share.OAuth.API
import Share.OAuth.Session (AuthenticatedUserId)
import Share.Utils.Servant.Cookies qualified as Cookies
import Share.Utils.URI (URIParam)
import Stripe.Concepts (CouponId)
import Cloud.Web.Cluster.API (ClusterAPI)

type API = ServiceProviderAPI :<|> CloudAPI

type CloudAPI =
  ( "v1"
      :> ( ("account" :> AccountAPI)
             :<|> ServiceV1API
             :<|> DeploymentV1API
             :<|> EnvironmentAPI
             :<|> LogsAPI
             :<|> StoragePoolAPI
             :<|> UserV1API
         )
  )
    :<|> ( "v2"
             :> ( ("account" :> AccountAPI)
                    :<|> ("acceptTerms" :> AuthenticatedUserId :> Post '[JSON] NoContent)
                    :<|> ("acceptTerms" :> AuthenticatedUserId :> Delete '[JSON] NoContent)
                    :<|> ServiceV2API
                    :<|> DeploymentV2API
                    :<|> EnvironmentAPI
                    :<|> LogsAPI
                    :<|> StoragePoolAPI
                    :<|> UserV2API
                    :<|> "stripe" :> StripeAPI
                    :<|> DaemonAPI
                    :<|> DomainAPI
                    :<|> "byoc" :> ByocAPI
                    :<|> "cluster" :> ClusterAPI
                )
         )
    :<|> ("internal" :> Internal.API)
    :<|> ("local" :> Local.API)
    :<|> ("enroll" :> EnrollFreeTierEndpoint)
    :<|> (".well-known" :> "jwks.json" :> JWKSEndpoint)

data CustomerInfo = CustomerInfo
  { customerInfoName :: !Text,
    customerInfoAddress :: !(Maybe Address)
  }

instance FromJSON CustomerInfo where
  parseJSON = withObject "CustomerInfo" $ \o -> do
    customerInfoName <- o .: "name"
    customerInfoAddress <- o .:? "address"
    pure CustomerInfo {..}

data CreateSubscription = CreateSubscription
  { cloudTier :: !CloudTier,
    couponId :: !(Maybe CouponId),
    customer :: !(Maybe CustomerInfo)
  }

instance FromJSON CreateSubscription where
  parseJSON = withObject "CreateSubscription" $ \o -> do
    cloudTier <- o .: "cloudTier"
    couponId <- explicitParseFieldMaybe couponIdFromJSON o "couponId"
    customer <- o .:? "customer"
    pure CreateSubscription {..}

type AccountAPI =
  (AuthenticatedUserId :> Get '[JSON] UserAccountInfo)
    :<|> ("subscription" :> AuthenticatedUserId :> ReqBody '[JSON] CreateSubscription :> Post '[JSON] IncompleteSubscription)

type SbtbAPI = AuthenticatedUserId :> "workshop" :> Get '[JSON] NoContent

-- Redirect through Share, creating an account if necessary, then enrolling in the free tier
-- of cloud upon success.
type EnrollFreeTierEndpoint =
  QueryParam "return_to" URIParam
    :> Verb 'GET 302 '[PlainText] (Headers '[Header "Set-Cookie" Cookies.SetCookie, Header "Location" String] NoContent)

-- Redirect through Share, creating an account if necessary, then enrolling in the free tier
-- of cloud upon success.
type EnrollPaidTeirEndpoint =
  QueryParam "return_to" URIParam
    :> Verb 'GET 302 '[PlainText] (Headers '[Header "Set-Cookie" Cookies.SetCookie, Header "Location" String] NoContent)


api :: Proxy API
api = Proxy

type UserV1API =
  "users"
    :> ( UserServiceGetAPI
           :<|> UserServiceGetHistoryAPI
           :<|> UserServiceCurrentDeploymentAPI
           :<|> UserUnassignServiceAPI
           :<|> UserAssignServiceV1API
           :<|> UserDeleteServiceAPI
           :<|> UserLogsByServiceAPI
       )

type UserV2API =
  "users"
    :> ( UserServiceGetAPI
           :<|> UserServiceGetHistoryAPI
           :<|> UserServiceCurrentDeploymentAPI
           :<|> UserUnassignServiceAPI
           :<|> UserAssignServiceV2API
           :<|> UserDeleteServiceAPI
           :<|> UserLogsByServiceAPI
       )

type UserServiceGetAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "services"
    :> Capture "service" ServiceName
    :> Get '[JSON] (Maybe ServiceDetail)

type UserServiceGetHistoryAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "services"
    :> Capture "service" ServiceName
    :> "deployments"
    :> Get '[JSON] [ServiceAssignment]

type UserServiceCurrentDeploymentAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "current"
    :> "deployment"
    :> Capture "service" ServiceName
    :> Get '[JSON] (Maybe DeploymentDetails)

type UserUnassignServiceAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "unassign"
    :> Capture "service" ServiceName
    :> Delete '[JSON] NoContent

type UserAssignServiceV1API =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "assign"
    :> Capture "service" ServiceName
    :> Capture "hash" DeploymentHash
    :> Post '[JSON] NoContent

type UserAssignServiceV2API =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "assign"
    :> Capture "service" ServiceName
    :> Capture "hash" DeploymentHash
    :> Post '[JSON] ServiceURI

type UserDeleteServiceAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "delete"
    :> Capture "service" ServiceName
    :> Delete '[JSON] NoContent

type UserLogsByServiceAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "user" UserHandle
    :> "logs"
    :> "service"
    :> Capture "service" ServiceName
    :> QueryParam "search" Text
    :> QueryParam "limit" Int
    :> QueryParam "start" Text
    :> QueryParam "end" Text
    :> QueryParam "direction" Text
    :> Get '[JSON] LogQueryResult

type JWKSEndpoint =
  Get '[JSON] JWK.JWKSet

-- Stripe

type StripeAPI =
  "events"
    :> Header' '[Required, Strict] "Stripe-Signature" StripeSignature
    :> ReqBody '[JSON] (WithRawBody Value)
    :> PostNoContent
