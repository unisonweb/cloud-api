module Cloud.Postgres.Queries.User
  ( acceptTerms,
    addToFreeTier,
    isUserCloudUser,
    isCloudSupreme,
    userByHandle,
    userByUserId,
    userTours,
    cloudTierDetails,
    userCloudTier,
    getUserLogTime,
    organizationMemberships,
    unacceptTerms,
    addToPaidTier,
    canUserActOnBehalf
  )
where

import Cloud.Postgres qualified as PG
import Cloud.Prelude
import Cloud.User.Types (CloudTier (..), User (..), CloudTierDetails(..), user_id)
import Cloud.User.UserHandle (UserHandle (..))
import Data.Time (UTCTime)
import Share.OAuth.Types (UserId)
import Stripe.Concepts (ProductId(ProductId))

userByUserId :: UserId -> PG.Transaction e (Maybe User)
userByUserId uid = do
  PG.query1Row
    [PG.sql|
        SELECT u.id, u.name, u.primary_email, u.avatar_url, u.handle, u.private
        FROM users u
        WHERE u.id = #{uid}
      |]

userByHandle :: UserHandle -> PG.Transaction e (Maybe User)
userByHandle handle = do
  PG.query1Row
    [PG.sql|
        SELECT u.id, u.name, u.primary_email, u.avatar_url, u.handle, u.private
        FROM users u
        WHERE u.handle = lower(#{handle})
      |]

-- | Returns the handles of all orgs the provided user is a member of.
organizationMemberships :: UserId -> PG.Transaction e [UserHandle]
organizationMemberships uid = do
  PG.queryListCol
    [PG.sql|
        SELECT org_user.handle FROM users AS org_user
          JOIN org_members ON organization_user_id = org_user.id
          WHERE member_user_id = #{uid}
      |]

userTours :: UserId -> PG.Transaction e [Text]
userTours uid = do
  PG.queryListCol
    [PG.sql|
        SELECT tour_id FROM tours
          WHERE user_id = #{uid}
      |]

userCloudTier :: UserId -> PG.Transaction e CloudTier
userCloudTier uid = do
  result <-
    PG.query1Col
      [PG.sql|
        SELECT tiers.name
        FROM cloud_tiers tiers JOIN cloud_user_subscriptions subs
          ON subs.stripe_product_id = tiers.stripe_product_id JOIN stripe_customers customers
          ON subs.stripe_customer_id = customers.stripe_customer_id
        WHERE customers.unison_user_id = #{uid}
          AND subs.status IN ('active', 'trialing')
      |]
  pure $ fromMaybe Free result

canUserActOnBehalf :: UserId -> UserId -> PG.Transaction e Bool
canUserActOnBehalf userId targetId =
  if userId == targetId
    then pure True
    else do
      PG.queryExpect1Col
        [PG.sql|
            SELECT (EXISTS (
              SELECT 1
              FROM org_members om
              WHERE om.member_user_id = #{userId}
                AND om.organization_user_id = #{targetId}
                OR EXISTS (
                  SELECT 1
                  FROM cloud_supremes cs
                  WHERE cs.user_id = #{userId}
                )
            ))
          |]


-- Terms is stored as a "completed tour"
acceptTerms :: UserId -> PG.Transaction e ()
acceptTerms uid = do
  PG.execute_
    [PG.sql|
        INSERT INTO tours (user_id, tour_id)
          VALUES (#{uid}, 'welcome-terms')
          ON CONFLICT DO NOTHING
      |]

unacceptTerms :: UserId -> PG.Transaction e ()
unacceptTerms uid = do
  PG.execute_
    [PG.sql|
        DELETE FROM tours
          WHERE user_id = #{uid}
            AND tour_id = 'welcome-terms'
      |]

addToFreeTier :: UserId -> PG.Transaction e ()
addToFreeTier uid = do
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_users (user_id)
          VALUES (#{uid})
          ON CONFLICT DO NOTHING
      |]

addToPaidTier :: User -> PG.Transaction e ()
addToPaidTier User {handle = (UserHandle handle), user_id} = do

  let stripeCustomerId = "cus_" <> handle
  let stripeSubscriptionId = "sub_" <> handle
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_users (user_id)
          VALUES (#{user_id})
          ON CONFLICT DO NOTHING
      |]
  PG.execute_
    [PG.sql|
        INSERT INTO stripe_customers (stripe_customer_id, unison_user_id)
          VALUES (#{stripeCustomerId}, #{user_id})
          ON CONFLICT DO NOTHING
      |]
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_user_subscriptions (stripe_subscription_id, stripe_customer_id, stripe_product_id, status, paid_through)
          VALUES (#{stripeSubscriptionId},
                  #{stripeCustomerId},
                  (SELECT stripe_product_id FROM cloud_tiers WHERE name ='Starter'),
                  'active',
                  NOW() + INTERVAL '6 months')
          ON CONFLICT DO NOTHING
      |]

isUserCloudUser :: UserId -> PG.Transaction e Bool
isUserCloudUser _userId = do
  pure True
  -- result <-
  --   PG.query1Col
  --     [PG.sql|
  --       WITH updated AS (
  --         UPDATE cloud_users SET last_activity = NOW()
  --         WHERE user_id = #{userId}
  --         RETURNING 1
  --       )
  --       SELECT (COUNT(updated.*) > 0) FROM updated;
  --     |]
  -- pure $ fromMaybe False result

getUserLogTime :: UserId -> PG.Transaction e (Maybe UTCTime)
getUserLogTime userId = do
  PG.query1Col
    [PG.sql|
        SELECT created_at
          FROM cloud_users
          WHERE user_id = #{userId}
      |]

cloudTierDetails :: CloudTier -> PG.Transaction e (Maybe CloudTierDetails)
cloudTierDetails tier = do
  res <-
    PG.query1Row
      [PG.sql|
              SELECT name, stripe_product_id, default_stripe_price_id
                FROM cloud_tiers
                WHERE name = #{tier}
            |]
  pure $ fmap (\(name, productIdText, price) -> CloudTierDetails name (ProductId productIdText) price) res

isCloudSupreme :: UserId -> PG.Transaction e Bool
isCloudSupreme user_id =
  PG.queryExpect1Col
    [PG.sql|
        SELECT EXISTS (
          SELECT 1 FROM cloud_supremes WHERE user_id = #{user_id}
        )
        |]