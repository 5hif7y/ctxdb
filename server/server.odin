// Minimal local HTTP JSON API over the ctxdb store.
//
// The server implements the local Engram route subset with one request per
// connection. It is intentionally dependency-free: HTTP parsing and routing
// are plain Odin over core:net.
package server

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import "../llm"
import "../store"

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

VERSION :: "0.1.0"
DEFAULT_PORT :: 7437

Request :: struct {
	method: string,
	path:   string,
	query:  map[string]string,
	body:   string,
}

Response :: struct {
	status:       int,
	content_type: string,
	body:         string,
}

Serve :: proc(s: ^store.STORE, port: int, default_project: string) -> string {
	listener, lerr := net.listen_tcp({net.IP4_Loopback, port})
	if lerr != nil {
		return fmt.tprintf("listen on 127.0.0.1:%d failed: %v", port, lerr)
	}
	defer net.close(listener)
	fmt.printf("ctxdb HTTP API listening on http://127.0.0.1:%d\n", port)
	for {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			continue
		}
		handle_connection(s, client, default_project)
		net.close(client)
	}
	return ""
}

handle_connection :: proc(s: ^store.STORE, client: net.TCP_Socket, default_project: string) {
	req, rerr := read_request(client)
	if rerr != "" {
		send_response(client, json_error(400, rerr))
		return
	}
	resp := route(s, req, default_project)
	delete(req.method)
	delete(req.path)
	delete(req.body)
	delete(req.query)
	send_response(client, resp)
}

read_request :: proc(client: net.TCP_Socket) -> (Request, string) {
	buf := make([dynamic]u8)
	defer delete(buf)
	tmp: [8192]u8
	header_end := -1
	for header_end < 0 {
		n, rerr := net.recv_tcp(client, tmp[:])
		if n > 0 {
			append(&buf, ..tmp[:n])
		}
		if rerr != nil || n <= 0 {
			return {}, "empty request"
		}
		if len(buf) > 2 * 1024 * 1024 {
			return {}, "request too large"
		}
		header_end = strings.index(string(buf[:]), "\r\n\r\n")
	}

	head := string(buf[:header_end])
	lines := strings.split(head, "\r\n")
	defer delete(lines)
	if len(lines) == 0 {
		return {}, "invalid request line"
	}
	parts := strings.split(lines[0], " ")
	defer delete(parts)
	if len(parts) < 2 {
		return {}, "invalid request line"
	}
	req := Request{method = strings.clone(parts[0])}
	full_path := parts[1]
	if q := strings.index_byte(full_path, '?'); q >= 0 {
		req.path = strings.clone(full_path[:q])
		req.query = parse_query(full_path[q + 1:])
	} else {
		req.path = strings.clone(full_path)
	}

	content_length := 0
	for line in lines[1:] {
		if colon := strings.index_byte(line, ':'); colon > 0 {
			key := strings.to_lower(strings.trim_space(line[:colon]))
			value := strings.trim_space(line[colon + 1:])
			if key == "content-length" {
				content_length = parse_int(value, 0)
			}
		}
	}

	body_start := header_end + 4
	have := len(buf) - body_start
	for have < content_length {
		n, rerr := net.recv_tcp(client, tmp[:])
		if n > 0 {
			append(&buf, ..tmp[:n])
			have += n
		}
		if rerr != nil || n <= 0 {
			break
		}
	}
	if content_length > 0 {
		end := min(body_start + content_length, len(buf))
		req.body = strings.clone(string(buf[body_start:end]))
	}
	return req, ""
}

send_response :: proc(client: net.TCP_Socket, resp: Response) {
	status_text := "OK"
	switch resp.status {
	case 201: status_text = "Created"
	case 204: status_text = "No Content"
	case 400: status_text = "Bad Request"
	case 404: status_text = "Not Found"
	case 405: status_text = "Method Not Allowed"
	case 409: status_text = "Conflict"
	case 422: status_text = "Unprocessable Entity"
	case 500: status_text = "Internal Server Error"
	}
	content_type := resp.content_type
	if content_type == "" {
		content_type = "application/json"
	}
	head := cat(
		"HTTP/1.1 ", fmt.tprintf("%d", resp.status), " ", status_text, "\r\n",
		"Content-Type: ", content_type, "\r\n",
		"Content-Length: ", fmt.tprintf("%d", len(resp.body)), "\r\n",
		"Connection: close\r\n\r\n",
	)
	payload := cat(head, resp.body)
	data := transmute([]u8)payload
	written := 0
	for written < len(data) {
		n, serr := net.send_tcp(client, data[written:])
		if serr != nil || n <= 0 {
			break
		}
		written += n
	}
}

json_ok :: proc(value: any) -> Response {
	data, err := json.marshal(value)
	if err != nil {
		return json_error(500, "cannot encode JSON")
	}
	return Response{status = 200, body = string(data)}
}

json_error :: proc(status: int, message: string) -> Response {
	data, _ := json.marshal(struct{ error: string `json:"error"` }{error = message})
	return Response{status = status, body = string(data)}
}

json_created :: proc(value: any) -> Response {
	resp := json_ok(value)
	resp.status = 201
	return resp
}

route :: proc(s: ^store.STORE, req: Request, default_project: string) -> Response {
	path := req.path
	switch {
	case path == "/health":
		stats, err := store.GetStats(s)
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(struct {
			status:  string      `json:"status"`,
			service: string      `json:"service"`,
			version: string      `json:"version"`,
			stats:   store.Stats `json:"stats"`,
		}{status = "ok", service = "ctxdb", version = VERSION, stats = stats})
	case path == "/sessions/recent" && req.method == "GET":
		project_name := query_project(s, req, default_project)
		sessions, err := store.RecentSessions(s, project_name, query_int(req, "limit", 5))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(sessions)
	case path == "/sessions" && req.method == "POST":
		return handle_create_session(s, req, default_project)
	case strings.has_prefix(path, "/sessions/") && strings.has_suffix(path, "/end") && req.method == "POST":
		id := path[10:len(path) - 4]
		body: struct{ summary: string `json:"summary"` }
		_ = json.unmarshal_string(req.body, &body)
		if err := store.EndSession(s, id, body.summary); err != "" {
			return json_error(404, err)
		}
		return json_ok(struct{ id: string `json:"id"`, status: string `json:"status"` }{id = id, status = "ended"})
	case strings.has_prefix(path, "/sessions/") && strings.has_suffix(path, "/finalize") && req.method == "POST":
		id := path[10:len(path) - 9]
		body: struct {
			project: string `json:"project"`,
			summary: string `json:"summary"`,
		}
		if e := json.unmarshal_string(req.body, &body); e != nil {
			return json_error(400, "invalid JSON body")
		}
		project_name := body.project
		if project_name == "" {
			project_name = default_project
		}
		result, err := store.FinalizeSession(s, store.Finalize_Session_Params{session_id = id, project = project_name, summary = body.summary})
		if err != "" {
			return json_error(400, err)
		}
		return json_ok(result)
	case strings.has_prefix(path, "/sessions/") && req.method == "GET":
		id := path[10:]
		session, err := store.GetSession(s, id)
		if err != "" {
			return json_error(404, err)
		}
		return json_ok(session)
	case strings.has_prefix(path, "/sessions/") && req.method == "DELETE":
		id := path[10:]
		if err := store.DeleteSession(s, id); err != "" {
			return json_error(409, err)
		}
		return Response{status = 204, body = ""}
	case path == "/observations/recent" && req.method == "GET":
		project_name := query_project(s, req, default_project)
		observations, err := store.RecentObservations(s, project_name, query_string(req, "scope"), query_int(req, "limit", 20))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(observations)
	case path == "/observations" && req.method == "POST":
		return handle_add_observation(s, req, default_project)
	case path == "/observations/passive" && req.method == "POST":
		return handle_passive(s, req, default_project)
	case path == "/observations/consolidate" && req.method == "POST":
		return handle_consolidate(s, req)
	case path == "/observations/save-result" && req.method == "GET":
		op := query_string(req, "operation_id")
		id, err := store.GetObservationSaveResult(s, op)
		if err != "" {
			return json_error(409, err)
		}
		return json_ok(struct{ id: i64 `json:"id"` }{id = id})
	case strings.has_prefix(path, "/observations/") && strings.has_suffix(path, "/pin"):
		id := parse_id(path[14:len(path) - 4])
		if req.method == "PUT" {
			if err := store.PinObservation(s, id, true); err != "" {
				return json_error(404, err)
			}
			return json_ok(struct{ pinned: bool `json:"pinned"` }{pinned = true})
		}
		if req.method == "DELETE" {
			if err := store.PinObservation(s, id, false); err != "" {
				return json_error(404, err)
			}
			return json_ok(struct{ pinned: bool `json:"pinned"` }{pinned = false})
		}
		return json_error(405, "method not allowed")
	case strings.has_prefix(path, "/observations/") && req.method == "GET":
		id := parse_id(path[14:])
		obs, err := store.GetObservation(s, id)
		if err != "" {
			return json_error(404, err)
		}
		return json_ok(obs)
	case strings.has_prefix(path, "/observations/") && req.method == "PATCH":
		return handle_update_observation(s, req, path[14:])
	case strings.has_prefix(path, "/observations/") && req.method == "DELETE":
		id := parse_id(path[14:])
		hard := query_string(req, "hard") == "true"
		if err := store.DeleteObservation(s, id, hard); err != "" {
			return json_error(404, err)
		}
		return json_ok(struct{ deleted: bool `json:"deleted"` }{deleted = true})
	case path == "/search" && req.method == "GET":
		return handle_search(s, req, default_project)
	case path == "/context" && req.method == "GET":
		project_name := query_project(s, req, default_project)
		text, err := store.FormatContext(s, project_name, query_string(req, "scope"), store.context_options_default())
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(struct{ ctx_text: string `json:"context"` }{ctx_text = text})
	case path == "/timeline" && req.method == "GET":
		result, err := store.Timeline(s, parse_id(query_string(req, "id")), query_int(req, "before", 5), query_int(req, "after", 5))
		if err != "" {
			return json_error(404, err)
		}
		return json_ok(result)
	case path == "/review" && req.method == "GET":
		observations, err := store.ObservationsNeedingReview(s, query_string(req, "project"), query_int(req, "limit", 10))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(observations)
	case path == "/review/mark_reviewed" && req.method == "POST":
		body: struct {
			observation_id: i64 `json:"observation_id"`,
			id:             i64 `json:"id"`,
		}
		_ = json.unmarshal_string(req.body, &body)
		target := body.observation_id
		if target == 0 {
			target = body.id
		}
		if err := store.MarkReviewed(s, target); err != "" {
			return json_error(404, err)
		}
		return json_ok(struct{ id: i64 `json:"id"`, status: string `json:"status"` }{id = target, status = "reviewed"})
	case path == "/prompts" && req.method == "POST":
		return handle_add_prompt(s, req, default_project)
	case path == "/prompts/recent" && req.method == "GET":
		prompts, err := store.RecentPrompts(s, query_project(s, req, default_project), query_int(req, "limit", 20))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(prompts)
	case path == "/prompts/search" && req.method == "GET":
		prompts, err := store.SearchPrompts(s, query_string(req, "q"), query_project(s, req, default_project), query_int(req, "limit", 10))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(prompts)
	case strings.has_prefix(path, "/prompts/") && req.method == "DELETE":
		if err := store.DeletePrompt(s, parse_id(path[9:])); err != "" {
			return json_error(404, err)
		}
		return Response{status = 204, body = ""}
	case path == "/stats" && req.method == "GET":
		project_name := query_string(req, "project")
		stats: store.Stats
		err: string
		if project_name != "" {
			stats, err = store.GetStatsProject(s, project_name)
		} else {
			stats, err = store.GetStats(s)
		}
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(stats)
	case path == "/projects" && req.method == "GET":
		projects, err := store.ListProjectsWithStats(s)
		if err != "" {
			return json_error(500, err)
		}
		defer delete(projects)
		return json_ok(projects)
	case path == "/project/current" && req.method == "GET":
		cwd, _ := os.getwd(context.allocator)
		project_name, err := store.ResolveCurrentProject(s, default_project, cwd)
		if err != "" {
			return json_error(422, err)
		}
		return json_ok(struct{ project: string `json:"project"` }{project = project_name})
	case path == "/topic-keys/suggest" && req.method == "POST":
		body: struct {
			type:    string `json:"type"`,
			title:   string `json:"title"`,
			content: string `json:"content"`,
		}
		_ = json.unmarshal_string(req.body, &body)
		return json_ok(struct{ topic_key: string `json:"topic_key"` }{topic_key = store.SuggestTopicKey(body.type, body.title, body.content)})
	case path == "/export" && req.method == "GET":
		data, err := store.Export(s, query_string(req, "project"))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(data)
	case path == "/import" && req.method == "POST":
		data: store.Export_Data
		if err := json.unmarshal_string(req.body, &data); err != nil {
			return json_error(400, "invalid import JSON")
		}
		result, err := store.Import(s, data)
		if err != "" {
			return json_error(400, err)
		}
		return json_ok(result)
	case path == "/conflicts" && req.method == "GET":
		items, err := store.ListRelations(s, query_string(req, "project"), query_string(req, "status"), query_int(req, "limit", 0))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(items)
	case path == "/conflicts/stats" && req.method == "GET":
		stats, err := store.RelationStats(s, query_string(req, "project"))
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(stats)
	case strings.has_prefix(path, "/conflicts/") && req.method == "GET":
		rel, err := store.GetRelation(s, path[11:])
		if err != "" {
			return json_error(404, err)
		}
		return json_ok(rel)
	case path == "/conflicts/judge" && req.method == "POST":
		return handle_judge(s, req)
	case path == "/conflicts/compare" && req.method == "POST":
		return handle_compare(s, req)
	case path == "/conflicts/scan" && req.method == "POST":
		body: struct {
			project:     string `json:"project"`,
			limit:       int    `json:"limit"`,
			apply:       bool   `json:"apply"`,
			max_insert:  int    `json:"max_insert"`,
			semantic:    bool   `json:"semantic"`,
			runner:      string `json:"runner"`,
			max_semantic: int   `json:"max_semantic"`,
		}
		_ = json.unmarshal_string(req.body, &body)
		if body.semantic {
			return handle_semantic_scan(s, body.project, body.limit, body.apply, body.runner, body.max_semantic)
		}
		result, err := store.ScanProject(s, store.Scan_Options{project = body.project, limit = body.limit, apply = body.apply, max_insert = body.max_insert})
		if err != "" {
			return json_error(400, err)
		}
		return json_ok(result)
	case path == "/doctor" && req.method == "GET":
		stats, err := store.GetStats(s)
		if err != "" {
			return json_error(500, err)
		}
		return json_ok(struct {
			status:   string      `json:"status"`,
			database: string      `json:"database"`,
			stats:    store.Stats `json:"stats"`,
		}{status = "ok", database = store.DBPath(s), stats = stats})
	case:
		return json_error(404, "not found")
	}
}

handle_create_session :: proc(s: ^store.STORE, req: Request, default_project: string) -> Response {
	body: struct {
		id:        string `json:"id"`,
		project:   string `json:"project"`,
		directory: string `json:"directory"`,
		mode:      string `json:"ownership_mode"`,
	}
	if err := json.unmarshal_string(req.body, &body); err != nil {
		return json_error(400, "invalid JSON body")
	}
	project_name := body.project
	if project_name == "" {
		project_name = default_project
	}
	if project_name == "" {
		cwd, _ := os.getwd(context.allocator)
		resolved, err := store.ResolveCurrentProject(s, "", cwd)
		if err != "" {
			return json_error(422, err)
		}
		project_name = resolved
	}
	mode := body.mode
	if mode == "" {
		mode = store.SESSION_OWNERSHIP_SHARED
	}
	if err := store.StartSession(s, body.id, project_name, body.directory, mode); err != "" {
		return json_error(400, err)
	}
	return json_created(struct{ id: string `json:"id"` }{id = body.id})
}

handle_add_observation :: proc(s: ^store.STORE, req: Request, default_project: string) -> Response {
	body: struct {
		session_id:   string `json:"session_id"`,
		type:         string `json:"type"`,
		title:        string `json:"title"`,
		content:      string `json:"content"`,
		observation:  string `json:"observation"`,
		project:      string `json:"project"`,
		scope:        string `json:"scope"`,
		topic_key:    string `json:"topic_key"`,
		operation_id: string `json:"operation_id"`,
	}
	if err := json.unmarshal_string(req.body, &body); err != nil {
		return json_error(400, "invalid JSON body")
	}
	if body.content == "" {
		body.content = body.observation
	}
	project_name := body.project
	if project_name == "" {
		project_name = default_project
	}
	if project_name == "" {
		cwd, _ := os.getwd(context.allocator)
		resolved, err := store.ResolveCurrentProject(s, "", cwd)
		if err != "" {
			return json_error(422, err)
		}
		project_name = resolved
	}
	session_id := body.session_id
	if session_id == "" {
		cwd, _ := os.getwd(context.allocator)
		resolved, err := store.ActiveSessionForDirectory(s, project_name, cwd)
		if err != "" {
			return json_error(500, err)
		}
		session_id = resolved
	}
	typ := body.type
	if typ == "" {
		typ = "manual"
	}
	result, err := store.AddObservation(s, store.AddObservationParams{
		session_id = session_id, type = typ, title = body.title, content = body.content,
		project = project_name, scope = body.scope, topic_key = body.topic_key,
		operation_id = body.operation_id,
	})
	if err != "" {
		return json_error(400, err)
	}
	return json_created(struct {
		id:     i64    `json:"id"`,
		status: string `json:"status"`,
	}{id = result.id, status = "saved"})
}

handle_update_observation :: proc(s: ^store.STORE, req: Request, id_text: string) -> Response {
	body: struct {
		title:     string `json:"title"`,
		content:   string `json:"content"`,
		find:      string `json:"find"`,
		replace:   string `json:"replace"`,
		type:      string `json:"type"`,
		scope:     string `json:"scope"`,
		topic_key: string `json:"topic_key"`,
	}
	if err := json.unmarshal_string(req.body, &body); err != nil {
		return json_error(400, "invalid JSON body")
	}
	params: store.UpdateObservationParams
	if body.title != "" { params.title = body.title }
	if body.content != "" { params.content = body.content }
	if body.find != "" { params.find = body.find }
	if body.replace != "" { params.replace = body.replace }
	if body.type != "" { params.type = body.type }
	if body.scope != "" { params.scope = body.scope }
	if body.topic_key != "" { params.topic_key = body.topic_key }
	obs, err := store.UpdateObservation(s, parse_id(id_text), params)
	if err != "" {
		return json_error(400, err)
	}
	return json_ok(obs)
}

handle_search :: proc(s: ^store.STORE, req: Request, default_project: string) -> Response {
	query := query_string(req, "q")
	if query == "" {
		query = query_string(req, "query")
	}
	project_name := query_string(req, "project")
	if project_name == "" && query_string(req, "all_projects") != "true" {
		project_name = default_project
	}
	if project_name == "" && query_string(req, "all_projects") != "true" {
		cwd, _ := os.getwd(context.allocator)
		resolved, err := store.ResolveCurrentProject(s, "", cwd)
		if err != "" {
			return json_error(422, err)
		}
		project_name = resolved
	}
	results, err := store.Search(s, query, store.SearchOptions{
		type = query_string(req, "type"), project = project_name,
		scope = query_string(req, "scope"), limit = query_int(req, "limit", 10),
		match_mode = query_string(req, "match"),
	})
	if err != "" {
		return json_error(400, err)
	}
	defer delete(results)
	return json_ok(results)
}

handle_passive :: proc(s: ^store.STORE, req: Request, default_project: string) -> Response {
	body: struct {
		session_id: string `json:"session_id"`,
		content:    string `json:"content"`,
		project:    string `json:"project"`,
		source:     string `json:"source"`,
	}
	_ = json.unmarshal_string(req.body, &body)
	project_name := body.project
	if project_name == "" {
		project_name = default_project
	}
	result, err := store.PassiveCapture(s, store.Passive_Capture_Params{
		session_id = body.session_id, content = body.content,
		project = project_name, source = body.source,
	})
	if err != "" {
		return json_error(400, err)
	}
	return json_ok(result)
}

handle_consolidate :: proc(s: ^store.STORE, req: Request) -> Response {
	body: struct {
		ids:         []i64 `json:"ids"`,
		overrides:   struct {
			title:     string `json:"title"`,
			content:   string `json:"content"`,
			type:      string `json:"type"`,
			topic_key: string `json:"topic_key"`,
		} `json:"overrides"`,
		confirm:     bool   `json:"confirm"`,
		fingerprint: string `json:"fingerprint"`,
	}
	if err := json.unmarshal_string(req.body, &body); err != nil {
		return json_error(400, "invalid JSON body")
	}
	result, err := store.ConsolidateObservations(s, store.Consolidate_Params{
		ids = body.ids,
		overrides = store.Consolidate_Overrides{
			title = body.overrides.title, content = body.overrides.content,
			typ = body.overrides.type, topic_key = body.overrides.topic_key,
		},
		confirm = body.confirm, fingerprint = body.fingerprint,
	})
	if err != "" {
		return json_error(409, err)
	}
	return json_ok(result)
}

handle_add_prompt :: proc(s: ^store.STORE, req: Request, default_project: string) -> Response {
	body: struct {
		session_id:      string `json:"session_id"`,
		content:         string `json:"content"`,
		project:         string `json:"project"`,
		source_inbox_id: string `json:"source_inbox_id"`,
	}
	if err := json.unmarshal_string(req.body, &body); err != nil {
		return json_error(400, "invalid JSON body")
	}
	project_name := body.project
	if project_name == "" {
		project_name = default_project
	}
	id, err := store.AddPrompt(s, store.AddPromptParams{
		session_id = body.session_id, content = body.content,
		project = project_name, source_inbox_id = body.source_inbox_id,
	})
	if err != "" {
		return json_error(400, err)
	}
	return json_created(struct{ id: i64 `json:"id"` }{id = id})
}

handle_semantic_scan :: proc(s: ^store.STORE, project_name: string, limit: int, apply: bool, runner: string, max_semantic: int) -> Response {
	pairs, err := store.FindCandidatePairs(s, project_name, limit, 3)
	if err != "" {
		return json_error(400, err)
	}
	defer delete(pairs)
	if max_semantic > 0 && len(pairs) > max_semantic {
		pairs = pairs[:max_semantic]
	}
	Semantic_Item :: struct {
		source_id:  i64    `json:"source_id"`,
		target_id:  i64    `json:"target_id"`,
		relation:   string `json:"relation"`,
		confidence: f64    `json:"confidence"`,
		reasoning:  string `json:"reasoning"`,
		model:      string `json:"model"`,
		applied:    bool   `json:"applied"`,
		error:      string `json:"error,omitempty"`,
	}
	results := make([dynamic]Semantic_Item, 0, len(pairs))
	defer delete(results)
	judged := 0
	for pair in pairs {
		prompt := llm.BuildPrompt(
			pair.source_sync_id, pair.source_title, pair.source_content,
			pair.target_sync_id, pair.target_title, pair.target_content,
		)
		verdict, verr := llm.Compare(prompt, runner)
		item := Semantic_Item{source_id = pair.source_id, target_id = pair.target_id}
		if verr != "" {
			item.error = verr
			append(&results, item)
			continue
		}
		item.relation = verdict.relation
		item.confidence = verdict.confidence
		item.reasoning = verdict.reasoning
		item.model = verdict.model
		if apply {
			_, jerr := store.JudgeBySemantic(s, store.Judge_By_Semantic_Params{
				source_id = pair.source_sync_id, target_id = pair.target_sync_id,
				relation = verdict.relation, confidence = verdict.confidence,
				reasoning = verdict.reasoning, model = verdict.model,
			})
			if jerr != "" {
				item.error = jerr
			} else {
				item.applied = true
				judged += 1
			}
		}
		append(&results, item)
	}
	return json_ok(struct {
		project:          string          `json:"project"`,
		dry_run:          bool            `json:"dry_run"`,
		candidates_found: int             `json:"candidates_found"`,
		judged:           int             `json:"judged"`,
		results:          []Semantic_Item `json:"results"`,
	}{project = project_name, dry_run = !apply, candidates_found = len(pairs), judged = judged, results = results[:]})
}

handle_judge :: proc(s: ^store.STORE, req: Request) -> Response {
	body: struct {
		judgment_id: string  `json:"judgment_id"`,
		relation:    string  `json:"relation"`,
		reason:      string  `json:"reason"`,
		evidence:    string  `json:"evidence"`,
		confidence:  f64     `json:"confidence"`,
		session_id:  string  `json:"session_id"`,
	}
	if err := json.unmarshal_string(req.body, &body); err != nil {
		return json_error(400, "invalid JSON body")
	}
	params := store.Judge_Relation_Params{
		judgment_id = body.judgment_id, relation = body.relation,
		reason = body.reason, evidence = body.evidence, confidence = body.confidence,
		has_confidence = body.confidence != 0,
		marked_by_actor = "agent", marked_by_kind = "agent", session_id = body.session_id,
	}
	rel, err := store.JudgeRelation(s, params)
	if err != "" {
		return json_error(400, err)
	}
	return json_ok(rel)
}

handle_compare :: proc(s: ^store.STORE, req: Request) -> Response {
	body: struct {
		memory_id_a: i64    `json:"memory_id_a"`,
		memory_id_b: i64    `json:"memory_id_b"`,
		relation:    string `json:"relation"`,
		reasoning:   string `json:"reasoning"`,
		confidence:  f64    `json:"confidence"`,
		model:       string `json:"model"`,
	}
	if err := json.unmarshal_string(req.body, &body); err != nil {
		return json_error(400, "invalid JSON body")
	}
	a, err := store.GetObservation(s, body.memory_id_a)
	if err != "" {
		return json_error(404, err)
	}
	b, berr := store.GetObservation(s, body.memory_id_b)
	if berr != "" {
		return json_error(404, berr)
	}
	sync_id, jerr := store.JudgeBySemantic(s, store.Judge_By_Semantic_Params{
		source_id = a.sync_id, target_id = b.sync_id, relation = body.relation,
		confidence = body.confidence, reasoning = body.reasoning, model = body.model,
	})
	if jerr != "" {
		return json_error(400, jerr)
	}
	return json_ok(struct{ sync_id: string `json:"sync_id"` }{sync_id = sync_id})
}

// ─── Query helpers ──────────────────────────────────────────────────────────

query_string :: proc(req: Request, key: string) -> string {
	v, ok := req.query[key]
	if !ok { return "" }
	return v
}

query_int :: proc(req: Request, key: string, fallback: int) -> int {
	v := query_string(req, key)
	if v == "" { return fallback }
	return parse_int(v, fallback)
}

query_project :: proc(s: ^store.STORE, req: Request, default_project: string) -> string {
	project_name := query_string(req, "project")
	if project_name != "" { return project_name }
	if query_string(req, "all_projects") == "true" { return "" }
	if default_project != "" { return default_project }
	cwd, _ := os.getwd(context.allocator)
	resolved, _ := store.ResolveCurrentProject(s, "", cwd)
	return resolved
}

parse_query :: proc(raw: string) -> map[string]string {
	out := make(map[string]string)
	for part in strings.split(raw, "&") {
		if part == "" { continue }
		if eq := strings.index_byte(part, '='); eq >= 0 {
			out[url_decode(part[:eq])] = url_decode(part[eq + 1:])
		} else {
			out[url_decode(part)] = ""
		}
	}
	return out
}

url_decode :: proc(value: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	i := 0
	for i < len(value) {
		c := value[i]
		if c == '+' {
			strings.write_byte(&b, ' ')
			i += 1
		} else if c == '%' && i + 2 < len(value) {
			hi := hex_value(value[i + 1])
			lo := hex_value(value[i + 2])
			if hi >= 0 && lo >= 0 {
				strings.write_byte(&b, u8(hi * 16 + lo))
				i += 3
			} else {
				strings.write_byte(&b, c)
				i += 1
			}
		} else {
			strings.write_byte(&b, c)
			i += 1
		}
	}
	return strings.clone(strings.to_string(b))
}

hex_value :: proc(c: u8) -> int {
	switch c {
	case '0'..='9': return int(c - '0')
	case 'a'..='f': return int(c - 'a' + 10)
	case 'A'..='F': return int(c - 'A' + 10)
	}
	return -1
}

parse_int :: proc(text: string, fallback: int) -> int {
	n, ok := strconv.parse_int(text)
	if !ok { return fallback }
	return n
}

parse_id :: proc(text: string) -> i64 {
	return i64(parse_int(text, 0))
}
