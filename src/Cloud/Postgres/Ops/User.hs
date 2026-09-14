module Cloud.Postgres.Ops.User
  ( userCloudTier,
    expectUserById,
    expectUserById_,
    userTours,
    getUserLogTime,
    acceptTerms,
    unacceptTerms,
    addToFreeTier,
    organizationMemberships,
    cloudTierDetails,
    addToPaidTier,
    isCloudSupreme
  )
where

import Cloud.Postgres qualified as PG
import Cloud.Postgres.App (postgresM)
import Cloud.Postgres.Ops.Internal
import Cloud.Postgres.Queries qualified as Q
import Cloud.Prelude
import Cloud.User.Types (CloudTier, CloudTierDetails, User)
import Cloud.User.UserHandle (UserHandle)
import Cloud.Web.App (WebApp)
import Data.Time (UTCTime)
import Share.OAuth.Types

userTours :: UserId -> WebApp [Text]
userTours user_id = postgresM $ PG.runTransaction $ Q.userTours user_id

userCloudTier :: UserId -> WebApp CloudTier
userCloudTier user_id = postgresM $ PG.runTransaction $ Q.userCloudTier user_id

expectUserById :: UserId -> WebApp User
expectUserById uid = orRespondError =<< postgresM (PG.runTransaction (expectUserById_ uid))

getUserLogTime :: UserId -> WebApp (Maybe UTCTime)
getUserLogTime userId =
  postgresM $
    PG.runTransaction $
      Q.getUserLogTime userId

organizationMemberships :: UserId -> WebApp [UserHandle]
organizationMemberships user_id = postgresM $ PG.runTransaction $ Q.organizationMemberships user_id

acceptTerms :: UserId -> WebApp ()
acceptTerms user_id = postgresM $ PG.runTransaction $ Q.acceptTerms user_id

unacceptTerms :: UserId -> WebApp ()
unacceptTerms user_id = postgresM $ PG.runTransaction $ Q.unacceptTerms user_id

addToFreeTier :: UserId -> WebApp ()
addToFreeTier user_id = postgresM $ PG.runTransaction $ Q.addToFreeTier user_id

addToPaidTier :: User -> WebApp ()
addToPaidTier user = postgresM $ PG.runTransaction $ Q.addToPaidTier user

cloudTierDetails :: CloudTier -> WebApp (Maybe CloudTierDetails)
cloudTierDetails tier = postgresM $ PG.runTransaction $ Q.cloudTierDetails tier

isCloudSupreme :: UserId -> WebApp Bool
isCloudSupreme user_id = postgresM $ PG.runTransaction $ Q.isCloudSupreme user_id