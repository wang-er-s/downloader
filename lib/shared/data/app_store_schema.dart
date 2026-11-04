// Shared business schema v1, matching the source design.
const appStoreSchemaV1 = r'''
CREATE TABLE download_tasks (
  id TEXT PRIMARY KEY NOT NULL,
  request_id TEXT NOT NULL UNIQUE,
  engine_id TEXT NOT NULL UNIQUE,
  generation INTEGER NOT NULL DEFAULT 0 CHECK (generation >= 0),
  original_url TEXT NOT NULL,
  effective_url TEXT,
  requested_file_name TEXT,
  display_name TEXT NOT NULL,
  directory_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN (
    'queued', 'running', 'paused', 'waitingRecovery',
    'publishing', 'failed', 'completed', 'cancelling', 'deleting'
  )),
  downloaded_bytes INTEGER NOT NULL DEFAULT 0 CHECK (downloaded_bytes >= 0),
  total_bytes INTEGER CHECK (total_bytes IS NULL OR total_bytes >= 0),
  staging_ref TEXT,
  target_ref TEXT,
  engine_receipt_json TEXT,
  pending_command_json TEXT,
  publish_operation_json TEXT,
  last_error_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE saved_downloads (
  id TEXT PRIMARY KEY NOT NULL,
  url TEXT NOT NULL,
  file_name TEXT,
  directory_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE engine_receipt_acks (
  engine_id TEXT NOT NULL,
  generation INTEGER NOT NULL CHECK (generation >= 0),
  task_id TEXT NOT NULL,
  receipt_version INTEGER NOT NULL CHECK (receipt_version > 0),
  release_refs_json TEXT NOT NULL DEFAULT '[]',
  PRIMARY KEY (engine_id, generation)
  -- 不设置任务外键，取消/删除记录后仍需重发最后确认。
);
CREATE TABLE app_settings (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  theme TEXT NOT NULL CHECK (theme IN ('system', 'light', 'dark')),
  default_directory_json TEXT NOT NULL
);
PRAGMA user_version = 1;
''';
