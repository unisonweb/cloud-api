ALTER TABLE cloud_daemon_assignments DROP CONSTRAINT cloud_daemon_assignments_daemon_hash_fkey;

ALTER TABLE cloud_daemons DROP CONSTRAINT cloud_daemons_daemon_hash_key;

ALTER TABLE cloud_daemons
    ADD CONSTRAINT cloud_daemons_daemon_hash_cluster_key UNIQUE (daemon_hash, cluster_id);

ALTER TABLE cloud_daemon_assignments
    ADD CONSTRAINT cloud_daemon_assignments_daemon_hash_cluster_key FOREIGN KEY (daemon_hash, cluster_id) REFERENCES cloud_daemons (daemon_hash, cluster_id) ON DELETE CASCADE;

ALTER TABLE cloud_daemon_names DROP CONSTRAINT cloud_daemon_names_daemon_name_user_id_key;

ALTER TABLE cloud_daemon_names
    ADD CONSTRAINT cloud_daemon_names_daemon_name_user_id_cluster_key UNIQUE (daemon_name, user_id, cluster_id);

ALTER TABLE cloud_deployments DROP CONSTRAINT cloud_deployments_user_id_deployment_hash_key;

ALTER TABLE cloud_deployments
    ADD CONSTRAINT cloud_deployments_user_id_deployment_hash_cluster_key UNIQUE (user_id, deployment_hash, cluster_id);

ALTER TABLE cloud_deployment_tags DROP CONSTRAINT cloud_deployment_tags_deployment_hash_tag_key;

ALTER TABLE cloud_deployment_tags
    ADD CONSTRAINT cloud_deployment_tags_deployment_hash_tag_cluster_key UNIQUE (deployment_hash, tag, cluster_id);

ALTER TABLE cloud_environments
    DROP CONSTRAINT cloud_environments_user_id_name_key;

ALTER TABLE cloud_environments
    ADD CONSTRAINT cloud_environments_user_id_name_cluster_key UNIQUE (user_id, name, cluster_id);

ALTER TABLE cloud_environment_storage_pool
    DROP CONSTRAINT cloud_environnment_storage_pool_pkey;

ALTER TABLE cloud_environment_storage_pool
    ADD CONSTRAINT cloud_environment_storage_pool_pkey PRIMARY KEY (environment_id, storage_pool_id, cluster_id);

ALTER TABLE cloud_services
    DROP CONSTRAINT cloud_services_service_name_user_id_key;

ALTER TABLE cloud_services
    ADD CONSTRAINT cloud_services_service_name_user_id_cluster_key UNIQUE (service_name, user_id, cluster_id);

ALTER TABLE cloud_service_tags
    DROP CONSTRAINT cloud_service_tags_service_id_tag_key;

ALTER TABLE cloud_service_tags
    ADD CONSTRAINT cloud_service_tags_service_id_tag_cluster_key UNIQUE (service_id, tag, cluster_id);

ALTER TABLE cloud_storage_pools
    DROP CONSTRAINT cesp_unique_name;

ALTER TABLE cloud_storage_pools
    ADD CONSTRAINT cesp_unique_name_cluster UNIQUE (name, user_id, cluster_id);

ALTER TABLE cloud_web_deployments
    DROP CONSTRAINT cloud_web_deployments_user_id_deployment_hash_key;

ALTER TABLE cloud_web_deployments
    ADD CONSTRAINT cloud_web_deployments_user_id_deployment_hash_cluster_key UNIQUE (user_id, deployment_hash, cluster_id);

