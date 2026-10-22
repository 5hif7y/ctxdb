// MCP stdio server for ctxdb.
//
// Messages are newline-delimited JSON-RPC 2.0, matching the stdio transport
// used by Engram's Go server. The implementation is intentionally synchronous:
// a single SQLite connection serializes local writes.
#+feature dynamic-literals
package mcp

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "../project"
import "../sqlite"
import "../store"
import "../util"

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

SERVER_NAME :: "ctxdb"
SERVER_VERSION :: "0.1.0"
PROTOCOL_VERSION :: "2025-06-18"

RPC_Request :: struct {
	jsonrpc: string     `json:"jsonrpc"`,
	id:      json.Value `json:"id"`,
	method:  string     `json:"method"`,
	params:  json.Value `json:"params"`,
}

Property :: struct {
	type:        string `json:"type"`,
	description: string `json:"description,omitempty"`,
}

Schema :: struct {
	type:       string              `json:"type"`,
	properties: map[string]Property `json:"properties"`,
	required:   []string            `json:"required,omitempty"`,
}

Tool :: struct {
	name:        string `json:"name"`,
	description: string `json:"description"`,
	inputSchema: Schema `json:"inputSchema"`,
}

Tool_List :: struct {
	tools: []Tool `json:"tools"`,
}

Text_Content :: struct {
	type: string `json:"type"`,
	text: string `json:"text"`,
}

Call_Result :: struct {
	content: []Text_Content `json:"content"`,
	isError: bool           `json:"isError,omitempty"`,
}

Server_Info :: struct {
	name:    string `json:"name"`,
	version: string `json:"version"`,
}

Capabilities :: struct {
	tools: map[string]bool `json:"tools"`,
}

Init_Result :: struct {
	protocolVersion: string       `json:"protocolVersion"`,
	capabilities:    Capabilities `json:"capabilities"`,
	serverInfo:      Server_Info  `json:"serverInfo"`,
}

JSON_Object_Result :: struct {
	value: string
}

arg_string :: proc(args: json.Object, key: string) -> string {
	v, ok := args[key]
	if !ok {
		return ""
	}
	#partial switch x in v {
	case json.String:
		return string(x)
	case json.Integer:
		return fmt.tprintf("%d", x)
	case json.Float:
		return fmt.tprintf("%g", x)
	case json.Boolean:
		return x ? "true" : "false"
	}
	return ""
}

arg_int :: proc(args: json.Object, key: string, fallback: int) -> int {
	v, ok := args[key]
	if !ok {
		return fallback
	}
	#partial switch x in v {
	case json.Integer:
		return int(x)
	case json.Float:
		return int(x)
	case json.String:
		return store_parse_int(string(x), fallback)
	}
	return fallback
}

arg_float :: proc(args: json.Object, key: string, fallback: f64) -> f64 {
	v, ok := args[key]
	if !ok {
		return fallback
	}
	#partial switch x in v {
	case json.Float:
		return x
	case json.Integer:
		return f64(x)
	case json.String:
		value, parsed := strconv.parse_f64(string(x))
		if parsed { return value }
	}
	return fallback
}

arg_bool :: proc(args: json.Object, key: string, fallback: bool) -> bool {
	v, ok := args[key]
	if !ok {
		return fallback
	}
	#partial switch x in v {
	case json.Boolean:
		return x
	case json.String:
		return string(x) == "true" || string(x) == "1"
	case json.Integer:
		return x != 0
	}
	return fallback
}

arg_present :: proc(args: json.Object, key: string) -> bool {
	_, ok := args[key]
	return ok
}

store_parse_int :: proc(value: string, fallback: int) -> int {
	n := 0
	sign := 1
	i := 0
	if len(value) > 0 && value[0] == '-' {
		sign = -1
		i = 1
	}
	for ; i < len(value); i += 1 {
		c := value[i]
		if c < '0' || c > '9' {
			return fallback
		}
		n = n * 10 + int(c - '0')
	}
	return n * sign
}

schema :: proc(props: map[string]Property, required: []string = nil) -> Schema {
	// A dynamic slice literal is backed by temporary storage; copy it to the
	// heap so schemas remain valid after the tool list construction returns.
	required_slice := required
	if len(required) > 0 {
		required_slice = make([]string, len(required))
		copy(required_slice, required)
	}
	return Schema{type = "object", properties = props, required = required_slice}
}

str_prop :: proc(description: string) -> Property {
	return Property{type = "string", description = description}
}

int_prop :: proc(description: string) -> Property {
	return Property{type = "integer", description = description}
}

bool_prop :: proc(description: string) -> Property {
	return Property{type = "boolean", description = description}
}

tool_list :: proc() -> [dynamic]Tool {
	tools := make([dynamic]Tool, 0, 24)
	append(&tools, Tool{
		name = "mem_save",
		description = "Save an important observation (decision, bugfix, pattern, discovery, config, session summary) to persistent memory.",
		inputSchema = schema(map[string]Property{
			"title" = str_prop("Short, searchable title"),
			"content" = str_prop("Structured content; What / Why / Where / Learned"),
			"type" = str_prop("Category: decision, architecture, bugfix, pattern, config, discovery, learning (default: manual)"),
			"session_id" = str_prop("Existing session identity"),
			"scope" = str_prop("project (default), personal, or global"),
			"topic_key" = str_prop("Topic key for upserts (e.g. architecture/auth-model)"),
			"project" = str_prop("Explicit project name"),
			"operation_id" = str_prop("Optional replay-safe operation id"),
		}, []string{"title"}),
	})
	append(&tools, Tool{
		name = "mem_search",
		description = "Search past memories. Returns compact results; use mem_get_observation for full content.",
		inputSchema = schema(map[string]Property{
			"query" = str_prop("Search query"),
			"type" = str_prop("Optional observation type filter"),
			"project" = str_prop("Known project; omit for current project"),
			"all_projects" = bool_prop("Search every project"),
			"scope" = str_prop("Optional scope filter"),
			"match" = str_prop("all (default) or any"),
			"limit" = int_prop("Max results (default 10)"),
		}, []string{"query"}),
	})
	append(&tools, Tool{
		name = "mem_get_observation",
		description = "Get the full untruncated observation by numeric ID.",
		inputSchema = schema(map[string]Property{"id" = int_prop("Observation ID")}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_context",
		description = "Get recent session context for the current project.",
		inputSchema = schema(map[string]Property{
			"project" = str_prop("Project name"),
			"all_projects" = bool_prop("Cross-project context"),
			"scope" = str_prop("Optional scope filter"),
		}),
	})
	append(&tools, Tool{
		name = "mem_session_start",
		description = "Register or renew a runtime session.",
		inputSchema = schema(map[string]Property{
			"id" = str_prop("Session ID"),
			"project" = str_prop("Project name"),
			"directory" = str_prop("Working directory"),
		}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_session_end",
		description = "Mark a session as ended and store its summary.",
		inputSchema = schema(map[string]Property{
			"id" = str_prop("Session ID"),
			"summary" = str_prop("Session summary"),
		}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_session_summary",
		description = "Save a session summary observation and end the session atomically.",
		inputSchema = schema(map[string]Property{
			"session_id" = str_prop("Session ID"),
			"summary" = str_prop("Goal / Discoveries / Accomplished / Next Steps / Files"),
			"project" = str_prop("Project name"),
		}, []string{"session_id", "summary"}),
	})
	append(&tools, Tool{
		name = "mem_save_prompt",
		description = "Persist a user prompt as retrievable context.",
		inputSchema = schema(map[string]Property{
			"session_id" = str_prop("Session ID"),
			"content" = str_prop("Prompt content"),
			"project" = str_prop("Project name"),
			"source_inbox_id" = str_prop("Optional inbox identity"),
		}, []string{"session_id", "content"}),
	})
	append(&tools, Tool{
		name = "mem_search_prompts",
		description = "Search stored prompts and return their original content.",
		inputSchema = schema(map[string]Property{
			"query" = str_prop("Prompt search query"),
			"project" = str_prop("Known project"),
			"all_projects" = bool_prop("Search every project"),
			"limit" = int_prop("Max results (default 10)"),
		}, []string{"query"}),
	})
	append(&tools, Tool{
		name = "mem_current_project",
		description = "Detect the current project from the working directory.",
		inputSchema = schema(map[string]Property{}),
	})
	append(&tools, Tool{
		name = "mem_list_projects",
		description = "List every known project with observation, session, and prompt counts.",
		inputSchema = schema(map[string]Property{}),
	})
	append(&tools, Tool{
		name = "mem_timeline",
		description = "Show chronological context around an observation.",
		inputSchema = schema(map[string]Property{
			"id" = int_prop("Observation ID"),
			"before" = int_prop("Entries before (default 5)"),
			"after" = int_prop("Entries after (default 5)"),
		}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_delete",
		description = "Delete an observation by ID. Soft-delete by default; hard_delete=true is permanent.",
		inputSchema = schema(map[string]Property{
			"id" = int_prop("Observation ID"),
			"hard_delete" = bool_prop("Permanently remove the row"),
		}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_update",
		description = "Update an existing observation by ID. Only provided fields change.",
		inputSchema = schema(map[string]Property{
			"id" = int_prop("Observation ID"),
			"title" = str_prop("New title"),
			"content" = str_prop("New content"),
			"find" = str_prop("Literal text to replace (requires replace)"),
			"replace" = str_prop("Replacement text (requires find)"),
			"type" = str_prop("New type"),
			"scope" = str_prop("New scope"),
			"topic_key" = str_prop("New topic key"),
		}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_stats",
		description = "Return memory-system counters and known projects.",
		inputSchema = schema(map[string]Property{
			"project" = str_prop("Optional project scope"),
		}),
	})
	append(&tools, Tool{
		name = "mem_suggest_topic_key",
		description = "Suggest a stable topic_key for an observation save.",
		inputSchema = schema(map[string]Property{
			"type" = str_prop("Observation type"),
			"title" = str_prop("Observation title"),
			"content" = str_prop("Observation content"),
		}),
	})
	append(&tools, Tool{
		name = "mem_pin",
		description = "Pin an observation so it appears in context.",
		inputSchema = schema(map[string]Property{"id" = int_prop("Observation ID")}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_unpin",
		description = "Unpin an observation.",
		inputSchema = schema(map[string]Property{"id" = int_prop("Observation ID")}, []string{"id"}),
	})
	append(&tools, Tool{
		name = "mem_review",
		description = "List observations due for review or reset one observation's review date.",
		inputSchema = schema(map[string]Property{
			"action" = str_prop("list | mark_reviewed"),
			"project" = str_prop("Project filter for list"),
			"limit" = int_prop("Max results for list"),
			"observation_id" = int_prop("Observation id for mark_reviewed"),
		}, []string{"action"}),
	})
	append(&tools, Tool{
		name = "mem_judge",
		description = "Record a verdict for a pending memory relation (conflict).",
		inputSchema = schema(map[string]Property{
			"judgment_id" = str_prop("Relation sync_id"),
			"relation" = str_prop("related, compatible, scoped, conflicts_with, supersedes, not_conflict"),
			"reason" = str_prop("Optional explanation"),
			"evidence" = str_prop("Optional evidence"),
			"confidence" = Property{type = "number", description = "0.0..1.0"},
			"session_id" = str_prop("Session where the judgment was made"),
		}, []string{"judgment_id", "relation"}),
	})
	append(&tools, Tool{
		name = "mem_judge_many",
		description = "Record 1..32 independent relation verdicts and return ordered outcomes.",
		inputSchema = schema(map[string]Property{
			"judgments" = Property{type = "array", description = "Array of {judgment_id, relation, reason?, evidence?, confidence?}"},
			"session_id" = str_prop("Session id"),
		}, []string{"judgments"}),
	})
	append(&tools, Tool{
		name = "mem_compare",
		description = "Persist a semantic verdict between two observations by integer ID.",
		inputSchema = schema(map[string]Property{
			"memory_id_a" = int_prop("First observation ID"),
			"memory_id_b" = int_prop("Second observation ID"),
			"relation" = str_prop("Verdict verb"),
			"reasoning" = str_prop("Short explanation"),
			"confidence" = Property{type = "number", description = "0.0..1.0"},
			"model" = str_prop("Model identifier"),
		}, []string{"memory_id_a", "memory_id_b", "relation", "reasoning", "confidence"}),
	})
	append(&tools, Tool{
		name = "mem_consolidate",
		description = "Preview or apply an atomic merge of multiple live observations.",
		inputSchema = schema(map[string]Property{
			"ids" = Property{type = "array", description = "Observation IDs (at least two)"},
			"overrides" = Property{type = "object", description = "Optional title/content/type/topic_key"},
			"confirm" = bool_prop("Apply the merge"),
			"fingerprint" = str_prop("Fingerprint returned by the preview"),
		}, []string{"ids"}),
	})
	append(&tools, Tool{
		name = "mem_capture_passive",
		description = "Extract Key Learnings / Aprendizajes items from text and save them.",
		inputSchema = schema(map[string]Property{
			"session_id" = str_prop("Session ID"),
			"content" = str_prop("Agent output to scan"),
			"project" = str_prop("Project name"),
			"source" = str_prop("Source label"),
		}, []string{"session_id", "content"}),
	})
	append(&tools, Tool{
		name = "mem_session_finalize",
		description = "Atomically save a session summary observation and end the session.",
		inputSchema = schema(map[string]Property{
			"session_id" = str_prop("Session ID"),
			"project" = str_prop("Project name"),
			"summary" = str_prop("Structured session summary"),
		}, []string{"session_id", "summary"}),
	})
	append(&tools, Tool{
		name = "mem_merge_projects",
		description = "Merge legacy project-name variants into one canonical project.",
		inputSchema = schema(map[string]Property{
			"from" = str_prop("Comma-separated source project names"),
			"to" = str_prop("Canonical project name"),
		}, []string{"from", "to"}),
	})
	append(&tools, Tool{
		name = "mem_doctor",
		description = "Read-only operational diagnostics for the local store.",
		inputSchema = schema(map[string]Property{}),
	})
	return tools
}

result_text :: proc(text: string, is_error := false) -> Call_Result {
	content := make([]Text_Content, 1)
	content[0] = Text_Content{type = "text", text = text}
	return Call_Result{content = content, isError = is_error}
}

json_text :: proc(value: any) -> (string, bool) {
	data, err := json.marshal(value)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// Serve runs the stdio MCP loop until stdin closes.
Serve :: proc(s: ^store.STORE, default_project: string) {
	r: bufio.Reader
	bufio.reader_init(&r, os.to_reader(os.stdin))
	defer bufio.reader_destroy(&r)

	for {
		line, rerr := bufio.reader_read_string(&r, '\n')
		if rerr != nil {
			break
		}
		trimmed := strings.trim_space(line)
		if trimmed == "" {
			continue
		}
		handle_line(s, default_project, trimmed)
	}
}

handle_line :: proc(s: ^store.STORE, default_project: string, line: string) {
	req: RPC_Request
	if err := json.unmarshal_string(line, &req); err != nil {
		write_error(json.Value{}, -32700, "parse error")
		return
	}
	defer json.destroy_value(req.id)
	defer json.destroy_value(req.params)

	if req.method == "notifications/initialized" || req.method == "notifications/cancelled" {
		return
	}
	switch req.method {
	case "initialize":
		write_result(req.id, Init_Result{
			protocolVersion = PROTOCOL_VERSION,
			capabilities = Capabilities{tools = map[string]bool{"listChanged" = false}},
			serverInfo = Server_Info{name = SERVER_NAME, version = SERVER_VERSION},
		})
	case "ping":
		write_result(req.id, struct{}{})
	case "tools/list":
		tools := tool_list()
		write_result(req.id, Tool_List{tools = tools[:]})
		for i in 0 ..< len(tools) {
			delete(tools[i].inputSchema.properties)
			if tools[i].inputSchema.required != nil {
				delete(tools[i].inputSchema.required)
			}
		}
		delete(tools)
	case "tools/call":
		handle_tool_call(s, default_project, req.id, req.params)
	case "resources/list":
		write_result(req.id, struct{ resources: []string } {resources = []string{}})
	case "prompts/list":
		write_result(req.id, struct{ prompts: []string } {prompts = []string{}})
	case:
		write_error(req.id, -32601, cat("method not found: ", req.method))
	}
}

handle_tool_call :: proc(s: ^store.STORE, default_project: string, id: json.Value, params: json.Value) {
	name_value, name_err := json.match(params, "name", flags = {.Ignore_Key_Not_Found})
	if name_err != .None {
		write_tool_error(id, "missing tool name")
		return
	}
	name: string
	#partial switch v in name_value {
	case json.String:
		name = string(v)
	case:
		write_tool_error(id, "tool name must be a string")
		return
	}
	args_value, args_err := json.match(params, "arguments", flags = {.Ignore_Key_Not_Found})
	args: json.Object
	if args_err == .None {
		if object, ok := args_value.(json.Object); ok {
			args = object
		}
	}

	switch name {
	case "mem_current_project":
		cwd, _ := os.getwd(context.allocator)
		result, err := project.Resolve(default_project, cwd)
		if err != "" {
			write_tool_error(id, err)
			return
		}
		text, _ := json_text(result)
		write_tool_result(id, text)
	case "mem_save":
		handle_save(s, default_project, id, args)
	case "mem_search":
		handle_search(s, default_project, id, args)
	case "mem_get_observation":
		obs_id := i64(arg_int(args, "id", 0))
		obs, err := store.GetObservation(s, obs_id)
		if err != "" {
			write_tool_error(id, err)
			return
		}
		now := store.Now(s.db)
		text, _ := json_text(struct {
			using observation: store.Observation,
			state:             store.Observation_State,
		}{observation = obs, state = store_observation_state(obs, now)})
		write_tool_result(id, text)
	case "mem_context":
		write_context(s, default_project, id, args)
	case "mem_session_start":
		handle_session_start(s, default_project, id, args)
	case "mem_session_end":
		session_id := arg_string(args, "id")
		if err := store.EndSession(s, session_id, arg_string(args, "summary")); err != "" {
			write_tool_error(id, err)
			return
		}
		write_tool_result(id, cat("Session ended: ", session_id))
	case "mem_session_summary":
		handle_session_summary(s, default_project, id, args)
	case "mem_save_prompt":
		handle_save_prompt(s, default_project, id, args)
	case "mem_search_prompts":
		handle_search_prompts(s, default_project, id, args)
	case "mem_list_projects":
		projects, err := store.ListProjectsWithStats(s)
		if err != "" {
			write_tool_error(id, err)
			return
		}
		defer delete(projects)
		text, _ := json_text(projects)
		write_tool_result(id, text)
	case "mem_timeline":
		result, err := store.Timeline(s, i64(arg_int(args, "id", 0)), arg_int(args, "before", 5), arg_int(args, "after", 5))
		if err != "" {
			write_tool_error(id, err)
			return
		}
		defer delete(result.before)
		defer delete(result.after)
		text, _ := json_text(result)
		write_tool_result(id, text)
	case "mem_delete":
		err := store.DeleteObservation(s, i64(arg_int(args, "id", 0)), arg_bool(args, "hard_delete", false))
		if err != "" {
			write_tool_error(id, err)
			return
		}
		write_tool_result(id, "Observation deleted")
	case "mem_update":
		handle_update(s, id, args)
	case "mem_stats":
		handle_stats(s, default_project, id, args)
	case "mem_suggest_topic_key":
		write_tool_result(id, store.SuggestTopicKey(
			arg_string(args, "type"), arg_string(args, "title"), arg_string(args, "content"),
		))
	case "mem_pin":
		if err := store.PinObservation(s, i64(arg_int(args, "id", 0)), true); err != "" {
			write_tool_error(id, err)
			return
		}
		write_tool_result(id, "Observation pinned")
	case "mem_unpin":
		if err := store.PinObservation(s, i64(arg_int(args, "id", 0)), false); err != "" {
			write_tool_error(id, err)
			return
		}
		write_tool_result(id, "Observation unpinned")
	case "mem_review":
		handle_review(s, default_project, id, args)
	case "mem_judge":
		handle_judge(s, id, args)
	case "mem_judge_many":
		handle_judge_many(s, id, args)
	case "mem_compare":
		handle_compare(s, id, args)
	case "mem_consolidate":
		handle_consolidate(s, id, args)
	case "mem_capture_passive":
		handle_capture_passive(s, default_project, id, args)
	case "mem_session_finalize":
		handle_session_finalize(s, default_project, id, args)
	case "mem_merge_projects":
		handle_merge_projects(s, id, args)
	case "mem_doctor":
		handle_doctor(s, id)
	case:
		write_tool_error(id, cat("unknown tool: ", name))
	}
}

store_observation_state :: proc(obs: store.Observation, now: string) -> store.Observation_State {
	if obs.review_after == "" || now == "" {
		return .active
	}
	return .needs_review if obs.review_after <= now else .active
}

resolve_project_arg :: proc(s: ^store.STORE, default_project: string, args: json.Object) -> (string, string) {
	explicit := arg_string(args, "project")
	if explicit == "" {
		explicit = default_project
	}
	cwd, _ := os.getwd(context.allocator)
	return store.ResolveCurrentProject(s, explicit, cwd)
}

handle_save :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	title := arg_string(args, "title")
	content := arg_string(args, "content")
	if content == "" {
		content = arg_string(args, "observation")
	}
	if strings.trim_space(title) == "" {
		write_tool_error(id, store.ERR_TITLE_REQUIRED)
		return
	}
	project_name, err := resolve_project_arg(s, default_project, args)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	cwd, _ := os.getwd(context.allocator)
	session_id := arg_string(args, "session_id")
	if session_id == "" {
		session_id, err = store.ActiveSessionForDirectory(s, project_name, cwd)
		if err != "" {
			write_tool_error(id, err)
			return
		}
	}
	typ := arg_string(args, "type")
	if typ == "" {
		typ = "manual"
	}
	result, aerr := store.AddObservation(s, store.AddObservationParams{
		session_id = session_id,
		type = typ,
		title = title,
		content = content,
		project = project_name,
		scope = arg_string(args, "scope"),
		topic_key = arg_string(args, "topic_key"),
		operation_id = arg_string(args, "operation_id"),
	})
	if aerr != "" {
		write_tool_error(id, aerr)
		return
	}
	prefix := "Memory saved"
	if result.replayed {
		prefix = "Memory save replayed"
	}
	write_tool_result(id, fmt.tprintf("%s: #%d %q (%s)", prefix, result.id, title, typ))
}

handle_search :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	query := arg_string(args, "query")
	all_projects := arg_bool(args, "all_projects", false)
	project_name := ""
	err := ""
	if !all_projects {
		project_name, err = resolve_project_arg(s, default_project, args)
		if err != "" {
			write_tool_error(id, err)
			return
		}
	}
	results, serr := store.Search(s, query, store.SearchOptions{
		type = arg_string(args, "type"),
		project = project_name,
		scope = arg_string(args, "scope"),
		limit = arg_int(args, "limit", 10),
		match_mode = arg_string(args, "match"),
	})
	if serr != "" {
		write_tool_error(id, serr)
		return
	}
	defer delete(results)

	compact := make([dynamic]store.SearchPreviewResult, 0, len(results))
	defer delete(compact)
	for r in results {
		cp: store.SearchPreviewResult
		cp.id = r.id
		cp.sync_id = r.sync_id
		cp.type = r.type
		cp.title = r.title
		cp.preview = util.TruncateRunes(r.content, 300)
		cp.truncated = len(r.content) > len(cp.preview)
		cp.project = r.project
		cp.topic_key = r.topic_key
		cp.scope = r.scope
		cp.review_after = r.review_after
		cp.pinned = r.pinned
		cp.created_at = r.created_at
		cp.rank = r.rank
		append(&compact, cp)
	}
	text, _ := json_text(compact[:])
	write_tool_result(id, text)
}

write_context :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	project_name := ""
	if !arg_bool(args, "all_projects", false) {
		err := ""
		project_name, err = resolve_project_arg(s, default_project, args)
		if err != "" {
			write_tool_error(id, err)
			return
		}
	}
	rendered, err := store.FormatContext(s, project_name, arg_string(args, "scope"), store.context_options_default())
	if err != "" {
		write_tool_error(id, err)
		return
	}
	if rendered == "" {
		write_tool_result(id, "No previous session memories found.")
		return
	}
	write_tool_result(id, rendered)
}

handle_session_start :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	project_name, err := resolve_project_arg(s, default_project, args)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	cwd, _ := os.getwd(context.allocator)
	directory := arg_string(args, "directory")
	if directory == "" {
		directory = cwd
	}
	session_id := arg_string(args, "id")
	if serr := store.StartSession(s, session_id, project_name, directory, store.SESSION_OWNERSHIP_SHARED); serr != "" {
		write_tool_error(id, serr)
		return
	}
	write_tool_result(id, cat("Session started: ", session_id))
}

handle_session_summary :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	session_id := arg_string(args, "session_id")
	summary := arg_string(args, "summary")
	project_name, err := resolve_project_arg(s, default_project, args)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	result, aerr := store.AddObservation(s, store.AddObservationParams{
		session_id = session_id,
		type = "session_summary",
		title = "Session summary",
		content = summary,
		project = project_name,
		scope = "project",
	})
	if aerr != "" {
		write_tool_error(id, aerr)
		return
	}
	if eerr := store.EndSession(s, session_id, summary); eerr != "" {
		write_tool_error(id, eerr)
		return
	}
	write_tool_result(id, fmt.tprintf("Session finalized: #%d", result.id))
}

handle_save_prompt :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	project_name, err := resolve_project_arg(s, default_project, args)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	prompt_id, perr := store.AddPrompt(s, store.AddPromptParams{
		session_id = arg_string(args, "session_id"),
		content = arg_string(args, "content"),
		project = project_name,
		source_inbox_id = arg_string(args, "source_inbox_id"),
	})
	if perr != "" {
		write_tool_error(id, perr)
		return
	}
	write_tool_result(id, fmt.tprintf("Prompt saved: #%d", prompt_id))
}

handle_search_prompts :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	project_name := ""
	if !arg_bool(args, "all_projects", false) {
		err := ""
		project_name, err = resolve_project_arg(s, default_project, args)
		if err != "" {
			write_tool_error(id, err)
			return
		}
	}
	prompts, err := store.SearchPrompts(s, arg_string(args, "query"), project_name, arg_int(args, "limit", 10))
	if err != "" {
		write_tool_error(id, err)
		return
	}
	defer delete(prompts)
	text, _ := json_text(prompts)
	write_tool_result(id, text)
}

handle_update :: proc(s: ^store.STORE, id: json.Value, args: json.Object) {
	params: store.UpdateObservationParams
	if arg_present(args, "title") {
		params.title = arg_string(args, "title")
	}
	if arg_present(args, "content") {
		params.content = arg_string(args, "content")
	}
	if arg_present(args, "find") {
		params.find = arg_string(args, "find")
	}
	if arg_present(args, "replace") {
		params.replace = arg_string(args, "replace")
	}
	if arg_present(args, "type") {
		params.type = arg_string(args, "type")
	}
	if arg_present(args, "scope") {
		params.scope = arg_string(args, "scope")
	}
	if arg_present(args, "topic_key") {
		params.topic_key = arg_string(args, "topic_key")
	}
	updated, err := store.UpdateObservation(s, i64(arg_int(args, "id", 0)), params)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	text, _ := json_text(updated)
	write_tool_result(id, text)
}

handle_stats :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	project_name := arg_string(args, "project")
	if project_name == "" {
		project_name = default_project
	}
	stats: store.Stats
	err: string
	if strings.trim_space(project_name) != "" {
		stats, err = store.GetStatsProject(s, project_name)
	} else {
		stats, err = store.GetStats(s)
	}
	if err != "" {
		write_tool_error(id, err)
		return
	}
	text, _ := json_text(stats)
	write_tool_result(id, text)
}

handle_review :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	action := arg_string(args, "action")
	switch action {
	case "list":
		project_name := arg_string(args, "project")
		observations, err := store.ObservationsNeedingReview(s, project_name, arg_int(args, "limit", 10))
		if err != "" {
			write_tool_error(id, err)
			return
		}
		defer delete(observations)
		text, _ := json_text(observations)
		write_tool_result(id, text)
	case "mark_reviewed":
		obs_id := arg_int(args, "observation_id", 0)
		if obs_id == 0 {
			obs_id = arg_int(args, "id", 0)
		}
		if err := store.MarkReviewed(s, i64(obs_id)); err != "" {
			write_tool_error(id, err)
			return
		}
		write_tool_result(id, fmt.tprintf("Observation #%d marked reviewed", obs_id))
	case:
		write_tool_error(id, "action must be list or mark_reviewed")
	}
}

Judgment_Outcome :: struct {
	index:       int    `json:"index"`,
	judgment_id: string `json:"judgment_id"`,
	status:      string `json:"status"`,
	relation:    string `json:"relation,omitempty"`,
	error:       string `json:"error,omitempty"`,
}

handle_judge :: proc(s: ^store.STORE, id: json.Value, args: json.Object) {
	confidence := arg_float(args, "confidence", 0)
	params := store.Judge_Relation_Params{
		judgment_id = arg_string(args, "judgment_id"),
		relation = arg_string(args, "relation"),
		reason = arg_string(args, "reason"),
		evidence = arg_string(args, "evidence"),
		confidence = confidence,
		has_confidence = arg_present(args, "confidence"),
		marked_by_actor = "agent",
		marked_by_kind = "agent",
		session_id = arg_string(args, "session_id"),
	}
	rel, err := store.JudgeRelation(s, params)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	text, _ := json_text(struct{ relation: store.Relation `json:"relation"` }{relation = rel})
	write_tool_result(id, text)
}

handle_judge_many :: proc(s: ^store.STORE, id: json.Value, args: json.Object) {
	raw, ok := args["judgments"]
	if !ok {
		write_tool_error(id, "judgments is required")
		return
	}
	array, is_array := raw.(json.Array)
	if !is_array {
		write_tool_error(id, "judgments must be an array")
		return
	}
	session_id := arg_string(args, "session_id")
	outcomes := make([dynamic]Judgment_Outcome)
	defer delete(outcomes)
	for item, index in array {
		outcome: Judgment_Outcome
		outcome.index = index
		outcome.status = "error"
		object, is_object := item.(json.Object)
		if !is_object {
			outcome.error = "judgment item must be an object"
			append(&outcomes, outcome)
			continue
		}
		outcome.judgment_id = arg_string(object, "judgment_id")
		confidence := arg_float(object, "confidence", 0)
		params := store.Judge_Relation_Params{
			judgment_id = outcome.judgment_id,
			relation = arg_string(object, "relation"),
			reason = arg_string(object, "reason"),
			evidence = arg_string(object, "evidence"),
			confidence = confidence,
			has_confidence = arg_present(object, "confidence"),
			marked_by_actor = "agent",
			marked_by_kind = "agent",
			session_id = session_id,
		}
		rel, err := store.JudgeRelation(s, params)
		if err != "" {
			outcome.error = err
		} else {
			outcome.status = "success"
			outcome.relation = rel.relation
		}
		append(&outcomes, outcome)
	}
	text, _ := json_text(struct{ outcomes: []Judgment_Outcome `json:"outcomes"` }{outcomes = outcomes[:]})
	write_tool_result(id, text)
}

handle_compare :: proc(s: ^store.STORE, id: json.Value, args: json.Object) {
	a, aerr := store.GetObservation(s, i64(arg_int(args, "memory_id_a", 0)))
	if aerr != "" {
		write_tool_error(id, aerr)
		return
	}
	b, berr := store.GetObservation(s, i64(arg_int(args, "memory_id_b", 0)))
	if berr != "" {
		write_tool_error(id, berr)
		return
	}
	sync_id, err := store.JudgeBySemantic(s, store.Judge_By_Semantic_Params{
		source_id = a.sync_id,
		target_id = b.sync_id,
		relation = arg_string(args, "relation"),
		confidence = arg_float(args, "confidence", 0),
		reasoning = arg_string(args, "reasoning"),
		model = arg_string(args, "model"),
	})
	if err != "" {
		write_tool_error(id, err)
		return
	}
	text, _ := json_text(struct{ sync_id: string `json:"sync_id"` }{sync_id = sync_id})
	write_tool_result(id, text)
}

handle_consolidate :: proc(s: ^store.STORE, id: json.Value, args: json.Object) {
	ids: []i64
	if raw, ok := args["ids"]; ok {
		if array, is_array := raw.(json.Array); is_array {
			ids = make([]i64, len(array))
			for item, i in array {
				#partial switch value in item {
				case json.Integer: ids[i] = value
				case json.Float: ids[i] = i64(value)
				}
			}
		}
	}
	defer if ids != nil { delete(ids) }
	overrides: store.Consolidate_Overrides
	if raw, ok := args["overrides"]; ok {
		if object, is_object := raw.(json.Object); is_object {
			overrides.title = arg_string(object, "title")
			overrides.content = arg_string(object, "content")
			overrides.typ = arg_string(object, "type")
			overrides.topic_key = arg_string(object, "topic_key")
		}
	}
	result, err := store.ConsolidateObservations(s, store.Consolidate_Params{
		ids = ids,
		overrides = overrides,
		confirm = arg_bool(args, "confirm", false),
		fingerprint = arg_string(args, "fingerprint"),
	})
	if err != "" {
		write_tool_error(id, err)
		return
	}
	text, _ := json_text(result)
	write_tool_result(id, text)
}

handle_capture_passive :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	project_name, err := resolve_project_arg(s, default_project, args)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	result, perr := store.PassiveCapture(s, store.Passive_Capture_Params{
		session_id = arg_string(args, "session_id"),
		content = arg_string(args, "content"),
		project = project_name,
		source = arg_string(args, "source"),
	})
	if perr != "" {
		write_tool_error(id, perr)
		return
	}
	text, _ := json_text(result)
	write_tool_result(id, text)
}

handle_session_finalize :: proc(s: ^store.STORE, default_project: string, id: json.Value, args: json.Object) {
	project_name, err := resolve_project_arg(s, default_project, args)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	result, ferr := store.FinalizeSession(s, store.Finalize_Session_Params{
		session_id = arg_string(args, "session_id"),
		project = project_name,
		summary = arg_string(args, "summary"),
	})
	if ferr != "" {
		write_tool_error(id, ferr)
		return
	}
	text, _ := json_text(result)
	write_tool_result(id, text)
}

handle_merge_projects :: proc(s: ^store.STORE, id: json.Value, args: json.Object) {
	canonical := arg_string(args, "to")
	from := arg_string(args, "from")
	if canonical == "" || from == "" {
		write_tool_error(id, "both from and to are required")
		return
	}
	sources := strings.split(from, ",")
	defer delete(sources)
	result, err := store.MergeProjects(s, sources, canonical)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	text, _ := json_text(result)
	write_tool_result(id, text)
}

handle_doctor :: proc(s: ^store.STORE, id: json.Value) {
	stats, err := store.GetStats(s)
	if err != "" {
		write_tool_error(id, err)
		return
	}
	report := struct {
		status:       string      `json:"status"`,
		version:      string      `json:"version"`,
		sqlite:       string      `json:"sqlite"`,
		database:     string      `json:"database"`,
		tables_ok:    bool        `json:"tables_ok"`,
		stats:        store.Stats `json:"stats"`,
	}{
		status = "ok",
		version = SERVER_VERSION,
		sqlite = sqlite.libversion(),
		database = store.DBPath(s),
		tables_ok = store.table_exists(s, "observations") && store.table_exists(s, "observations_fts"),
		stats = stats,
	}
	text, _ := json_text(report)
	write_tool_result(id, text)
}

write_result :: proc(id: json.Value, value: any) {
	data, err := json.marshal(value)
	if err != nil {
		write_error(id, -32603, "internal error: cannot encode result")
		return
	}
	id_text, ierr := json.unparse(id)
	if ierr != nil {
		id_text = "null"
	}
	line := cat(`{"jsonrpc":"2.0","id":`, id_text, `,"result":`, string(data), `}`)
	fmt.println(line)
}

write_error :: proc(id: json.Value, code: int, message: string) {
	id_text, ierr := json.unparse(id)
	if ierr != nil {
		id_text = "null"
	}
	escaped, _ := json.marshal(message)
	error_text := fmt.tprintf(`"error":{"code":%d,"message":%s}`, code, string(escaped))
	line := cat(`{"jsonrpc":"2.0","id":`, id_text, `,`, error_text, `}`)
	fmt.println(line)
}

write_tool_result :: proc(id: json.Value, text: string) {
	write_result(id, result_text(text, false))
}

write_tool_error :: proc(id: json.Value, message: string) {
	write_result(id, result_text(message, true))
}
