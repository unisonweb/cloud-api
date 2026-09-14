{-# LANGUAGE DataKinds #-}

module Cloud.Daemon.API where

import Cloud.Daemon.Types (DaemonAssignment, DaemonDetails, DaemonId, DaemonName)
import Cloud.Deployment.DeploymentHash (DeploymentHash)
import Cloud.Prelude
import Data.ByteString qualified as BS
import Servant
import Share.OAuth.Session (AuthenticatedUserId)
import Cloud.Web.Types (EnvironmentId, CloudApiHost)
import Share.OAuth.Types (UserId)

type DaemonAPI =
  ( "daemon-hashes"
      :> ( DaemonCreateAPI
             :<|> DaemonDeleteAPI
         )
  )
    :<|> ( "daemons"
             :> ( DaemonListAPI
                    :<|> DaemonGetAPI
                    :<|> DaemonNameCreateAPI
                    :<|> DaemonNameDeleteAPI
                    :<|> DaemonAssignAPI
                    :<|> DaemonUnassignAPI
                    :<|> DaemonGetHistoryAPI
                    :<|> DaemonTagsAPI
                    :<|> DaemonAllTagsAPI
                    :<|> DaemonByTagAPI
                    :<|> DaemonsWithoutTagAPI
                    :<|> DaemonSetTagAPI
                    :<|> DaemonDeleteTagAPI
                )
         )

type DaemonCreateAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam' [Required, Strict] "environmentId" EnvironmentId
    :> ReqBody '[OctetStream] BS.ByteString
    :> Post '[PlainText] DeploymentHash

type DaemonDeleteAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DeploymentHash
    :> DeleteNoContent

type DaemonListAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Get '[JSON] [DaemonDetails]

type DaemonGetAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> Get '[JSON] DaemonDetails

type DaemonNameCreateAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> QueryParam "owner" UserId
    :> Capture "daemon" DaemonName
    :> Post '[PlainText] DaemonId

type DaemonNameDeleteAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> DeleteNoContent

type DaemonAssignAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> "assign"
    :> Capture "hash" DeploymentHash
    :> PostNoContent

type DaemonUnassignAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> "unassign"
    :> PostNoContent

type DaemonGetHistoryAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> "history"
    :> Get '[JSON] [DaemonAssignment]

type DaemonTagsAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> "tags"
    :> Get '[JSON] [Text]

type DaemonAllTagsAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "tags"
    :> Get '[JSON] [Text]

type DaemonByTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "tags"
    :> Capture "tag" Text
    :> Get '[JSON] [DaemonDetails]

type DaemonsWithoutTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "tags"
    :> "untagged"
    :> Get '[JSON] [DaemonDetails]

type DaemonSetTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> "tags"
    :> Capture "tag" Text
    :> PostNoContent

type DaemonDeleteTagAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "daemon" DaemonId
    :> "tags"
    :> Capture "tag" Text
    :> DeleteNoContent
