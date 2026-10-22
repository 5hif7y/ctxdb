package store

import "../sqlite"

Config :: struct {
	data_dir:               string,
	max_observation_length: int,
	max_context_results:    int,
	max_search_results:     int,
	dedupe_window_minutes:  int,
}

DEFAULT_MAX_OBSERVATION_LENGTH :: 50000
DEFAULT_MAX_CONTEXT_RESULTS :: 20
DEFAULT_MAX_SEARCH_RESULTS :: 20
DEFAULT_DEDUPE_WINDOW_MINUTES :: 15

STORE :: struct {
	db:   ^sqlite.DB,
	cfg:  Config,
	path: string,
}

Session :: struct {
	id:                    string `json:"id"`,
	project:               string `json:"project"`,
	ownership_mode:        string `json:"ownership_mode,omitempty"`,
	directory:             string `json:"directory"`,
	started_at:            string `json:"started_at"`,
	ended_at:              string `json:"ended_at,omitempty"`,
	summary:               string `json:"summary,omitempty"`,
	runtime_lease_expires: string `json:"-"`,
}

SessionSummary :: struct {
	id:                string `json:"id"`,
	project:           string `json:"project"`,
	started_at:        string `json:"started_at"`,
	ended_at:          string `json:"ended_at,omitempty"`,
	summary:           string `json:"summary,omitempty"`,
	observation_count: int    `json:"observation_count"`,
}

Observation :: struct {
	id:                    i64    `json:"id"`,
	sync_id:               string `json:"sync_id"`,
	session_id:            string `json:"session_id"`,
	type:                  string `json:"type"`,
	title:                 string `json:"title"`,
	content:               string `json:"content"`,
	tool_name:             string `json:"tool_name,omitempty"`,
	project:               string `json:"project,omitempty"`,
	scope:                 string `json:"scope"`,
	topic_key:             string `json:"topic_key,omitempty"`,
	revision_count:        int    `json:"revision_count"`,
	duplicate_count:       int    `json:"duplicate_count"`,
	last_seen_at:          string `json:"last_seen_at,omitempty"`,
	review_after:          string `json:"review_after,omitempty"`,
	superseded_by_sync_id: string `json:"superseded_by_sync_id,omitempty"`,
	pinned:                bool   `json:"-"`,
	created_at:            string `json:"created_at"`,
	updated_at:            string `json:"updated_at"`,
	deleted_at:            string `json:"deleted_at,omitempty"`,
}

// Observation_State mirrors the virtual lifecycle field exposed by Engram.
Observation_State :: enum {
	active,
	needs_review,
}

// observation_state classifies review_after against the supplied now string.
// Both values use SQLite's "YYYY-MM-DD HH:MM:SS" shape, so lexicographic
// comparison is sufficient.
observation_state :: proc(o: Observation, now: string) -> Observation_State {
	if o.review_after == "" || now == "" {
		return .active
	}
	return .needs_review if o.review_after <= now else .active
}

SearchResult :: struct {
	using _: Observation,
	rank:    f64 `json:"rank"`,
}

SearchPreviewResult :: struct {
	id:           i64    `json:"id"`,
	sync_id:      string `json:"sync_id"`,
	type:         string `json:"type"`,
	title:        string `json:"title"`,
	preview:      string `json:"preview"`,
	truncated:    bool   `json:"truncated"`,
	project:      string `json:"project,omitempty"`,
	topic_key:    string `json:"topic_key,omitempty"`,
	scope:        string `json:"scope"`,
	review_after: string `json:"review_after,omitempty"`,
	pinned:       bool   `json:"-"`,
	created_at:   string `json:"created_at"`,
	rank:         f64    `json:"rank"`,
}

TimelineEntry :: struct {
	id:                    i64    `json:"id"`,
	session_id:            string `json:"session_id"`,
	type:                  string `json:"type"`,
	title:                 string `json:"title"`,
	content:               string `json:"content"`,
	tool_name:             string `json:"tool_name,omitempty"`,
	project:               string `json:"project,omitempty"`,
	scope:                 string `json:"scope"`,
	topic_key:             string `json:"topic_key,omitempty"`,
	revision_count:        int    `json:"revision_count"`,
	duplicate_count:       int    `json:"duplicate_count"`,
	last_seen_at:          string `json:"last_seen_at,omitempty"`,
	superseded_by_sync_id: string `json:"superseded_by_sync_id,omitempty"`,
	created_at:            string `json:"created_at"`,
	updated_at:            string `json:"updated_at"`,
	deleted_at:            string `json:"deleted_at,omitempty"`,
	is_focus:              bool   `json:"is_focus"`,
}

TimelineResult :: struct {
	focus:          Observation     `json:"focus"`,
	before:         []TimelineEntry `json:"before"`,
	after:          []TimelineEntry `json:"after"`,
	session_info:   Maybe(Session)  `json:"session_info"`,
	total_in_range: int             `json:"total_in_range"`,
}

SearchOptions :: struct {
	type:       string,
	project:    string,
	scope:      string,
	limit:      int,
	match_mode: string, // "" | "all" | "any"
}

AddObservationParams :: struct {
	session_id:   string,
	type:         string,
	title:        string,
	content:      string,
	tool_name:    string,
	project:      string,
	scope:        string,
	topic_key:    string,
	operation_id: string,
}

AddObservationResult :: struct {
	id:       i64,
	replayed: bool,
}

UpdateObservationParams :: struct {
	type:      Maybe(string),
	title:     Maybe(string),
	content:   Maybe(string),
	find:      Maybe(string),
	replace:   Maybe(string),
	project:   Maybe(string),
	scope:     Maybe(string),
	topic_key: Maybe(string),
}

Prompt :: struct {
	source_inbox_id: string `json:"source_inbox_id,omitempty"`,
	id:              i64    `json:"id"`,
	sync_id:         string `json:"sync_id"`,
	session_id:      string `json:"session_id"`,
	content:         string `json:"content"`,
	project:         string `json:"project,omitempty"`,
	created_at:      string `json:"created_at"`,
}

AddPromptParams :: struct {
	session_id:      string,
	content:         string,
	project:         string,
	source_inbox_id: string,
}

Stats :: struct {
	total_sessions:     int      `json:"total_sessions"`,
	total_observations: int      `json:"total_observations"`,
	total_prompts:      int      `json:"total_prompts"`,
	projects:           []string `json:"projects"`,
}

ProjectStats :: struct {
	name:              string   `json:"name"`,
	observation_count: int      `json:"observation_count"`,
	session_count:     int      `json:"session_count"`,
	prompt_count:      int      `json:"prompt_count"`,
	directories:       []string `json:"directories"`,
}

ContextOptions :: struct {
	sessions:     int,
	pinned:       int,
	observations: int,
	prompts:      int,
	compact:      bool,
	max_bytes:    int,
}

context_options_default :: proc() -> ContextOptions {
	return ContextOptions{
		sessions = 5,
		pinned = 0,
		observations = DEFAULT_MAX_CONTEXT_RESULTS,
		prompts = 10,
		max_bytes = 0,
	}
}

// Stable error strings are part of ctxdb's CLI/MCP contract.
ERR_OBSERVATION_NOT_FOUND :: "observation not found"
ERR_SESSION_NOT_FOUND :: "session not found"
ERR_TITLE_REQUIRED :: "observation title is required"
ERR_CONTENT_REQUIRED :: "observation content is required"
ERR_PROJECT_REQUIRED :: "project is required"
ERR_OPERATION_CONFLICT :: "observation operation conflict"
ERR_OPERATION_EXPIRED :: "observation operation expired"

// Now returns a timestamp string ordered lexicographically with SQLite's
// datetime() values. Microseconds keep ordering strict inside one session.
Now :: proc(db: ^sqlite.DB) -> string {
	stmt, err := sqlite.prepare(db, "SELECT datetime('now')")
	if err != "" {
		return ""
	}
	defer sqlite.finalize(&stmt)
	has_row, serr := sqlite.step(&stmt)
	if serr != "" || !has_row {
		return ""
	}
	return sqlite.column_text(&stmt, 0)
}
