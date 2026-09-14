-- Allow auto-generating updated_at timestamps.
CREATE EXTENSION IF NOT EXISTS moddatetime;

ALTER TABLE users ALTER COLUMN created_at TYPE timestamptz;
ALTER TABLE users
ADD COLUMN updated_at timestamptz NOT NULL DEFAULT NOW();
CREATE TRIGGER users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW
  EXECUTE PROCEDURE moddatetime (updated_at);

ALTER TABLE latest_push ALTER COLUMN pushed_at TYPE timestamptz;

ALTER TABLE github_users
ADD COLUMN created_at timestamptz NOT NULL DEFAULT NOW(),
ADD COLUMN updated_at timestamptz NOT NULL DEFAULT NOW();
CREATE TRIGGER github_users_updated_at
  BEFORE UPDATE ON github_users
  FOR EACH ROW
  EXECUTE PROCEDURE moddatetime (updated_at);

ALTER TABLE tours
ADD COLUMN created_at timestamptz NOT NULL DEFAULT NOW(),
ADD COLUMN updated_at timestamptz NOT NULL DEFAULT NOW();
CREATE TRIGGER tours_updated_at
  BEFORE UPDATE ON tours
  FOR EACH ROW
  EXECUTE PROCEDURE moddatetime (updated_at);

ALTER TABLE org_members
ADD COLUMN created_at timestamptz NOT NULL DEFAULT NOW(),
ADD COLUMN updated_at timestamptz NOT NULL DEFAULT NOW();
CREATE TRIGGER org_members_updated_at
  BEFORE UPDATE ON org_members
  FOR EACH ROW
  EXECUTE PROCEDURE moddatetime (updated_at);

ALTER TABLE cloud_users
ADD COLUMN created_at timestamptz NOT NULL DEFAULT NOW(),
ADD COLUMN updated_at timestamptz NOT NULL DEFAULT NOW();
CREATE TRIGGER cloud_users_updated_at
  BEFORE UPDATE ON cloud_users
  FOR EACH ROW
  EXECUTE PROCEDURE moddatetime (updated_at);
