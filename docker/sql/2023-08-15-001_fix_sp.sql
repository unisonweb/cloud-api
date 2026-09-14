ALTER TABLE cloud_storage_pools ADD CONSTRAINT cesp_unique_name UNIQUE (name, user_id);
