// Project identity detection.
//
// The resolution order mirrors Engram's documented contract:
//   explicit request project > ENGRAM_PROJECT > .engram/config.json (inside
//   the enclosing repository) > git origin remote / repository root >
//   single child repository > working-directory basename.
//
// Git metadata is read directly from .git/config and .git files instead of
// spawning git. This is deliberately pure Odin and avoids a runtime process
// dependency for identity resolution.
package project

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../util"

ENV_PROJECT :: "ENGRAM_PROJECT"

SOURCE_CONFIG :: "config"
SOURCE_GIT_REMOTE :: "git_remote"
SOURCE_GIT_ROOT :: "git_root"
SOURCE_GIT_CHILD :: "git_child"
SOURCE_DIR_BASENAME :: "dir_basename"
SOURCE_EXPLICIT :: "explicit_override"
SOURCE_PROCESS :: "process_override"
SOURCE_ALL :: "all_projects"

Config_File :: struct {
	project_name: string `json:"project_name"`,
}

Result :: struct {
	project: string,
	source:  string,
	path:    string,
	warning: string,
}

// detect resolves a project for dir, using an explicit request override when
// non-empty. ENGRAM_PROJECT is handled by Resolve.
detect :: proc(dir: string, explicit: string) -> (Result, string) {
	cwd := dir
	if cwd == "" {
		cwd = "."
	}
	abs, err := filepath.abs(cwd)
	if err == nil {
		cwd = abs
	}

	root, found := find_git_root(cwd)
	if found {
		if cfg, ok := find_config(cwd, root); ok {
			return resolve_config(cfg, cwd)
		}
		if name, ok := read_origin_repo_name(root); ok && name != "" {
			return Result{project = name, source = SOURCE_GIT_REMOTE, path = root}, ""
		}
		return Result{project = normalize_basename(root), source = SOURCE_GIT_ROOT, path = root}, ""
	}

	// Outside git, only the current directory's config is authoritative.
	cfg_path, _ := filepath.join({cwd, ".engram", "config.json"})
	if path_exists(cfg_path) {
		return resolve_config(cfg_path, cwd)
	}

	// Look for exactly one child repository.
	children := make([dynamic]string)
	defer delete(children)
	if entries, derr := os.read_all_directory_by_path(cwd, context.allocator); derr == nil {
		defer delete(entries)
		for entry in entries {
			if entry.type != .Directory {
				continue
			}
			child := entry.fullpath
			if _, ok := find_git_root(child); ok {
				append(&children, child)
			}
		}
	}
	switch len(children) {
	case 0:
	case 1:
		child_result, err := detect(children[0], "")
		if err != "" {
			return {}, err
		}
		child_result.source = SOURCE_GIT_CHILD
		child_result.warning = "auto-selected the only git repository below the working directory"
		return child_result, ""
	case:
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "ambiguous project: multiple git repos found in cwd: ")
		for child, i in children {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, normalize_basename(child))
		}
		return {}, strings.to_string(b)
	}

	return Result{project = normalize_basename(cwd), source = SOURCE_DIR_BASENAME, path = cwd}, ""
}

// Resolve applies the process-level precedence rules and canonicalizes names.
Resolve :: proc(explicit: string, dir: string) -> (Result, string) {
	raw := strings.trim_space(explicit)
	source := SOURCE_EXPLICIT
	if raw == "" {
		if env := strings.trim_space(os.get_env_alloc(ENV_PROJECT, context.allocator)); env != "" {
			raw = env
			source = SOURCE_PROCESS
		}
	}
	if raw != "" {
		normalized, warning := util.NormalizeProject(raw)
		return Result{project = normalized, source = source, path = dir, warning = warning}, ""
	}
	return detect(dir, "")
}

// Resolve_all returns an empty project for explicit cross-project reads.
Resolve_all :: proc(explicit: string) -> (string, string) {
	if strings.trim_space(explicit) != "" {
		return "", "--all and --project cannot be used together"
	}
	return "", ""
}

resolve_config :: proc(cfg_path: string, dir: string) -> (Result, string) {
	data, err := os.read_entire_file_from_path(cfg_path, context.allocator)
	if err != nil {
		return {}, fmt.tprintf("invalid .engram/config.json: cannot read %s", cfg_path)
	}
	defer delete(data)

	cfg: Config_File
	uerr := json.unmarshal(data, &cfg)
	if uerr != nil {
		return {}, fmt.tprintf("invalid .engram/config.json: cannot parse %s", cfg_path)
	}
	name := strings.clone(strings.trim_space(cfg.project_name))
	if name == "" {
		return {}, "invalid .engram/config.json: project_name is required"
	}
	normalized, warning := util.NormalizeProject(name)
	return Result{project = normalized, source = SOURCE_CONFIG, path = dir, warning = warning}, ""
}

find_config :: proc(start_dir, stop_dir: string) -> (string, bool) {
	current, _ := filepath.clean(start_dir)
	stop, _ := filepath.clean(stop_dir)
	for {
		candidate, _ := filepath.join({current, ".engram", "config.json"})
		if path_exists(candidate) {
			return candidate, true
		}
		if current == stop {
			break
		}
		parent := filepath.dir(current)
		if parent == current {
			break
		}
		current = parent
	}
	return "", false
}

// find_git_root walks upward to the nearest directory containing .git.
find_git_root :: proc(start_dir: string) -> (string, bool) {
	current, _ := filepath.clean(start_dir)
	for {
		git_path, _ := filepath.join({current, ".git"})
		if path_exists(git_path) {
			return current, true
		}
		parent := filepath.dir(current)
		if parent == current {
			return "", false
		}
		current = parent
	}
}

// read_origin_repo_name reads .git/config directly. Handles both a .git
// directory and a .git file pointing at a worktree git dir.
read_origin_repo_name :: proc(root: string) -> (string, bool) {
	git_path, _ := filepath.join({root, ".git"})
	cfg_path := git_path
	if info, err := os.stat(git_path, context.allocator); err == nil {
		if info.type == .Regular {
			// `.git` is a file: "gitdir: /path/to/worktree/gitdir".
			data, rerr := os.read_entire_file_from_path(git_path, context.allocator)
			if rerr != nil {
				return "", false
			}
			defer delete(data)
			text := string(data)
			if idx := strings.index(text, "gitdir:"); idx >= 0 {
				dir := strings.trim_space(text[idx + len("gitdir:"):])
				if nl := strings.index_byte(dir, '\n'); nl >= 0 {
					dir = strings.trim_space(dir[:nl])
				}
				if !filepath.is_abs(dir) {
					dir, _ = filepath.join({root, dir})
				}
				cfg_path, _ = filepath.join({dir, "config"})
			}
		} else {
			cfg_path, _ = filepath.join({git_path, "config"})
		}
	}

	data, err := os.read_entire_file_from_path(cfg_path, context.allocator)
	if err != nil {
		return "", false
	}
	defer delete(data)

	in_origin := false
	for line in strings.split_lines(string(data)) {
		trimmed := strings.trim_space(line)
		if strings.has_prefix(trimmed, "[") {
			lower := strings.to_lower(trimmed)
			in_origin = strings.has_prefix(lower, `[remote "origin"]`)
			continue
		}
		if !in_origin {
			continue
		}
		if eq := strings.index_byte(trimmed, '='); eq >= 0 {
			key := strings.to_lower(strings.trim_space(trimmed[:eq]))
			if key == "url" {
				url := strings.trim_space(trimmed[eq + 1:])
				return extract_repo_name(url), true
			}
		}
	}
	return "", false
}

// extract_repo_name handles SSH and HTTPS remotes, with or without .git.
extract_repo_name :: proc(url: string) -> string {
	u := strings.trim_space(url)
	if strings.has_suffix(u, ".git") {
		u = u[:len(u) - 4]
	}
	parts := strings.fields_proc(u, proc(r: rune) -> bool {
		return r == '/' || r == ':'
	})
	if len(parts) == 0 {
		return ""
	}
	return strings.clone(strings.trim_space(parts[len(parts) - 1]))
}

normalize_basename :: proc(dir: string) -> string {
	cleaned, _ := filepath.clean(dir)
	base := filepath.base(cleaned)
	if base == "" || base == "." || base == "/" {
		return "unknown"
	}
	normalized, _ := util.NormalizeProject(base)
	return normalized
}

path_exists :: proc(path: string) -> bool {
	_, err := os.stat(path, context.allocator)
	return err == nil
}
