ALTER TABLE cloud_daemon_assignments
    DROP CONSTRAINT cloud_daemon_assignments_daemon_hash_cluster_key,
    ADD CONSTRAINT cloud_daemon_assignments_daemon_hash_cluster_key FOREIGN KEY (daemon_hash, cluster_id) REFERENCES cloud_daemons (daemon_hash, cluster_id) ON DELETE CASCADE;
