{-# LANGUAGE DataKinds #-}

module Cloud.Deployment.API
  ( DeploymentV1API,
    DeploymentV2API,
  )
where

import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Prelude
import Data.ByteString qualified as BS
import Share.OAuth.Session (AuthenticatedUserId)
import Servant
import Cloud.Web.Types (EnvironmentId, HttpServiceVersion, DeploymentURI, CloudApiHost, DeploymentDetails)

type DeploymentV1API =
  "deployments"
    :> ( DeploymentListUnassignedAPI
           :<|> DeploymentsWithoutTagAPI
           :<|> DeploymentAllTagsAPI
           :<|> DeploymentCreateAPI
           :<|> DeploymentGetAPI
           :<|> DeploymentListAPI
           :<|> DeploymentDestroyAPI
           :<|> DeploymentExposeV1API
           :<|> DeployUnexposeAPI
           :<|> DeploymentTagsAPI
           :<|> DeploymentByTagAPI
           :<|> DeploymentSetTagAPI
           :<|> DeploymentDeleteTagAPI
       )

type DeploymentV2API =
  "deployments"
    :> ( DeploymentListUnassignedAPI
           :<|> DeploymentsWithoutTagAPI
           :<|> DeploymentAllTagsAPI
           :<|> DeploymentCreateAPI
           :<|> DeploymentGetAPI
           :<|> DeploymentListAPI
           :<|> DeploymentDestroyAPI
           :<|> DeploymentExposeV2API
           :<|> DeployUnexposeAPI
           :<|> DeploymentTagsAPI
           :<|> DeploymentByTagAPI
           :<|> DeploymentSetTagAPI
           :<|> DeploymentDeleteTagAPI
       )

type DeploymentGetAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "hash" DeploymentHash
    :> Get '[JSON] DeploymentDetails

type DeploymentListAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Get '[JSON] [DeploymentDetails]

type DeploymentListUnassignedAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "unassigned"
    :> Get '[JSON] [DeploymentDetails]

type DeploymentCreateAPI =
  AuthenticatedUserId
    :> "create"
    :> QueryParam'[Required, Strict] "environmentId" EnvironmentId
    :> ReqBody '[OctetStream] BS.ByteString
    :> Post '[PlainText] DeploymentHash

type DeploymentDestroyAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "hash" DeploymentHash
    :> Delete '[JSON] NoContent

type DeploymentExposeV1API =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "expose"
    :> Capture "hash" DeploymentHash
    :> QueryParam "httpServiceVersion" HttpServiceVersion
    :> Post '[JSON] NoContent

type DeploymentExposeV2API =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "expose"
    :> Capture "hash" DeploymentHash
    :> QueryParam "httpServiceVersion" HttpServiceVersion
    :> Post '[JSON] DeploymentURI

type DeployUnexposeAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "unexpose"
    :> Capture "hash" DeploymentHash
    :> Delete '[JSON] NoContent

type DeploymentTagsAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "hash" DeploymentHash
    :> "tags"
    :> Get '[JSON] [Text]

type DeploymentAllTagsAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "tags"
    :> Get '[JSON] [Text]

type DeploymentByTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "tag"
    :> Capture "tag" Text
    :> Get '[JSON] [DeploymentDetails]

type DeploymentsWithoutTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "untagged"
    :> Get '[JSON] [DeploymentDetails]

type DeploymentSetTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "hash" DeploymentHash
    :> "tag"
    :> Capture "tag" Text
    :> Post '[JSON] NoContent

type DeploymentDeleteTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "hash" DeploymentHash
    :> "tag"
    :> Capture "tag" Text
    :> Delete '[JSON] NoContent
