CREATE TABLE cloud_daemons (
  user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  daemon_hash TEXT NOT NULL,
  deployed_at TIMESTAMP WITHOUT TIME ZONE NOT NULL default now(),
  undeployed_at TIMESTAMP WITHOUT TIME ZONE,
  environment uuid NOT NULL REFERENCES cloud_environments (id) ON DELETE CASCADE,
  UNIQUE (daemon_hash)
);

CREATE TABLE cloud_daemon_names (
  id UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  daemon_name TEXT NOT NULL,
  UNIQUE (daemon_name, user_id)
);

CREATE TABLE cloud_daemon_assignments (
  daemon_id UUID NOT NULL REFERENCES cloud_daemon_names (id) ON DELETE CASCADE,
  daemon_hash Text NOT NULL REFERENCES cloud_daemons (daemon_hash) ON DELETE CASCADE,
  assignment_time TIMESTAMP WITHOUT TIME ZONE NOT NULL default now(),
  unassignment_time TIMESTAMP WITHOUT TIME ZONE
);

CREATE TABLE cloud_daemon_tags (
  user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  daemon_id UUID NOT NULL REFERENCES cloud_daemon_names (id) ON DELETE CASCADE,
  tag TEXT NOT NULL,
  UNIQUE (daemon_id, tag)
);
