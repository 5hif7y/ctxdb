// Interactive terminal UI for ctxdb.
//
// This is a focused Odin port of Engram's Bubble Tea screens: dashboard,
// search, recent observations, detail/timeline, sessions and session detail.
// It uses ANSI rendering and termios raw mode directly, with no external TUI
// dependency.
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:unicode/utf8"

import "../store"

CLEAR :: "\x1b[2J\x1b[H"
HIDE_CURSOR :: "\x1b[?25l"
SHOW_CURSOR :: "\x1b[?25h"
RESET :: "\x1b[0m"
BOLD :: "\x1b[1m"
DIM :: "\x1b[2m"
PINK :: "\x1b[38;5;212m"
LAVENDER :: "\x1b[38;5;183m"
TEAL :: "\x1b[38;5;80m"
GREEN :: "\x1b[38;5;114m"
YELLOW :: "\x1b[38;5;221m"
RED :: "\x1b[38;5;203m"
GREY :: "\x1b[38;5;245m"

Screen :: enum {
	dashboard,
	search,
	results,
	recent,
	detail,
	timeline,
	sessions,
	session_detail,
}

Key :: enum {
	none,
	up,
	down,
	left,
	right,
	enter,
	escape,
	backspace,
	ctrl_c,
	rune,
}

Key_Event :: struct {
	key: Key,
	ch:  rune,
}

Model :: struct {
	s:             ^store.STORE,
	screen:        Screen,
	prev:          Screen,
	width:         int,
	height:        int,
	cursor:        int,
	scroll:        int,
	query:         [dynamic]u8,
	results:       []store.SearchResult,
	observations:  []store.Observation,
	sessions:      []store.SessionSummary,
	focus:         store.Observation,
	timeline:      store.TimelineResult,
	session_id:    string,
	status:        string,
	project:       string,
	all_projects:  bool,
	should_quit:   bool,
}

Run :: proc(s: ^store.STORE, project_name: string) -> string {
	model := Model{s = s, project = project_name, screen = .dashboard, width = 100, height = 30}
	defer model_cleanup(&model)

	raw, raw_err := enable_raw()
	if raw_err != "" {
		return raw_err
	}
	defer disable_raw(&raw)
	fmt.print(HIDE_CURSOR)
	defer fmt.print(SHOW_CURSOR + RESET)

	for !model.should_quit {
		model.width, model.height = terminal_size()
		render(&model)
		event := read_key()
		update(&model, event)
	}
	return ""
}

terminal_size :: proc() -> (width, height: int) {
	width, height = 100, 30
	if cols := os.get_env_alloc("COLUMNS", context.allocator); strings.trim_space(cols) != "" {
		if n, ok := parse_uint(strings.trim_space(cols)); ok && n > 20 { width = int(n) }
	}
	if lines := os.get_env_alloc("LINES", context.allocator); strings.trim_space(lines) != "" {
		if n, ok := parse_uint(strings.trim_space(lines)); ok && n > 5 { height = int(n) }
	}
	if pw, ph, ok := platform_terminal_size(); ok {
		width = pw
		height = ph
	}
	return
}

parse_uint :: proc(text: string) -> (int, bool) {
	if text == "" { return 0, false }
	n := 0
	for c in text {
		if c < '0' || c > '9' { return 0, false }
		n = n * 10 + int(c - '0')
	}
	return n, true
}

// ─── Terminal raw mode ──────────────────────────────────────────────────────

Raw_State :: struct {
	fd:       posix.FD,
	original: posix.termios,
}

enable_raw :: proc() -> (Raw_State, string) {
	fd := posix.FD(os.fd(os.stdin))
	original: posix.termios
	if posix.tcgetattr(fd, &original) != .OK {
		return {}, "cannot read terminal attributes"
	}
	raw := original
	raw.c_lflag &~= {.ICANON, .ECHO, .ISIG}
	raw.c_iflag &~= {.ICRNL, .IXON}
	raw.c_oflag &~= {.OPOST}
	raw.c_cc[posix.Control_Char.VMIN] = 0
	raw.c_cc[posix.Control_Char.VTIME] = 1
	if posix.tcsetattr(fd, .TCSANOW, &raw) != .OK {
		return {}, "cannot enable raw terminal mode"
	}
	return Raw_State{fd = fd, original = original}, ""
}

disable_raw :: proc(state: ^Raw_State) {
	_ = posix.tcsetattr(state.fd, .TCSANOW, &state.original)
}

read_key :: proc() -> Key_Event {
	buf: [1]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n == 0 {
		return Key_Event{key = .none}
	}
	b := buf[0]
	switch b {
	case 3:
		return Key_Event{key = .ctrl_c}
	case 13, 10:
		return Key_Event{key = .enter}
	case 127, 8:
		return Key_Event{key = .backspace}
	case 27:
		second, ok := read_byte_timeout()
		if !ok { return Key_Event{key = .escape} }
		if second != '[' && second != 'O' { return Key_Event{key = .escape} }
		third, ok2 := read_byte_timeout()
		if !ok2 { return Key_Event{key = .escape} }
		switch third {
		case 'A': return Key_Event{key = .up}
		case 'B': return Key_Event{key = .down}
		case 'C': return Key_Event{key = .right}
		case 'D': return Key_Event{key = .left}
		}
		return Key_Event{key = .escape}
	case:
		if b >= 32 {
			r, _ := utf8.decode_rune(buf[:])
			return Key_Event{key = .rune, ch = r}
		}
	}
	return Key_Event{key = .none}
}

read_byte_timeout :: proc() -> (u8, bool) {
	buf: [1]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n == 0 { return 0, false }
	return buf[0], true
}

// ─── Update ─────────────────────────────────────────────────────────────────

update :: proc(m: ^Model, event: Key_Event) {
	if event.key == .ctrl_c {
		m.should_quit = true
		return
	}
	if event.key == .escape {
		back(m)
		return
	}
	ev := event
	if m.screen != .search && ev.key == .rune {
		switch ev.ch {
		case 'j':
			ev.key = .down
		case 'k':
			ev.key = .up
		case 'q':
			m.should_quit = true
			return
		}
	}
	switch m.screen {
	case .dashboard:
		update_dashboard(m, ev)
	case .search:
		update_search(m, ev)
	case .results:
		update_results(m, ev)
	case .recent:
		update_observations(m, ev, .recent)
	case .detail:
		update_detail(m, ev)
	case .timeline:
		update_timeline(m, ev)
	case .sessions:
		update_sessions(m, ev)
	case .session_detail:
		update_session_detail(m, ev)
	}
}

back :: proc(m: ^Model) {
	switch m.screen {
	case .search, .recent, .sessions, .timeline:
		m.screen = .dashboard
	case .results:
		m.screen = .search
	case .detail:
		m.screen = m.prev
	case .session_detail:
		m.screen = .sessions
	case .dashboard:
		m.should_quit = true
	}
}

update_dashboard :: proc(m: ^Model, event: Key_Event) {
	#partial switch event.key {
	case .down:
		m.cursor = min(m.cursor + 1, 3)
	case .up:
		m.cursor = max(m.cursor - 1, 0)
	case .enter:
		switch m.cursor {
		case 0:
			m.screen = .search
			m.status = ""
		case 1:
			load_recent(m)
		case 2:
			load_sessions(m)
		case 3:
			m.should_quit = true
		}
	}
}

update_search :: proc(m: ^Model, event: Key_Event) {
	#partial switch event.key {
	case .backspace:
		if len(m.query) > 0 { pop(&m.query) }
	case .enter:
		run_search(m)
	case .rune:
		if event.ch < 128 { append(&m.query, u8(event.ch)) }
	}
}

run_search :: proc(m: ^Model) {
	query := string(m.query[:])
	if strings.trim_space(query) == "" { return }
	project_name := m.project
	if m.all_projects { project_name = "" }
	results, err := store.Search(m.s, query, store.SearchOptions{project = project_name, limit = 50, match_mode = "all"})
	if err != "" {
		m.status = err
		return
	}
	delete(m.results)
	m.results = results
	m.cursor = 0
	m.scroll = 0
	m.screen = .results
	m.status = fmt.tprintf("%d results", len(results))
}

Observation_Screen :: enum { recent, session }

update_observations :: proc(m: ^Model, event: Key_Event, screen: Observation_Screen) {
	#partial switch event.key {
	case .down:
		m.cursor = min(m.cursor + 1, max(len(m.observations) - 1, 0))
	case .up:
		m.cursor = max(m.cursor - 1, 0)
	case .enter:
		if m.cursor < len(m.observations) {
			m.focus = m.observations[m.cursor]
			m.prev = m.screen
			m.screen = .detail
			m.scroll = 0
		}
	}
}

update_results :: proc(m: ^Model, event: Key_Event) {
	#partial switch event.key {
	case .down:
		m.cursor = min(m.cursor + 1, max(len(m.results) - 1, 0))
	case .up:
		m.cursor = max(m.cursor - 1, 0)
	case .enter:
		if m.cursor < len(m.results) {
			m.focus = store.AsObservation(m.results[m.cursor])
			m.prev = .results
			m.screen = .detail
			m.scroll = 0
		}
	}
}

update_detail :: proc(m: ^Model, event: Key_Event) {
	#partial switch event.key {
	case .down:
		m.scroll += 1
	case .up:
		m.scroll = max(m.scroll - 1, 0)
	case .rune:
		if event.ch == 't' {
			load_timeline(m)
		}
	}
}

update_timeline :: proc(m: ^Model, event: Key_Event) {
	#partial switch event.key {
	case .down:
		m.scroll += 1
	case .up:
		m.scroll = max(m.scroll - 1, 0)
	}
}

update_sessions :: proc(m: ^Model, event: Key_Event) {
	#partial switch event.key {
	case .down:
		m.cursor = min(m.cursor + 1, max(len(m.sessions) - 1, 0))
	case .up:
		m.cursor = max(m.cursor - 1, 0)
	case .enter:
		if m.cursor < len(m.sessions) {
			m.session_id = m.sessions[m.cursor].id
			observations, err := store.SessionObservations(m.s, m.session_id, 200)
			if err != "" {
				m.status = err
				return
			}
			delete(m.observations)
			m.observations = observations
			m.cursor = 0
			m.screen = .session_detail
		}
	}
}

update_session_detail :: proc(m: ^Model, event: Key_Event) {
	update_observations(m, event, .session)
}

load_recent :: proc(m: ^Model) {
	project_name := m.project
	if m.all_projects { project_name = "" }
	observations, err := store.RecentObservations(m.s, project_name, "", 50)
	if err != "" {
		m.status = err
		return
	}
	delete(m.observations)
	m.observations = observations
	m.cursor = 0
	m.scroll = 0
	m.screen = .recent
}

load_sessions :: proc(m: ^Model) {
	project_name := m.project
	if m.all_projects { project_name = "" }
	sessions, err := store.RecentSessions(m.s, project_name, 50)
	if err != "" {
		m.status = err
		return
	}
	delete(m.sessions)
	m.sessions = sessions
	m.cursor = 0
	m.scroll = 0
	m.screen = .sessions
}

load_timeline :: proc(m: ^Model) {
	result, err := store.Timeline(m.s, m.focus.id, 5, 5)
	if err != "" {
		m.status = err
		return
	}
	m.timeline = result
	m.prev = .detail
	m.screen = .timeline
	m.scroll = 0
}

model_cleanup :: proc(m: ^Model) {
	delete(m.query)
	delete(m.results)
	delete(m.observations)
	delete(m.sessions)
	delete(m.timeline.before)
	delete(m.timeline.after)
}

// ─── Render ─────────────────────────────────────────────────────────────────

render :: proc(m: ^Model) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, CLEAR)
	switch m.screen {
	case .dashboard: render_dashboard(m, &b)
	case .search: render_search(m, &b)
	case .results: render_results(m, &b)
	case .recent: render_observation_list(m, &b, "Recent observations")
	case .detail: render_detail(m, &b)
	case .timeline: render_timeline(m, &b)
	case .sessions: render_sessions(m, &b)
	case .session_detail: render_observation_list(m, &b, cat("Session ", m.session_id))
	}
	if m.status != "" {
		fmt.sbprintf(&b, "\n%s%s%s\n", YELLOW, m.status, RESET)
	}
	strings.write_string(&b, "\n")
	fmt.print(strings.to_string(b))
}

header :: proc(b: ^strings.Builder, title: string) {
	fmt.sbprintf(b, "%s%s ctxdb %s%s\n", BOLD, PINK, RESET, "")
	fmt.sbprintf(b, "%s%s%s\n", LAVENDER, title, RESET)
	fmt.sbprintf(b, "%s────────────────────────────────────────────────────────────%s\n", GREY, RESET)
}

footer :: proc(b: ^strings.Builder, text: string) {
	fmt.sbprintf(b, "\n%s%s%s\n", DIM, text, RESET)
}

render_dashboard :: proc(m: ^Model, b: ^strings.Builder) {
	header(b, "Memory dashboard")
	stats, err := store.GetStats(m.s)
	if err == "" {
		fmt.sbprintf(b, "  %s%d%s sessions   %s%d%s observations   %s%d%s prompts   %s%d%s projects\n\n",
			TEAL, stats.total_sessions, RESET, GREEN, stats.total_observations, RESET,
			YELLOW, stats.total_prompts, RESET, LAVENDER, len(stats.projects), RESET)
	} else {
		fmt.sbprintf(b, "  %s%s%s\n\n", RED, err, RESET)
	}
	menu := []string{"Search memories", "Recent observations", "Sessions", "Quit"}
	for item, i in menu {
		marker := "  "
		if i == m.cursor { marker = "› " }
		color := GREY
		if i == m.cursor { color = PINK }
		fmt.sbprintf(b, "%s%s%s%s%s\n", color, marker, item, RESET, "")
	}
	footer(b, "j/k navigate • enter select • q quit")
}

render_search :: proc(m: ^Model, b: ^strings.Builder) {
	header(b, "Search")
	fmt.sbprintf(b, "  Query: %s%s%s\n", BOLD, string(m.query[:]), RESET)
	footer(b, "type to search • enter run • esc back")
}

render_results :: proc(m: ^Model, b: ^strings.Builder) {
	header(b, "Search results")
	if len(m.results) == 0 {
		fmt.sbprintf(b, "  %sNo results%s\n", GREY, RESET)
	}
	start := window_start(m.cursor, len(m.results), m.height - 9)
	for r, i in m.results[start:] {
		index := start + i
		if index >= len(m.results) { break }
		marker := "  "
		if index == m.cursor { marker = "› " }
		fmt.sbprintf(b, "%s%s#%d [%s] %s%s\n", index == m.cursor ? PINK : RESET, marker, r.id, r.type, truncate(r.title, m.width - 20), RESET)
	}
	footer(b, "j/k navigate • enter open • esc back")
}

render_observation_list :: proc(m: ^Model, b: ^strings.Builder, title: string) {
	header(b, title)
	if len(m.observations) == 0 {
		fmt.sbprintf(b, "  %sNo observations%s\n", GREY, RESET)
	}
	start := window_start(m.cursor, len(m.observations), m.height - 9)
	for obs, i in m.observations[start:] {
		index := start + i
		if index >= len(m.observations) { break }
		marker := "  "
		if index == m.cursor { marker = "› " }
		fmt.sbprintf(b, "%s%s#%d [%s] %s%s\n", index == m.cursor ? PINK : RESET, marker, obs.id, obs.type, truncate(obs.title, m.width - 20), RESET)
	}
	footer(b, "j/k navigate • enter open • esc back")
}

render_detail :: proc(m: ^Model, b: ^strings.Builder) {
	header(b, fmt.tprintf("#%d %s", m.focus.id, m.focus.title))
	fmt.sbprintf(b, "%s%s | project: %s | scope: %s | topic: %s%s\n\n", GREY, m.focus.type, m.focus.project, m.focus.scope, m.focus.topic_key, RESET)
	lines := wrap_text(m.focus.content, max(m.width - 4, 20))
	for line, i in lines {
		if i < m.scroll { continue }
		if i - m.scroll >= m.height - 10 { break }
		fmt.sbprintf(b, "  %s\n", line)
	}
	defer delete(lines)
	footer(b, "j/k scroll • t timeline • esc back")
}

render_timeline :: proc(m: ^Model, b: ^strings.Builder) {
	header(b, "Timeline")
	for entry in m.timeline.before {
		fmt.sbprintf(b, "  %s#%d [%s] %s%s\n", GREY, entry.id, entry.type, truncate(entry.title, m.width - 24), RESET)
	}
	fmt.sbprintf(b, "\n%s>>> #%d [%s] %s%s\n", PINK, m.timeline.focus.id, m.timeline.focus.type, m.timeline.focus.title, RESET)
	for entry in m.timeline.after {
		fmt.sbprintf(b, "  %s#%d [%s] %s%s\n", GREY, entry.id, entry.type, truncate(entry.title, m.width - 24), RESET)
	}
	footer(b, "esc back")
}

render_sessions :: proc(m: ^Model, b: ^strings.Builder) {
	header(b, "Sessions")
	start := window_start(m.cursor, len(m.sessions), m.height - 9)
	for sess, i in m.sessions[start:] {
		index := start + i
		if index >= len(m.sessions) { break }
		marker := "  "
		if index == m.cursor { marker = "› " }
		summary := ""
		if sess.summary != "" { summary = cat(" — ", truncate(sess.summary, 40)) }
		fmt.sbprintf(b, "%s%s%s  %s (%d obs)%s%s\n", index == m.cursor ? PINK : RESET, marker, sess.id, sess.started_at, sess.observation_count, summary, RESET)
	}
	footer(b, "j/k navigate • enter open • esc back")
}

window_start :: proc(cursor, length, visible: int) -> int {
	if visible <= 1 { return 0 }
	if cursor < visible / 2 { return 0 }
	start := cursor - visible / 2
	return min(start, max(length - visible, 0))
}

truncate :: proc(text: string, limit: int) -> string {
	if limit <= 3 { return "" }
	count := 0
	for _, byte_index in text {
		if count >= limit - 3 {
			return cat(text[:byte_index], "...")
		}
		count += 1
	}
	return text
}

wrap_text :: proc(text: string, width: int) -> []string {
	out := make([dynamic]string)
	line := strings.builder_make()
	defer strings.builder_destroy(&line)
	for word in strings.fields(text) {
		if len(line.buf) == 0 {
			strings.write_string(&line, word)
		} else if len(line.buf) + 1 + len(word) <= width {
			strings.write_byte(&line, ' ')
			strings.write_string(&line, word)
		} else {
			append(&out, strings.clone(strings.to_string(line)))
			strings.builder_reset(&line)
			strings.write_string(&line, word)
		}
	}
	if len(line.buf) > 0 {
		append(&out, strings.clone(strings.to_string(line)))
	}
	return exact_slice(out)
}

exact_slice :: proc(arr: [dynamic]$T) -> []T {
	out := make([]T, len(arr))
	copy(out, arr[:])
	delete(arr)
	return out
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}
