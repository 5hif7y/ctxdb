// Obsidian vault export with incremental state, session/topic hubs, and graph
// configuration. This mirrors Engram's vault layout while remaining plain Odin.
package obsidian

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../store"

STATE_VERSION :: 1
STATE_FILE :: ".engram-sync-state.json"

Sync_State :: struct {
	last_export_at: string            `json:"last_export_at"`,
	files:          map[string]string `json:"files"`,
	session_hubs:   map[string]string `json:"session_hubs"`,
	topic_hubs:     map[string]string `json:"topic_hubs"`,
	version:        int               `json:"version"`,
}

Export_Result :: struct {
	created:     int      `json:"created"`,
	updated:     int      `json:"updated"`,
	deleted:     int      `json:"deleted"`,
	skipped:     int      `json:"skipped"`,
	hubs:        int      `json:"hubs_created"`,
	errors:      [dynamic]string `json:"errors,omitempty"`,
	root:        string   `json:"root"`,
}

Obs_Ref :: struct {
	id:        i64,
	slug:      string,
	title:     string,
	topic_key: string,
	typ:       string,
}

DEFAULT_GRAPH :: `{
  "collapse-filter": false,
  "search": "",
  "showTags": false,
  "showAttachments": false,
  "hideUnresolved": false,
  "showOrphans": true,
  "collapse-color-groups": true,
  "colorGroups": [
    { "query": "path:engram/_sessions", "color": { "a": 1, "rgb": 14736466 } },
    { "query": "path:engram/_topics",   "color": { "a": 1, "rgb": 13893887 } },
    { "query": "tag:#architecture",     "color": { "a": 1, "rgb": 7935 } },
    { "query": "tag:#bugfix",           "color": { "a": 1, "rgb": 16711680 } },
    { "query": "tag:#decision",         "color": { "a": 1, "rgb": 65322 } },
    { "query": "tag:#pattern",          "color": { "a": 1, "rgb": 16741120 } }
  ],
  "collapse-display": true,
  "showArrow": false,
  "textFadeMultiplier": 0,
  "nodeSizeMultiplier": 1,
  "lineSizeMultiplier": 1,
  "collapse-forces": false,
  "centerStrength": 0.515147569444444,
  "repelStrength": 12.7118055555556,
  "linkStrength": 0.729210069444444,
  "linkDistance": 207,
  "scale": 0.1,
  "close": false
}`

Export :: proc(
	s: ^store.STORE,
	vault: string,
	project_name: string,
	limit: int,
	since: string,
	force: bool,
	graph_mode: string,
) -> (Export_Result, string) {
	if strings.trim_space(vault) == "" {
		return {}, "--vault path is required"
	}
	if graph_mode != "" && graph_mode != "preserve" && graph_mode != "force" && graph_mode != "skip" {
		return {}, cat("invalid --graph-config value: ", graph_mode, " (accepted: preserve, force, skip)")
	}
	root, _ := filepath.join({vault, "engram"})
	if err := ensure_dir(root); err != "" {
		return {}, err
	}
	for sub in ([]string{"_sessions", "_topics"}) {
		path, _ := filepath.join({root, sub})
		if err := ensure_dir(path); err != "" {
			return {}, err
		}
	}
	if werr := write_graph_config(vault, graph_mode == "" ? "preserve" : graph_mode); werr != "" {
		return {}, werr
	}

	state, serr := read_state(cat(root, "/", STATE_FILE))
	if serr != "" {
		return {}, serr
	}
	defer delete(state.files)
	defer delete(state.session_hubs)
	defer delete(state.topic_hubs)
	if force {
		clear(&state.files)
		clear(&state.session_hubs)
		clear(&state.topic_hubs)
		state.last_export_at = ""
	}

	data, xerr := store.Export(s, project_name)
	if xerr != "" {
		return {}, xerr
	}
	defer {
		delete(data.sessions)
		delete(data.observations)
		delete(data.prompts)
		delete(data.relations)
		delete(data.prompt_tombstones)
	}

	result := Export_Result{root = root}
	cutoff := since
	if cutoff == "" {
		cutoff = state.last_export_at
	}
	full_scope := project_name == ""

	present := make(map[string]bool)
	defer delete(present)
	for obs in data.observations {
		present[fmt.tprintf("%d", obs.id)] = true
	}

	// Deleted observations and hard-deleted tracked IDs retire their notes.
	for obs in data.observations {
		if obs.deleted_at == "" {
			continue
		}
		key := fmt.tprintf("%d", obs.id)
		if rel, tracked := state.files[key]; tracked {
			_ = remove_export_file(root, rel)
			_, _ = delete_key(&state.files, key)
			result.deleted += 1
		}
	}
	if full_scope {
		for key, rel in state.files {
			if present[key] {
				continue
			}
			_ = remove_export_file(root, rel)
			_, _ = delete_key(&state.files, key)
			result.deleted += 1
		}
	}

	session_refs := make(map[string][dynamic]Obs_Ref)
	defer {
		for _, refs in session_refs { delete(refs) }
		delete(session_refs)
	}
	topic_refs := make(map[string][dynamic]Obs_Ref)
	defer {
		for _, refs in topic_refs { delete(refs) }
		delete(topic_refs)
	}

	count := 0
	for obs in data.observations {
		if obs.deleted_at != "" {
			continue
		}
		if limit > 0 && count >= limit {
			break
		}
		project := obs.project
		if project == "" { project = "unknown" }
		project = sanitize(project)
		obs_type := sanitize(obs.type)
		slug := slugify(obs.title, obs.id)
		rel := cat(project, "/", obs_type, "/", slug, ".md")
		key := fmt.tprintf("%d", obs.id)

		if !force && cutoff != "" && obs.updated_at <= cutoff {
			if old, tracked := state.files[key]; tracked && old == rel {
				result.skipped += 1
				add_hub_ref(&session_refs, &topic_refs, obs, slug)
				count += 1
				continue
			}
		}

		content := observation_markdown(obs, slug)
		abs, _ := filepath.join({root, rel})
		dir := filepath.dir(abs)
		if err := ensure_dir(dir); err != "" {
			append(&result.errors, err)
			continue
		}
		existed := false
		if old_data, read_err := os.read_entire_file_from_path(abs, context.allocator); read_err == nil {
			existed = true
			unchanged := string(old_data) == content
			delete(old_data)
			if unchanged && state.files[key] == rel {
				result.skipped += 1
				add_hub_ref(&session_refs, &topic_refs, obs, slug)
				count += 1
				continue
			}
		}
		if werr := os.write_entire_file_from_string(abs, content); werr != nil {
			append(&result.errors, os.error_string(werr))
			continue
		}
		if old, tracked := state.files[key]; tracked && old != rel {
			_ = remove_export_file(root, old)
		}
		state.files[key] = rel
		if existed { result.updated += 1 } else { result.created += 1 }
		add_hub_ref(&session_refs, &topic_refs, obs, slug)
		count += 1
	}

	// Session hubs.
	for session_id, refs in session_refs {
		if session_id == "" || len(refs) == 0 { continue }
		rel := cat("_sessions/", sanitize(session_id), ".md")
		abs, _ := filepath.join({root, rel})
		content := session_hub_markdown(session_id, refs[:])
		if werr := os.write_entire_file_from_string(abs, content); werr != nil {
			append(&result.errors, os.error_string(werr))
			continue
		}
		state.session_hubs[session_id] = rel
		result.hubs += 1
	}
	// Topic hubs (>=2 observations).
	for prefix, refs in topic_refs {
		if len(refs) < 2 { continue }
		safe, _ := strings.replace_all(prefix, "/", "--")
		rel := cat("_topics/", sanitize(safe), ".md")
		abs, _ := filepath.join({root, rel})
		content := topic_hub_markdown(prefix, refs[:])
		if werr := os.write_entire_file_from_string(abs, content); werr != nil {
			append(&result.errors, os.error_string(werr))
			continue
		}
		state.topic_hubs[prefix] = rel
		result.hubs += 1
	}

	// Retire stale hubs in full-scope runs.
	if full_scope {
		for key, rel in state.session_hubs {
			if _, live := session_refs[key]; live { continue }
			_ = remove_export_file(root, rel)
			_, _ = delete_key(&state.session_hubs, key)
			result.deleted += 1
		}
		for key, rel in state.topic_hubs {
			if refs, live := topic_refs[key]; live && len(refs) >= 2 { continue }
			_ = remove_export_file(root, rel)
			_, _ = delete_key(&state.topic_hubs, key)
			result.deleted += 1
		}
	}

	state.last_export_at = store.Now(s.db)
	state.version = STATE_VERSION
	if werr := write_state(cat(root, "/", STATE_FILE), state); werr != "" {
		return result, werr
	}
	return result, ""
}

add_hub_ref :: proc(session_refs: ^map[string][dynamic]Obs_Ref, topic_refs: ^map[string][dynamic]Obs_Ref, obs: store.Backup_Observation, slug: string) {
	ref := Obs_Ref{id = obs.id, slug = slug, title = obs.title, topic_key = obs.topic_key, typ = obs.type}
	if obs.session_id != "" {
		refs := session_refs^[obs.session_id]
		append(&refs, ref)
		session_refs^[obs.session_id] = refs
	}
	if obs.topic_key != "" {
		prefix := topic_prefix(obs.topic_key)
		refs := topic_refs^[prefix]
		append(&refs, ref)
		topic_refs^[prefix] = refs
	}
}

observation_markdown :: proc(obs: store.Backup_Observation, slug: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "---\n")
	fmt.sbprintf(&b, "id: %d\n", obs.id)
	fmt.sbprintf(&b, "type: %s\n", obs.type)
	fmt.sbprintf(&b, "project: %s\n", obs.project)
	fmt.sbprintf(&b, "scope: %s\n", obs.scope)
	if obs.topic_key == "" {
		strings.write_string(&b, "topic_key: \"\"\n")
	} else {
		fmt.sbprintf(&b, "topic_key: %s\n", obs.topic_key)
	}
	fmt.sbprintf(&b, "session_id: %s\n", obs.session_id)
	fmt.sbprintf(&b, "created_at: %s\n", yaml_quote(obs.created_at))
	fmt.sbprintf(&b, "updated_at: %s\n", yaml_quote(obs.updated_at))
	fmt.sbprintf(&b, "revision_count: %d\n", obs.revision_count)
	strings.write_string(&b, "tags:\n")
	if obs.project != "" { fmt.sbprintf(&b, "  - %s\n", sanitize_tag(obs.project)) }
	if obs.type != "" { fmt.sbprintf(&b, "  - %s\n", sanitize_tag(obs.type)) }
	fmt.sbprintf(&b, "aliases:\n  - %s\n", yaml_quote(obs.title))
	strings.write_string(&b, "---\n\n")
	fmt.sbprintf(&b, "# %s\n\n", obs.title)
	strings.write_string(&b, obs.content)
	strings.write_string(&b, "\n")
	if obs.session_id != "" {
		fmt.sbprintf(&b, "\n---\n*Session*: [[session-%s]]\n", sanitize(obs.session_id))
	}
	if obs.topic_key != "" {
		prefix, _ := strings.replace_all(topic_prefix(obs.topic_key), "/", "--")
		fmt.sbprintf(&b, "*Topic*: [[topic-%s]]\n", sanitize(prefix))
	}
	_ = slug
	return strings.clone(strings.to_string(b))
}

session_hub_markdown :: proc(session_id: string, refs: []Obs_Ref) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "---\ntype: session-hub\n")
	fmt.sbprintf(&b, "session_id: %s\n", session_id)
	strings.write_string(&b, "tags:\n  - session\n---\n\n")
	fmt.sbprintf(&b, "# Session: %s\n\n## Observations\n", session_id)
	for ref in refs {
		fmt.sbprintf(&b, "- [[%s]]\n", ref.slug)
	}
	return strings.clone(strings.to_string(b))
}

topic_hub_markdown :: proc(prefix: string, refs: []Obs_Ref) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "---\ntype: topic-hub\n")
	fmt.sbprintf(&b, "topic_prefix: %s\n", prefix)
	strings.write_string(&b, "tags:\n  - topic\n---\n\n")
	fmt.sbprintf(&b, "# Topic: %s\n\n## Related Observations\n", prefix)
	for ref in refs {
		fmt.sbprintf(&b, "- [[%s]] (%s)\n", ref.slug, ref.typ)
	}
	return strings.clone(strings.to_string(b))
}

topic_prefix :: proc(topic_key: string) -> string {
	if idx := strings.last_index_byte(topic_key, '/'); idx >= 0 {
		return topic_key[:idx]
	}
	return topic_key
}

slugify :: proc(title: string, id: i64) -> string {
	if title == "" {
		return fmt.tprintf("observation-%d", id)
	}
	v := strings.to_lower(title)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	last_dash := false
	for r in v {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			strings.write_rune(&b, r)
			last_dash = false
		} else if !last_dash && len(b.buf) > 0 {
			strings.write_byte(&b, '-')
			last_dash = true
		}
	}
	base := strings.trim(strings.to_string(b), "-")
	if len(base) > 60 {
		base = strings.trim_right(base[:60], "-")
	}
	if base == "" {
		return fmt.tprintf("observation-%d", id)
	}
	return fmt.tprintf("%s-%d", base, id)
}

read_state :: proc(path: string) -> (Sync_State, string) {
	state := Sync_State{
		files = make(map[string]string),
		session_hubs = make(map[string]string),
		topic_hubs = make(map[string]string),
		version = STATE_VERSION,
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return state, ""
	}
	defer delete(data)
	if jerr := json.unmarshal(data, &state); jerr != nil {
		return {}, "invalid Obsidian sync state"
	}
	if state.files == nil { state.files = make(map[string]string) }
	if state.session_hubs == nil { state.session_hubs = make(map[string]string) }
	if state.topic_hubs == nil { state.topic_hubs = make(map[string]string) }
	return state, ""
}

write_state :: proc(path: string, state: Sync_State) -> string {
	data, err := json.marshal(state, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil { return "cannot encode Obsidian sync state" }
	if werr := os.write_entire_file_from_string(path, string(data)); werr != nil {
		return os.error_string(werr)
	}
	return ""
}

write_graph_config :: proc(vault, mode: string) -> string {
	if mode == "skip" { return "" }
	dir, _ := filepath.join({vault, ".obsidian"})
	path, _ := filepath.join({dir, "graph.json"})
	if mode == "preserve" {
		if _, err := os.stat(path, context.allocator); err == nil {
			return ""
		}
	}
	if err := ensure_dir(dir); err != "" { return err }
	if werr := os.write_entire_file_from_string(path, DEFAULT_GRAPH); werr != nil {
		return os.error_string(werr)
	}
	return ""
}

remove_export_file :: proc(root, rel: string) -> string {
	abs, _ := filepath.join({root, rel})
	clean_root, _ := filepath.clean(root)
	clean_abs, _ := filepath.clean(abs)
	if !strings.has_prefix(clean_abs, cat(clean_root, "/")) {
		return "unsafe export path rejected"
	}
	_ = os.remove(clean_abs)
	return ""
}

ensure_dir :: proc(path: string) -> string {
	if _, err := os.stat(path, context.allocator); err == nil {
		return ""
	}
	if err := os.make_directory_all(path); err != nil {
		return os.error_string(err)
	}
	return ""
}

sanitize :: proc(value: string) -> string {
	v := strings.trim_space(value)
	v, _ = strings.replace_all(v, "/", "_")
	v, _ = strings.replace_all(v, "\\", "_")
	v, _ = strings.replace_all(v, "..", "__")
	return strings.to_lower(v)
}

sanitize_tag :: proc(value: string) -> string {
	return sanitize(value)
}

yaml_quote :: proc(value: string) -> string {
	escaped, _ := strings.replace_all(value, `"`, `\"`)
	return cat(`"`, escaped, `"`)
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}
