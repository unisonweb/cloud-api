
ALTER TABLE cloud_clusters ADD COLUMN cluster_uri VARCHAR(255) NOT NULL DEFAULT 'https://public.unison.cloud:443';
ALTER TABLE cloud_clusters ADD COLUMN service_uri VARCHAR(255) NOT NULL DEFAULT 'https://public.unison.cloud:443';
ALTER TABLE cloud_clusters ADD COLUMN loki_uri VARCHAR(255) NOT NULL DEFAULT 'http://loki-read-http.service.us-west-2.consul.unison-lang.org:5100';

UPDATE cloud_clusters SET cluster_uri = CONCAT(cluster_uri_scheme, '://', cluster_uri_host, ':', cluster_uri_port);
UPDATE cloud_clusters SET service_uri = CONCAT(service_uri_scheme, '://', service_uri_host, ':', service_uri_port);
UPDATE cloud_clusters SET loki_uri = CONCAT(loki_scheme, '://', loki_host, ':', loki_port);

ALTER TABLE cloud_clusters DROP COLUMN cluster_uri_scheme;
ALTER TABLE cloud_clusters DROP COLUMN cluster_uri_host;
ALTER TABLE cloud_clusters DROP COLUMN cluster_uri_port;
ALTER TABLE cloud_clusters DROP COLUMN service_uri_scheme;
ALTER TABLE cloud_clusters DROP COLUMN service_uri_host;
ALTER TABLE cloud_clusters DROP COLUMN service_uri_port;
ALTER TABLE cloud_clusters DROP COLUMN service_uri_prefix;
ALTER TABLE cloud_clusters DROP COLUMN loki_scheme;
ALTER TABLE cloud_clusters DROP COLUMN loki_host;
ALTER TABLE cloud_clusters DROP COLUMN loki_port;

ALTER TABLE cloud_clusters ALTER COLUMN cluster_uri SET NOT NULL;
ALTER TABLE cloud_clusters ALTER COLUMN service_uri SET NOT NULL;
ALTER TABLE cloud_clusters ALTER COLUMN loki_uri SET NOT NULL;

CREATE OR REPLACE FUNCTION check_token_limit()
    RETURNS TRIGGER AS $$
    BEGIN
        -- Count tokens for the cluster
        IF (
            SELECT COUNT(*) FROM cloud_cluster_tokens
            WHERE cluster_id = NEW.cluster_id
        ) > 2 THEN
            -- Delete the oldest token(s) for this cluster, keeping only the 2 most recent
            DELETE FROM cloud_cluster_tokens
            WHERE token_hash IN (
                SELECT token_hash FROM cloud_cluster_tokens
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


CREATE TABLE cloud_supremes (
    user_id UUID NOT NULL PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE);

INSERT INTO cloud_supremes (user_id)
    SELECT id FROM users WHERE handle IN ('stew', 'ceedubs', 'pchiusano', 'rlmark', 'systemfw');