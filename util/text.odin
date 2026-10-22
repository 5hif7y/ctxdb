// Text and identity helpers shared by the store, CLI, and MCP surfaces.
package util

import "core:crypto"
import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:strings"
import "core:unicode/utf8"

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

// NormalizeProject applies Engram's canonical project-name normalization:
// trim, Unicode lowercase, collapse consecutive '-' and '_'.
//
// NFC normalization is intentionally not implemented in phase 1 (Odin's
// standard library does not ship Unicode normalization tables). The function
// still handles the common ASCII cases and preserves non-ASCII code points.
NormalizeProject :: proc(project: string) -> (normalized: string, warning: string) {
	if project == "" {
		return "", ""
	}
	n := strings.to_lower(strings.trim_space(project))
	for strings.contains(n, "--") {
		n, _ = strings.replace_all(n, "--", "-")
	}
	for strings.contains(n, "__") {
		n, _ = strings.replace_all(n, "__", "_")
	}
	if n == project {
		return n, ""
	}
	return n, cat("project name normalized: ", project, " -> ", n)
}

NormalizeScope :: proc(scope: string) -> string {
	v := strings.to_lower(strings.trim_space(scope))
	switch v {
	case "personal", "global":
		return v
	case:
		return "project"
	}
}

NormalizeTopicKey :: proc(topic: string) -> string {
	v := strings.to_lower(strings.trim_space(topic))
	if v == "" {
		return ""
	}
	v = strings.join(strings.fields(v), "-")
	if len(v) > 120 {
		v = v[:120]
	}
	return v
}

private_open :: "<private>"
private_close :: "</private>"

// StripPrivateTags removes <private>...</private> sections (case-insensitive,
// multiline) replacing each complete section with [REDACTED]. An unterminated
// opening tag is left untouched, matching the Go implementation's regex.
StripPrivateTags :: proc(s: string) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	rest := s
	for len(rest) > 0 {
		open := index_ci(rest, private_open)
		if open < 0 {
			strings.write_string(&b, rest)
			break
		}
		strings.write_string(&b, rest[:open])
		after_open := rest[open + len(private_open):]
		close := index_ci(after_open, private_close)
		if close < 0 {
			// Unterminated tag: keep the original text from the tag onward.
			strings.write_string(&b, rest[open:])
			break
		}
		strings.write_string(&b, "[REDACTED]")
		rest = after_open[close + len(private_close):]
	}
	return strings.clone(strings.trim_space(strings.to_string(b)))
}

// index_ci returns the byte index of needle in haystack using ASCII
// case-folding, or -1 when absent.
index_ci :: proc(haystack, needle: string) -> int {
	if len(needle) == 0 {
		return 0
	}
	if len(haystack) < len(needle) {
		return -1
	}
	for i in 0 ..= len(haystack) - len(needle) {
		ok := true
		for j in 0 ..< len(needle) {
			a := haystack[i + j]
			b := needle[j]
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if b >= 'A' && b <= 'Z' {
				b += 'a' - 'A'
			}
			if a != b {
				ok = false
				break
			}
		}
		if ok {
			return i
		}
	}
	return -1
}

MAX_OBSERVATION_LENGTH :: 50000
TRUNCATION_MARKER :: "... [truncated]"

// TruncateContent caps content at max bytes without splitting a UTF-8 rune.
TruncateContent :: proc(content: string, max: int = MAX_OBSERVATION_LENGTH) -> (result: string, truncated: bool) {
	if len(content) <= max {
		return content, false
	}
	end := max
	for end > 0 && !utf8.rune_start(content[end]) {
		end -= 1
	}
	return cat(content[:end], TRUNCATION_MARKER), true
}

// TruncateRunes returns at most max runes, appending "..." when shortened.
TruncateRunes :: proc(s: string, max: int) -> string {
	if max <= 0 {
		return ""
	}
	count := 0
	for _, byte_index in s {
		if count == max {
			return cat(s[:byte_index], "...")
		}
		count += 1
	}
	return s
}

// HashNormalized implements the exact-dedupe hash: lowercase, collapse all
// whitespace runs to one space, SHA-256, lowercase hex.
HashNormalized :: proc(content: string) -> string {
	normalized := strings.to_lower(strings.join(strings.fields(content), " "))
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)normalized)
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	encoded, _ := hex.encode(digest[:])
	return string(encoded)
}

// NewSyncID returns prefix-<16 lowercase hex chars>.
NewSyncID :: proc(prefix: string) -> string {
	buf: [8]u8
	crypto.rand_bytes(buf[:])
	encoded, _ := hex.encode(buf[:])
	return cat(prefix, "-", string(encoded))
}

// SplitSearchTerms mirrors Engram's search term tokenization: split on
// whitespace, trim surrounding double quotes, drop empty terms.
SplitSearchTerms :: proc(query: string) -> [dynamic]string {
	fields := strings.fields(query)
	defer delete(fields)
	out := make([dynamic]string, 0, len(fields))
	for f in fields {
		t := strings.trim(f, `"`)
		if t != "" {
			append(&out, t)
		}
	}
	return out
}

// SanitizeFTS quotes each term so FTS5 treats operators as literal text.
SanitizeFTS :: proc(query: string) -> string {
	words := strings.fields(query)
	for i in 0 ..< len(words) {
		w := strings.trim(words[i], `"`)
		w, _ = strings.replace_all(w, `"`, `""`)
		words[i] = cat(`"`, w, `"`)
	}
	return strings.join(words, " ")
}

// HasShortFTSTerm reports whether any term is too short for trigram FTS.
HasShortFTSTerm :: proc(query: string) -> bool {
	terms := SplitSearchTerms(query)
	defer delete(terms)
	for term in terms {
		if utf8.rune_count_in_string(term) < 3 {
			return true
		}
	}
	return false
}

// EscapeLike escapes a term for a LIKE ... ESCAPE '\' pattern.
EscapeLike :: proc(term: string) -> string {
	t, _ := strings.replace_all(term, `\`, `\\`)
	t, _ = strings.replace_all(t, `%`, `\%`)
	out, _ := strings.replace_all(t, `_`, `\_`)
	return out
}

// ObservationFingerprint is the v1 canonical replay fingerprint used by
// observation_save_operations. It matches Engram's Go implementation:
// SHA-256 over length-prefixed fields in a fixed order.
ObservationFingerprint :: proc(
	session_id, typ, title, content, tool_name, project, scope, topic_key: string,
) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	length: [8]u8
	for value in ([]string{session_id, typ, title, content, tool_name, project, scope, topic_key}) {
		endian.unchecked_put_u64be(length[:], u64(len(value)))
		sha2.update(&ctx, length[:])
		sha2.update(&ctx, transmute([]u8)value)
	}
	digest: [32]u8
	sha2.final(&ctx, digest[:])
	encoded, _ := hex.encode(digest[:])
	return cat("v1:", string(encoded))
}
