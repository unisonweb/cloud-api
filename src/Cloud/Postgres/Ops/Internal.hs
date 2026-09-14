module Cloud.Postgres.Ops.Internal
  ( orRespondError,
    expectUserById_,
  )
where

import Cloud.Errors (ToServerError, respondError)
import Cloud.Utils.Logging (Loggable)
import Cloud.Web.App (WebApp)
import Share.OAuth.Types (UserId)
import qualified Cloud.Postgres as PG
import Cloud.Web.Errors (CloudWebError (..))
import Cloud.User.Types (User)
import qualified Cloud.Postgres.Queries as Q
import Cloud.Prelude

orRespondError :: (Loggable e, ToServerError e) => Either e a -> WebApp a
orRespondError = either respondError pure

expectUserById_ :: UserId -> PG.Transaction e (Either CloudWebError User)
expectUserById_ uid = maybeToEither (UserNotFoundForId uid) <$> Q.userByUserId uid

