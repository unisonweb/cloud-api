{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE RecordWildCards #-}
-- Manipulating JWT claims with addClaim etc. directly is deprecated, so we'll need to fix that eventually.
-- The new way appears to be to define custom types with JSON instances and use those to encode/decode the JWT;
-- see https://github.com/frasertweedale/hs-jose/issues/116
-- https://github.com/unisonweb/unison/issues/5153
{-# OPTIONS_GHC -Wno-deprecations #-}

{- Endpoints which are only active on the local deployment -}
module Cloud.Web.Local.Impl where

import Cloud.App (AppM)
-- import Cloud.Deployment qualified as Deployment
import Cloud.Env
import Cloud.Errors
    ( InternalServerError(InternalServerError),
      ErrorID(ErrorID),
      respondError )
import Cloud.Errors qualified as Errors
import Cloud.Postgres qualified as PG
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.User.Types
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.App
import Cloud.Web.Errors qualified as Errors
import Cloud.Web.Local.API
import Control.Lens
import Control.Monad.Random (randomIO)
import Control.Monad.Reader
import Crypto.JWT (SignedJWT)
import Crypto.JWT qualified as JWT
import Data.Aeson (ToJSON (toJSON))
import Data.Set qualified as Set
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime, nominalDay)
import Servant
import Servant.Auth.Server
import Share.JWT (JWTParam (..))
import Share.JWT qualified as ShareJWT
import Share.OAuth.Scopes (Scopes (Scopes))
import Share.OAuth.Scopes qualified as Scopes
import Share.OAuth.Session (Session)
import Share.OAuth.Session qualified as Session
import Share.OAuth.Types (AccessToken (..), JTI (JTI), SessionId (SessionId), UserId)
import Share.Utils.IDs qualified as IDs
import Cloud.User.Env (AuthEnv(..))
import Cloud.Postgres.App (postgresM)
import Cloud.User.Impl (enlilIssuer, enlilAud)
import Cloud.User.App (authM)
import qualified Cloud.Deployment as Deployment

-- | Login to the specified user without checking credentials.
-- Only available when running locally.
localLoginEndpoint :: UserHandle -> WebApp (Headers '[Header "Set-Cookie" SetCookie] Text)
localLoginEndpoint userHandle = do
  (User {user_id}) <-
    postgresM (PG.runTransaction (Q.userByHandle userHandle)) >>= \case
      Nothing -> Errors.respondError $ Errors.EntityMissing (ErrorID "no-user-for-handle") "No user for this handle"
      Just u -> pure u

  iss <- enlilIssuer
  aud <- enlilAud

  session <- liftIO $ Session.createSession iss (Set.singleton aud) user_id
  setSessionCookie session >>= \case
    Nothing -> Errors.respondError $ Errors.InternalServerError "local:failed-create-session" ("Failed to create session" :: Text)
    Just setAuthHeaders -> do
      pure $ setAuthHeaders "Logged in to the test account."
  where
    setSessionCookie :: (AddHeader "Set-Cookie" SetCookie resp resp') => Session -> WebApp (Maybe (resp -> resp'))
    setSessionCookie sess = authM $ do
      AuthEnv {envSessionCookieName, envCookieSettings, envJwtSettings} <- ask
      liftIO (ShareJWT.createSignedCookie envJwtSettings envCookieSettings envSessionCookieName sess) >>= \case
        Left _err -> pure Nothing
        Right cookie -> pure . Just $ addHeader @"Set-Cookie" cookie

data AccessTokenClaims = AccessTokenClaims
  { standardClaims :: ShareJWT.StandardClaims,
    scope :: Scopes
  }

instance ShareJWT.AsJWTClaims AccessTokenClaims where
  toClaims (AccessTokenClaims {standardClaims, scope}) =
    ShareJWT.toClaims standardClaims
      & ShareJWT.addClaim "scope" scope

  fromClaims claims = do
    standardClaims <- ShareJWT.fromClaims @ShareJWT.StandardClaims claims
    scope <- ShareJWT.getClaim "scope" claims
    pure $ AccessTokenClaims {..}

addStandardClaims :: ShareJWT.StandardClaims -> JWT.ClaimsSet -> JWT.ClaimsSet
addStandardClaims (ShareJWT.StandardClaims sub iat exp iss aud jti) claims =
  claims
    & JWT.claimSub ?~ (JWT.string # IDs.toText sub)
    & JWT.claimIat ?~ JWT.NumericDate iat
    & JWT.claimExp ?~ JWT.NumericDate exp
    & JWT.claimIss ?~ (JWT.uri # iss)
    & JWT.claimAud ?~ JWT.Audience (Set.toList aud <&> review JWT.uri)
    & JWT.claimJti ?~ jti

addJSONClaim :: (ToJSON a) => Text -> a -> JWT.ClaimsSet -> JWT.ClaimsSet
addJSONClaim name a =
  JWT.addClaim name (toJSON a)

jwtHeader :: JWT.JWSHeader ()
jwtHeader = JWT.newJWSHeader ((), JWT.HS256)

signJWT :: (ShareJWT.AsJWTClaims a) => a -> WebApp SignedJWT
signJWT val = do
  jwtSettings <- asks (envJwtSettings . authEnv)
  ShareJWT.signJWT jwtSettings val >>= \case
    Left (err :: JWT.JWTError) -> respondError (InternalServerError "jwt:signing-error" err)
    Right a -> pure a

newStandardClaims :: URI -> UserId -> NominalDiffTime -> SessionId -> AppM reqCtx ShareJWT.StandardClaims
newStandardClaims aud sub ttl (SessionId sessionIdUUID) = do
  iat <- liftIO getCurrentTime
  let exp = addUTCTime ttl iat
  let jti = IDs.toText $ JTI sessionIdUUID
  iss <- enlilIssuer
  pure (ShareJWT.StandardClaims {sub = IDs.toText sub, aud = Set.singleton aud, ..})

createAccessToken :: URI -> UserId -> SessionId -> Scopes -> WebApp AccessToken
createAccessToken aud userID sessionID scope = do
  let accessTokenTTL :: NominalDiffTime
      accessTokenTTL = 300 * nominalDay

  standardClaims <- newStandardClaims aud userID accessTokenTTL sessionID
  let accessTokenClaims = AccessTokenClaims {scope, standardClaims}
  signedJWT <- signJWT accessTokenClaims
  pure (AccessToken (JWTParam signedJWT))

-- | Return an access token for the specified user.
-- Only available when running locally.
localAccessTokenEndpoint ::
  UserHandle ->
  WebApp Text
localAccessTokenEndpoint userHandle = do
  (User {user_id}) <-
    postgresM (PG.runTransaction (Q.userByHandle userHandle)) >>= \case
      Nothing -> Errors.respondError $ Errors.EntityMissing (ErrorID "no-user-for-handle") "No user for this handle"
      Just u -> pure u
  sessionID <- randomIO
  aud <- enlilAud
  AccessToken (JWTParam accessToken) <- createAccessToken aud user_id sessionID (Scopes $ Set.fromList [Scopes.OpenId])
  pure (ShareJWT.signedJWTToText accessToken)

-- | All of these endpoints are only accessible on the local deployment, otherwise they just 404.
server :: ServerT API WebApp
server = do
  let userRoutes userHandle =
        localLoginEndpoint userHandle
          :<|> localAccessTokenEndpoint userHandle
  hoistServer (Proxy @API) guardLocal userRoutes
  where
    -- Local endpoints should just 404 on any other deployment.
    guardLocal :: forall x. WebApp x -> WebApp x
    guardLocal m =
      if Deployment.onLocal
        then m
        else Errors.respondError $ Errors.EntityMissing (ErrorID "local-on-nonlocal") "Not Found"
