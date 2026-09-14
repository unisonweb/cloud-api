module Cloud.User.Impl
  ( createSubscription
  , userAccountInfo
  , enlilIssuer
  , enlilAud
  , jwksEndpoint
  )
where

import Cloud.Postgres.Ops qualified as PGO
import Cloud.User.Types
import Cloud.Web.App (WebApp)
import Share.OAuth.Types
import Cloud.Stripe.API (runStripe, StripeAPI (..))
import Control.Monad.RWS (asks)
import Cloud.Env (envStripeConfig, envApiOrigin)
import Stripe.Concepts (CustomerId, CouponId)
import Cloud.Stripe.Customers (CreateCustomer(..))
import Cloud.Stripe.Types (Email (..), PersonName (..), customerId)
import Cloud.Errors (leftToErrorResponse, respondError, InternalServerError (..))
import Cloud.Stripe.Subscriptions (CreateSubscription(..), subscriptionId, subscription, SubscriptionWithClientSecret, subscriptionStatus)
import Cloud.Web.Errors (BadRequest(..))
import Cloud.User.Env ( AuthEnv(..) )
import Cloud.Postgres.Ops (cloudTierDetails, createOrUpdateSubscription)
import Share.Utils.Show (tShow)
import Data.Maybe (isJust)
import Cloud.Web.API (CustomerInfo, customerInfoAddress, customerInfoName)
import Control.Applicative ((<|>))
import Cloud.App (AppM)
import Network.URI (URI)
import Cloud.User.App (authM)
import qualified Crypto.JWT as JWK
import qualified Share.JWT as JWT


-- | JWT Issuer, currently just root URI
enlilIssuer :: AppM reqCtx URI
enlilIssuer = do
  asks envApiOrigin

-- | JWT Audience, currently the same as the issuer.
enlilAud :: AppM reqCtx URI
enlilAud = enlilIssuer


userAccountInfo :: UserId -> WebApp UserAccountInfo
userAccountInfo userId = do
  User {user_name, avatar_url, user_email, handle, user_id} <- PGO.expectUserById userId
  organizationMemberships <- PGO.organizationMemberships user_id
  completedTours <- PGO.userTours user_id
  cloudTier <- PGO.userCloudTier user_id
  pure $
    UserAccountInfo
      { handle = handle,
        name = user_name,
        avatarUrl = avatar_url,
        userId = user_id,
        primaryEmail = user_email,
        organizationMemberships,
        completedTours,
        cloudTier
      }

createOrGetStripeUser :: UserId -> Maybe CustomerInfo -> WebApp CustomerId
createOrGetStripeUser userId customerInfo = do
  customerIdMaybe <- PGO.stripeCustomerId userId
  case customerIdMaybe of
    Just customerId -> pure customerId
    Nothing -> do
      user <- PGO.expectUserById userId
      stripeConfig <- asks envStripeConfig
      let req = CreateCustomer { description = Nothing
        , email = Just . Email . user_email $ user
        , name = PersonName <$> ((customerInfoName <$> customerInfo) <|> user_name user)
        , address = customerInfo >>= customerInfoAddress
        }
      customer <- runStripe stripeConfig (\api -> createCustomer api Nothing req) >>= leftToErrorResponse
      let custId = customerId customer
      PGO.createStripeCustomer userId custId
      pure custId

createSubscription :: UserId -> Maybe CustomerInfo -> CloudTier -> Maybe CouponId -> WebApp SubscriptionWithClientSecret
createSubscription userId customerInfo tier coupon =
  case tier of
    Free -> respondError $ BadRequest "A subscription is not needed to be in the free tier"
    tier -> do
      existingSubscription <- PGO.userSubscription userId
      case existingSubscription of
        Just _ -> respondError $ BadRequest "User already has a subscription"
        Nothing -> do
          customerId <- createOrGetStripeUser userId customerInfo
          tierDetailsMaybe <- cloudTierDetails tier
          tierDetails <- case tierDetailsMaybe of
            Just details -> pure details
            Nothing -> respondError $ InternalServerError "no-tier-details" ("Could not find information for tier: " <> tShow tier)
          -- TODO instead of enabling automatic tax if an address is provided, we should check the
          -- Stripe customer response to see whether automatic tax is supported for this customer.
          let enableAutomaticTax = isJust (customerInfo >>= customerInfoAddress)
          let req = CreateSubscription customerId (defaultStripePrice tierDetails) coupon (Just enableAutomaticTax)
          stripeConfig <- asks envStripeConfig
          subWithPaymentIntent <- runStripe stripeConfig (\api -> createSubscription' api Nothing req) >>= leftToErrorResponse
          let sub = subscription subWithPaymentIntent
          createOrUpdateSubscription (subscriptionId sub) customerId (stripeProductId tierDetails) (subscriptionStatus sub)
          pure subWithPaymentIntent

-- | JWK RFC: https://tools.ietf.org/html/rfc7517
jwksEndpoint :: AppM ctx JWK.JWKSet
jwksEndpoint = authM $ do
  asks (JWT.publicJWKSet . envJwtSettings)
