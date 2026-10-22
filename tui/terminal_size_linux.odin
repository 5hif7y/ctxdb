#+build linux
package tui

import "core:os"
import "core:sys/linux"

Winsize :: struct {
	ws_row:    u16,
	ws_col:    u16,
	ws_xpixel: u16,
	ws_ypixel: u16,
}

platform_terminal_size :: proc() -> (width, height: int, ok: bool) {
	ws: Winsize
	ret := linux.ioctl(linux.Fd(os.fd(os.stdout)), u32(linux.TIOCGWINSZ), uintptr(&ws))
	if ret != ~uintptr(0) && ws.ws_col > 0 && ws.ws_row > 0 {
		return int(ws.ws_col), int(ws.ws_row), true
	}
	return 0, 0, false
}
