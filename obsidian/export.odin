// Obsidian vault export (markdown notes, one per observation).
package obsidian

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../store"

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

Export_Result :: struct {
	observations_written: int `json:"observations_written"`,
	sessions_written:     int `json:"sessions_written"`,
	root:                 string `json:"root"`,
}

Export :: proc(s: ^store.STORE, vault: string, project_name: string, limit: int, since: string) -> (Export_Result, string) {
	if strings.trim_space(vault) == "" {
		return {}, "--vault path is required"
	}
	data, err := store.Export(s, project_name)
	if err != "" {
		return {}, err
	}
	defer {
		delete(data.sessions)
		delete(data.observations)
		delete(data.prompts)
		delete(data.relations)
		delete(data.prompt_tombstones)
	}

	root, _ := filepath.join({vault, "engram"})
	if derr := ensure_dir(root); derr != "" {
		return {}, derr
	}
	for sub in ([]string{"_sessions", "_topics"}) {
		path, _ := filepath.join({root, sub})
		if derr := ensure_dir(path); derr != "" {
			return {}, derr
		}
	}

	result := Export_Result{root = root}
	count := 0
	for obs in data.observations {
		if obs.deleted_at != "" {
			continue
		}
		if since != "" && obs.created_at < since {
			continue
		}
		if limit > 0 && count >= limit {
			break
		}
		if werr := write_observation(root, obs); werr != "" {
			return result, werr
		}
		result.observations_written += 1
		count += 1
	}

	for sess in data.sessions {
		if werr := write_session(root, sess); werr != "" {
			return result, werr
		}
		result.sessions_written += 1
	}
	return result, ""
}

write_observation :: proc(root: string, obs: store.Backup_Observation) -> string {
	project := sanitize(obs.project)
	if project == "" {
		project = "_global"
	}
	typ := sanitize(obs.type)
	if typ == "" {
		typ = "observation"
	}
	dir, _ := filepath.join({root, project, typ})
	if err := ensure_dir(dir); err != "" {
		return err
	}
	slug := slugify(obs.title)
	if slug == "" {
		slug = "observation"
	}
	name := fmt.tprintf("%d-%s.md", obs.id, slug)
	path, _ := filepath.join({dir, name})

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "---\n")
	fmt.sbprintf(&b, "id: %d\n", obs.id)
	fmt.sbprintf(&b, "sync_id: %s\n", yaml_quote(obs.sync_id))
	fmt.sbprintf(&b, "session_id: %s\n", yaml_quote(obs.session_id))
	fmt.sbprintf(&b, "project: %s\n", yaml_quote(obs.project))
	fmt.sbprintf(&b, "type: %s\n", yaml_quote(obs.type))
	fmt.sbprintf(&b, "scope: %s\n", yaml_quote(obs.scope))
	if obs.topic_key != "" {
		fmt.sbprintf(&b, "topic_key: %s\n", yaml_quote(obs.topic_key))
	}
	fmt.sbprintf(&b, "created_at: %s\n", yaml_quote(obs.created_at))
	fmt.sbprintf(&b, "updated_at: %s\n", yaml_quote(obs.updated_at))
	if obs.review_after != "" {
		fmt.sbprintf(&b, "review_after: %s\n", yaml_quote(obs.review_after))
	}
	fmt.sbprintf(&b, "pinned: %v\n", obs.pinned)
	strings.write_string(&b, "tags: [engram")
	if obs.project != "" {
		strings.write_string(&b, ", ")
		strings.write_string(&b, sanitize_tag(obs.project))
	}
	if obs.type != "" {
		strings.write_string(&b, ", ")
		strings.write_string(&b, sanitize_tag(obs.type))
	}
	strings.write_string(&b, "]\n---\n\n")
	fmt.sbprintf(&b, "# %s\n\n", obs.title)
	strings.write_string(&b, obs.content)
	strings.write_string(&b, "\n")
	if werr := os.write_entire_file_from_string(path, strings.to_string(b)); werr != nil {
		return os.error_string(werr)
	}
	return ""
}

write_session :: proc(root: string, sess: store.Session) -> string {
	path, _ := filepath.join({root, "_sessions", cat(sanitize(sess.id), ".md")})
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "# Session %s\n\n", sess.id)
	fmt.sbprintf(&b, "- Project: `%s`\n", sess.project)
	fmt.sbprintf(&b, "- Started: %s\n", sess.started_at)
	if sess.ended_at != "" {
		fmt.sbprintf(&b, "- Ended: %s\n", sess.ended_at)
	}
	if sess.summary != "" {
		strings.write_string(&b, "\n## Summary\n\n")
		strings.write_string(&b, sess.summary)
		strings.write_string(&b, "\n")
	}
	if werr := os.write_entire_file_from_string(path, strings.to_string(b)); werr != nil {
		return os.error_string(werr)
	}
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

slugify :: proc(value: string) -> string {
	v := strings.to_lower(value)
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
	result := strings.clone(strings.trim(strings.to_string(b), "-"))
	if len(result) > 80 {
		result = result[:80]
	}
	return result
}

yaml_quote :: proc(value: string) -> string {
	escaped, _ := strings.replace_all(value, `"`, `\"`)
	return cat(`"`, escaped, `"`)
}
