{-# LANGUAGE DataKinds #-}

module Cloud.Storage.API
  ( StoragePoolAPI,
  )
where

import Cloud.Storage.Types
import Share.OAuth.Session
import Servant
import Cloud.Web.Types (EnvironmentId, CloudApiHost)
import Share.OAuth.Types (UserId)

type StoragePoolAPI =
  "storage"
    :> ( StoragePoolCreateAPI
           :<|> StoragePoolGetAPI
           :<|> StoragePoolDeleteAPI
           :<|> StoragePoolListAPI
           :<|> StoragePoolAssignEnvAPI
           :<|> StoragePoolUnassignEnvAPI
       )

type StoragePoolCreateAPI =
  AuthenticatedUserId
    :> QueryParam "owner" UserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> "create"
    :> Capture "name" StoragePoolName
    :> Post '[PlainText] StoragePoolId

type StoragePoolGetAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "pool" StoragePoolId
    :> Get '[JSON] (Maybe StoragePool)

type StoragePoolDeleteAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "pool" StoragePoolId
    :> Delete '[JSON] NoContent

type StoragePoolAssignEnvAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "pool" StoragePoolId
    :> "assign"
    :> Capture "env" EnvironmentId
    :> Post '[JSON] NoContent

type StoragePoolListAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Get '[JSON] [StoragePool]

type StoragePoolUnassignEnvAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Capture "pool" StoragePoolId
    :> "unassign"
    :> Capture "env" EnvironmentId
    :> Post '[JSON] NoContent
