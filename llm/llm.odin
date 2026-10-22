// Semantic conflict runner.
//
// Engram delegates LLM comparison to an external agent CLI. This port follows
// the same boundary: it shells out to `claude` or `opencode`, sends the locked
// prompt on stdin, and parses a structured verdict. No model SDK or scripting
// runtime is embedded in the binary.
package llm

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Verdict :: struct {
	relation:   string  `json:"Relation"`,
	confidence: f64     `json:"Confidence"`,
	reasoning:  string  `json:"Reasoning"`,
	model:      string  `json:"Model"`,
	duration_ms: i64    `json:"-"`
}

PROMPT_TEMPLATE :: `You are a semantic memory auditor. Compare the two observations below and classify their relationship.

=== Observation A ===
ID: %s
Title: %s
Content: %s

=== Observation B ===
ID: %s
Title: %s
Content: %s

Choose EXACTLY ONE relation from this locked vocabulary:
- conflicts_with   — the observations make contradictory claims
- supersedes       — observation A replaces or overrides observation B (or vice versa)
- scoped           — one is a narrower instance of the other
- related          — they share a topic but do not conflict
- compatible       — they are consistent and complementary
- not_conflict     — they are unrelated; no meaningful semantic overlap

Respond with a single-line JSON object and nothing else:
{"Relation":"<verb>","Confidence":<0.0-1.0>,"Reasoning":"<200 chars max>"}`

BuildPrompt :: proc(
	a_id, a_title, a_content: string,
	b_id, b_title, b_content: string,
) -> string {
	return fmt.tprintf(PROMPT_TEMPLATE, a_id, a_title, a_content, b_id, b_title, b_content)
}

valid_relation :: proc(value: string) -> bool {
	switch value {
	case "conflicts_with", "supersedes", "scoped", "related", "compatible", "not_conflict":
		return true
	}
	return false
}

Runner :: enum { claude, opencode }

select_runner :: proc(explicit: string) -> (Runner, string) {
	name := strings.trim_space(explicit)
	if name == "" {
		name = strings.trim_space(os.get_env_alloc("ENGRAM_AGENT_CLI", context.allocator))
	}
	switch name {
	case "claude":
		return .claude, ""
	case "opencode":
		return .opencode, ""
	case "":
		return {}, "ENGRAM_AGENT_CLI is not set; supported values are: claude, opencode"
	case:
		return {}, cat("unrecognized agent CLI: ", name, "; supported values are: claude, opencode")
	}
}

Compare :: proc(prompt: string, explicit_runner := "") -> (Verdict, string) {
	runner, rerr := select_runner(explicit_runner)
	if rerr != "" {
		return {}, rerr
	}
	command: []string
	switch runner {
	case .claude:
		command = []string{"claude", "-p", "--output-format", "json", "--model", "haiku", "--max-turns", "1"}
	case .opencode:
		command = []string{"opencode", "run", "--format", "json", "--pure"}
	}

	stdin_r, stdin_w, pipe_err := os.pipe()
	if pipe_err != nil {
		return {}, "cannot create agent CLI stdin pipe"
	}
	defer os.close(stdin_r)
	if _, werr := os.write(stdin_w, transmute([]u8)prompt); werr != nil {
		os.close(stdin_w)
		return {}, "cannot write prompt to agent CLI"
	}
	os.close(stdin_w)

	desc := os.Process_Desc{command = command, stdin = stdin_r}
	state, stdout, stderr, exec_err := os.process_exec(desc, context.allocator)
	if exec_err != nil {
		return {}, cat("agent CLI failed: ", os.error_string(exec_err))
	}
	if !state.exited || state.exit_code != 0 {
		message := strings.trim_space(string(stderr))
		if message == "" {
			message = fmt.tprintf("agent CLI exited with code %d", state.exit_code)
		}
		return {}, message
	}
	switch runner {
	case .claude:
		return parse_claude(string(stdout))
	case .opencode:
		return parse_opencode(string(stdout))
	}
	return {}, "unsupported agent CLI"
}

parse_claude :: proc(raw: string) -> (Verdict, string) {
	Envelope :: struct {
		type:        string                     `json:"type"`,
		result:      string                     `json:"result"`,
		duration_ms: i64                        `json:"duration_ms"`,
		modelUsage:  map[string]json.Value `json:"modelUsage"`,
	}
	env: Envelope
	if err := json.unmarshal_string(raw, &env); err != nil {
		return {}, "agent CLI returned malformed JSON envelope"
	}
	defer delete(env.modelUsage)
	inner := strip_fence(strings.trim_space(env.result))
	verdict: Verdict
	if err := json.unmarshal_string(inner, &verdict); err != nil {
		return {}, "agent CLI returned malformed verdict JSON"
	}
	verdict.duration_ms = env.duration_ms
	if verdict.model == "" {
		for key, _ in env.modelUsage {
			verdict.model = key
			break
		}
	}
	return validate(verdict)
}

parse_opencode :: proc(raw: string) -> (Verdict, string) {
	last_text := ""
	model := ""
	for line in strings.split_lines(raw) {
		trimmed := strings.trim_space(line)
		if trimmed == "" { continue }
		value: json.Value
		if err := json.unmarshal_string(trimmed, &value); err != nil { continue }
		object, is_object := value.(json.Object)
		if !is_object { continue }
		type_value, has_type := object["type"]
		if !has_type { continue }
		kind, is_string := type_value.(json.String)
		if !is_string { continue }
		if string(kind) == "text" {
			part_value, has_part := object["part"]
			if !has_part { continue }
			part, is_part := part_value.(json.Object)
			if !is_part { continue }
			text_value, has_text := part["text"]
			if has_text {
				text, is_text := text_value.(json.String)
				if is_text && text != "" {
					last_text = string(text)
				}
			}
		}
		if string(kind) == "step_finish" {
			meta_value, has_meta := object["metadata"]
			if has_meta {
				meta, is_meta := meta_value.(json.Object)
				if is_meta {
					if mv, ok := meta["model"]; ok {
						if ms, ok_s := mv.(json.String); ok_s {
							model = string(ms)
						}
					}
				}
			}
		}
	}
	if last_text == "" {
		return {}, "opencode returned no text event"
	}
	verdict: Verdict
	if err := json.unmarshal_string(strings.trim_space(last_text), &verdict); err != nil {
		return {}, "opencode returned malformed verdict JSON"
	}
	if verdict.model == "" {
		verdict.model = model
	}
	return validate(verdict)
}

validate :: proc(verdict: Verdict) -> (Verdict, string) {
	if !valid_relation(verdict.relation) {
		return {}, cat("agent returned a relation outside the locked vocabulary: ", verdict.relation)
	}
	if verdict.confidence < 0 || verdict.confidence > 1 {
		return {}, "agent returned confidence outside [0.0, 1.0]"
	}
	return verdict, ""
}

strip_fence :: proc(value: string) -> string {
	text := strings.trim_space(value)
	if strings.has_prefix(text, "```") {
		if newline := strings.index_byte(text, '\n'); newline >= 0 {
			text = text[newline + 1:]
		}
		text = strings.trim_space(text)
		if strings.has_suffix(text, "```") {
			text = strings.trim_space(text[:len(text) - 3])
		}
	}
	return text
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}
