{-# LANGUAGE OverloadedLists #-}

module Cloud.Stripe.Types
  ( Customer (..)
  , CustomerDescription (..)
  , Email (..)
  , PersonName (..)
  , IdempotencyKey (..)
  , parseJSONCustomerId
  , parseJSONSubscriptionId
  , PriceId (..)
  , Subscription (..)
  , SubscriptionItem (..)
  , SubscriptionItemId (..)
  , SubscriptionStatus (..)
  , EventId (..)
  , EventType (..)
  , EventData (..)
  , Event (..)
  , eventDataToEventType
  , Invoice (..)
  , InvoiceLine (..)
  , InvoiceLinePeriod (..)
  , InvoiceLines (..)
  , parseJSONProductId
  , Price (..)
  , couponIdFromJSON
  , Address(..)
  )

where
import Cloud.Prelude
import Servant
import Data.Aeson
import Hasql.Interpolate (EncodeValue, DecodeValue, decodeValue, encodeValue)
import Stripe.Concepts (SubscriptionId (..), ProductId (..), CustomerId (..), CouponId (..))
import Data.Aeson.Types (explicitParseFieldMaybe, Parser, explicitParseField)
import Data.Time.Clock.POSIX (POSIXTime)
import Hasql.Encoders (enum)
import Web.FormUrlEncoded (ToForm (..))

newtype IdempotencyKey = IdempotencyKey Text
  deriving newtype (ToHttpApiData)

newtype PriceId = PriceId Text
  deriving newtype (DecodeValue, FromJSON, ToHttpApiData)

newtype EventId = EventId Text
  deriving (Show)
  deriving newtype (EncodeValue)

newtype EventType = EventType Text
  deriving newtype (Show)

data Price = Price
  { priceId :: !PriceId
  , priceProduct :: !ProductId
  }

instance FromJSON Price where
  parseJSON = withObject "Price" $ \o -> do
    priceId <- o .: "id"
    priceProduct <- explicitParseField parseJSONProductId o "product"
    pure Price {..}

newtype SubscriptionItemId = SubscriptionItemId Text
  deriving newtype (DecodeValue, EncodeValue, FromJSON, ToHttpApiData)

data SubscriptionItem = SubscriptionItem
  { subscriptionItemId :: SubscriptionItemId
  , subscriptionItemPrice :: Price
  }

instance FromJSON SubscriptionItem where
  parseJSON = withObject "SubscriptionItem" $ \o -> do
    subscriptionItemId <- o .: "id"
    subscriptionItemPrice <- o .: "price"
    pure SubscriptionItem {..}

data SubscriptionStatus = Trialing | Active | Incomplete | IncompleteExpired | PastDue | Canceled | Unpaid | Paused | Unknown Text

subscriptionStatusFromText :: Text -> SubscriptionStatus
subscriptionStatusFromText = \case
  "trialing" -> Trialing
  "active" -> Active
  "incomplete" -> Incomplete
  "incomplete_expired" -> IncompleteExpired
  "past_due" -> PastDue
  "canceled" -> Canceled
  "unpaid" -> Unpaid
  "paused" -> Paused
  other -> Unknown other

subscriptionStatusToText :: SubscriptionStatus -> Text
subscriptionStatusToText = \case
  Trialing -> "trialing"
  Active -> "active"
  Incomplete -> "incomplete"
  IncompleteExpired -> "incomplete_expired"
  PastDue -> "past_due"
  Canceled -> "canceled"
  Unpaid -> "unpaid"
  Paused -> "paused"
  Unknown other -> other

instance Show SubscriptionStatus where
  show = show . subscriptionStatusToText

instance FromJSON SubscriptionStatus where
  parseJSON = withText "SubscriptionStatus" (pure . subscriptionStatusFromText)

instance EncodeValue SubscriptionStatus where
  encodeValue = enum subscriptionStatusToText

instance DecodeValue SubscriptionStatus where
  decodeValue = subscriptionStatusFromText <$> decodeValue

data Subscription = Subscription
  { subscriptionId :: !SubscriptionId
  , subscriptionStatus :: !SubscriptionStatus
  , customer :: !CustomerId
  , items :: ![SubscriptionItem]
  }

instance FromJSON Subscription where
  parseJSON = withObject "Subscription" $ \o -> do
    subscriptionId <- explicitParseField parseJSONSubscriptionId o "id"
    subscriptionStatus <- o .: "status"
    customer <- explicitParseField parseJSONCustomerId o "customer"
    items <- o .: "items" >>= (.: "data")
    pure Subscription {..}

parseJSONCustomerId :: Value -> Parser CustomerId
parseJSONCustomerId = fmap CustomerId . parseJSON

data InvoiceLinePeriod = InvoiceLinePeriod
  { invoiceLinePeriodStart :: !POSIXTime
  , invoiceLinePeriodEnd :: !POSIXTime
  }

instance FromJSON InvoiceLinePeriod where
  parseJSON = withObject "InvoiceLinePeriod" $ \o -> do
    invoiceLinePeriodStart <- o .: "start"
    invoiceLinePeriodEnd <- o .: "end"
    pure InvoiceLinePeriod {..}

data InvoiceLine = InvoiceLine
  { invoiceLinePrice :: !Price
  , invoiceLinePeriod :: !InvoiceLinePeriod
  }

instance FromJSON InvoiceLine where
  parseJSON = withObject "InvoiceLine" $ \o -> do
    invoiceLinePrice <- o .: "price"
    invoiceLinePeriod <- o .: "period"
    pure InvoiceLine {..}

newtype InvoiceLines = InvoiceLines
  { invoiceLinesData :: [InvoiceLine]
  }

instance FromJSON InvoiceLines where
  parseJSON = withObject "InvoiceLines" $ \o -> do
    invoiceLinesData <- o .: "data"
    pure InvoiceLines {..}

data Invoice = Invoice
  { invoiceSubscription :: !(Maybe SubscriptionId)
  , invoiceLines :: !InvoiceLines
  }

parseJSONSubscriptionId :: Value -> Parser SubscriptionId
parseJSONSubscriptionId = fmap SubscriptionId . parseJSON

parseJSONProductId :: Value -> Parser ProductId
parseJSONProductId = fmap ProductId . parseJSON

instance FromJSON Invoice where
  parseJSON = withObject "Invoice" $ \o -> do
    invoiceSubscription <- explicitParseFieldMaybe parseJSONSubscriptionId o "subscription"
    invoiceLines <- o .: "lines"
    pure Invoice {..}

data EventData
  = InvoicePaid Invoice
  | CustomerSubscriptionCreated Subscription
  | CustomerSubscriptionDeleted Subscription
  | CustomerSubscriptionPaused Subscription
  | CustomerSubscriptionResumed Subscription
  | CustomerSubscriptionUpdated Subscription
  | CustomerDeleted Customer
  | OtherEvent EventType Object

eventDataToEventType :: EventData -> EventType
eventDataToEventType = \case
  InvoicePaid _ -> EventType "invoice.paid"
  CustomerSubscriptionCreated _ -> EventType "customer.subscription.created"
  CustomerSubscriptionDeleted _ -> EventType "customer.subscription.deleted"
  CustomerSubscriptionPaused _ -> EventType "customer.subscription.paused"
  CustomerSubscriptionResumed _ -> EventType "customer.subscription.resumed"
  CustomerSubscriptionUpdated _ -> EventType "customer.subscription.updated"
  CustomerDeleted _ -> EventType "customer.deleted"
  OtherEvent eventType _ -> eventType

data Event = Event
  { eventId :: !EventId
  , eventData :: !EventData
  , eventCreated :: !POSIXTime
  } deriving (Generic)

instance FromJSON Event where
  parseJSON = withObject "Event" $ \o -> do
    eventId <- EventId <$> o .: "id"
    eventTypeText <- o .: "type"
    eventData <- o .: "data" >>= (.: "object") >>= parseEventData eventTypeText
    eventCreated <- o .: "created"
    pure Event {..}
    where parseEventData eventType = withObject "EventData" $ \o -> case eventType of
            "invoice.paid" -> InvoicePaid <$> parseJSON (Object o)
            "customer.subscription.created" -> CustomerSubscriptionCreated <$> parseJSON (Object o)
            "customer.subscription.deleted" -> CustomerSubscriptionDeleted <$> parseJSON (Object o)
            "customer.subscription.paused" -> CustomerSubscriptionPaused <$> parseJSON (Object o)
            "customer.subscription.resumed" -> CustomerSubscriptionResumed <$> parseJSON (Object o)
            "customer.subscription.updated" -> CustomerSubscriptionUpdated <$> parseJSON (Object o)
            "customer.deleted" -> CustomerDeleted <$> parseJSON (Object o)
            _ -> pure $ OtherEvent (EventType eventType) o

newtype CustomerDescription = CustomerDescription Text
  deriving newtype (FromJSON, ToHttpApiData)

newtype Email = Email Text
  deriving newtype (FromJSON, ToHttpApiData)

newtype PersonName = PersonName Text
  deriving newtype (FromJSON, ToHttpApiData)

data Customer = Customer
  { customerId        :: !CustomerId
  , customerDescription :: !(Maybe CustomerDescription)
  , customerEmail       :: !(Maybe Email)
  }

instance FromJSON Customer where
  parseJSON = withObject "Customer" $ \o -> do
    customerId <- explicitParseField parseJSONCustomerId o "id"
    customerDescription <- o .:? "description"
    customerEmail <- o .:? "email"
    pure Customer{..}

couponIdFromJSON :: Value -> Parser CouponId
couponIdFromJSON = fmap CouponId . parseJSON

data Address = Address
  { addressCity :: Text
  , addressCountry :: Text
  , addressLine1 :: Text
  , addressLine2 :: Maybe Text
  , addressPostalCode :: Text
  , addressState :: Maybe Text
  }

instance ToForm Address where
  toForm Address{..} =
    [ ("city", toQueryParam addressCity)
    , ("country", toQueryParam addressCountry)
    , ("line1", toQueryParam addressLine1)
    , ("postal_code", toQueryParam addressPostalCode)
    ]
    <> maybe [] (\t -> [("line2", toQueryParam t)]) addressLine2
    <> maybe [] (\t -> [("state", toQueryParam t)]) addressState

instance FromJSON Address where
  parseJSON = withObject "Address" $ \o -> do
    addressCity <- o .: "city"
    addressCountry <- o .: "country"
    addressLine1 <- o .: "line1"
    addressLine2 <- o .:? "line2"
    addressPostalCode <- o .: "postal_code"
    addressState <- o .:? "state"
    pure Address{..}
