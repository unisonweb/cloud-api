-- This is a relation between unison users and a linked Stripe customer.
CREATE TABLE stripe_customers (
  stripe_customer_id text NOT NULL CHECK (length(stripe_customer_id) > 4) PRIMARY KEY UNIQUE,
  unison_user_id uuid NOT NULL UNIQUE,

  FOREIGN KEY (unison_user_id) REFERENCES users (id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX stripe_customers_by_unison_user_id ON stripe_customers(unison_user_id);

CREATE TABLE stripe_events (
  stripe_event_id text NOT NULL PRIMARY KEY UNIQUE,
  payload jsonb NOT NULL,
  received_at timestamp with time zone NOT NULL DEFAULT now()
);

CREATE TABLE cloud_tiers (
  stripe_product_id text NOT NULL CHECK (length(stripe_product_id) > 4) PRIMARY KEY UNIQUE,
  name text NOT NULL UNIQUE,
  default_stripe_price_id text NOT NULL CHECK (length(default_stripe_price_id) > 4)
);

CREATE UNIQUE INDEX cloud_tiers_by_name ON cloud_tiers(name);

CREATE TABLE cloud_user_subscriptions (
  stripe_subscription_id text NOT NULL CHECK (length(stripe_subscription_id) > 4) PRIMARY KEY UNIQUE,
  stripe_customer_id text NOT NULL CHECK (length(stripe_customer_id) > 4),
  stripe_product_id text NOT NULL CHECK (length(stripe_product_id) > 4),
  status text NOT NULL CHECK (length(status) > 0),
  paid_through timestamp with time zone,

  FOREIGN KEY (stripe_customer_id) REFERENCES stripe_customers (stripe_customer_id) ON DELETE CASCADE
);

CREATE INDEX cloud_user_subscriptions_by_customer_id ON cloud_user_subscriptions(stripe_customer_id);
