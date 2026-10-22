// Periodic Obsidian export. This is a polling loop, not a filesystem watcher:
// every cycle calls the same incremental Export used by one-shot mode.
package obsidian

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"

import "../store"

Watch_Options :: struct {
	vault:      string,
	project:    string,
	limit:      int,
	since:      string,
	force:      bool,
	graph_mode: string,
	interval:   time.Duration,
}

// Package-private stop flag shared with the platform signal adapter.
watch_stop: i32

// Watch runs an immediate export, then repeats every interval until SIGINT or
// SIGTERM. Export errors are logged and do not terminate the loop. The graph
// config is applied only on the first cycle; subsequent cycles use "skip".
Watch :: proc(s: ^store.STORE, opts: Watch_Options) -> (int, string) {
	if strings.trim_space(opts.vault) == "" {
		return 0, "--vault path is required"
	}
	if opts.graph_mode != "preserve" && opts.graph_mode != "force" && opts.graph_mode != "skip" {
		return 0, "invalid --graph-config value (accepted: preserve, force, skip)"
	}
	if opts.interval <= 0 {
		return 0, "watch interval must be positive"
	}
	sync.atomic_store(&watch_stop, 0)
	graceful := install_watch_signals()
	defer restore_watch_signals()
	if !graceful {
		fmt.eprintln("[ctxdb] obsidian watch: graceful signal handling is unavailable on this platform")
	}

	cycles := 0
	for {
		cycles += 1
		mode := opts.graph_mode
		if cycles > 1 {
			mode = "skip"
		}
		force := opts.force && cycles == 1
		result, err := Export(s, opts.vault, opts.project, opts.limit, opts.since, force, mode)
		if err != "" {
			fmt.eprintfln("[ctxdb] obsidian sync error: %s", err)
		} else if cycles == 1 ||
			result.created + result.updated + result.deleted + result.hubs > 0 {
			buf: [16]u8
			fmt.eprintfln(
				"[%s] obsidian sync: created=%d updated=%d deleted=%d skipped=%d hubs=%d",
				time.to_string_hms(time.now(), buf[:]),
				result.created,
				result.updated,
				result.deleted,
				result.skipped,
				result.hubs,
			)
		}
		if sync.atomic_load(&watch_stop) != 0 {
			break
		}
		if !sleep_until_stop(opts.interval) {
			break
		}
	}
	return cycles, ""
}

sleep_until_stop :: proc(d: time.Duration) -> bool {
	remaining := d
	chunk := time.Duration(200 * time.Millisecond)
	for remaining > 0 {
		if sync.atomic_load(&watch_stop) != 0 {
			return false
		}
		step := chunk
		if remaining < step {
			step = remaining
		}
		time.sleep(step)
		remaining -= step
	}
	return sync.atomic_load(&watch_stop) == 0
}
