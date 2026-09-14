{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}

{- Endpoints which are only active on the local deployment -}
module Cloud.Web.Local.API (API) where

import Cloud.Prelude
import Cloud.User.UserHandle (UserHandle)
import Servant
import Servant.Auth.Server

type API =
  ( "user"
      :> Capture "user_handle" UserHandle
      :> ( "login" :> LocalLoginEndpoint
             :<|> "access-token" :> LocalAccessTokenEndpoint
         )
  )

-- | GET /local/login
-- Logs the user in to the specified account without needing to redirect through an
-- auth provider.
type LocalLoginEndpoint =
  Get '[PlainText] (Headers '[Header "Set-Cookie" SetCookie] Text)

-- | GET /local/access-token
-- Gets an access token for the specified user.
type LocalAccessTokenEndpoint =
  Get '[PlainText] Text
