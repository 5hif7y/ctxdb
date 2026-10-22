// Read-only compatibility inspection and database copy.
package store

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "../sqlite"

Compatibility_Report :: struct {
	status:       string   `json:"status"`,
	database:     string   `json:"database"`,
	schema_ok:    bool     `json:"schema_ok"`,
	tables:       []string `json:"tables"`,
	sessions:     int      `json:"sessions"`,
	observations: int      `json:"observations"`,
	prompts:      int      `json:"prompts"`,
	issues:       []string `json:"issues"`,
}

Compatibility :: proc(data_dir: string) -> (Compatibility_Report, string) {
	report := Compatibility_Report{status = "ok", database = data_dir}
	db_path, _ := filepath.join({data_dir, DB_FILENAME})
	if _, stat_err := os.stat(db_path, context.allocator); stat_err != nil {
		return report, "database file not found"
	}
	db, err := sqlite.open_readonly(db_path)
	if err != "" {
		return report, err
	}
	defer sqlite.close(&db)

	tables := make([dynamic]string)
	stmt, terr := sqlite.prepare(&db, "SELECT name FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
	if terr != "" {
		return report, terr
	}
	for {
		has, serr := sqlite.step(&stmt)
		if serr != "" || !has { break }
		append(&tables, sqlite.column_text(&stmt, 0))
	}
	sqlite.finalize(&stmt)
	report.tables = exact_slice(tables)

	report.sessions = readonly_count(&db, "sessions")
	report.observations = readonly_count(&db, "observations")
	report.prompts = readonly_count(&db, "user_prompts")
	issues := make([dynamic]string)
	defer delete(issues)
	for required in ([]string{"sessions", "observations", "observations_fts", "user_prompts"}) {
		found := false
		for table in report.tables {
			if table == required { found = true; break }
		}
		if !found {
			append(&issues, cat("missing table: ", required))
		}
	}
	report.schema_ok = len(issues) == 0
	report.issues = exact_slice(issues)
	if !report.schema_ok {
		report.status = "incompatible"
	}
	return report, ""
}

readonly_count :: proc(db: ^sqlite.DB, table: string) -> int {
	sql := cat("SELECT COUNT(*) FROM ", table)
	stmt, err := sqlite.prepare(db, sql)
	if err != "" { return 0 }
	defer sqlite.finalize(&stmt)
	has, serr := sqlite.step(&stmt)
	if serr != "" || !has { return 0 }
	return int(sqlite.column_int(&stmt, 0))
}

CopyDatabase :: proc(source_dir, destination_dir: string) -> (string, string) {
	src_path, _ := filepath.join({source_dir, DB_FILENAME})
	dst_path, _ := filepath.join({destination_dir, DB_FILENAME})
	if _, err := os.stat(src_path, context.allocator); err != nil {
		return "", "source database not found"
	}
	if _, err := os.stat(dst_path, context.allocator); err == nil {
		return "", "destination database already exists"
	}
	if err := os.make_directory_all(destination_dir); err != nil {
		return "", "cannot create destination directory"
	}
	src, err := sqlite.open_readonly(src_path)
	if err != "" {
		return "", err
	}
	stmt, perr := sqlite.prepare(&src, "VACUUM INTO ?")
	if perr != "" {
		sqlite.close(&src)
		return "", perr
	}
	_ = sqlite.bind_text(&stmt, 1, dst_path)
	_, serr := sqlite.step(&stmt)
	sqlite.finalize(&stmt)
	sqlite.close(&src)
	if serr != "" {
		return "", serr
	}
	// Open the copy once so additive migrations are applied to the copy only.
	dst, derr := Open(FallbackConfig(destination_dir))
	if derr != "" {
		return "", derr
	}
	Close(dst)
	return fmt.tprintf("database copied to %s", dst_path), ""
}
