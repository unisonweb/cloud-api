create table cloud_storage_pools (
  id UUID NOT NULL PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name Text NOT NULL,
  created_at Timestamp NOT NULL DEFAULT now()
);

create table cloud_environnment_storage_pool (
  environment_id UUID NOT NULL REFERENCES cloud_environments(id) ON DELETE CASCADE,
  storage_pool_id UUID NOT NULL REFERENCES cloud_storage_pools(id) ON DELETE CASCADE,
  created_at Timestamp NOT NULL DEFAULT now(),
  PRIMARY KEY (environment_id, storage_pool_id)
);