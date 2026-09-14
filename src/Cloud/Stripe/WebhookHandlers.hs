module Cloud.Stripe.WebhookHandlers
  ( handleEvent
  )

where

import Cloud.Stripe.Types
import Cloud.Web.App (WebApp)
import Cloud.Utils.Logging (logErrorText, logDebugText)
import Share.Utils.Show (tShow)
import Cloud.Postgres.Ops (createOrUpdateSubscription, deleteUserSubscription, updateSubscriptionPaidThrough, deleteStripeCustomer)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)

handleEvent :: Event -> WebApp ()
handleEvent (Event eventId eventData _) =
  let eventType = eventDataToEventType eventData
  in
  case eventData of
  InvoicePaid (Invoice (Just subscriptionId) (InvoiceLines [lineItem])) ->
    -- NOTE: currently we expect invoices to have exactly one item that corresponds to a single
    -- subscription. This is perhaps a bit brittle, but if actual data varies from this assumption
    -- then I'd rather log errors and do nothing than potentially do wrong things with billing.
    let
      periodEnd = invoiceLinePeriodEnd . invoiceLinePeriod $ lineItem
    in updateSubscriptionPaidThrough subscriptionId (posixSecondsToUTCTime periodEnd)
  InvoicePaid _ -> logErrorText $ "unexpected " <> tShow eventType <> " event (non-subscription?)" <> tShow eventId
  CustomerSubscriptionCreated (Subscription subId status customer [SubscriptionItem _ (Price _ product)]) ->
    createOrUpdateSubscription subId customer product status
  CustomerSubscriptionCreated {} ->
    logErrorText $ "unexpected customer.subscription.created event" <> tShow eventId
  CustomerSubscriptionDeleted sub ->
    deleteUserSubscription (subscriptionId sub)
  CustomerSubscriptionUpdated (Subscription subId IncompleteExpired _ _) ->
    deleteUserSubscription subId
  CustomerSubscriptionUpdated (Subscription subId status customer [SubscriptionItem _ (Price _ product)]) ->
    createOrUpdateSubscription subId customer product status
  CustomerSubscriptionUpdated {} ->
    logErrorText $ "unexpected customer.subscription.updated event" <> tShow eventId
  CustomerDeleted (Customer { customerId }) ->
    deleteStripeCustomer customerId
  _ -> logDebugText $ "ignoring " <> tShow (eventDataToEventType eventData) <> " event " <> tShow eventId
