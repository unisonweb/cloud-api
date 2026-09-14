module Cloud.Postgres.Queries.Stripe
(
createOrUpdateSubscription,
    stripeCustomerId,
    saveStripeEvent,
    createStripeCustomer,
    deleteUserSubscription,
    userSubscription,
    updateSubscriptionPaidThrough,
    deleteStripeCustomer,

) where
import Share.OAuth.Types (UserId)
import qualified Cloud.Postgres as PG
import Stripe.Concepts
import qualified Cloud.Stripe.Types as Stripe
import Hasql.Interpolate (Json)
import Data.Time (UTCTime)
import Cloud.Stripe.Types
    

stripeCustomerId :: UserId -> PG.Transaction e (Maybe CustomerId)
stripeCustomerId userId =
  fmap CustomerId
    <$> PG.query1Col
      [PG.sql|
        SELECT stripe_customer_id
          FROM stripe_customers
          WHERE unison_user_id = #{userId}
      |]

createStripeCustomer :: UserId -> CustomerId -> PG.Transaction e ()
createStripeCustomer userId (CustomerId cid) =
  PG.execute_
    [PG.sql|
        INSERT INTO stripe_customers (unison_user_id, stripe_customer_id)
          VALUES (#{userId}, #{cid})
      |]

saveStripeEvent :: Stripe.Event -> Json -> PG.Transaction e ()
saveStripeEvent event payload =
  PG.execute_
    [PG.sql|
        INSERT INTO stripe_events (stripe_event_id, payload)
          VALUES (#{eventId}, #{payload})
        ON CONFLICT DO NOTHING
      |]
  where
    eventId = Stripe.eventId event

userSubscription :: UserId -> PG.Transaction e (Maybe SubscriptionId)
userSubscription userId =
  fmap SubscriptionId
    <$> PG.query1Col
      [PG.sql|
        SELECT subs.stripe_subscription_id
        FROM cloud_user_subscriptions subs JOIN stripe_customers customers
          ON subs.stripe_customer_id = customers.stripe_customer_id
        WHERE customers.unison_user_id = #{userId}
          AND subs.status NOT IN ('canceled', 'incomplete', 'incomplete_expired')
      |]

updateSubscriptionPaidThrough :: SubscriptionId -> UTCTime -> PG.Transaction e ()
updateSubscriptionPaidThrough (SubscriptionId subId) paidThrough =
  PG.execute_
    [PG.sql|
        UPDATE cloud_user_subscriptions
          SET paid_through = #{paidThrough}
          WHERE stripe_subscription_id = #{subId}
      |]

createOrUpdateSubscription :: SubscriptionId -> CustomerId -> ProductId -> SubscriptionStatus -> PG.Transaction e ()
createOrUpdateSubscription (SubscriptionId subId) (CustomerId customerId) (ProductId productId) status =
  PG.execute_
    [PG.sql|
        INSERT INTO cloud_user_subscriptions (stripe_subscription_id, stripe_customer_id, stripe_product_id, status)
          VALUES (#{subId}, #{customerId}, #{productId}, #{status})
          ON CONFLICT (stripe_subscription_id) DO UPDATE
          SET stripe_product_id = EXCLUDED.stripe_product_id, status = EXCLUDED.status
      |]

deleteUserSubscription :: SubscriptionId -> PG.Transaction e ()
deleteUserSubscription (SubscriptionId subId) =
  PG.execute_
    [PG.sql|
        DELETE FROM cloud_user_subscriptions
          WHERE stripe_subscription_id = #{subId}
      |]

deleteStripeCustomer :: CustomerId -> PG.Transaction e ()
deleteStripeCustomer (CustomerId cid) =
  PG.execute_
    [PG.sql|
        DELETE FROM stripe_customers
          WHERE stripe_customer_id = #{cid}
      |]
