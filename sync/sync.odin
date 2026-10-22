// Git-friendly local sync: content-addressed gzipped JSON chunks plus a
// manifest. This is the local subset of Engram's sync format; cloud delivery
// and mutation ledgers remain separate.
package syncer

import "core:bytes"
import "core:compress/gzip"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../store"
import "../util"

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

MANIFEST_VERSION :: 2

Manifest :: struct {
	version: int            `json:"version"`,
	chunks:  []Chunk_Entry  `json:"chunks"`,
}

Chunk_Entry :: struct {
	id:         string `json:"id"`,
	created_by: string `json:"created_by"`,
	created_at: string `json:"created_at"`,
	sessions:   int    `json:"sessions"`,
	memories:   int    `json:"memories"`,
	prompts:    int    `json:"prompts"`,
}

Sync_Result :: struct {
	empty:        bool   `json:"empty,omitempty"`,
	chunk_id:     string `json:"chunk_id,omitempty"`,
	sessions:     int    `json:"sessions"`,
	observations: int    `json:"observations"`,
	prompts:      int    `json:"prompts"`,
}

Import_Result :: struct {
	chunks_imported:  int `json:"chunks_imported"`,
	sessions:         int `json:"sessions"`,
	observations:     int `json:"observations"`,
	prompts:          int `json:"prompts"`,
}

Status :: struct {
	manifest_chunks: int `json:"manifest_chunks"`,
	local_chunks:    int `json:"local_chunks"`,
	pending:         int `json:"pending_import"`,
}

manifest_path :: proc(dir: string) -> string {
	path, _ := filepath.join({dir, "manifest.json"})
	return path
}

chunks_dir :: proc(dir: string) -> string {
	path, _ := filepath.join({dir, "chunks"})
	return path
}

read_manifest :: proc(dir: string) -> (Manifest, string) {
	path := manifest_path(dir)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return Manifest{version = MANIFEST_VERSION}, ""
	}
	defer delete(data)
	m: Manifest
	if jerr := json.unmarshal(data, &m); jerr != nil {
		return {}, "invalid sync manifest"
	}
	if m.version == 0 {
		m.version = MANIFEST_VERSION
	}
	return m, ""
}

write_manifest :: proc(dir: string, manifest: Manifest) -> string {
	data, err := json.marshal(manifest, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		return "cannot encode manifest"
	}
	path := manifest_path(dir)
	if werr := os.write_entire_file_from_string(path, string(data)); werr != nil {
		return os.error_string(werr)
	}
	return ""
}

ensure_sync_dirs :: proc(dir: string) -> string {
	for path in ([]string{dir, chunks_dir(dir)}) {
		if _, err := os.stat(path, context.allocator); err != nil {
			if mkerr := os.make_directory_all(path); mkerr != nil {
				return os.error_string(mkerr)
			}
		}
	}
	return ""
}

Export :: proc(s: ^store.STORE, dir, project_name: string) -> (Sync_Result, string) {
	if err := ensure_sync_dirs(dir); err != "" {
		return {}, err
	}
	manifest, merr := read_manifest(dir)
	if merr != "" {
		return {}, merr
	}
	data, xerr := store.Export(s, project_name)
	if xerr != "" {
		return {}, xerr
	}
	if len(data.sessions) == 0 && len(data.observations) == 0 && len(data.prompts) == 0 {
		return Sync_Result{empty = true}, ""
	}
	chunk_json, jerr := json.marshal(data)
	if jerr != nil {
		return {}, "cannot encode sync chunk"
	}
	chunk_id := sha256_hex8(chunk_json)
	for entry in manifest.chunks {
		if entry.id == chunk_id {
			return Sync_Result{empty = true, chunk_id = chunk_id}, ""
		}
	}
	compressed := gzip_store(chunk_json)
	defer delete(compressed)
	chunk_name := fmt.tprintf("%s.jsonl.gz", chunk_id)
	chunk_path, _ := filepath.join({chunks_dir(dir), chunk_name})
	if werr := os.write_entire_file_from_bytes(chunk_path, compressed); werr != nil {
		return {}, os.error_string(werr)
	}
	entry := Chunk_Entry{
		id = chunk_id,
		created_by = created_by(),
		created_at = store.Now(s.db),
		sessions = len(data.sessions),
		memories = len(data.observations),
		prompts = len(data.prompts),
	}
	chunks := make([dynamic]Chunk_Entry, 0, len(manifest.chunks) + 1)
	append(&chunks, ..manifest.chunks)
	append(&chunks, entry)
	manifest.chunks = chunks[:]
	if err := write_manifest(dir, manifest); err != "" {
		return {}, err
	}
	if err := store.RecordSyncedChunk(s, store.SYNC_LOCAL_TARGET, chunk_id); err != "" {
		return {}, err
	}
	return Sync_Result{chunk_id = chunk_id, sessions = entry.sessions, observations = entry.memories, prompts = entry.prompts}, ""
}

Import :: proc(s: ^store.STORE, dir: string) -> (Import_Result, string) {
	manifest, merr := read_manifest(dir)
	if merr != "" {
		return {}, merr
	}
	local, lerr := store.GetSyncedChunks(s, store.SYNC_LOCAL_TARGET)
	if lerr != "" {
		return {}, lerr
	}
	defer delete(local)
	result: Import_Result
	for entry in manifest.chunks {
		if local[entry.id] {
			continue
		}
		chunk_path, _ := filepath.join({chunks_dir(dir), cat(entry.id, ".jsonl.gz")})
		raw, rerr := os.read_entire_file_from_path(chunk_path, context.allocator)
		if rerr != nil {
			return result, cat("cannot read chunk ", entry.id)
		}
		defer delete(raw)
		decoded, gerr := gzip_load(raw)
		if gerr != "" {
			return result, gerr
		}
		data: store.Export_Data
		if jerr := json.unmarshal(decoded, &data); jerr != nil {
			return result, cat("invalid chunk JSON: ", entry.id)
		}
		imported, ierr := store.Import(s, data)
		if ierr != "" {
			return result, ierr
		}
		result.chunks_imported += 1
		result.sessions += imported.sessions_imported
		result.observations += imported.observations_imported + imported.observations_updated
		result.prompts += imported.prompts_imported
		if err := store.RecordSyncedChunk(s, store.SYNC_LOCAL_TARGET, entry.id); err != "" {
			return result, err
		}
	}
	return result, ""
}

GetStatus :: proc(s: ^store.STORE, dir: string) -> (Status, string) {
	manifest, merr := read_manifest(dir)
	if merr != "" {
		return {}, merr
	}
	local, lerr := store.GetSyncedChunks(s, store.SYNC_LOCAL_TARGET)
	if lerr != "" {
		return {}, lerr
	}
	defer delete(local)
	status := Status{manifest_chunks = len(manifest.chunks), local_chunks = len(local)}
	for entry in manifest.chunks {
		if !local[entry.id] {
			status.pending += 1
		}
	}
	return status, ""
}

created_by :: proc() -> string {
	if user := strings.trim_space(os.get_env_alloc("USER", context.allocator)); user != "" {
		return user
	}
	if user := strings.trim_space(os.get_env_alloc("USERNAME", context.allocator)); user != "" {
		return user
	}
	return "unknown"
}

// ─── Gzip stored-block writer ───────────────────────────────────────────────
// Odin's standard library ships a gzip reader but not a writer. Stored
// (uncompressed) DEFLATE blocks are valid gzip and readable by Go, Python, and
// the Odin reader, so the chunk container remains interoperable.

gzip_store :: proc(data: []byte) -> []byte {
	out := make([dynamic]u8, 0, len(data) + 32)
	append(&out, 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03)
	pos := 0
	if len(data) == 0 {
		append(&out, 1, 0, 0)
		append(&out, 0xff, 0xff)
	}
	for pos < len(data) {
		n := min(65535, len(data) - pos)
		final := pos + n >= len(data)
		append(&out, final ? 1 : 0)
		put_u16le(&out, u16(n))
		put_u16le(&out, ~u16(n))
		append(&out, ..data[pos:pos + n])
		pos += n
	}
	put_u32le(&out, hash.crc32(data))
	put_u32le(&out, u32(len(data)))
	return out[:]
}

gzip_load :: proc(data: []byte) -> ([]byte, string) {
	buf: bytes.Buffer
	if err := gzip.load_from_bytes(data, &buf, len(data)); err != nil {
		return nil, "cannot decompress sync chunk"
	}
	out := make([]byte, len(bytes.buffer_to_bytes(&buf)))
	copy(out, bytes.buffer_to_bytes(&buf))
	bytes.buffer_destroy(&buf)
	return out, ""
}

put_u16le :: proc(out: ^[dynamic]u8, value: u16) {
	append(out, u8(value & 0xff), u8((value >> 8) & 0xff))
}

put_u32le :: proc(out: ^[dynamic]u8, value: u32) {
	append(out, u8(value & 0xff), u8((value >> 8) & 0xff), u8((value >> 16) & 0xff), u8((value >> 24) & 0xff))
}

sha256_hex8 :: proc(data: []byte) -> string {
	return util.Sha256Hex8(data)
}
