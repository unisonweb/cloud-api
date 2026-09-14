{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLists #-}

module Cloud.Stripe.Customers
  (CustomerAPI
  , CreateCustomer(..)
  )

where

import Cloud.Prelude
import Servant
import Web.FormUrlEncoded (ToForm(..))
import Cloud.Stripe.Types
import Cloud.Stripe.ApiHelpers (nestedForm)

type CustomerAPI = CreateCustomerAPI

type CreateCustomerAPI =
  Header "Idempotency-Key" IdempotencyKey
  :> ReqBody '[FormUrlEncoded] CreateCustomer
  :> Post '[JSON] Customer

data CreateCustomer = CreateCustomer
  { description :: !(Maybe CustomerDescription)
  , email       :: !(Maybe Email)
  , name    :: !(Maybe PersonName)
  , address :: !(Maybe Address)
  } deriving (Generic)

instance ToForm CreateCustomer where
  toForm CreateCustomer {..} =
    maybe [] (\(CustomerDescription t) -> [("description", toQueryParam t)]) description
    <> maybe [] (\(Email t) -> [("email", toQueryParam t)]) email
    <> maybe [] (\(PersonName t) -> [("name", toQueryParam t)]) name
    <> maybe [] (nestedForm "address" . toForm) address
