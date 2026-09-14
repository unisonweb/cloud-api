-- This will speed up one of the metrics queries that we execute frequently.
CREATE INDEX idx_cloud_jobs_launched_at_user_id 
  ON cloud_jobs (launched_at DESC, user_id);
