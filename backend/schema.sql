-- Robink V2 SaaS — PostgreSQL schema
-- Supabase uyumlu. Render.com deploy'da otomatik calistirilir.

CREATE TABLE IF NOT EXISTS users (
  id           TEXT PRIMARY KEY,
  username     TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  created_at   BIGINT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS users_username_lower_idx ON users (LOWER(username));

CREATE TABLE IF NOT EXISTS devices (
  id          TEXT PRIMARY KEY,
  user_id     TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  token       TEXT NOT NULL,
  last_seen   BIGINT NOT NULL,
  created_at  BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS devices_user_idx ON devices (user_id);

CREATE TABLE IF NOT EXISTS pairing_codes (
  code         TEXT PRIMARY KEY,
  created_by   TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at   BIGINT NOT NULL,
  expires_at   BIGINT NOT NULL,
  used_at      BIGINT,
  device_id    TEXT REFERENCES devices(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS pairing_codes_created_by_idx ON pairing_codes (created_by);

CREATE TABLE IF NOT EXISTS commands (
  id           TEXT PRIMARY KEY,
  device_id    TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  item_n       INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'pending',
  output       TEXT,
  error        TEXT,
  exit_code    INTEGER,
  duration_ms  INTEGER,
  created_at   BIGINT NOT NULL,
  started_at   BIGINT,
  finished_at  BIGINT
);
CREATE INDEX IF NOT EXISTS commands_user_idx ON commands (user_id);
CREATE INDEX IF NOT EXISTS commands_device_status_idx ON commands (device_id, status);
