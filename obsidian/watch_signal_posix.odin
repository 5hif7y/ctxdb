#+build linux, darwin, freebsd, openbsd, netbsd
package obsidian

import "core:sync"
import "core:sys/posix"

@(private)
old_int: posix.sigaction_t
@(private)
old_term: posix.sigaction_t
@(private)
signals_installed: bool

@(private)
watch_signal :: proc "c" (sig: posix.Signal) {
	sync.atomic_store(&watch_stop, 1)
}

install_watch_signals :: proc() -> bool {
	act: posix.sigaction_t
	act.sa_handler = watch_signal
	act.sa_flags = {}
	if posix.sigaction(.SIGINT, &act, &old_int) != .OK {
		return false
	}
	if posix.sigaction(.SIGTERM, &act, &old_term) != .OK {
		posix.sigaction(.SIGINT, &old_int, nil)
		return false
	}
	signals_installed = true
	return true
}

restore_watch_signals :: proc() {
	if !signals_installed {
		return
	}
	posix.sigaction(.SIGINT, &old_int, nil)
	posix.sigaction(.SIGTERM, &old_term, nil)
	signals_installed = false
}
