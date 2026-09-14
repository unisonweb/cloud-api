
CREATE TYPE URI_TYPE as ENUM('host', 'local', 'ip');
CREATE TYPE SCHEME as ENUM('http', 'https');

CREATE TABLE cloud_clusters (
    id UUID NOT NULL PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    hostname TEXT NOT NULL UNIQUE,
    service_uri_type URI_TYPE NOT NULL, 
    service_uri_scheme SCHEME NOT NULL,
    service_uri_host VARCHAR(255),
    service_uri_port VARCHAR(255),
    service_uri_prefix TEXT NOT NULL,
    loki_scheme SCHEME NOT NULL,
    loki_host VARCHAR(255) NOT NULL,
    loki_port VARCHAR(255) NOT NULL,
    loki_task_name TEXT NOT NULL,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE cloud_cluster_tokens (
    cluster_id UUID NOT NULL REFERENCES cloud_clusters(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP
);
-- TODO Create a function that drops old tokens to keep them under 2:
CREATE FUNCTION check_token_limit()
RETURNS TRIGGER AS $$
BEGIN
    -- Count tokens for the cluster
    IF (
        SELECT COUNT(*) FROM cloud_cluster_tokens
        WHERE cluster_id = NEW.cluster_id
    ) > 2 THEN
        -- Delete the oldest token(s) for this cluster, keeping only the 2 most recent
        DELETE FROM cloud_cluster_tokens
        WHERE id IN (
            SELECT id FROM cloud_cluster_tokens
            WHERE cluster_id = NEW.cluster_id
            ORDER BY created_at ASC
            LIMIT (
                SELECT COUNT(*) - 2 FROM cloud_cluster_tokens WHERE cluster_id = NEW.cluster_id
            )
        );
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TYPE EVENT_TYPE as ENUM('cluster_created', 'cluster_deleted', 'cluster_updated');

CREATE TABLE cloud_cluster_events (
    id UUID NOT NULL PRIMARY KEY DEFAULT uuid_generate_v4(),
    cluster_id UUID NOT NULL REFERENCES cloud_clusters(id) ON DELETE CASCADE,
    event_type EVENT_TYPE NOT NULL,
    event_data JSONB NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- TODO Create a trigger that makes sure there are no more than 2 tokens per cluster:
CREATE TRIGGER limit_tokens_per_cluster
AFTER INSERT ON cloud_cluster_tokens
FOR EACH ROW
EXECUTE FUNCTION check_token_limit();

