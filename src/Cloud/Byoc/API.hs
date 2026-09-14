{-# LANGUAGE DataKinds #-}

module Cloud.Byoc.API
  ( ByocAPI,
  )
where

import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Prelude
import Cloud.Web.Types (ByocUserJWT, CloudApiHost, DeploymentURI, EnvironmentId, HttpServiceVersion, NimbusRedirect)
import Servant
import Share.OAuth.Session (AuthenticatedUserId)
import Cloud.Byoc.Env (ClusterId, ClusterToken, SchemeType)
import Share.OAuth.Types (UserId)
import Cloud.Service.Types (ServiceId)

type ByocAPI =
  ( Header' [Required, Strict] "Authorization" ByocUserJWT
      :> "publish"
      :> ( ("webservice" :> ByocExposeAPI)
             :<|> ("webservice" :> ByocUnexposeAPI)
             :<|> ("nativeservice" :> ByocDeploymentAPI)
             :<|> ("nativeservice" :> ByocUndeployAPI)
             :<|> ("daemon-hashes" :> (ByocUploadedDaemonHashAPI :<|> ByocDeletedDaemonHashAPI))
             :<|> ("environment" :> ByocEnvironmentDeleteAPI)
             :<|> ("environmentValue" :> ByocEnvironmentDeleteValueAPI)
         )
  )
    :<|> ( AuthenticatedUserId
             :> ( ( "deployments"
                      :> ( DeploymentCreateByocAPI
                             :<|> DeploymentDeleteByocAPI
                             :<|> DeploymentExposeByocAPI
                             :<|> DeploymentUnexposeByocAPI
                         )
                  )
                    :<|> ( "daemon-hashes"
                             :> ( DaemonHashCreateByocAPI
                                    :<|> DaemonHashDeleteByocAPI
                                )
                         )
                    :<|> ( "environments"
                             :> ( CreateEnvironmentAPI
                                    :<|> SetEnvironmentValueAPI
                                    :<|> DeleteEnvironmentValueAPI
                                    :<|> DeleteEnvironmentAPI
                                )
                         )
                    :<|> ("jobs" :> SubmitJobAPI)
                    :<|> ("logs" :> (QueryUserLogsAPI :<|> QueryDeploymentLogsAPI :<|> QueryServiceLogsAPI))
                     :<|> ( "clusters"
                              :> ( CreateClusterAPI
                                    :<|>  ClusterSetClusterURIAPI
                                    :<|>  ClusterGetClusterTokenAPI
                                )
                            )
                )
         )

type CreateEnvironmentAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam "owner" UserId
    :> Capture "environment" Text
    :> Post '[JSON] NimbusRedirect

type SetEnvironmentValueAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "environment" EnvironmentId
    :> Put '[JSON] NimbusRedirect

type DeleteEnvironmentValueAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "environment" EnvironmentId
    :> Capture "name" Text
    :> Delete '[JSON] NimbusRedirect

type DeleteEnvironmentAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "environment" EnvironmentId
    :> Delete '[JSON] NimbusRedirect

type DeploymentCreateByocAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam "owner" UserId
    :> QueryParam' [Required, Strict] "environmentId" EnvironmentId
    :> "create"
    :> Post '[JSON] NimbusRedirect

type DaemonHashCreateByocAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam "owner" UserId
    :> QueryParam' [Required, Strict] "environmentId" EnvironmentId
    :> "create"
    :> Post '[JSON] NimbusRedirect

type DeploymentDeleteByocAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "hash" DeploymentHash
    :> Delete '[JSON] NimbusRedirect

type DaemonHashDeleteByocAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "hash" DeploymentHash
    :> Delete '[JSON] NimbusRedirect

type DeploymentExposeByocAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> "expose"
    :> Capture "hash" DeploymentHash
    :> Post '[JSON] NimbusRedirect

type DeploymentUnexposeByocAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> "unexpose"
    :> Capture "hash" DeploymentHash
    :> Delete '[JSON] NimbusRedirect

type ByocDeploymentAPI =
  Capture "deploymentHash" DeploymentHash
    :> PostNoContent

type ByocUploadedDaemonHashAPI =
  Capture "daemonHash" DeploymentHash
    :> PostNoContent

type ByocExposeAPI =
  QueryParam' [Required, Strict] "httpServiceVersion" HttpServiceVersion
    :> Post '[JSON] DeploymentURI

type ByocUnexposeAPI = DeleteNoContent

type ByocUndeployAPI = DeleteNoContent

type ByocDeletedDaemonHashAPI = DeleteNoContent

type ByocEnvironmentDeleteAPI =
  DeleteNoContent

type ByocEnvironmentDeleteValueAPI =
  DeleteNoContent

type SubmitJobAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam "ownerId" UserId
    :> QueryParam' [Required, Strict] "environmentId" EnvironmentId
    :> Post '[JSON] NimbusRedirect

type QueryUserLogsAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam  "ownerId" UserId
    :> Get '[JSON] NimbusRedirect

type QueryDeploymentLogsAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> "deployment"
    :> Capture "hash" DeploymentHash
    :> Get '[JSON] NimbusRedirect

type QueryServiceLogsAPI =
  Header' [Required, Strict] "Host" CloudApiHost
    :> "service"
    :> Capture "service" ServiceId
    :> Get '[JSON] NimbusRedirect

type CreateClusterAPI =
    Capture "name" Text
    :> QueryParam "owner" UserId
    :> QueryParam "clusterUri" Text
    :> QueryParam "uriStyle" SchemeType
    :> Post '[PlainText] ClusterId

type ClusterSetClusterURIAPI =
  Capture "clusterId" ClusterId
  :> "clusterUri"
  :> ReqBody '[JSON] Text
  :> PostNoContent

type ClusterGetClusterTokenAPI =
  Capture "clusterId" ClusterId
  :> "token"
    :> Post '[PlainText] ClusterToken
