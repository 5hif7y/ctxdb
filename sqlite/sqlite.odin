// Minimal SQLite3 bindings and a small, allocation-friendly wrapper.
//
// ctxdb deliberately links against the system SQLite library instead of
// vendoring a C library. FTS5 with the trigram tokenizer is required.
package sqlite

import "core:c"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import lib "system:sqlite3"
} else {
	foreign import lib "system:sqlite3"
}

// SQLITE_TRANSIENT is the destructor sentinel value ((sqlite3_destructor_type)-1):
// SQLite copies the bound text immediately, so temporary Odin strings are safe.
SQLITE_TRANSIENT :: rawptr(~uintptr(0))

SQLITE_OK :: 0
SQLITE_ROW :: 100
SQLITE_DONE :: 101

SQLITE_OPEN_READWRITE :: 0x00000002
SQLITE_OPEN_CREATE :: 0x00000004
SQLITE_OPEN_FULLMUTEX :: 0x00010000

Db :: struct {}
Stmt :: struct {}

@(default_calling_convention = "c")
foreign lib {
	sqlite3_open_v2 :: proc(filename: cstring, ppDb: ^^Db, flags: c.int, zVfs: cstring) -> c.int ---
	sqlite3_close_v2 :: proc(db: ^Db) -> c.int ---
	sqlite3_errmsg :: proc(db: ^Db) -> cstring ---
	sqlite3_extended_errcode :: proc(db: ^Db) -> c.int ---
	sqlite3_exec :: proc(db: ^Db, sql: cstring, callback: rawptr, arg: rawptr, errmsg: ^cstring) -> c.int ---
	sqlite3_free :: proc(p: rawptr) ---
	sqlite3_busy_timeout :: proc(db: ^Db, ms: c.int) -> c.int ---
	sqlite3_prepare_v2 :: proc(db: ^Db, sql: cstring, nByte: c.int, ppStmt: ^^Stmt, pzTail: ^cstring) -> c.int ---
	sqlite3_finalize :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_step :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_reset :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_clear_bindings :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_bind_text :: proc(stmt: ^Stmt, index: c.int, value: cstring, n: c.int, destructor: rawptr) -> c.int ---
	sqlite3_bind_int64 :: proc(stmt: ^Stmt, index: c.int, value: i64) -> c.int ---
	sqlite3_bind_double :: proc(stmt: ^Stmt, index: c.int, value: f64) -> c.int ---
	sqlite3_bind_null :: proc(stmt: ^Stmt, index: c.int) -> c.int ---
	sqlite3_column_count :: proc(stmt: ^Stmt) -> c.int ---
	sqlite3_column_type :: proc(stmt: ^Stmt, iCol: c.int) -> c.int ---
	sqlite3_column_text :: proc(stmt: ^Stmt, iCol: c.int) -> cstring ---
	sqlite3_column_bytes :: proc(stmt: ^Stmt, iCol: c.int) -> c.int ---
	sqlite3_column_int64 :: proc(stmt: ^Stmt, iCol: c.int) -> i64 ---
	sqlite3_column_double :: proc(stmt: ^Stmt, iCol: c.int) -> f64 ---
	sqlite3_changes :: proc(db: ^Db) -> c.int ---
	sqlite3_last_insert_rowid :: proc(db: ^Db) -> i64 ---
	sqlite3_libversion :: proc() -> cstring ---
}

SQLITE_INTEGER :: 1
SQLITE_FLOAT :: 2
SQLITE_TEXT :: 3
SQLITE_NULL :: 5

DB :: struct {
	handle: ^Db,
	path:   string,
}

STMT :: struct {
	handle: ^Stmt,
	db:     ^DB,
}

// open opens (or creates) a database. The connection is configured for the
// single-writer / multi-reader usage pattern of the local store.
open :: proc(path: string) -> (DB, string) {
	db: DB
	db.path = strings.clone(path)
	path_buf := make([]byte, len(path) + 1)
	copy(path_buf, path)
	path_buf[len(path)] = 0
	defer delete(path_buf)

	rc := sqlite3_open_v2(cstring(raw_data(path_buf)), &db.handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
	if rc != SQLITE_OK {
		msg := db_error_message(db)
		if db.handle != nil {
			sqlite3_close_v2(db.handle)
		}
		return {}, msg
	}
	_ = sqlite3_busy_timeout(db.handle, 5000)
	return db, ""
}

close :: proc(db: ^DB) {
	if db.handle != nil {
		_ = sqlite3_close_v2(db.handle)
		db.handle = nil
	}
	if db.path != "" {
		delete(db.path)
		db.path = ""
	}
}

error_message :: proc(db: ^DB) -> string {
	return db_error_message(db^)
}

db_error_message :: proc(db: DB) -> string {
	if db.handle == nil {
		return "sqlite: database handle is nil"
	}
	return strings.clone(string(sqlite3_errmsg(db.handle)))
}

exec :: proc(db: ^DB, sql: string) -> string {
	sql_buf := make([]byte, len(sql) + 1)
	copy(sql_buf, sql)
	sql_buf[len(sql)] = 0
	defer delete(sql_buf)
	rc := sqlite3_exec(db.handle, cstring(raw_data(sql_buf)), nil, nil, nil)
	if rc != SQLITE_OK {
		return db_error_message(db^)
	}
	return ""
}

exec_script :: exec

last_insert_rowid :: proc(db: ^DB) -> i64 {
	return sqlite3_last_insert_rowid(db.handle)
}

changes :: proc(db: ^DB) -> int {
	return int(sqlite3_changes(db.handle))
}

libversion :: proc() -> string {
	return strings.clone(string(sqlite3_libversion()))
}

prepare :: proc(db: ^DB, sql: string) -> (STMT, string) {
	stmt: STMT
	stmt.db = db
	// nByte is provided, so the input does not have to be NUL-terminated and
	// SQLite copies the statement text. Avoid an allocation on every query.
	rc := sqlite3_prepare_v2(db.handle, cstring(raw_data(sql)), c.int(len(sql)), &stmt.handle, nil)
	if rc != SQLITE_OK {
		return {}, db_error_message(db^)
	}
	return stmt, ""
}

finalize :: proc(stmt: ^STMT) {
	if stmt.handle != nil {
		_ = sqlite3_finalize(stmt.handle)
		stmt.handle = nil
	}
}

reset :: proc(stmt: ^STMT) -> string {
	rc := sqlite3_reset(stmt.handle)
	_ = sqlite3_clear_bindings(stmt.handle)
	if rc != SQLITE_OK {
		return db_error(stmt)
	}
	return ""
}

db_error :: proc(stmt: ^STMT) -> string {
	if stmt.db == nil {
		return "sqlite: statement has no database"
	}
	return strings.clone(string(sqlite3_errmsg(stmt.db.handle)))
}

bind_text :: proc(stmt: ^STMT, index: int, value: string) -> string {
	// SQLITE_STATIC: the string remains alive until step/reset. All callers
	// keep their arguments valid for the duration of the statement. An empty
	// string must still be a real text value: SQLite treats a nil data pointer
	// as NULL, which would break equality filters such as `? = ''`.
	ptr := cstring(raw_data(value))
	if len(value) == 0 {
		ptr = cstring("")
	}
	rc := sqlite3_bind_text(stmt.handle, c.int(index), ptr, c.int(len(value)), SQLITE_TRANSIENT)
	if rc != SQLITE_OK {
		return db_error(stmt)
	}
	return ""
}

bind_int :: proc(stmt: ^STMT, index: int, value: i64) -> string {
	rc := sqlite3_bind_int64(stmt.handle, c.int(index), value)
	if rc != SQLITE_OK {
		return db_error(stmt)
	}
	return ""
}

bind_double :: proc(stmt: ^STMT, index: int, value: f64) -> string {
	rc := sqlite3_bind_double(stmt.handle, c.int(index), value)
	if rc != SQLITE_OK {
		return db_error(stmt)
	}
	return ""
}

bind_null :: proc(stmt: ^STMT, index: int) -> string {
	rc := sqlite3_bind_null(stmt.handle, c.int(index))
	if rc != SQLITE_OK {
		return db_error(stmt)
	}
	return ""
}

// step returns (has_row, error). has_row is false both at completion and on
// error; callers must inspect the error string before treating false as done.
step :: proc(stmt: ^STMT) -> (bool, string) {
	rc := sqlite3_step(stmt.handle)
	switch rc {
	case SQLITE_ROW:
		return true, ""
	case SQLITE_DONE:
		return false, ""
	case:
		return false, db_error(stmt)
	}
}

column_count :: proc(stmt: ^STMT) -> int {
	return int(sqlite3_column_count(stmt.handle))
}

column_type :: proc(stmt: ^STMT, index: int) -> int {
	return int(sqlite3_column_type(stmt.handle, c.int(index)))
}

column_is_null :: proc(stmt: ^STMT, index: int) -> bool {
	return sqlite3_column_type(stmt.handle, c.int(index)) == SQLITE_NULL
}

// column_text returns a freshly allocated copy. SQLite's pointer is only valid
// until the next step/finalize, and the store keeps values beyond that point.
column_text :: proc(stmt: ^STMT, index: int) -> string {
	if column_is_null(stmt, index) {
		return ""
	}
	p := sqlite3_column_text(stmt.handle, c.int(index))
	n := sqlite3_column_bytes(stmt.handle, c.int(index))
	if p == nil || n <= 0 {
		return ""
	}
	bytes := ([^]u8)(rawptr(p))
	return strings.clone(string(bytes[:int(n)]))
}

column_int :: proc(stmt: ^STMT, index: int) -> i64 {
	return sqlite3_column_int64(stmt.handle, c.int(index))
}

column_double :: proc(stmt: ^STMT, index: int) -> f64 {
	return sqlite3_column_double(stmt.handle, c.int(index))
}

// transaction wraps a unit of work. Nested transactions are intentionally not
// supported; callers compose operations inside one explicit transaction.
transaction :: proc(db: ^DB, body: proc(db: ^DB) -> string) -> string {
	if err := exec(db, "BEGIN IMMEDIATE"); err != "" {
		return err
	}
	if err := body(db); err != "" {
		_ = exec(db, "ROLLBACK")
		return err
	}
	if err := exec(db, "COMMIT"); err != "" {
		_ = exec(db, "ROLLBACK")
		return err
	}
	return ""
}
