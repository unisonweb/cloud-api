module Cloud.Postgres.Ops.Stripe
(
    saveStripeEvent,
    stripeCustomerId,
    createStripeCustomer,
    updateSubscriptionPaidThrough,
    createOrUpdateSubscription,
    deleteUserSubscription,
    userSubscription,
    deleteStripeCustomer,

) where
import Share.OAuth.Types (UserId)
import Cloud.Web.App (WebApp)
import Stripe.Concepts
import qualified Cloud.Postgres as PG
import qualified Cloud.Postgres.Queries as Q
import Cloud.Stripe.Types (Event, SubscriptionStatus)
import Hasql.Interpolate (Json)
import Data.Time (UTCTime)
import Cloud.Utils.Logging (logInfoText)
import Share.Utils.Show (tShow)
import Cloud.Postgres.App (postgresM)


stripeCustomerId :: UserId -> WebApp (Maybe CustomerId)
stripeCustomerId uid = postgresM $ PG.runTransaction $ Q.stripeCustomerId uid

createStripeCustomer :: UserId -> CustomerId -> WebApp ()
createStripeCustomer uid cid = postgresM $ PG.runTransaction $ Q.createStripeCustomer uid cid

saveStripeEvent :: Event -> Json -> WebApp ()
saveStripeEvent event payload = postgresM $ PG.runTransaction $ Q.saveStripeEvent event payload

userSubscription :: UserId -> WebApp (Maybe SubscriptionId)
userSubscription uid = postgresM $ PG.runTransaction $ Q.userSubscription uid

updateSubscriptionPaidThrough :: SubscriptionId -> UTCTime -> WebApp ()
updateSubscriptionPaidThrough subId paidThrough = do
  logInfoText $ "Updating subscription for subscription id " <> tShow subId <> " as paid through " <> tShow paidThrough
  postgresM $ PG.runTransaction $ Q.updateSubscriptionPaidThrough subId paidThrough

createOrUpdateSubscription :: SubscriptionId -> CustomerId -> ProductId -> SubscriptionStatus -> WebApp ()
createOrUpdateSubscription subId cid pid status = do
  logInfoText $ "Creating or updating subscription for subscription id " <> tShow subId <> " with customer id " <> tShow cid <> " and product id " <> tShow pid <> "and status" <> tShow status
  postgresM $ PG.runTransaction $ Q.createOrUpdateSubscription subId cid pid status

deleteUserSubscription :: SubscriptionId -> WebApp ()
deleteUserSubscription sid = do
  logInfoText $ "Deleting subscription for subscription id " <> tShow sid
  postgresM $ PG.runTransaction $ Q.deleteUserSubscription sid

-- Because of ON DELETE CASCADE, this will also delete any subscriptions associated with the customer
deleteStripeCustomer :: CustomerId -> WebApp ()
deleteStripeCustomer cid = do
  logInfoText $ "Deleting stripe customer for customer id " <> tShow cid
  postgresM $ PG.runTransaction $ Q.deleteStripeCustomer cid
