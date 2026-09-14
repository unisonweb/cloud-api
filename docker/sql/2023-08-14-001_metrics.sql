ALTER TABLE cloud_services ADD COLUMN created_at TIMESTAMP DEFAULT now() NOT NULL;

ALTER TABLE cloud_users ADD COLUMN last_activity TIMESTAMP DEFAULT now() NOT NULL;

CREATE TABLE cloud_jobs (
    id UUID PRIMARY KEY NOT NULL DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES cloud_users(user_id),
    job_hash TEXT NOT NULL,
    launched_at TIMESTAMP DEFAULT now() NOT NULL
);