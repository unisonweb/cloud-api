ALTER TABLE cloud_daemon_assignments ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_daemon_names ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_daemons ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_daemon_tags ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_deployments ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_deployment_tags ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_environments ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_environment_storage_pool ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_jobs ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_service_assignments ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_services ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_service_tags ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_storage_pools ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

ALTER TABLE cloud_web_deployments ADD COLUMN cluster VARCHAR(255) NOT NULL DEFAULT 'default';

CREATE TABLE cluster_access (
    cluster VARCHAR(255) NOT NULL,
    user_id UUID NOT NULL,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

                                