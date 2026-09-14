{-# LANGUAGE DataKinds #-}

module Cloud.Service.API
  ( ServiceV1API,
    ServiceV2API,
  )
where

import Cloud.Deployment.DeploymentHash
import Cloud.Prelude
import Cloud.Service.Types
import Share.OAuth.Session
import Servant
import Cloud.Web.Types (CloudApiHost)
import Share.OAuth.Types (UserId)

type ServiceV1API =
  "services"
    :> ( ServiceCreateAPI
           :<|> ServiceSetV1API
           :<|> ServiceUnassignAPI
           :<|> ServiceGetAPI
           :<|> ServiceGetHistoryAPI
           :<|> ServiceDeleteAPI
           :<|> ServiceListAPI
           :<|> ServiceTagsAPI
           :<|> ServiceAllTagsAPI
           :<|> ServiceByTagAPI
           :<|> ServicesWithoutTagAPI
           :<|> ServiceSetTagAPI
           :<|> ServiceDeleteTagAPI
       )

type ServiceV2API =
  "services"
    :> ( ServiceCreateAPI
           :<|> ServiceSetV2API
           :<|> ServiceUnassignAPI
           :<|> ServiceGetAPI
           :<|> ServiceGetHistoryAPI
           :<|> ServiceDeleteAPI
           :<|> ServiceListAPI
           :<|> ServiceTagsAPI
           :<|> ServiceAllTagsAPI
           :<|> ServiceByTagAPI
           :<|> ServicesWithoutTagAPI
           :<|> ServiceSetTagAPI
           :<|> ServiceDeleteTagAPI
       )

type ServiceCreateAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam "owner" UserId
    :> Capture "name" ServiceName
    :> Post '[PlainText] ServiceId

type ServiceSetV1API =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "service" ServiceId
    :> "assign"
    :> Capture "hash" DeploymentHash
    :> Post '[JSON] NoContent

type ServiceSetV2API =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "service" ServiceId
    :> "assign"
    :> Capture "hash" DeploymentHash
    :> Post '[JSON] ServiceURI

type ServiceUnassignAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "service" ServiceId
    :> "unassign"
    :> Post '[JSON] NoContent

type ServiceGetAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "id" ServiceId
    :> Get '[JSON] ServiceDetail

type ServiceGetHistoryAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "id" ServiceId
    :> "deployments"
    :> Get '[JSON] [ServiceAssignment]

type ServiceDeleteAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "id" ServiceId
    :> Delete '[JSON] NoContent

type ServiceListAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Get '[JSON] [ServiceDetail]

type ServiceTagsAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "id" ServiceId
    :> "tags"
    :> Get '[JSON] [Text]

type ServiceAllTagsAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "tags"
    :> Get '[JSON] [Text]

type ServiceByTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "tags"
    :> Capture "tag" Text
    :> Get '[JSON] [ServiceDetail]

type ServicesWithoutTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "untagged"
    :> Get '[JSON] [ServiceDetail]

type ServiceSetTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "id" ServiceId
    :> "tags"
    :> Capture "tag" Text
    :> Post '[JSON] NoContent

type ServiceDeleteTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "id" ServiceId
    :> "tags"
    :> Capture "tag" Text
    :> Delete '[JSON] NoContent
