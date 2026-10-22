package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import "mcp"
import "obsidian"
import "server"
import "store"
import "sync"

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

VERSION :: "0.1.0"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		print_usage()
		return
	}
	command := args[1]
	switch command {
	case "help", "--help", "-h":
		print_usage()
	case "version", "--version", "-v":
		fmt.println(cat("ctxdb ", VERSION))
	case "mcp":
		run_mcp(args[2:])
	case "serve":
		run_serve(args[2:])
	case "sync":
		run_sync(args[2:])
	case "save":
		run_save(args[2:])
	case "search":
		run_search(args[2:])
	case "get":
		run_get(args[2:])
	case "context":
		run_context(args[2:])
	case "timeline":
		run_timeline(args[2:])
	case "export":
		run_export(args[2:])
	case "import":
		run_import(args[2:])
	case "conflicts":
		run_conflicts(args[2:])
	case "obsidian-export":
		run_obsidian_export(args[2:])
	case "stats":
		run_stats(args[2:])
	case "projects":
		run_projects(args[2:])
	case "delete":
		run_delete(args[2:])
	case "session":
		run_session(args[2:])
	case "prompt":
		run_prompt(args[2:])
	case "init":
		run_init(args[2:])
	case "doctor":
		run_doctor(args[2:])
	case "compatibility":
		run_compatibility(args[2:])
	case "migrate-copy":
		run_migrate_copy(args[2:])
	case:
		fmt.wprintln(os.to_writer(os.stderr), cat("unknown command: ", command))
		print_usage()
		os.exit(1)
	}
}

print_usage :: proc() {
	fmt.println(`ctxdb ` + VERSION + ` — Odin port of Engram's local memory core

Usage:
  ctxdb <command> [arguments]

Commands:
  save <title> <content> [--type TYPE] [--project NAME] [--scope SCOPE] [--topic KEY]
  search <query> [--type TYPE] [--project NAME|--all] [--scope SCOPE] [--limit N] [--match all|any]
  get <id> [--json]
  context [project] [--project NAME|--all] [--scope SCOPE]
  timeline <id> [--before N] [--after N]
  stats [--project NAME|--all]
  projects list
  delete <id> [--hard]
  delete session <id>
  delete prompt <id>
  delete project <name> [--hard]
  session start <id> [--project NAME] [--directory DIR] [--mode shared|project_owned]
  session end <id> [summary]
  session get <id>
  prompt save <session_id> <content> [--project NAME] [--inbox ID]
  prompt search <query> [--project NAME|--all] [--limit N]
  export [file.json] [--project NAME|--all]
  import <file.json>
  conflicts list|show|stats|scan [options]
  obsidian-export --vault DIR [--project NAME|--all] [--limit N] [--since DATE]
  serve [port] [--project NAME]
  sync [--import|--status] [--project NAME|--all] [--dir .engram]
  init [name] [--force]
  doctor [--json]
  compatibility [--data-dir DIR] [--json]
  migrate-copy --data-dir SRC --output-dir DST --confirm-quiescent [--json]
  mcp [--project NAME]
  version
  help

Environment:
  ENGRAM_DATA_DIR  Absolute data directory (default: ~/.engram)
  ENGRAM_PROJECT   Process-level project override`)
}

open_store :: proc() -> (^store.STORE, bool) {
	cfg, cfg_err := store.DefaultConfig()
	if cfg_err != "" {
		fmt.wprintln(os.to_writer(os.stderr), cfg_err)
		return nil, false
	}
	s, err := store.Open(cfg)
	if err != "" {
		fmt.wprintln(os.to_writer(os.stderr), err)
		return nil, false
	}
	return s, true
}

fail :: proc(message: string) {
	fmt.wprintln(os.to_writer(os.stderr), message)
	os.exit(1)
}

cwd :: proc() -> string {
	dir, err := os.getwd(context.allocator)
	if err != nil {
		return "."
	}
	return dir
}

resolve_project :: proc(s: ^store.STORE, explicit: string) -> string {
	project_name, err := store.ResolveCurrentProject(s, explicit, cwd())
	if err != "" {
		fail(err)
	}
	return project_name
}

run_mcp :: proc(args: []string) {
	default_project := ""
	i := 0
	for i < len(args) {
		switch args[i] {
		case "--project":
			if i + 1 < len(args) {
				default_project = args[i + 1]
				i += 1
			}
		}
		i += 1
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	mcp.Serve(s, default_project)
}

run_save :: proc(args: []string) {
	title := ""
	content := ""
	typ := "manual"
	project_flag := ""
	scope := "project"
	topic_key := ""
	positionals := make([dynamic]string)
	defer delete(positionals)

	i := 0
	end_of_options := false
	for i < len(args) {
		arg := args[i]
		if !end_of_options && arg == "--" {
			end_of_options = true
			i += 1
			continue
		}
		if !end_of_options && strings.has_prefix(arg, "-") {
			switch arg {
			case "--type", "--project", "--scope", "--topic":
				if i + 1 >= len(args) || strings.trim_space(args[i + 1]) == "" {
					fail(cat(arg, " requires a value"))
				}
				value := args[i + 1]
				switch arg {
				case "--type":
					typ = value
				case "--project":
					project_flag = value
				case "--scope":
					scope = value
				case "--topic":
					topic_key = value
				}
				i += 2
			case:
				fail(cat("unknown save flag: ", arg))
			}
			continue
		}
		append(&positionals, arg)
		if len(positionals) > 2 {
			fail("save requires exactly two positional arguments")
		}
		i += 1
	}
	if len(positionals) != 2 {
		fail("usage: ctxdb save <title> <content> [--type TYPE] [--project PROJECT] [--scope SCOPE] [--topic KEY]")
	}
	title = positionals[0]
	content = positionals[1]

	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)

	project_name := resolve_project(s, project_flag)
	if project_name == "" {
		fail("cannot save without an unambiguous project identity; use --project <name>")
	}
	directory := cwd()
	session_id, err := store.ResolveManualSession(s, project_name, directory)
	if err != "" {
		fail(err)
	}
	result, aerr := store.AddObservation(s, store.AddObservationParams{
		session_id = session_id,
		type = typ,
		title = title,
		content = content,
		project = project_name,
		scope = scope,
		topic_key = topic_key,
	})
	if aerr != "" {
		fail(aerr)
	}
	fmt.printf("Memory saved: #%d %q (%s)\n", result.id, title, typ)
}

run_search :: proc(args: []string) {
	query_parts := make([dynamic]string)
	defer delete(query_parts)
	opts := store.SearchOptions{limit = 10}
	all_projects := false

	i := 0
	for i < len(args) {
		switch args[i] {
		case "--type":
			if i + 1 < len(args) {
				opts.type = args[i + 1]
				i += 1
			}
		case "--project":
			if i + 1 < len(args) {
				opts.project = args[i + 1]
				i += 1
			}
		case "--scope":
			if i + 1 < len(args) {
				opts.scope = args[i + 1]
				i += 1
			}
		case "--match":
			if i + 1 < len(args) {
				opts.match_mode = args[i + 1]
				i += 1
			}
		case "--limit":
			if i + 1 < len(args) {
				opts.limit = parse_int(args[i + 1], 10)
				i += 1
			}
		case "--all":
			all_projects = true
		case:
			append(&query_parts, args[i])
		}
		i += 1
	}
	query := strings.join(query_parts[:], " ")
	if strings.trim_space(query) == "" {
		fail("search query is required")
	}

	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	if !all_projects {
		opts.project = resolve_project(s, opts.project)
	}
	results, err := store.Search(s, query, opts)
	if err != "" {
		fail(err)
	}
	defer delete(results)

	if len(results) == 0 {
		fmt.printf("No memories found for: %q\n", query)
		return
	}
	fmt.printf("Found %d memories:\n\n", len(results))
	for r, index in results {
		project_suffix := ""
		if r.project != "" {
			project_suffix = cat(" | project: ", r.project)
		}
		fmt.printf("[%d] #%d (%s) — %s\n    %s\n    %s%s | scope: %s\n\n",
			index + 1, r.id, r.type, r.title,
			preview_content(r.content, 300),
			r.created_at, project_suffix, r.scope,
		)
	}
}

run_get :: proc(args: []string) {
	id := i64(0)
	as_json := false
	for arg in args {
		switch arg {
		case "--json":
			as_json = true
		case:
			id = i64(parse_int(arg, 0))
		}
	}
	if id == 0 {
		fail("usage: ctxdb get <observation_id> [--json]")
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	obs, err := store.GetObservation(s, id)
	if err != "" {
		fail(err)
	}
	if as_json {
		print_json(obs)
		return
	}
	fmt.printf("#%d [%s] %s\n", obs.id, obs.type, obs.title)
	fmt.printf("session: %s | project: %s | scope: %s | topic: %s\n", obs.session_id, obs.project, obs.scope, obs.topic_key)
	fmt.printf("created: %s | updated: %s | revisions: %d | duplicates: %d\n\n", obs.created_at, obs.updated_at, obs.revision_count, obs.duplicate_count)
	fmt.println(obs.content)
}

run_context :: proc(args: []string) {
	project_flag := ""
	scope := ""
	all_projects := false
	legacy_project := ""
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--project":
			if i + 1 < len(args) {
				project_flag = args[i + 1]
				i += 1
			}
		case "--scope":
			if i + 1 < len(args) {
				scope = args[i + 1]
				i += 1
			}
		case "--all":
			all_projects = true
		case:
			if strings.has_prefix(args[i], "-") {
				fail(cat("unknown context flag: ", args[i]))
			}
			legacy_project = args[i]
		}
	}
	if legacy_project != "" {
		project_flag = legacy_project
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	project_name := ""
	if !all_projects {
		project_name = resolve_project(s, project_flag)
	}
	rendered, err := store.FormatContext(s, project_name, scope, store.context_options_default())
	if err != "" {
		fail(err)
	}
	if rendered == "" {
		fmt.println("No previous session memories found.")
		return
	}
	fmt.print(rendered)
}

run_timeline :: proc(args: []string) {
	id := i64(0)
	before := 5
	after := 5
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--before":
			if i + 1 < len(args) {
				before = parse_int(args[i + 1], 5)
				i += 1
			}
		case "--after":
			if i + 1 < len(args) {
				after = parse_int(args[i + 1], 5)
				i += 1
			}
		case:
			id = i64(parse_int(args[i], 0))
		}
	}
	if id == 0 {
		fail("usage: ctxdb timeline <observation_id> [--before N] [--after N]")
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	result, err := store.Timeline(s, id, before, after)
	if err != "" {
		fail(err)
	}
	defer delete(result.before)
	defer delete(result.after)
	if session, session_ok := result.session_info.?; session_ok {
		fmt.printf("Session: %s (%s)\n", session.project, session.started_at)
		fmt.printf("Total observations in session: %d\n\n", result.total_in_range)
	}
	if len(result.before) > 0 {
		fmt.println("─── Before ───")
		for entry in result.before {
			fmt.printf("  #%d [%s] %s — %s\n", entry.id, entry.type, entry.title, preview_content(entry.content, 150))
		}
		fmt.println()
	}
	fmt.printf(">>> #%d [%s] %s <<<\n", result.focus.id, result.focus.type, result.focus.title)
	fmt.printf("    %s\n", preview_content(result.focus.content, 500))
	fmt.printf("    %s\n\n", result.focus.created_at)
	if len(result.after) > 0 {
		fmt.println("─── After ───")
		for entry in result.after {
			fmt.printf("  #%d [%s] %s — %s\n", entry.id, entry.type, entry.title, preview_content(entry.content, 150))
		}
	}
}

run_stats :: proc(args: []string) {
	project_name := ""
	all_projects := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--project":
			if i + 1 < len(args) {
				project_name = args[i + 1]
				i += 1
			}
		case "--all":
			all_projects = true
		}
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	if !all_projects && project_name == "" {
		project_name = resolve_project(s, "")
	}
	stats: store.Stats
	err: string
	if project_name != "" {
		stats, err = store.GetStatsProject(s, project_name)
	} else {
		stats, err = store.GetStats(s)
	}
	if err != "" {
		fail(err)
	}
	projects := "none yet"
	if len(stats.projects) > 0 {
		projects = strings.join(stats.projects, ", ")
	}
	fmt.println("ctxdb Memory Stats")
	fmt.printf("  Sessions:     %d\n", stats.total_sessions)
	fmt.printf("  Observations: %d\n", stats.total_observations)
	fmt.printf("  Prompts:      %d\n", stats.total_prompts)
	fmt.printf("  Projects:     %s\n", projects)
	fmt.printf("  Database:     %s\n", store.DBPath(s))
}

run_projects :: proc(args: []string) {
	if len(args) > 0 && args[0] == "merge" {
		from := ""
		to := ""
		apply := false
		for i := 1; i < len(args); i += 1 {
			switch args[i] {
			case "--from":
				if i + 1 < len(args) { from = args[i + 1]; i += 1 }
			case "--to":
				if i + 1 < len(args) { to = args[i + 1]; i += 1 }
			case "--apply":
				apply = true
			}
		}
		if from == "" || to == "" {
			fail("usage: ctxdb projects merge --from A,B --to CANONICAL [--apply]")
		}
		s, ok := open_store()
		if !ok { return }
		defer store.Close(s)
		sources := strings.split(from, ",")
		defer delete(sources)
		if !apply {
			result, err := store.PreviewMergeProjects(s, sources, to)
			if err != "" { fail(err) }
			print_json(result)
			return
		}
		result, err := store.MergeProjects(s, sources, to)
		if err != "" { fail(err) }
		print_json(result)
		return
	}
	if len(args) > 0 && args[0] == "prune" {
		dry_run := false
		for arg in args[1:] {
			if arg == "--dry-run" { dry_run = true }
		}
		s, ok := open_store()
		if !ok { return }
		defer store.Close(s)
		projects, err := store.ListProjectsWithStats(s)
		if err != "" { fail(err) }
		defer delete(projects)
		pruned := 0
		for p in projects {
			if p.observation_count == 0 {
				if dry_run {
					fmt.println(cat("would prune: ", p.name))
				} else {
					_, perr := store.PruneProject(s, p.name)
					if perr == "" { pruned += 1 }
				}
			}
		}
		if dry_run {
			fmt.println("dry run complete")
		} else {
			fmt.printf("Pruned %d empty projects\n", pruned)
		}
		return
	}
	if len(args) > 0 && args[0] != "list" {
		fail("usage: ctxdb projects list|merge|prune")
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	projects, err := store.ListProjectsWithStats(s)
	if err != "" {
		fail(err)
	}
	defer delete(projects)
	if len(projects) == 0 {
		fmt.println("No projects yet.")
		return
	}
	for p in projects {
		fmt.printf("%-30s observations=%d sessions=%d prompts=%d\n", p.name, p.observation_count, p.session_count, p.prompt_count)
	}
}

run_sync :: proc(args: []string) {
	dir := ".engram"
	project_flag := ""
	all_projects := false
	mode := "export"
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--import":
			mode = "import"
		case "--status":
			mode = "status"
		case "--project":
			if i + 1 < len(args) { project_flag = args[i + 1]; i += 1 }
		case "--all":
			all_projects = true
		case "--dir":
			if i + 1 < len(args) { dir = args[i + 1]; i += 1 }
		}
	}
	s, ok := open_store()
	if !ok { return }
	defer store.Close(s)
	switch mode {
	case "import":
		result, err := sync.Import(s, dir)
		if err != "" { fail(err) }
		print_json(result)
	case "status":
		status, err := sync.GetStatus(s, dir)
		if err != "" { fail(err) }
		print_json(status)
	case:
		if !all_projects && project_flag == "" {
			project_flag = resolve_project(s, "")
		}
		result, err := sync.Export(s, dir, project_flag)
		if err != "" { fail(err) }
		print_json(result)
	}
}

run_serve :: proc(args: []string) {
	port := server.DEFAULT_PORT
	default_project := ""
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--project":
			if i + 1 < len(args) {
				default_project = args[i + 1]
				i += 1
			}
		case:
			if !strings.has_prefix(args[i], "-") {
				port = parse_int(args[i], port)
			}
		}
	}
	if env := os.get_env_alloc("ENGRAM_PORT", context.allocator); strings.trim_space(env) != "" {
		port = parse_int(strings.trim_space(env), port)
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	if err := server.Serve(s, port, default_project); err != "" {
		fail(err)
	}
}

run_export :: proc(args: []string) {
	out_file := "engram-export.json"
	project_flag := ""
	all_projects := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--project":
			if i + 1 < len(args) {
				project_flag = args[i + 1]
				i += 1
			}
		case "--all":
			all_projects = true
		case:
			if !strings.has_prefix(args[i], "-") {
				out_file = args[i]
			}
		}
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	if !all_projects && project_flag == "" {
		project_flag = resolve_project(s, "")
	}
	data, err := store.Export(s, project_flag)
	if err != "" {
		fail(err)
	}
	encoded, jerr := store.Marshal_Export(data)
	if jerr != nil {
		fail("cannot encode export JSON")
	}
	if out_file == "-" {
		fmt.print(string(encoded))
		return
	}
	if werr := os.write_entire_file_from_string(out_file, string(encoded)); werr != nil {
		fail(cat("cannot write ", out_file))
	}
	fmt.printf("Exported %d sessions, %d observations, %d prompts to %s\n",
		len(data.sessions), len(data.observations), len(data.prompts), out_file)
}

run_import :: proc(args: []string) {
	if len(args) < 1 {
		fail("usage: ctxdb import <file.json>")
	}
	data, rerr := os.read_entire_file_from_path(args[0], context.allocator)
	if rerr != nil {
		fail(cat("cannot read ", args[0]))
	}
	defer delete(data)
	export: store.Export_Data
	if err := json.unmarshal(data, &export); err != nil {
		fail("invalid export JSON")
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	result, err := store.Import(s, export)
	if err != "" {
		fail(err)
	}
	print_json(result)
}

run_conflicts :: proc(args: []string) {
	if len(args) < 1 {
		fail("usage: ctxdb conflicts list|show|stats|scan|judge|compare")
	}
	action := args[0]
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	switch action {
	case "list":
		project_flag := ""
		status := ""
		limit := 0
		for i := 1; i < len(args); i += 1 {
			switch args[i] {
			case "--project":
				if i + 1 < len(args) { project_flag = args[i + 1]; i += 1 }
			case "--status":
				if i + 1 < len(args) { status = args[i + 1]; i += 1 }
			case "--limit":
				if i + 1 < len(args) { limit = parse_int(args[i + 1], 0); i += 1 }
			}
		}
		items, err := store.ListRelations(s, project_flag, status, limit)
		if err != "" { fail(err) }
		defer delete(items)
		print_json(items)
	case "show":
		if len(args) < 2 { fail("usage: ctxdb conflicts show <relation_sync_id>") }
		rel, err := store.GetRelation(s, args[1])
		if err != "" { fail(err) }
		print_json(rel)
	case "stats":
		project_flag := ""
		for i := 1; i < len(args); i += 1 {
			if args[i] == "--project" && i + 1 < len(args) { project_flag = args[i + 1]; i += 1 }
		}
		stats, err := store.RelationStats(s, project_flag)
		if err != "" { fail(err) }
		print_json(stats)
	case "scan":
		project_flag := ""
		limit := 100
		apply := false
		max_insert := 100
		for i := 1; i < len(args); i += 1 {
			switch args[i] {
			case "--project":
				if i + 1 < len(args) { project_flag = args[i + 1]; i += 1 }
			case "--limit":
				if i + 1 < len(args) { limit = parse_int(args[i + 1], 100); i += 1 }
			case "--apply":
				apply = true
			case "--max-insert":
				if i + 1 < len(args) { max_insert = parse_int(args[i + 1], 100); i += 1 }
			}
		}
		if project_flag == "" { project_flag = resolve_project(s, "") }
		result, err := store.ScanProject(s, store.Scan_Options{project = project_flag, limit = limit, apply = apply, max_insert = max_insert})
		if err != "" { fail(err) }
		print_json(result)
	case "judge":
		if len(args) < 3 { fail("usage: ctxdb conflicts judge <judgment_id> <relation> [--reason TEXT] [--confidence N]") }
		params := store.Judge_Relation_Params{judgment_id = args[1], relation = args[2], marked_by_actor = "user", marked_by_kind = "human"}
		for i := 3; i < len(args); i += 1 {
			switch args[i] {
			case "--reason":
				if i + 1 < len(args) { params.reason = args[i + 1]; i += 1 }
			case "--evidence":
				if i + 1 < len(args) { params.evidence = args[i + 1]; i += 1 }
			case "--confidence":
				if i + 1 < len(args) { params.confidence = parse_float(args[i + 1], 0); params.has_confidence = true; i += 1 }
			}
		}
		rel, err := store.JudgeRelation(s, params)
		if err != "" { fail(err) }
		print_json(rel)
	case "compare":
		if len(args) < 5 { fail("usage: ctxdb conflicts compare <id_a> <id_b> <relation> <confidence> [--reason TEXT] [--model NAME]") }
		a, err := store.GetObservation(s, i64(parse_int(args[1], 0)))
		if err != "" { fail(err) }
		b, berr := store.GetObservation(s, i64(parse_int(args[2], 0)))
		if berr != "" { fail(berr) }
		reason := ""
		model := ""
		for i := 5; i < len(args); i += 1 {
			switch args[i] {
			case "--reason":
				if i + 1 < len(args) { reason = args[i + 1]; i += 1 }
			case "--model":
				if i + 1 < len(args) { model = args[i + 1]; i += 1 }
			}
		}
		sync_id, jerr := store.JudgeBySemantic(s, store.Judge_By_Semantic_Params{
			source_id = a.sync_id, target_id = b.sync_id, relation = args[3],
			confidence = parse_float(args[4], 0), reasoning = reason, model = model,
		})
		if jerr != "" { fail(jerr) }
		print_json(struct{ sync_id: string `json:"sync_id"` }{sync_id = sync_id})
	case:
		fail("usage: ctxdb conflicts list|show|stats|scan|judge|compare")
	}
}

run_obsidian_export :: proc(args: []string) {
	vault := ""
	project_flag := ""
	all_projects := false
	limit := 0
	since := ""
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--vault":
			if i + 1 < len(args) { vault = args[i + 1]; i += 1 }
		case "--project":
			if i + 1 < len(args) { project_flag = args[i + 1]; i += 1 }
		case "--all":
			all_projects = true
		case "--limit":
			if i + 1 < len(args) { limit = parse_int(args[i + 1], 0); i += 1 }
		case "--since":
			if i + 1 < len(args) { since = args[i + 1]; i += 1 }
		}
	}
	if vault == "" { fail("obsidian-export requires --vault") }
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	if !all_projects && project_flag == "" {
		project_flag = resolve_project(s, "")
	}
	result, err := obsidian.Export(s, vault, project_flag, limit, since)
	if err != "" { fail(err) }
	print_json(result)
}

run_delete :: proc(args: []string) {
	if len(args) > 0 {
		switch args[0] {
		case "session":
			if len(args) < 2 { fail("usage: ctxdb delete session <id>") }
			s, ok := open_store()
			if !ok { return }
			defer store.Close(s)
			if err := store.DeleteSession(s, args[1]); err != "" { fail(err) }
			fmt.println(cat("Session deleted: ", args[1]))
			return
		case "prompt":
			if len(args) < 2 { fail("usage: ctxdb delete prompt <id>") }
			s, ok := open_store()
			if !ok { return }
			defer store.Close(s)
			if err := store.DeletePrompt(s, i64(parse_int(args[1], 0))); err != "" { fail(err) }
			fmt.println(cat("Prompt deleted: ", args[1]))
			return
		case "project":
			if len(args) < 2 { fail("usage: ctxdb delete project <name> [--hard]") }
			hard := false
			for arg in args[2:] {
				if arg == "--hard" { hard = true }
			}
			s, ok := open_store()
			if !ok { return }
			defer store.Close(s)
			result, err := store.DeleteProject(s, args[1], hard)
			if err != "" { fail(err) }
			print_json(result)
			return
		}
	}
	id := i64(0)
	hard := false
	for arg in args {
		switch arg {
		case "--hard":
			hard = true
		case:
			id = i64(parse_int(arg, 0))
		}
	}
	if id == 0 {
		fail("usage: ctxdb delete <observation_id> [--hard]")
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	if err := store.DeleteObservation(s, id, hard); err != "" {
		fail(err)
	}
	if hard {
		fmt.printf("Observation #%d permanently deleted\n", id)
	} else {
		fmt.printf("Observation #%d soft-deleted\n", id)
	}
}

run_session :: proc(args: []string) {
	if len(args) < 2 {
		fail("usage: ctxdb session start|end|get <id>")
	}
	action := args[0]
	session_id := args[1]
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	switch action {
	case "start":
		project_flag := ""
		directory := ""
		mode := store.SESSION_OWNERSHIP_SHARED
		for i := 2; i < len(args); i += 1 {
			switch args[i] {
			case "--project":
				if i + 1 < len(args) {
					project_flag = args[i + 1]
					i += 1
				}
			case "--directory":
				if i + 1 < len(args) {
					directory = args[i + 1]
					i += 1
				}
			case "--mode":
				if i + 1 < len(args) {
					mode = args[i + 1]
					i += 1
				}
			}
		}
		project_name := resolve_project(s, project_flag)
		if directory == "" {
			directory = cwd()
		}
		if err := store.StartSession(s, session_id, project_name, directory, mode); err != "" {
			fail(err)
		}
		fmt.println(cat("Session started: ", session_id))
	case "end":
		summary := ""
		if len(args) > 2 {
			summary = strings.join(args[2:], " ")
		}
		if err := store.EndSession(s, session_id, summary); err != "" {
			fail(err)
		}
		fmt.println(cat("Session ended: ", session_id))
	case "get":
		session, err := store.GetSession(s, session_id)
		if err != "" {
			fail(err)
		}
		print_json(session)
	case "finalize":
		project_flag := ""
		summary := ""
		for i := 2; i < len(args); i += 1 {
			if args[i] == "--project" && i + 1 < len(args) {
				project_flag = args[i + 1]
				i += 1
			} else {
				summary = cat(summary, args[i])
			}
		}
		project_name := resolve_project(s, project_flag)
		result, err := store.FinalizeSession(s, store.Finalize_Session_Params{session_id = session_id, project = project_name, summary = summary})
		if err != "" { fail(err) }
		print_json(result)
	case:
		fail("usage: ctxdb session start|end|get|finalize <id>")
	}
}

run_prompt :: proc(args: []string) {
	if len(args) < 2 {
		fail("usage: ctxdb prompt save|search ...")
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	switch args[0] {
	case "save":
		if len(args) < 3 {
			fail("usage: ctxdb prompt save <session_id> <content> [--project NAME] [--inbox ID]")
		}
		session_id := args[1]
		content := args[2]
		project_flag := ""
		inbox := ""
		for i := 3; i < len(args); i += 1 {
			switch args[i] {
			case "--project":
				if i + 1 < len(args) {
					project_flag = args[i + 1]
					i += 1
				}
			case "--inbox":
				if i + 1 < len(args) {
					inbox = args[i + 1]
					i += 1
				}
			}
		}
		project_name := resolve_project(s, project_flag)
		prompt_id, err := store.AddPrompt(s, store.AddPromptParams{
			session_id = session_id,
			content = content,
			project = project_name,
			source_inbox_id = inbox,
		})
		if err != "" {
			fail(err)
		}
		fmt.printf("Prompt saved: #%d\n", prompt_id)
	case "search":
		query := ""
		project_flag := ""
		all_projects := false
		limit := 10
		for i := 1; i < len(args); i += 1 {
			switch args[i] {
			case "--project":
				if i + 1 < len(args) {
					project_flag = args[i + 1]
					i += 1
				}
			case "--all":
				all_projects = true
			case "--limit":
				if i + 1 < len(args) {
					limit = parse_int(args[i + 1], 10)
					i += 1
				}
			case:
				query = args[i]
			}
		}
		project_name := ""
		if !all_projects {
			project_name = resolve_project(s, project_flag)
		}
		prompts, err := store.SearchPrompts(s, query, project_name, limit)
		if err != "" {
			fail(err)
		}
		defer delete(prompts)
		if len(prompts) == 0 {
			fmt.printf("No prompts found for: %q\n", query)
			return
		}
		for p in prompts {
			fmt.printf("#%d [%s] %s\n%s\n\n", p.id, p.project, p.created_at, p.content)
		}
	case:
		fail("usage: ctxdb prompt save|search ...")
	}
}

run_init :: proc(args: []string) {
	name := ""
	force := false
	for arg in args {
		switch arg {
		case "--force", "-f":
			force = true
		case:
			name = arg
		}
	}
	if name == "" {
		name = base_name(cwd())
	}
	if err := os.make_directory_all(".engram"); err != nil {
		fail("cannot create .engram directory")
	}
	path := ".engram/config.json"
	if !force {
		if _, err := os.stat(path, context.allocator); err == nil {
			fail(cat(path, " already exists (use --force to overwrite)"))
		}
	}
	data := cat(`{"project_name":`, json_quote(name), `}`)
	if err := os.write_entire_file_from_string(path, data); err != nil {
		fail(cat("cannot write ", path))
	}
	fmt.println(cat("Initialized ctxdb project: ", name))
}

run_compatibility :: proc(args: []string) {
	data_dir := ""
	as_json := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--data-dir":
			if i + 1 < len(args) { data_dir = args[i + 1]; i += 1 }
		case "--json":
			as_json = true
		}
	}
	if data_dir == "" {
		cfg, cerr := store.DefaultConfig()
		if cerr != "" { fail(cerr) }
		data_dir = cfg.data_dir
	}
	report, err := store.Compatibility(data_dir)
	if err != "" { fail(err) }
	if as_json {
		print_json(report)
		return
	}
	fmt.printf("Compatibility: %s\n", report.status)
	fmt.printf("  Database:     %s\n", report.database)
	fmt.printf("  Schema OK:    %v\n", report.schema_ok)
	fmt.printf("  Sessions:     %d\n", report.sessions)
	fmt.printf("  Observations: %d\n", report.observations)
	fmt.printf("  Prompts:      %d\n", report.prompts)
	for issue in report.issues {
		fmt.printf("  Issue:        %s\n", issue)
	}
}

run_migrate_copy :: proc(args: []string) {
	source := ""
	destination := ""
	confirmed := false
	as_json := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--data-dir":
			if i + 1 < len(args) { source = args[i + 1]; i += 1 }
		case "--output-dir":
			if i + 1 < len(args) { destination = args[i + 1]; i += 1 }
		case "--confirm-quiescent":
			confirmed = true
		case "--json":
			as_json = true
		}
	}
	if source == "" || destination == "" {
		fail("usage: ctxdb migrate-copy --data-dir SRC --output-dir DST --confirm-quiescent")
	}
	if !confirmed {
		fail("migrate-copy requires --confirm-quiescent")
	}
	message, err := store.CopyDatabase(source, destination)
	if err != "" { fail(err) }
	if as_json {
		print_json(struct{ status: string `json:"status"`, message: string `json:"message"` }{status = "ok", message = message})
	} else {
		fmt.println(message)
	}
}

run_doctor :: proc(args: []string) {
	as_json := false
	for arg in args {
		if arg == "--json" {
			as_json = true
		}
	}
	s, ok := open_store()
	if !ok {
		return
	}
	defer store.Close(s)
	stats, err := store.GetStats(s)
	if err != "" {
		fail(err)
	}
	if as_json {
		report := struct {
			status:    string      `json:"status"`,
			version:   string      `json:"version"`,
			sqlite:    string      `json:"sqlite"`,
			database:  string      `json:"database"`,
			tables_ok: bool        `json:"tables_ok"`,
			stats:     store.Stats `json:"stats"`,
		}{
			status = "ok",
			version = VERSION,
			sqlite = store.SQLiteVersion(),
			database = store.DBPath(s),
			tables_ok = true,
			stats = stats,
		}
		print_json(report)
		return
	}
	fmt.println("ctxdb Doctor")
	fmt.printf("  Status:       ok\n")
	fmt.printf("  Database:     %s\n", store.DBPath(s))
	fmt.printf("  Sessions:     %d\n", stats.total_sessions)
	fmt.printf("  Observations: %d\n", stats.total_observations)
	fmt.printf("  Prompts:      %d\n", stats.total_prompts)
}

// Helpers shared by CLI commands.

parse_float :: proc(text: string, fallback: f64) -> f64 {
	value, ok := strconv.parse_f64(text)
	if !ok {
		return fallback
	}
	return value
}

parse_int :: proc(text: string, fallback: int) -> int {
	n := 0
	sign := 1
	i := 0
	if len(text) > 0 && text[0] == '-' {
		sign = -1
		i = 1
	}
	if i >= len(text) {
		return fallback
	}
	for ; i < len(text); i += 1 {
		c := text[i]
		if c < '0' || c > '9' {
			return fallback
		}
		n = n * 10 + int(c - '0')
	}
	return n * sign
}

preview_content :: proc(content: string, limit: int) -> string {
	return truncate_runes(content, limit)
}

truncate_runes :: proc(s: string, limit: int) -> string {
	if limit <= 0 {
		return ""
	}
	count := 0
	for _, byte_index in s {
		if count == limit {
			return cat(s[:byte_index], "...")
		}
		count += 1
	}
	return s
}

print_json :: proc(value: any) {
	data, err := json.marshal(value, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		fail("cannot encode JSON output")
	}
	fmt.println(string(data))
}

json_quote :: proc(value: string) -> string {
	data, err := json.marshal(value)
	if err != nil {
		return `""`
	}
	return string(data)
}

base_name :: proc(path: string) -> string {
	trimmed := strings.trim_right(path, "/")
	if idx := strings.last_index_byte(trimmed, '/'); idx >= 0 {
		return trimmed[idx + 1:]
	}
	return trimmed
}
