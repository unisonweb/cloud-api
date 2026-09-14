{-# LANGUAGE DataKinds #-}

module Cloud.Environment.API
  ( EnvironmentAPI,
  )
where

import Cloud.Environment.Types (UserEnvironment)
import Cloud.Prelude
import Share.OAuth.Session
import Servant
import Cloud.Web.Types (EnvironmentId, CloudApiHost)

type EnvironmentAPI =
  "environments"
    :> ( CreateEnvironmentAPI
           :<|> SetEnvironmentValueAPI
           :<|> DeleteEnvironmentValueAPI
           :<|> DeleteEnvironmentAPI
           :<|> ListEnvironmentsAPI
       )

type CreateEnvironmentAPI =
  AuthenticatedUserId
    :> Capture "environment" Text
    :> Post '[PlainText] EnvironmentId

type SetEnvironmentValueAPI =
  AuthenticatedUserId
    :> Capture "environment" EnvironmentId
    :> Capture "name" Text
    :> ReqBody '[PlainText] Text
    :> Post '[JSON] NoContent

type DeleteEnvironmentValueAPI =
  AuthenticatedUserId
    :> Capture "environment" EnvironmentId
    :> Capture "name" Text
    :> Delete '[JSON] NoContent

type DeleteEnvironmentAPI =
  AuthenticatedUserId
    :> Capture "environment" EnvironmentId
    :> Delete '[JSON] NoContent

type ListEnvironmentsAPI =
  AuthenticatedUserId
    :> Header' [Required, Strict] "Host" CloudApiHost
    :> Get '[JSON] [UserEnvironment]
