{-# LANGUAGE OverloadedRecordDot #-}

module Cloud.Service.Impl
  ( servicesV2Endpoint,
    servicesV1Endpoint,
  )
where

import Cloud.Deployment.DeploymentHash (DeploymentHash (..))
import Cloud.Byoc.Env
    ( ClusterConfig (..), ClusterId (..) )
import Cloud.Postgres.Ops qualified as PGO
import Cloud.Prelude
import Cloud.Service.API
import Cloud.Service.Types
import Cloud.Web.App (WebApp)
import Share.OAuth.Types (UserId)
import Servant
import Cloud.User.Types (User (User))
import Cloud.Byoc.Impl (clusterByHost, clusterServiceURI)
import Cloud.Web.Types (CloudApiHost)
import Cloud.Postgres.Ops.Byoc (clusterConfigByHostname)

servicesV1Endpoint :: ServerT ServiceV1API WebApp
servicesV1Endpoint =
  serviceCreateEndpoint
    :<|> serviceSetEndpointV1
    :<|> serviceUnassignEndpoint
    :<|> serviceGetEndpoint
    :<|> serviceGetHistoryEndpoint
    :<|> serviceDeleteEndpoint
    :<|> serviceListEndpoint
    :<|> serviceTagsEndpoint
    :<|> serviceAllTagsEndpoint
    :<|> serviceByTagEndpoint
    :<|> serviceUntaggedEndpoint
    :<|> serviceSetTagEndpoint
    :<|> serviceDeleteTagEndpoint

servicesV2Endpoint :: ServerT ServiceV2API WebApp
servicesV2Endpoint =
  serviceCreateEndpoint
    :<|> serviceSetEndpointV2
    :<|> serviceUnassignEndpoint
    :<|> serviceGetEndpoint
    :<|> serviceGetHistoryEndpoint
    :<|> serviceDeleteEndpoint
    :<|> serviceListEndpoint
    :<|> serviceTagsEndpoint
    :<|> serviceAllTagsEndpoint
    :<|> serviceByTagEndpoint
    :<|> serviceUntaggedEndpoint
    :<|> serviceSetTagEndpoint
    :<|> serviceDeleteTagEndpoint

serviceCreateEndpoint :: UserId -> CloudApiHost -> Maybe UserId -> ServiceName -> WebApp ServiceId
serviceCreateEndpoint uid host maybeOwner sn = do
  let ownerId = fromMaybe uid maybeOwner
  clusterId <- PGO.clusterIdByHost host
  PGO.createService clusterId uid ownerId sn

serviceSetEndpoint_ :: ClusterId -> UserId -> ServiceId -> DeploymentHash -> WebApp (User, ServiceName)
serviceSetEndpoint_ = PGO.setServiceId

serviceSetEndpointV1 :: UserId -> CloudApiHost -> ServiceId -> DeploymentHash -> WebApp NoContent
serviceSetEndpointV1 s host h d = do
  cluster <- clusterByHost host
  serviceSetEndpoint_ cluster s h d $> NoContent

serviceSetEndpointV2 :: UserId -> CloudApiHost -> ServiceId -> DeploymentHash -> WebApp ServiceURI
serviceSetEndpointV2 uid host service deployment = do
  clusterCfg <- clusterConfigByHostname host
  (User _ _ _ _ userHandle _, serviceName) <- serviceSetEndpoint_ clusterCfg.clusterId uid service deployment
  ServiceURI <$> clusterServiceURI clusterCfg userHandle serviceName

serviceUnassignEndpoint :: UserId -> CloudApiHost -> ServiceId -> WebApp NoContent
serviceUnassignEndpoint uid host sid = do
  clusterId <- PGO.clusterIdByHost host
  PGO.unassignService clusterId uid sid
  pure NoContent

serviceGetEndpoint :: UserId -> CloudApiHost -> ServiceId -> WebApp ServiceDetail
serviceGetEndpoint uid host name = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getServiceId clusterId uid name

serviceGetHistoryEndpoint :: UserId -> CloudApiHost -> ServiceId -> WebApp [ServiceAssignment]
serviceGetHistoryEndpoint uid host name = do
  clusterId <- PGO.clusterIdByHost host
  PGO.getServiceHistory clusterId uid name

serviceDeleteEndpoint :: UserId -> CloudApiHost -> ServiceId -> WebApp NoContent
serviceDeleteEndpoint uid host sid = do
  cluster <- clusterByHost host
  PGO.deleteService cluster uid sid
  pure NoContent

serviceListEndpoint :: UserId -> CloudApiHost -> WebApp [ServiceDetail]
serviceListEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listServices clusterId uid

serviceTagsEndpoint :: UserId -> CloudApiHost -> ServiceId -> WebApp [Text]
serviceTagsEndpoint uid host serviceId = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listServiceTags clusterId uid serviceId

serviceAllTagsEndpoint :: UserId -> CloudApiHost -> WebApp [Text]
serviceAllTagsEndpoint userId host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listAllServiceTags clusterId userId

serviceByTagEndpoint :: UserId -> CloudApiHost ->  Text -> WebApp [ServiceDetail]
serviceByTagEndpoint uid host tag = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listServicesByTag clusterId uid (Just tag)

serviceSetTagEndpoint :: UserId -> CloudApiHost -> ServiceId -> Text -> WebApp NoContent
serviceSetTagEndpoint uid host serviceId tags = do
  clusterId <- PGO.clusterIdByHost host
  PGO.setServiceTag clusterId uid serviceId tags
  pure NoContent

serviceDeleteTagEndpoint :: UserId -> CloudApiHost -> ServiceId -> Text -> WebApp NoContent
serviceDeleteTagEndpoint uid host serviceId tags = do
  clusterId <- PGO.clusterIdByHost host
  PGO.unsetServiceTag clusterId uid serviceId tags
  pure NoContent

serviceUntaggedEndpoint :: UserId -> CloudApiHost -> WebApp [ServiceDetail]
serviceUntaggedEndpoint uid host = do
  clusterId <- PGO.clusterIdByHost host
  PGO.listUntaggedServices clusterId uid

