-- A public view of users with cloud subscriptions.
-- We treat trials as active subscriptions for the purposes of this view.
CREATE VIEW public.cloud_subscribers AS
  SELECT customers.unison_user_id AS user_id, subs.status IN ('active', 'trialing') AS is_active, tiers.name AS tier_name
    FROM cloud_tiers tiers 
      JOIN cloud_user_subscriptions subs 
        ON subs.stripe_product_id = tiers.stripe_product_id 
      JOIN stripe_customers customers 
        ON subs.stripe_customer_id = customers.stripe_customer_id
;
