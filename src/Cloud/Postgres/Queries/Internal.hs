module Cloud.Postgres.Queries.Internal
(
    validateCloudUserHandle
) where
import Share.OAuth.Types (UserId)
import Cloud.User.UserHandle (UserHandle)
import qualified Cloud.Postgres as PG
import Cloud.User.Types (User)


validateCloudUserHandle :: UserId -> UserHandle -> PG.Transaction e (Maybe User)
validateCloudUserHandle uid handle = do
    PG.query1Row
      [PG.sql|
          SELECT u.id, u.name, u.primary_email, u.avatar_url, u.handle, u.private FROM cloud_users cu
            JOIN users u ON cu.user_id = u.id
            WHERE cu.user_id = #{uid}
              AND u.handle = #{handle}
        
      |]

