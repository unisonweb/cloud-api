
CREATE INDEX cloud_deployments_by_user_id ON cloud_deployments(user_id, cluster_id, deployed_at DESC);
CREATE INDEX cloud_services_by_user_id ON cloud_services(user_id, cluster_id, created_at DESC);

CREATE INDEX cloud_deployments_user_cluster ON cloud_deployments(user_id, cluster_id, deployment_hash);
CREATE INDEX cloud_service_assignments_deployment_unassignment ON cloud_service_assignments(deployment_hash, unassignment_time);
