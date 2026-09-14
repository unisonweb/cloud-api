module Cloud.User.Env
  ( AuthEnv (..),
  )
where

import Cloud.Prelude
import Network.URI (URI)
import Share.JWT qualified as JWT
import Share.OAuth.IdentityProvider.Types
import Share.Utils.Servant.Cookies qualified as Cookies
import Share.OAuth.ServiceProvider (ServiceProviderConfig)

data AuthEnv = AuthEnv
  { envCookieSettings :: Cookies.CookieSettings,
    envIdentityProvider :: IdentityProviderConfig,
    envJwtSettings :: JWT.JWTSettings,
    envShareOrigin :: URI, -- E.g. "https://api.unison-lang.org",
    envSpConfig :: ServiceProviderConfig,
    envSessionCookieName :: Text
  }