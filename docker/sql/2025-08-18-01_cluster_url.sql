ALTER TABLE cloud_clusters ADD COLUMN cluster_uri_scheme SCHEME NOT NULL default 'https';
ALTER TABLE cloud_clusters ADD COLUMN cluster_uri_host VARCHAR(255) NOT NULL default 'public.unison.cloud';
ALTER TABLE cloud_clusters ADD COLUMN cluster_uri_port VARCHAR(255) NOT NULL default '443';
