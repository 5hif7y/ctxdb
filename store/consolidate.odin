// Atomic consolidation of several observations into one survivor.
package store

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:sort"
import "core:strings"

import "../sqlite"
import "../util"

CONSOLIDATED_FROM_MARKER :: "## consolidated_from"

Consolidate_Overrides :: struct {
	title:     string,
	content:   string,
	typ:       string,
	topic_key: string,
}

Consolidate_Survivor :: struct {
	session_id: string `json:"session_id"`,
	title:      string `json:"title"`,
	content:    string `json:"content"`,
	type:       string `json:"type"`,
	scope:      string `json:"scope"`,
	project:    string `json:"project"`,
	topic_key:  string `json:"topic_key"`,
}

Consolidate_Plan :: struct {
	ids:         []i64              `json:"ids"`,
	sources:     []Observation      `json:"sources"`,
	survivor:    Consolidate_Survivor `json:"survivor"`,
	project:     string             `json:"project"`,
	fingerprint: string             `json:"fingerprint"`,
}

Consolidate_Params :: struct {
	ids:         []i64,
	overrides:   Consolidate_Overrides,
	confirm:     bool,
	fingerprint: string,
}

Consolidate_Result :: struct {
	plan:     Consolidate_Plan,
	survivor: Maybe(Observation),
}

consolidate_fingerprint :: proc(sources: []Observation, survivor: Consolidate_Survivor) -> string {
	// IDs are sorted before hashing so input order cannot change the plan.
	ordered := make([dynamic]Observation, 0, len(sources))
	defer delete(ordered)
	for src in sources {
		append(&ordered, src)
	}
	sort.quick_sort_proc(ordered[:], proc(a, b: Observation) -> int {
		if a.id < b.id { return -1 }
		if a.id > b.id { return 1 }
		return 0
	})
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "consolidate:v2\n")
	for src in ordered {
		fmt.sbprintf(&b, "%d\x00%s\x00%s\x00%s\x00%s\x00%s\x00%s\x00%v\n",
			src.id, src.sync_id, src.updated_at, src.title, src.content,
			src.project, src.scope, src.pinned)
	}
	fmt.sbprintf(&b, "\x00%s\x00%s\x00%s\x00%s\x00%s\x00%s\x00%s",
		survivor.session_id, survivor.title, survivor.content, survivor.type,
		survivor.scope, survivor.project, survivor.topic_key)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)strings.to_string(b))
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	encoded, _ := hex.encode(digest[:])
	return string(encoded)
}

build_consolidation_plan :: proc(s: ^STORE, ids: []i64, overrides: Consolidate_Overrides) -> (^Consolidate_Plan, string) {
	if len(ids) < 2 {
		return nil, "consolidate needs at least two source observations"
	}
	seen := make(map[i64]bool)
	defer delete(seen)
	sources := make([dynamic]Observation, 0, len(ids))
	for id in ids {
		if seen[id] {
			return nil, "consolidate source list contains duplicate ids"
		}
		seen[id] = true
		obs, err := GetObservation(s, id)
		if err != "" {
			return nil, "consolidate source missing or already deleted"
		}
		append(&sources, obs)
	}

	sort.quick_sort_proc(sources[:], proc(a, b: Observation) -> int {
		if a.created_at != b.created_at {
			return -1 if a.created_at > b.created_at else 1
		}
		if a.id != b.id {
			return -1 if a.id > b.id else 1
		}
		return 0
	})

	canonical := ""
	for i in 0 ..< len(sources) {
		project_name := sources[i].project
		if project_name == "" {
			resolved, err := session_project(s, sources[i].session_id)
			if err != "" {
				return nil, err
			}
			project_name = resolved
		}
		project_name, _ = util.NormalizeProject(project_name)
		if project_name == "" {
			return nil, ERR_PROJECT_REQUIRED
		}
		sources[i].project = project_name
		if i == 0 {
			canonical = project_name
		} else if project_name != canonical {
			return nil, "consolidate sources span multiple projects"
		}
	}

	newest := sources[0]
	survivor := Consolidate_Survivor{
		session_id = newest.session_id,
		type = overrides.typ,
		scope = util.NormalizeScope(newest.scope),
		project = canonical,
		topic_key = util.NormalizeTopicKey(overrides.topic_key),
	}
	if survivor.type == "" {
		survivor.type = newest.type
	}
	if overrides.title != "" {
		survivor.title = overrides.title
	} else {
		titles := make([dynamic]string, 0, len(sources))
		defer delete(titles)
		for src in sources {
			append(&titles, src.title)
		}
		survivor.title = strings.join(titles[:], " · ")
	}
	base := overrides.content
	if base == "" {
		contents := make([dynamic]string, 0, len(sources))
		defer delete(contents)
		for src in sources {
			append(&contents, src.content)
		}
		base = strings.join(contents[:], "\n\n")
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, strings.trim_right(base, "\n"))
	strings.write_string(&b, "\n\n")
	strings.write_string(&b, CONSOLIDATED_FROM_MARKER)
	strings.write_string(&b, "\n")
	for src in sources {
		fmt.sbprintf(&b, "- %s\n", src.sync_id)
	}
	survivor.content = strings.clone(strings.to_string(b))

	plan := new(Consolidate_Plan)
	plan.ids = make([]i64, len(ids))
	copy(plan.ids, ids)
	plan.sources = exact_slice(sources)
	plan.survivor = survivor
	plan.project = canonical
	plan.fingerprint = consolidate_fingerprint(plan.sources, survivor)
	return plan, ""
}

// ConsolidateObservations previews (confirm=false) or applies a merge.
ConsolidateObservations :: proc(s: ^STORE, p: Consolidate_Params) -> (Consolidate_Result, string) {
	plan, err := build_consolidation_plan(s, p.ids, p.overrides)
	if err != "" {
		return {}, err
	}
	if !p.confirm {
		return Consolidate_Result{plan = plan^}, ""
	}
	if p.fingerprint != plan.fingerprint {
		return Consolidate_Result{plan = plan^}, "consolidate sources changed since plan; re-plan required"
	}

	if terr := sqlite.exec(s.db, "BEGIN IMMEDIATE"); terr != "" {
		return {}, terr
	}
	// Re-resolve inside the transaction and confirm the fingerprint again.
	fresh, ferr := build_consolidation_plan(s, p.ids, p.overrides)
	if ferr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, ferr
	}
	if fresh.fingerprint != plan.fingerprint {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return Consolidate_Result{plan = fresh^}, "consolidate sources changed since plan; re-plan required"
	}

	sync_id := util.NewSyncID("obs")
	ins, ierr := sqlite.prepare(s.db, `
		INSERT INTO observations
			(sync_id, session_id, type, title, content, tool_name, project, scope, topic_key,
			 normalized_hash, revision_count, duplicate_count, last_seen_at, updated_at)
		VALUES (?, ?, ?, ?, ?, 'mem_consolidate', ?, ?, ?, ?, 1, 1, datetime('now'), datetime('now'))`)
	if ierr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, ierr
	}
	_ = sqlite.bind_text(&ins, 1, sync_id)
	_ = sqlite.bind_text(&ins, 2, fresh.survivor.session_id)
	_ = sqlite.bind_text(&ins, 3, fresh.survivor.type)
	_ = sqlite.bind_text(&ins, 4, fresh.survivor.title)
	_ = sqlite.bind_text(&ins, 5, fresh.survivor.content)
	_ = bind_nullable(&ins, 6, fresh.survivor.project)
	_ = sqlite.bind_text(&ins, 7, fresh.survivor.scope)
	_ = bind_nullable(&ins, 8, fresh.survivor.topic_key)
	_ = sqlite.bind_text(&ins, 9, util.HashNormalized(fresh.survivor.content))
	_, serr := sqlite.step(&ins)
	sqlite.finalize(&ins)
	if serr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, serr
	}

	for src in fresh.sources {
		upd, uerr := sqlite.prepare(s.db, `
			UPDATE observations
			SET deleted_at = datetime('now'), superseded_by_sync_id = ?, updated_at = datetime('now')
			WHERE id = ? AND deleted_at IS NULL`)
		if uerr != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return {}, uerr
		}
		_ = sqlite.bind_text(&upd, 1, sync_id)
		_ = sqlite.bind_int(&upd, 2, src.id)
		_, ude := sqlite.step(&upd)
		sqlite.finalize(&upd)
		if ude != "" {
			_ = sqlite.exec(s.db, "ROLLBACK")
			return {}, ude
		}
	}
	if cerr := sqlite.exec(s.db, "COMMIT"); cerr != "" {
		_ = sqlite.exec(s.db, "ROLLBACK")
		return {}, cerr
	}

	survivor, gerr := GetObservationBySyncID(s, sync_id)
	if gerr != "" {
		return Consolidate_Result{plan = fresh^}, gerr
	}
	return Consolidate_Result{plan = fresh^, survivor = survivor}, ""
}
