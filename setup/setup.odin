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
	{slug = "pi", description = "Pi (skill-only is enough; add MCP manually if wanted)", path = "~/.agents/skills/ctxdb/SKILL.md", format = .skill_only},
}

Run_Options :: struct {
	agent:        string,
	install_skill: bool,
	skill_parent: string,
	force:        bool,
}

run :: proc(opts: Run_Options) -> (int, string) {
	agent := find_agent(opts.agent)
	if agent == nil {
		return 1, cat("unknown setup target: ", opts.agent, " (use `ctxdb setup` to list targets)")
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

install_skill :: proc(parent: string, force: bool) -> string {
	home, herr := os.user_home_dir(context.allocator)
	if herr != nil {
		return "cannot resolve home directory for skill installation"
	}
	base := parent
	if strings.trim_space(base) == "" {
		base, _ = filepath.join({home, DEFAULT_SKILL_PARENT})
	}
	dir, _ := filepath.join({base, SKILL_NAME})
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
	tmp := cat(path, ".tmp")
	if werr := os.write_entire_file_from_string(tmp, SKILL_MARKDOWN); werr != nil {
		_ = os.remove(tmp)
		return cat("cannot write skill: ", os.error_string(werr))
	}
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return cat("cannot install skill: ", os.error_string(rerr))
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
