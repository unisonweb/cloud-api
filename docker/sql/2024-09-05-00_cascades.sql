ALTER TABLE cloud_jobs DROP CONSTRAINT cloud_jobs_user_id_fkey;
ALTER TABLE cloud_jobs ADD CONSTRAINT cloud_jobs_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE cloud_web_deployments DROP CONSTRAINT cloud_web_deployments_user_id_fkey;
ALTER TABLE cloud_web_deployments ADD CONSTRAINT cloud_web_deployments_user_id_fkey FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;
