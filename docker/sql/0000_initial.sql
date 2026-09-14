-- Allow auto-generating uuids
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  primary_email text NOT NULL CHECK (length(primary_email) > 0),
  email_verified boolean NOT NULL,
  avatar_url text NULL CHECK (length(avatar_url) > 0),
  name text NULL CHECK (length(name) > 0),
  -- Handles must be lowercase because we want to assert case-insensitive uniqueness.
  -- Alternatively we could add a unique index on the lowercased handle, but this is easier
  -- and saves us an index.
  handle text UNIQUE NOT NULL CHECK (length(handle) > 0 AND handle = lower(handle)),
  created_at timestamp NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX user_email ON users(lower(primary_email));
CREATE INDEX users_by_handle ON users (lower(handle) text_pattern_ops);
CREATE INDEX users_by_name ON users (lower(name) text_pattern_ops);


-- This is a relation between unison users and a linked github account.
CREATE TABLE github_users (
  github_user_id integer PRIMARY KEY UNIQUE,
  unison_user_id uuid NOT NULL UNIQUE,
  FOREIGN KEY (unison_user_id) REFERENCES users (id) ON DELETE CASCADE
);

-- Stores which tours/flows a user has accomplished, or notifications they've seen.
-- E.g. End-user license agreement, or welcome-tour
CREATE TABLE tours (
  user_id uuid NOT NULL,
  tour_id text NOT NULL,
  FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  PRIMARY KEY(user_id, tour_id)
);


-- (organization_user_id, member_user_id) indicates that the user at member_user_id
CREATE TABLE org_members (
    organization_user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    member_user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,

    PRIMARY KEY (organization_user_id, member_user_id),

    -- Orgs cannot be members of themselves.
    CHECK (organization_user_id <> member_user_id)
);

CREATE INDEX organizations_by_member ON org_members(member_user_id);

-- Stores the latest push for each user.
-- This table is used for tracking push metrics.
CREATE TABLE latest_push (
  user_id uuid PRIMARY KEY NOT NULL,
  pushed_at timestamp NOT NULL DEFAULT NOW(),

  FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
);

-- Users in this table have access to unison cloud.
CREATE TABLE cloud_users (
    user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE
);


CREATE TABLE cloud_environments (
    id UUID NOT NULL DEFAULT uuid_generate_v4() PRIMARY KEY,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name text NOT NULL,
    created_at timestamp NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, name)
);

CREATE TABLE cloud_services (
    id UUID NOT NULL DEFAULT uuid_generate_v4() PRIMARY KEY,
    service_name Text NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    UNIQUE (id),
    UNIQUE (service_name, user_id)
);

CREATE TABLE cloud_deployments (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    deployment_hash text NOT NULL PRIMARY KEY,
    deployed_at timestamp NOT NULL DEFAULT NOW(),
    undeployed_at timestamp NULL,
    environment UUID NOT NULL REFERENCES cloud_environments(id) ON DELETE CASCADE,
    UNIQUE (user_id, deployment_hash)
);

CREATE TABLE cloud_web_deployments (
    user_id UUID NOT NULL REFERENCES users(id),
    deployment_hash text NOT NULL PRIMARY KEY references cloud_deployments(deployment_hash) ON DELETE CASCADE,
    deployed_at timestamp NOT NULL DEFAULT NOW(),
    undeployed_at timestamp NULL,
    services_version smallint NOT NULL,
    UNIQUE (user_id, deployment_hash)
);

CREATE INDEX deploments_by_user_id ON cloud_deployments(user_id);
CREATE INDEX deployments_by_deployment_hash ON cloud_deployments(deployment_hash);

CREATE TABLE cloud_service_assignments (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    service_id UUID NOT NULL REFERENCES cloud_services(id) ON DELETE CASCADE,
    deployment_hash text NOT NULL REFERENCES cloud_deployments(deployment_hash) ON DELETE CASCADE,
    assignment_time timestamp NOT NULL DEFAULT NOW()
);

CREATE TABLE cloud_deployment_tags (
    deployment_hash text NOT NULL  REFERENCES cloud_deployments(deployment_hash) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tag text NOT NULL,
    UNIQUE (deployment_hash, tag)
);

CREATE TABLE cloud_service_tags (
    service_id UUID NOT NULL REFERENCES cloud_services(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    tag text NOT NULL,
    UNIQUE (service_id, tag)
);

