module Cloud.JWT (newStandardClaims) where

import Cloud.App (AppM)
import Cloud.User.Impl (enlilAud, enlilIssuer)
import Cloud.Prelude
import Data.Set qualified as Set
import Data.Time (NominalDiffTime, getCurrentTime)
import Data.Time.Clock (addUTCTime)
import Data.UUID (UUID)
import Share.JWT qualified as ShareJWT
import Share.OAuth.Types (JTI (..), UserId)
import Share.Utils.IDs qualified as IDs

newStandardClaims :: UserId -> NominalDiffTime -> UUID -> AppM reqCtx ShareJWT.StandardClaims
newStandardClaims sub ttl jtiUUID = do
  aud <- enlilAud
  iat <- liftIO getCurrentTime
  let exp = addUTCTime ttl iat
  let jti = IDs.toText $ JTI jtiUUID
  iss <- enlilIssuer
  pure (ShareJWT.StandardClaims {sub = IDs.toText sub, aud = Set.singleton aud, ..})
