{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}
module Cloud.Stripe.API
  ( StripeConfig (..)
  , StripeError (..)
  , runStripe
  , StripeAPI (..)
  )

where

import Cloud.Stripe.Customers
import Servant.Client qualified as S
import Servant
import Servant.Client
import Cloud.Prelude
import Stripe.Concepts
import Cloud.Stripe.Types
import qualified Data.ByteString as ByteString
import Cloud.Stripe.Subscriptions

type StripeAPIType = BasicAuth "" ApiSecretKey :>
  ("v1" :>
  (("customers" :> CustomerAPI) :<|> ("subscriptions" :> SubscriptionAPI)))

stripeAPIProxy :: Proxy StripeAPIType
stripeAPIProxy = Proxy

data StripeConfig = StripeConfig
  { stripeApiSecretKey :: ApiSecretKey,
    stripeClientEnv  :: S.ClientEnv,
    stripeWebhookSecretKey :: WebhookSecretKey
  }

newtype StripeError = StripeError ClientError
  deriving stock (Show, Eq, Generic)


data StripeAPI = StripeAPI
  { createCustomer :: Maybe IdempotencyKey -> CreateCustomer -> ClientM Customer
  , createSubscription' :: Maybe IdempotencyKey -> CreateSubscription -> ClientM SubscriptionWithClientSecret
  }
stripeAPI :: ApiSecretKey -> StripeAPI
stripeAPI (ApiSecretKey secretKeyBytes) =
  let authData = BasicAuthData secretKeyBytes ByteString.empty
  in
  case client stripeAPIProxy authData of
    (createCustomer :<|> createSubscription') -> StripeAPI {..}

runStripe :: (MonadIO m) => StripeConfig -> (StripeAPI -> S.ClientM a) -> m (Either StripeError a)
runStripe cfg request =
  let
    env = stripeClientEnv cfg
    api = stripeAPI (stripeApiSecretKey cfg)
  in
  do
  liftIO $ first StripeError <$> S.runClientM (request api) env
