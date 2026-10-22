package store

import "core:strings"

import "../sqlite"

// schema is intentionally compatible with Engram's local store. ctxdb can
// open an existing ~/.engram/engram.db without a destructive migration; the
// core tables, FTS definitions, and triggers match the Go implementation.
SCHEMA :: `
CREATE TABLE IF NOT EXISTS project_aliases (
	kind TEXT NOT NULL CHECK (kind IN ('key', 'cwd')),
	alias_key TEXT NOT NULL,
	project TEXT NOT NULL,
	PRIMARY KEY (kind, alias_key)
);

CREATE TABLE IF NOT EXISTS sessions (
	id         TEXT PRIMARY KEY,
	project    TEXT NOT NULL,
	ownership_mode TEXT,
	directory  TEXT NOT NULL,
	started_at TEXT NOT NULL DEFAULT (datetime('now')),
	ended_at   TEXT,
	summary    TEXT,
	runtime_lease_expires_at TEXT,
	local_creation_project TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project);

CREATE TABLE IF NOT EXISTS capture_project_provenance (
	entity_kind TEXT NOT NULL,
	entity_id TEXT NOT NULL,
	source TEXT NOT NULL,
	directory TEXT NOT NULL DEFAULT '',
	raw_project TEXT NOT NULL DEFAULT '',
	PRIMARY KEY (entity_kind, entity_id)
);

CREATE TABLE IF NOT EXISTS session_finalizations (
	session_id TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
	summary_id INTEGER NOT NULL,
	summary_sync_id TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS observations (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	sync_id    TEXT,
	session_id TEXT    NOT NULL,
	type       TEXT    NOT NULL,
	title      TEXT    NOT NULL,
	content    TEXT    NOT NULL,
	tool_name  TEXT,
	project    TEXT,
	scope      TEXT    NOT NULL DEFAULT 'project',
	topic_key  TEXT,
	normalized_hash TEXT,
	revision_count INTEGER NOT NULL DEFAULT 1,
	duplicate_count INTEGER NOT NULL DEFAULT 1,
	last_seen_at TEXT,
	pinned     BOOLEAN NOT NULL DEFAULT 0,
	created_at TEXT    NOT NULL DEFAULT (datetime('now')),
	updated_at TEXT    NOT NULL DEFAULT (datetime('now')),
	deleted_at TEXT,
	review_after TEXT,
	superseded_by_sync_id TEXT,
	expires_at TEXT,
	embedding BLOB,
	embedding_model TEXT,
	embedding_created_at TEXT,
	FOREIGN KEY (session_id) REFERENCES sessions(id)
);
CREATE INDEX IF NOT EXISTS idx_obs_session  ON observations(session_id);
CREATE INDEX IF NOT EXISTS idx_obs_type     ON observations(type);
CREATE INDEX IF NOT EXISTS idx_obs_project  ON observations(project);
CREATE INDEX IF NOT EXISTS idx_obs_created  ON observations(created_at DESC);

CREATE VIRTUAL TABLE IF NOT EXISTS observations_fts USING fts5(
	title,
	content,
	tool_name,
	type,
	project,
	topic_key,
	tokenize='trigram',
	content='observations',
	content_rowid='id'
);

CREATE TABLE IF NOT EXISTS observation_versions (
	id             INTEGER PRIMARY KEY AUTOINCREMENT,
	observation_id INTEGER NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
	title          TEXT,
	content        TEXT NOT NULL,
	version        INTEGER NOT NULL,
	created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
	UNIQUE(observation_id, version)
);

CREATE TABLE IF NOT EXISTS user_prompts (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	sync_id    TEXT,
	source_inbox_id TEXT,
	local_creation_session_id TEXT,
	local_creation_inbox_id TEXT,
	local_creation_project TEXT,
	session_id TEXT    NOT NULL,
	content    TEXT    NOT NULL,
	project    TEXT,
	created_at TEXT    NOT NULL DEFAULT (datetime('now')),
	FOREIGN KEY (session_id) REFERENCES sessions(id)
);
CREATE INDEX IF NOT EXISTS idx_prompts_session ON user_prompts(session_id);
CREATE INDEX IF NOT EXISTS idx_prompts_project ON user_prompts(project);
CREATE INDEX IF NOT EXISTS idx_prompts_created ON user_prompts(created_at DESC);

CREATE VIRTUAL TABLE IF NOT EXISTS prompts_fts USING fts5(
	content,
	project,
	tokenize='trigram',
	content='user_prompts',
	content_rowid='id'
);

CREATE TABLE IF NOT EXISTS prompt_tombstones (
	sync_id TEXT PRIMARY KEY,
	source_inbox_id TEXT,
	local_creation_session_id TEXT,
	local_creation_inbox_id TEXT,
	local_creation_project TEXT,
	session_id TEXT,
	project TEXT,
	deleted_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS prompt_source_confirmations (
	remote_target TEXT NOT NULL CHECK(length(trim(remote_target)) > 0),
	sync_id TEXT NOT NULL,
	session_id TEXT NOT NULL,
	source_inbox_id TEXT NOT NULL,
	prompt_project TEXT NOT NULL,
	kind TEXT NOT NULL CHECK(kind IN ('live','deleted')),
	asserted_owner_project TEXT NOT NULL,
	remote_attestation_id INTEGER NOT NULL CHECK(remote_attestation_id > 0),
	confirmed_at TEXT NOT NULL DEFAULT (datetime('now')),
	PRIMARY KEY (remote_target, sync_id)
);

CREATE TABLE IF NOT EXISTS sync_delete_tombstones (
	entity TEXT NOT NULL,
	entity_key TEXT NOT NULL,
	session_id TEXT,
	project TEXT NOT NULL DEFAULT '',
	deleted_at TEXT NOT NULL DEFAULT (datetime('now')),
	hard_delete BOOLEAN NOT NULL DEFAULT 1,
	active BOOLEAN NOT NULL DEFAULT 1,
	last_mutation_seq INTEGER NOT NULL DEFAULT 0,
	last_remote_mutation_seq INTEGER,
	superseded_by_sync_id TEXT,
	PRIMARY KEY (entity, entity_key)
);

CREATE TABLE IF NOT EXISTS sync_delete_tombstone_remote_floors (
	target_key TEXT NOT NULL,
	entity TEXT NOT NULL,
	entity_key TEXT NOT NULL,
	last_mutation_seq INTEGER NOT NULL,
	PRIMARY KEY (target_key, entity, entity_key)
);

CREATE TABLE IF NOT EXISTS review_clear_events (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	event_key TEXT NOT NULL UNIQUE,
	sync_id TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_chunks (
	target_key TEXT NOT NULL DEFAULT 'local',
	chunk_id TEXT NOT NULL,
	imported_at TEXT NOT NULL DEFAULT (datetime('now')),
	PRIMARY KEY (target_key, chunk_id)
);

CREATE TABLE IF NOT EXISTS sync_state (
	target_key TEXT PRIMARY KEY,
	lifecycle TEXT NOT NULL DEFAULT 'idle',
	last_enqueued_seq INTEGER NOT NULL DEFAULT 0,
	last_acked_seq INTEGER NOT NULL DEFAULT 0,
	last_pulled_seq INTEGER NOT NULL DEFAULT 0,
	consecutive_failures INTEGER NOT NULL DEFAULT 0,
	backoff_until TEXT,
	lease_owner TEXT,
	lease_until TEXT,
	last_error TEXT,
	last_success_at TEXT,
	reason_code TEXT,
	reason_message TEXT,
	updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sync_mutations (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	target_key TEXT NOT NULL,
	entity TEXT NOT NULL,
	entity_key TEXT NOT NULL,
	op TEXT NOT NULL,
	payload TEXT NOT NULL,
	source TEXT NOT NULL DEFAULT 'local',
	project TEXT NOT NULL DEFAULT '',
	occurred_at TEXT NOT NULL DEFAULT (datetime('now')),
	acked_at TEXT,
	disposition TEXT NOT NULL DEFAULT 'pending',
	disposition_reason TEXT,
	disposition_evidence TEXT,
	disposition_at TEXT,
	FOREIGN KEY (target_key) REFERENCES sync_state(target_key)
);
CREATE INDEX IF NOT EXISTS idx_sync_mutations_project ON sync_mutations(project);

CREATE TABLE IF NOT EXISTS cloud_upgrade_state (
	project TEXT PRIMARY KEY,
	stage TEXT NOT NULL DEFAULT 'planned',
	repair_class TEXT NOT NULL DEFAULT 'none',
	snapshot_json TEXT NOT NULL DEFAULT '{}',
	last_error_code TEXT,
	last_error_message TEXT,
	findings_json TEXT,
	applied_actions TEXT,
	updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS memory_relations (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	sync_id TEXT NOT NULL UNIQUE,
	source_id TEXT,
	target_id TEXT,
	relation TEXT NOT NULL DEFAULT 'pending',
	reason TEXT,
	evidence TEXT,
	confidence REAL,
	judgment_status TEXT NOT NULL DEFAULT 'pending',
	marked_by_actor TEXT,
	marked_by_kind TEXT,
	marked_by_model TEXT,
	session_id TEXT,
	superseded_at TEXT,
	superseded_by_relation_id INTEGER REFERENCES memory_relations(id) ON DELETE SET NULL,
	created_at TEXT NOT NULL DEFAULT (datetime('now')),
	updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_memrel_source ON memory_relations(source_id, judgment_status);
CREATE INDEX IF NOT EXISTS idx_memrel_target ON memory_relations(target_id, judgment_status);
CREATE INDEX IF NOT EXISTS idx_memrel_supersede ON memory_relations(superseded_by_relation_id);

CREATE TABLE IF NOT EXISTS sync_enrolled_projects (
	project TEXT PRIMARY KEY,
	enrolled_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sync_apply_deferred (
	seq INTEGER PRIMARY KEY AUTOINCREMENT,
	entity TEXT NOT NULL,
	entity_key TEXT NOT NULL,
	op TEXT NOT NULL,
	payload TEXT NOT NULL,
	error TEXT,
	apply_status TEXT NOT NULL DEFAULT 'pending',
	attempts INTEGER NOT NULL DEFAULT 0,
	created_at TEXT NOT NULL DEFAULT (datetime('now')),
	updated_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS observation_save_operations (
	operation_id TEXT NOT NULL PRIMARY KEY,
	fingerprint TEXT NOT NULL,
	observation_id INTEGER,
	created_at TEXT NOT NULL DEFAULT (datetime('now')),
	FOREIGN KEY (observation_id) REFERENCES observations(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_obs_save_op_created ON observation_save_operations(created_at);
`

FTS_TRIGGERS :: `
CREATE TRIGGER IF NOT EXISTS obs_fts_insert AFTER INSERT ON observations
WHEN new.deleted_at IS NULL BEGIN
	INSERT INTO observations_fts(rowid, title, content, tool_name, type, project, topic_key)
	VALUES (new.id, new.title, new.content, new.tool_name, new.type, new.project, new.topic_key);
END;

CREATE TRIGGER IF NOT EXISTS obs_fts_delete BEFORE DELETE ON observations
WHEN old.deleted_at IS NULL BEGIN
	DELETE FROM observations_fts WHERE rowid = old.id;
END;

CREATE TRIGGER IF NOT EXISTS obs_fts_update BEFORE UPDATE ON observations
WHEN old.deleted_at IS NULL BEGIN
	DELETE FROM observations_fts WHERE rowid = old.id;
END;

CREATE TRIGGER IF NOT EXISTS obs_fts_update_insert AFTER UPDATE ON observations
WHEN new.deleted_at IS NULL BEGIN
	INSERT INTO observations_fts(rowid, title, content, tool_name, type, project, topic_key)
	VALUES (new.id, new.title, new.content, new.tool_name, new.type, new.project, new.topic_key);
END;

CREATE TRIGGER IF NOT EXISTS prompt_fts_insert AFTER INSERT ON user_prompts BEGIN
	INSERT INTO prompts_fts(rowid, content, project) VALUES (new.id, new.content, new.project);
END;

CREATE TRIGGER IF NOT EXISTS prompt_fts_delete BEFORE DELETE ON user_prompts BEGIN
	DELETE FROM prompts_fts WHERE rowid = old.id;
END;

CREATE TRIGGER IF NOT EXISTS prompt_fts_update BEFORE UPDATE ON user_prompts BEGIN
	DELETE FROM prompts_fts WHERE rowid = old.id;
END;

CREATE TRIGGER IF NOT EXISTS prompt_fts_update_insert AFTER UPDATE ON user_prompts BEGIN
	INSERT INTO prompts_fts(rowid, content, project) VALUES (new.id, new.content, new.project);
END;
`

migrate :: proc(s: ^STORE) -> string {
	if err := sqlite.exec(s.db, SCHEMA); err != "" {
		return err
	}
	if err := ensure_core_columns(s); err != "" {
		return err
	}
	if err := sqlite.exec(s.db, FTS_TRIGGERS); err != "" {
		return err
	}
	// Older stores may have source rows without a matching FTS index. Rebuild
	// only when counts disagree; a healthy Engram store is left untouched.
	if fts_count(s, "observations", "deleted_at IS NULL") != fts_count(s, "observations_fts_docsize", "") {
		if err := rebuild_observations_fts(s); err != "" {
			return err
		}
	}
	if fts_count(s, "user_prompts", "") != fts_count(s, "prompts_fts_docsize", "") {
		if err := rebuild_prompts_fts(s); err != "" {
			return err
		}
	}
	return ""
}

fts_count :: proc(s: ^STORE, table: string, filter: string) -> i64 {
	sql := cat("SELECT COUNT(*) FROM ", table)
	if filter != "" {
		sql = cat(sql, " WHERE ", filter)
	}
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return -1
	}
	defer sqlite.finalize(&stmt)
	has, serr := sqlite.step(&stmt)
	if serr != "" || !has {
		return -1
	}
	return sqlite.column_int(&stmt, 0)
}

rebuild_observations_fts :: proc(s: ^STORE) -> string {
	return sqlite.exec(s.db, `
		DROP TRIGGER IF EXISTS obs_fts_insert;
		DROP TRIGGER IF EXISTS obs_fts_update_insert;
		DROP TRIGGER IF EXISTS obs_fts_update;
		DROP TRIGGER IF EXISTS obs_fts_delete;
		DROP TABLE IF EXISTS observations_fts;
		CREATE VIRTUAL TABLE observations_fts USING fts5(
			title, content, tool_name, type, project, topic_key,
			tokenize='trigram', content='observations', content_rowid='id'
		);
		INSERT INTO observations_fts(observations_fts) VALUES('rebuild');
		DELETE FROM observations_fts WHERE rowid IN (SELECT id FROM observations WHERE deleted_at IS NOT NULL);
		CREATE TRIGGER obs_fts_insert AFTER INSERT ON observations
		WHEN new.deleted_at IS NULL BEGIN
			INSERT INTO observations_fts(rowid, title, content, tool_name, type, project, topic_key)
			VALUES (new.id, new.title, new.content, new.tool_name, new.type, new.project, new.topic_key);
		END;
		CREATE TRIGGER obs_fts_delete BEFORE DELETE ON observations
		WHEN old.deleted_at IS NULL BEGIN
			DELETE FROM observations_fts WHERE rowid = old.id;
		END;
		CREATE TRIGGER obs_fts_update BEFORE UPDATE ON observations
		WHEN old.deleted_at IS NULL BEGIN
			DELETE FROM observations_fts WHERE rowid = old.id;
		END;
		CREATE TRIGGER obs_fts_update_insert AFTER UPDATE ON observations
		WHEN new.deleted_at IS NULL BEGIN
			INSERT INTO observations_fts(rowid, title, content, tool_name, type, project, topic_key)
			VALUES (new.id, new.title, new.content, new.tool_name, new.type, new.project, new.topic_key);
		END;
	`)
}

rebuild_prompts_fts :: proc(s: ^STORE) -> string {
	return sqlite.exec(s.db, `
		DROP TRIGGER IF EXISTS prompt_fts_insert;
		DROP TRIGGER IF EXISTS prompt_fts_update_insert;
		DROP TRIGGER IF EXISTS prompt_fts_update;
		DROP TRIGGER IF EXISTS prompt_fts_delete;
		DROP TABLE IF EXISTS prompts_fts;
		CREATE VIRTUAL TABLE prompts_fts USING fts5(
			content, project, tokenize='trigram', content='user_prompts', content_rowid='id'
		);
		INSERT INTO prompts_fts(prompts_fts) VALUES('rebuild');
		CREATE TRIGGER prompt_fts_insert AFTER INSERT ON user_prompts BEGIN
			INSERT INTO prompts_fts(rowid, content, project) VALUES (new.id, new.content, new.project);
		END;
		CREATE TRIGGER prompt_fts_delete BEFORE DELETE ON user_prompts BEGIN
			DELETE FROM prompts_fts WHERE rowid = old.id;
		END;
		CREATE TRIGGER prompt_fts_update BEFORE UPDATE ON user_prompts BEGIN
			DELETE FROM prompts_fts WHERE rowid = old.id;
		END;
		CREATE TRIGGER prompt_fts_update_insert AFTER UPDATE ON user_prompts BEGIN
			INSERT INTO prompts_fts(rowid, content, project) VALUES (new.id, new.content, new.project);
		END;
	`)
}

// ensure_core_columns upgrades stores created by older Engram schemas. Every
// statement is additive and nullable/defaulted.
ensure_core_columns :: proc(s: ^STORE) -> string {
	observations := []struct {
		name:       string,
		definition: string,
	}{
		{"sync_id", "TEXT"},
		{"scope", "TEXT NOT NULL DEFAULT 'project'"},
		{"topic_key", "TEXT"},
		{"normalized_hash", "TEXT"},
		{"revision_count", "INTEGER NOT NULL DEFAULT 1"},
		{"duplicate_count", "INTEGER NOT NULL DEFAULT 1"},
		{"last_seen_at", "TEXT"},
		{"pinned", "BOOLEAN NOT NULL DEFAULT 0"},
		{"updated_at", "TEXT NOT NULL DEFAULT ''"},
		{"deleted_at", "TEXT"},
		{"review_after", "TEXT"},
		{"superseded_by_sync_id", "TEXT"},
		{"expires_at", "TEXT"},
		{"embedding", "BLOB"},
		{"embedding_model", "TEXT"},
		{"embedding_created_at", "TEXT"},
	}
	for column in observations {
		if err := ensure_column(s, "observations", column.name, column.definition); err != "" {
			return err
		}
	}
	sessions := []struct {
		name:       string,
		definition: string,
	}{
		{"ownership_mode", "TEXT"},
		{"runtime_lease_expires_at", "TEXT"},
		{"local_creation_project", "TEXT"},
	}
	for column in sessions {
		if err := ensure_column(s, "sessions", column.name, column.definition); err != "" {
			return err
		}
	}
	prompts := []struct {
		name:       string,
		definition: string,
	}{
		{"sync_id", "TEXT"},
		{"source_inbox_id", "TEXT"},
		{"local_creation_session_id", "TEXT"},
		{"local_creation_inbox_id", "TEXT"},
		{"local_creation_project", "TEXT"},
	}
	for column in prompts {
		if err := ensure_column(s, "user_prompts", column.name, column.definition); err != "" {
			return err
		}
	}
	if err := ensure_column(s, "sync_mutations", "project", "TEXT NOT NULL DEFAULT ''"); err != "" {
		return err
	}
	if err := ensure_column(s, "sync_delete_tombstones", "superseded_by_sync_id", "TEXT"); err != "" {
		return err
	}
	return ""
}

ensure_column :: proc(s: ^STORE, table: string, column: string, definition: string) -> string {
	if table_has_column(s, table, column) {
		return ""
	}
	sql := cat("ALTER TABLE ", table, " ADD COLUMN ", column, " ", definition)
	return sqlite.exec(s.db, sql)
}

table_has_column :: proc(s: ^STORE, table: string, column: string) -> bool {
	sql := cat("PRAGMA table_info(", table, ")")
	stmt, err := sqlite.prepare(s.db, sql)
	if err != "" {
		return false
	}
	defer sqlite.finalize(&stmt)
	for {
		has_row, serr := sqlite.step(&stmt)
		if serr != "" || !has_row {
			return false
		}
		if sqlite.column_text(&stmt, 1) == column {
			return true
		}
	}
}

// table_exists is used by diagnostics and by the incremental port's tests.
table_exists :: proc(s: ^STORE, name: string) -> bool {
	stmt, err := sqlite.prepare(s.db, "SELECT 1 FROM sqlite_master WHERE name = ? LIMIT 1")
	if err != "" {
		return false
	}
	defer sqlite.finalize(&stmt)
	if berr := sqlite.bind_text(&stmt, 1, name); berr != "" {
		return false
	}
	has_row, serr := sqlite.step(&stmt)
	return serr == "" && has_row
}

// normalize_sql is a tiny helper for diagnostics output.
_normalize_sql :: proc(sql: string) -> string {
	return strings.trim_space(strings.join(strings.fields(sql), " "))
}
