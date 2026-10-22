// Passive learning extraction from agent output.
package store

import "core:strings"

import "../sqlite"
import "../util"

Passive_Capture_Params :: struct {
	session_id: string,
	content:    string,
	project:    string,
	source:     string,
}

Passive_Capture_Result :: struct {
	extracted:  int `json:"extracted"`,
	saved:      int `json:"saved"`,
	duplicates: int `json:"duplicates"`,
}

MIN_LEARNING_LENGTH :: 20
MIN_LEARNING_WORDS :: 4

// ExtractLearnings returns items from the last "Key Learnings" /
// "Aprendizajes" section. It mirrors Engram's numbered-then-bullet fallback.
ExtractLearnings :: proc(text: string) -> []string {
	lines := strings.split_lines(text)
	defer delete(lines)

	last_header := -1
	for line, i in lines {
		trimmed := strings.trim_space(line)
		if is_learning_header(trimmed) {
			last_header = i
		}
	}
	if last_header < 0 {
		return nil
	}

	// Section ends at the next heading of 1-3 hashes.
	end := len(lines)
	for i in last_header + 1 ..< len(lines) {
		trimmed := strings.trim_space(lines[i])
		if strings.has_prefix(trimmed, "# ") || strings.has_prefix(trimmed, "## ") || strings.has_prefix(trimmed, "### ") {
			end = i
			break
		}
	}

	numbered := make([dynamic]string)
	for i in last_header + 1 ..< end {
		line := strings.trim_space(lines[i])
		if item, ok := parse_numbered_item(line); ok {
			cleaned := clean_markdown(item)
			if len(cleaned) >= MIN_LEARNING_LENGTH && len(strings.fields(cleaned)) >= MIN_LEARNING_WORDS {
				append(&numbered, cleaned)
			}
		}
	}
	if len(numbered) > 0 {
		return exact_slice(numbered)
	}
	delete(numbered)

	bullets := make([dynamic]string)
	for i in last_header + 1 ..< end {
		line := strings.trim_space(lines[i])
		if item, ok := parse_bullet_item(line); ok {
			cleaned := clean_markdown(item)
			if len(cleaned) >= MIN_LEARNING_LENGTH && len(strings.fields(cleaned)) >= MIN_LEARNING_WORDS {
				append(&bullets, cleaned)
			}
		}
	}
	if len(bullets) > 0 {
		return exact_slice(bullets)
	}
	delete(bullets)
	return nil
}

is_learning_header :: proc(trimmed: string) -> bool {
	lower := strings.to_lower(trimmed)
	if !strings.has_prefix(lower, "#") {
		return false
	}
	body := strings.trim_left(lower, "#")
	body = strings.trim_space(body)
	body = strings.trim_right(body, ":")
	switch body {
	case "key learnings", "key learning", "learnings", "learning",
		"aprendizajes", "aprendizajes clave":
		return true
	}
	return false
}

parse_numbered_item :: proc(line: string) -> (string, bool) {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	start := i
	for i < len(line) && line[i] >= '0' && line[i] <= '9' {
		i += 1
	}
	if i == start || i >= len(line) {
		return "", false
	}
	if line[i] != '.' && line[i] != ')' {
		return "", false
	}
	i += 1
	if i >= len(line) || line[i] != ' ' {
		return "", false
	}
	return strings.trim_space(line[i + 1:]), true
}

parse_bullet_item :: proc(line: string) -> (string, bool) {
	if len(line) >= 2 && (line[0] == '-' || line[0] == '*') && line[1] == ' ' {
		return strings.trim_space(line[2:]), true
	}
	return "", false
}

clean_markdown :: proc(text: string) -> string {
	t, _ := strings.replace_all(text, "**", "")
	t, _ = strings.replace_all(t, "`", "")
	t, _ = strings.replace_all(t, "*", "")
	return strings.trim_space(strings.join(strings.fields(t), " "))
}

PassiveCapture :: proc(s: ^STORE, p: Passive_Capture_Params) -> (Passive_Capture_Result, string) {
	project_name, _ := util.NormalizeProject(p.project)
	learnings := ExtractLearnings(p.content)
	defer delete(learnings)
	result := Passive_Capture_Result{extracted = len(learnings)}
	for learning in learnings {
		norm_hash := util.HashNormalized(learning)
		exists, err := observation_hash_exists(s, norm_hash, project_name)
		if err != "" {
			return result, err
		}
		if exists {
			result.duplicates += 1
			continue
		}
		title := learning
		if len(title) > 60 {
			title = cat(title[:60], "...")
		}
		_, aerr := AddObservation(s, AddObservationParams{
			session_id = p.session_id,
			type = "learning",
			title = title,
			content = learning,
			project = project_name,
			scope = "project",
		})
		if aerr != "" {
			return result, aerr
		}
		result.saved += 1
	}
	return result, ""
}

observation_hash_exists :: proc(s: ^STORE, norm_hash, project_name: string) -> (bool, string) {
	stmt, err := sqlite.prepare(s.db, `
		SELECT 1 FROM observations
		WHERE normalized_hash = ? AND ifnull(project,'') = ifnull(?, '') AND deleted_at IS NULL
		LIMIT 1`)
	if err != "" {
		return false, err
	}
	defer sqlite.finalize(&stmt)
	_ = sqlite.bind_text(&stmt, 1, norm_hash)
	_ = bind_nullable(&stmt, 2, project_name)
	has, serr := sqlite.step(&stmt)
	if serr != "" {
		return false, serr
	}
	return has, ""
}
