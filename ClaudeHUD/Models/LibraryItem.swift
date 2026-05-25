import Foundation

/// One of the twelve top-level categories of Claude internals browsable from the Library tab.
/// Each case bundles its display label, SF Symbol, on-disk root location, and a per-category
/// "open with Claude" prompt template.
enum LibraryCategory: String, CaseIterable, Identifiable {
    case skills
    case agents
    case commands
    case hooks
    case rules
    case style
    case plans
    case scripts
    case tools
    case mcp
    case guides
    case settings
    case plugins

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .skills:   return "Skills"
        case .agents:   return "Agents"
        case .commands: return "Commands"
        case .hooks:    return "Hooks"
        case .rules:    return "Rules"
        case .style:    return "Style"
        case .plans:    return "Plans"
        case .scripts:  return "Scripts"
        case .tools:    return "CLI Tools"
        case .mcp:      return "MCP Servers"
        case .guides:   return "Guides"
        case .settings: return "Settings"
        case .plugins:  return "Plugins"
        }
    }

    var sfSymbol: String {
        switch self {
        case .skills:   return "wand.and.stars"
        case .agents:   return "person.crop.square.filled.and.at.rectangle"
        case .commands: return "command.square"
        case .hooks:    return "bolt.fill"
        case .rules:    return "checklist"
        case .style:    return "textformat"
        case .plans:    return "doc.text"
        case .scripts:  return "terminal"
        case .tools:    return "wrench.and.screwdriver"
        case .mcp:      return "antenna.radiowaves.left.and.right"
        case .guides:   return "book"
        case .settings: return "gearshape"
        case .plugins:  return "puzzlepiece.extension"
        }
    }

    /// Where on disk this category lives. May be a directory or a single file.
    var rootURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .skills:   return home.appendingPathComponent(".claude/skills", isDirectory: true)
        case .agents:   return home.appendingPathComponent(".claude/agents", isDirectory: true)
        case .commands: return home.appendingPathComponent(".claude/commands", isDirectory: true)
        case .hooks:    return home.appendingPathComponent(".claude/hooks", isDirectory: true)
        case .rules:    return home.appendingPathComponent(".claude/rules", isDirectory: true)
        case .style:    return home.appendingPathComponent(".claude/style", isDirectory: true)
        case .plans:    return home.appendingPathComponent(".claude/plans", isDirectory: true)
        case .scripts:  return home.appendingPathComponent(".claude/scripts", isDirectory: true)
        case .tools:    return home.appendingPathComponent(".claude/settings.json", isDirectory: false)
        case .mcp:      return home.appendingPathComponent(".claude/.mcp.json", isDirectory: false)
        case .guides:   return home.appendingPathComponent(".claude", isDirectory: true)
        case .settings: return home.appendingPathComponent(".claude/settings.json", isDirectory: false)
        case .plugins:  return home.appendingPathComponent(".claude/plugins/installed_plugins.json", isDirectory: false)
        }
    }

    /// One-line hint shown in the empty state for this category.
    var emptyHint: String {
        switch self {
        case .skills:   return "Add a SKILL.md file under ~/.claude/skills/<name>/ to register a new skill."
        case .agents:   return "Drop a .md file with name+description frontmatter into ~/.claude/agents/."
        case .commands: return "Drop a .md file into ~/.claude/commands/ for a custom slash command."
        case .hooks:    return "Configure hooks in ~/.claude/settings.json or add scripts to ~/.claude/hooks/."
        case .rules:    return "Add a .md file to ~/.claude/rules/ — it will be auto-loaded into every session."
        case .style:    return "Add a .md file to ~/.claude/style/ for on-demand style guidance."
        case .plans:    return "Plans accumulate as Claude finishes plan-mode tasks."
        case .scripts:  return "Drop utility scripts into ~/.claude/scripts/."
        case .tools:    return "Authorize CLI tools in ~/.claude/settings.json via Bash(<binary>:*) entries."
        case .mcp:      return "Configure MCP servers in ~/.claude/.mcp.json."
        case .guides:   return "Add CLAUDE.md (and @-imported guides) at ~/.claude/CLAUDE.md."
        case .settings: return "~/.claude/settings.json holds permissions, env, hooks, and MCP."
        case .plugins:  return "Install plugins via /plugin to populate this list."
        }
    }

    /// Prompt sent to a freshly launched Claude session when the user clicks
    /// "Open with Claude" on an item in this category. Keep terse — they get
    /// piped through shell quoting and a Ghostty temp script.
    func openPrompt(for item: LibraryItem) -> String {
        let name = item.displayName
        switch self {
        case .skills:
            return "Read @SKILL.md and give a brief 3-bullet summary: (1) what this skill does, (2) when it triggers, (3) any rough edges or things worth tightening. Then stop and wait for instructions. Do not edit anything yet."
        case .agents:
            return "Read the agent definition at \(item.path.path) and summarize in 3 lines: role, primary use cases, and tool surface. Then stop."
        case .commands:
            return "Read the slash-command definition at \(item.path.path) and summarize what it does in 3 lines. Then stop."
        case .hooks:
            return "Look at the hook entry for \(name) (\(item.path.path)) and explain what it does, when it fires, and whether it is doing anything risky. Then stop."
        case .rules:
            return "Read the rule at \(item.path.path) and summarize what behavior it enforces. Then stop."
        case .style:
            return "Read the style guide at \(item.path.path) and summarize the voice it enforces in 3 lines. Then stop."
        case .plans:
            return "Read the plan at \(item.path.path) and report whether it was executed, partially executed, or abandoned — and if I should pick it back up. Then stop."
        case .scripts:
            return "Look at the script at \(item.path.path) and explain what it does, when it should be run, and any side effects. Then stop."
        case .mcp:
            return "Look at the MCP server \(name) in ~/.claude/.mcp.json. Report what it exposes, whether the binary is reachable, and any obvious misconfig. Then stop."
        case .guides:
            return "Read the guide at \(item.path.path) and produce a 5-bullet TOC of the topics it covers. Then stop."
        case .settings:
            return "Open \(item.path.path) and report the top-level keys with one-line descriptions of what each one controls. Then stop."
        case .plugins:
            return "Look at the installed plugin \(name) and summarize what it adds (commands, skills, agents, MCP). Then stop."
        case .tools:
            return "Tell me what the `\(name)` CLI does, summarize the subcommands I have allowlisted, and flag any common patterns I'm missing. Then stop."
        }
    }
}

/// A single browsable Library row. Categories produce arrays of these via
/// `LibraryService` loaders. All categories share this shape so the UI can
/// render rows uniformly while still preserving frontmatter + body for the
/// markdown-based ones.
struct LibraryItem: Identifiable, Hashable {
    let id: String                    // stable unique id — usually the file path
    let category: LibraryCategory
    let displayName: String
    let summary: String               // one-line description for the row subtitle
    let path: URL                     // file or directory to open
    let isDirectory: Bool
    let frontmatter: [String: String] // empty for non-markdown categories
    let body: String                  // raw body (or original JSON / script text)
    let group: String?                // optional bucket (e.g. Hooks: "Scripts" vs "Registered")
    let subgroup: String?             // reserved for future use
}
