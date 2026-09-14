{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}

module Cloud.Stripe.Subscriptions
  ( SubscriptionAPI
  , CreateSubscription (..)
  , Subscription (..)
  , SubscriptionWithClientSecret (..)
  , SubscriptionItem (..)
  )

where
import Servant
import Cloud.Stripe.Types
import Stripe.Concepts
import Cloud.Prelude
import Web.FormUrlEncoded
import Data.Aeson
import Control.Monad (join)

type SubscriptionAPI = CreateSubscriptionEndpoint

type CreateSubscriptionEndpoint =
  Header "Idempotency-Key" IdempotencyKey
  :> ReqBody '[FormUrlEncoded] CreateSubscription
  :> Post '[JSON] SubscriptionWithClientSecret

data SubscriptionWithClientSecret = SubscriptionWithClientSecret
  { subscription :: !Subscription
  , latestInvoicePaymentIntentClientSecret :: !(Maybe Text)
  }

instance FromJSON SubscriptionWithClientSecret where
  parseJSON = withObject "SubscriptionWithClientSecret" $ \o -> do
    subscription <- parseJSON (Object o)
    latestInvoicePaymentIntentClientSecret <- (o .:? "latest_invoice") >>= traverse parseLatestInvoice <&> join
    pure SubscriptionWithClientSecret {..}
    where parseLatestInvoice = withObject "LatestInvoice" $ \o -> o .:? "payment_intent" >>= traverse (.:? "client_secret") <&> join

data CreateSubscription = CreateSubscription
  { customer :: !CustomerId,
    itemPrice :: !PriceId,
    coupon :: !(Maybe CouponId),
    automaticTaxEnabled :: !(Maybe Bool)
  }

instance ToForm CreateSubscription where
  toForm CreateSubscription {..} =
    [ ("customer", case customer of CustomerId t -> toQueryParam t),
      ("items[0][price]", case itemPrice of PriceId t -> toQueryParam t),
      ("payment_behavior", "default_incomplete"),
      ("payment_settings[save_default_payment_method]", "on_subscription"),
      ("expand[]", "latest_invoice.payment_intent")
    ]
      <> maybe [] (\(CouponId t) -> [("coupon", toQueryParam t)]) coupon
      <> maybe [] (\b -> [("automatic_tax[enabled]", toQueryParam b)]) automaticTaxEnabled
