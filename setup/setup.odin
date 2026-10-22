// Print-only agent setup and portable skill installation.
//
// ctxdb deliberately does not rewrite agent configuration files. The portable
// layer is the Agent Skills `SKILL.md`; each host still owns its MCP config.
package setup

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

SKILL_MARKDOWN :: string(#load("../skills/ctxdb/SKILL.md"))
SKILL_NAME :: "ctxdb"
DEFAULT_SKILL_PARENT :: ".agents/skills"

Agent :: struct {
	slug:        string,
	description: string,
	path:        string,
	format:      Format,
}

Format :: enum {
	generic_json,
	claude_cli,
	opencode_json,
	codex_toml,
	vscode_json,
	skill_only,
}

AGENTS := []Agent{
	{slug = "generic", description = "Any MCP-compatible client (mcpServers JSON)", path = "client MCP config", format = .generic_json},
	{slug = "claude-code", description = "Claude Code (user-scope MCP registration)", path = "~/.claude.json or claude CLI", format = .claude_cli},
	{slug = "opencode", description = "OpenCode (mcp local entry)", path = "~/.config/opencode/opencode.json(c)", format = .opencode_json},
	{slug = "codex", description = "Codex (mcp_servers TOML)", path = "~/.codex/config.toml", format = .codex_toml},
	{slug = "gemini-cli", description = "Gemini CLI (mcpServers JSON)", path = "~/.gemini/settings.json", format = .generic_json},
	{slug = "cursor", description = "Cursor (mcpServers JSON)", path = "~/.cursor/mcp.json", format = .generic_json},
	{slug = "windsurf", description = "Windsurf (mcpServers JSON)", path = "~/.codeium/windsurf/mcp_config.json", format = .generic_json},
	{slug = "qwen", description = "Qwen Code (mcpServers JSON)", path = "~/.qwen/settings.json", format = .generic_json},
	{slug = "kiro", description = "Kiro (mcpServers JSON)", path = "~/.kiro/settings/mcp.json", format = .generic_json},
	{slug = "kilocode", description = "Kilo Code (OpenCode-style mcp JSON)", path = "~/.config/kilo/opencode.json", format = .opencode_json},
	{slug = "kimi", description = "Kimi Code (mcpServers JSON)", path = "~/.kimi-code/mcp.json", format = .generic_json},
	{slug = "vscode-copilot", description = "VS Code / Copilot (servers JSON)", path = "<VS Code User>/mcp.json", format = .vscode_json},
	{slug = "antigravity-cli", description = "Antigravity (mcpServers JSON)", path = "~/.gemini/config/mcp_config.json", format = .generic_json},
	{slug = "pi", description = "Pi (writes agent skill + user mcp.json)", path = "<agent-dir>/mcp.json + <agent-dir>/skills/ctxdb/SKILL.md", format = .skill_only},
}

Run_Options :: struct {
	agent:        string,
	install_skill: bool,
	skill_parent: string,
	force:        bool,
	print_only:   bool,
}

run :: proc(opts: Run_Options) -> (int, string) {
	agent := find_agent(opts.agent)
	if agent == nil {
		return 1, cat("unknown setup target: ", opts.agent, " (use `ctxdb setup` to list targets)")
	}
	if agent.slug == "pi" {
		return run_pi(opts)
	}
	if opts.install_skill {
		if err := install_skill(opts.skill_parent, opts.force); err != "" {
			return 1, err
		}
	}
	print_snippet(agent^)
	if !opts.install_skill {
		fmt.println("")
		fmt.println("Skill (portable Agent Skills file):")
		fmt.println("  ctxdb setup --install-skill")
		fmt.println("  # or: ctxdb setup --install-skill --skill-dir <parent-skills-dir>")
	}
	return 0, ""
}

list :: proc() {
	fmt.println("ctxdb setup targets (print-only):")
	for agent in AGENTS {
		fmt.printf("  %-18s %s\n", agent.slug, agent.description)
	}
	fmt.println("")
	fmt.println("This command never rewrites agent configuration. It prints the MCP")
	fmt.println("snippet and can install the portable skill with --install-skill.")
	fmt.println("")
	fmt.println("Examples:")
	fmt.println("  ctxdb setup generic")
	fmt.println("  ctxdb setup claude-code")
	fmt.println("  ctxdb setup --install-skill")
	fmt.println("  ctxdb setup opencode --install-skill --skill-dir ~/.config/opencode/skills")
}

find_agent :: proc(slug: string) -> ^Agent {
	for i in 0 ..< len(AGENTS) {
		if AGENTS[i].slug == slug {
			return &AGENTS[i]
		}
	}
	return nil
}

print_snippet :: proc(agent: Agent) {
	bin := executable_path()
	fmt.printf("ctxdb setup: %s\n", agent.slug)
	fmt.printf("  %s\n", agent.description)
	fmt.printf("  config: %s\n", agent.path)
	fmt.printf("  binary: %s\n", bin)
	fmt.println("")
	switch agent.format {
	case .generic_json:
		fmt.println("Add this under the client's `mcpServers` object:")
		fmt.println("")
		fmt.println(cat("{\n  \"mcpServers\": {\n    \"ctxdb\": {\n      \"command\": ", json_quote(bin), ",\n      \"args\": [\"mcp\"]\n    }\n  }\n}"))
	case .claude_cli:
		fmt.println("Run this once, then restart Claude Code:")
		fmt.println("")
		fmt.printf("claude mcp add --transport stdio --scope user ctxdb -- %s mcp\n", shell_quote(bin))
		fmt.println("")
		fmt.println("If you prefer a config file, use the generic `mcpServers` snippet.")
	case .opencode_json:
		fmt.println("Add this under the client's `mcp` object (JSON or JSONC):")
		fmt.println("")
		fmt.println(cat("{\n  \"mcp\": {\n    \"ctxdb\": {\n      \"type\": \"local\",\n      \"command\": [", json_quote(bin), ", \"mcp\"],\n      \"enabled\": true\n    }\n  }\n}"))
	case .codex_toml:
		fmt.println("Add this block to the active Codex config:")
		fmt.println("")
		fmt.printf("[mcp_servers.ctxdb]\ncommand = %s\nargs = [\"mcp\"]\n", toml_quote(bin))
	case .vscode_json:
		fmt.println("Add this under the VS Code User `servers` object:")
		fmt.println("")
		fmt.println(cat("{\n  \"servers\": {\n    \"ctxdb\": {\n      \"type\": \"stdio\",\n      \"command\": ", json_quote(bin), ",\n      \"args\": [\"mcp\"]\n    }\n  }\n}"))
	case .skill_only:
		fmt.println("Pi reads Agent Skills directly. Install the portable skill:")
		fmt.println("")
		fmt.println("  ctxdb setup --install-skill")
		fmt.println("")
		fmt.println("If you also want MCP tools in Pi, use the generic snippet.")
	}
	fmt.println("")
	fmt.println("Skill name: ctxdb")
	fmt.println("The skill uses logical `mem_*` tool names, so it stays portable across")
	fmt.println("hosts. Use a server name other than `ctxdb` only if you know the tools")
	fmt.println("remain unambiguous.")
}

// ─── Pi ─────────────────────────────────────────────────────────────────────
//
// Pi is the one exception to print-only setup: it reads a plain JSON MCP file
// and user skills from <agent-dir>/skills, so ctxdb can install both without
// shelling out to the Pi CLI or rewriting unrelated host configuration.

run_pi :: proc(opts: Run_Options) -> (int, string) {
	agent_dir, agent_err := pi_agent_dir()
	if agent_err != "" {
		return 1, agent_err
	}
	mcp_path, _ := filepath.join({agent_dir, "mcp.json"})
	skill_parent := opts.skill_parent
	if strings.trim_space(skill_parent) == "" {
		skill_parent, _ = filepath.join({agent_dir, "skills"})
	}
	skill_path, _ := filepath.join({skill_parent, "ctxdb", "SKILL.md"})
	bin := executable_path()

	if opts.print_only {
		print_pi_plan(agent_dir, mcp_path, skill_path, bin)
		return 0, ""
	}
	if skill_err := install_skill_at(skill_parent, opts.force); skill_err != "" {
		return 1, skill_err
	}
	if mcp_err := install_pi_mcp(mcp_path, bin); mcp_err != "" {
		return 1, mcp_err
	}

	fmt.println("ctxdb setup: pi")
	fmt.printf("  agent dir: %s\n", agent_dir)
	fmt.printf("  MCP:       %s (ctxdb, exposure=direct)\n", mcp_path)
	fmt.printf("  skill:     %s\n", skill_path)
	fmt.println("")
	fmt.println("Next steps:")
	fmt.println("  - restart Pi, or run /reload in an active session")
	fmt.println("  - run `pi mcp list` to verify the ctxdb connection")
	fmt.println("  - use /skill:ctxdb to load the memory protocol explicitly")
	return 0, ""
}

print_pi_plan :: proc(agent_dir, mcp_path, skill_path, bin: string) {
	fmt.println("ctxdb setup pi (dry run)")
	fmt.printf("  agent dir: %s\n", agent_dir)
	fmt.printf("  MCP:       %s\n", mcp_path)
	fmt.printf("  skill:     %s\n", skill_path)
	fmt.printf("  command:   %s mcp\n", bin)
	fmt.println("")
	fmt.println("MCP entry to be written:")
	fmt.println(cat("{\n  \"mcpServers\": {\n    \"ctxdb\": {\n      \"command\": ", json_quote(bin), ",\n      \"args\": [\"mcp\"],\n      \"description\": \"Persistent project memory: save/search observations, sessions, prompts, conflicts, and context.\",\n      \"exposure\": \"direct\"\n    }\n  }\n}"))
	fmt.println("")
	fmt.println("Run without --print to write these files.")
}

pi_agent_dir :: proc() -> (string, string) {
	if env := os.get_env("PI_CODING_AGENT_DIR", context.allocator); strings.trim_space(env) != "" {
		if !filepath.is_abs(env) {
			return "", "PI_CODING_AGENT_DIR must be absolute"
		}
		return env, ""
	}
	home, err := os.user_home_dir(context.allocator)
	if err != nil {
		return "", "cannot resolve home directory for Pi setup"
	}
	dir, _ := filepath.join({home, ".pi", "agent"})
	return dir, ""
}

Pi_MCP_Entry :: struct {
	command:     string   `json:"command"`,
	args:        []string `json:"args"`,
	description: string   `json:"description"`,
	exposure:    string   `json:"exposure"`,
}

install_pi_mcp :: proc(path, bin: string) -> string {
	cfg := make(map[string]json.Value)
	if data, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
		defer delete(data)
		if strings.trim_space(string(data)) != "" {
			if jerr := json.unmarshal(data, &cfg); jerr != nil {
				return cat("cannot parse Pi MCP config: ", path)
			}
		}
	}
	if cfg == nil {
		cfg = make(map[string]json.Value)
	}

	servers := make(json.Object)
	if raw, ok := cfg["mcpServers"]; ok {
		existing, is_object := raw.(json.Object)
		if !is_object {
			return "Pi mcpServers must be a JSON object"
		}
		servers = existing
	}
	entry_data, merr := json.marshal(Pi_MCP_Entry{
		command = bin,
		args = []string{"mcp"},
		description = "Persistent project memory: save/search observations, sessions, prompts, conflicts, and context.",
		exposure = "direct",
	})
	if merr != nil {
		return "cannot encode Pi MCP entry"
	}
	defer delete(entry_data)
	entry_value: json.Value
	if uerr := json.unmarshal(entry_data, &entry_value); uerr != nil {
		return "cannot encode Pi MCP entry"
	}
	servers["ctxdb"] = entry_value
	cfg["mcpServers"] = servers

	data, err := json.marshal(cfg, json.Marshal_Options{pretty = true, use_spaces = true, spaces = 2})
	if err != nil {
		return "cannot encode Pi MCP config"
	}
	defer delete(data)
	dir := filepath.dir(path)
	if _, stat_err := os.stat(dir, context.allocator); stat_err != nil {
		if mkdir_err := os.make_directory_all(dir); mkdir_err != nil {
			return cat("cannot create Pi config directory: ", os.error_string(mkdir_err))
		}
	}
	return write_atomic(path, string(data))
}

write_atomic :: proc(path, content: string) -> string {
	tmp := cat(path, ".tmp")
	if werr := os.write_entire_file_from_string(tmp, content); werr != nil {
		_ = os.remove(tmp)
		return os.error_string(werr)
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return os.error_string(rerr)
	}
	return ""
}

install_skill :: proc(parent: string, force: bool) -> string {
	base := parent
	if strings.trim_space(base) == "" {
		home, herr := os.user_home_dir(context.allocator)
		if herr != nil {
			return "cannot resolve home directory for skill installation"
		}
		base, _ = filepath.join({home, DEFAULT_SKILL_PARENT})
	}
	return install_skill_at(base, force)
}

install_skill_at :: proc(parent: string, force: bool) -> string {
	dir, _ := filepath.join({parent, SKILL_NAME})
	path, _ := filepath.join({dir, "SKILL.md"})
	if existing, err := os.read_entire_file_from_path(path, context.allocator); err == nil {
		defer delete(existing)
		if string(existing) == SKILL_MARKDOWN {
			fmt.printf("Skill already installed: %s\n", path)
			return ""
		}
		if !force {
			return cat("skill already exists with different content: ", path, " (use --force to replace)")
		}
	}
	if _, stat_err := os.stat(dir, context.allocator); stat_err != nil {
		if err := os.make_directory_all(dir); err != nil {
			return cat("cannot create skill directory: ", os.error_string(err))
		}
	}
	if err := write_atomic(path, SKILL_MARKDOWN); err != "" {
		return cat("cannot install skill: ", err)
	}
	fmt.printf("Skill installed: %s\n", path)
	return ""
}

executable_path :: proc() -> string {
	path, err := os.get_executable_path(context.allocator)
	if err != nil || strings.trim_space(path) == "" {
		return "ctxdb"
	}
	return path
}

json_quote :: proc(value: string) -> string {
	data, err := json.marshal(value)
	if err != nil {
		return `"ctxdb"`
	}
	return string(data)
}

toml_quote :: proc(value: string) -> string {
	escaped, _ := strings.replace_all(value, `\`, `\\`)
	escaped, _ = strings.replace_all(escaped, `"`, `\"`)
	return cat(`"`, escaped, `"`)
}

shell_quote :: proc(value: string) -> string {
	safe := true
	for c in value {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '/' || c == '.' || c == '_' || c == '-') {
			safe = false
			break
		}
	}
	if safe {
		return value
	}
	escaped, _ := strings.replace_all(value, `'`, `'\''`)
	return cat(`'`, escaped, `'`)
}

cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}
