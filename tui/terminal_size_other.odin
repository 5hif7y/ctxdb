#+build !linux
package tui

platform_terminal_size :: proc() -> (width, height: int, ok: bool) {
	return 0, 0, false
}
