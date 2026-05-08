import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.claudehud", category: "SkillsService")

@MainActor
final class SkillsService: ObservableObject {
    @Published private(set) var skills: [SkillFile] = []
    @Published private(set) var lastError: String?

    /// Where skills live. `~/.claude/skills/`.
    static var skillsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// Recursively scan ~/.claude/skills for SKILL.md files (max depth 3 — top, sub, sub-sub).
    func reload() {
        let root = Self.skillsRoot
        var found: [SkillFile] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
            self.skills = []
            return
        }
        for case let url as URL in enumerator {
            // Cap depth to avoid runaway scans (skills can include `references/`, `templates/`, etc.).
            let rel = url.path.replacingOccurrences(of: root.path, with: "")
            let depth = rel.split(separator: "/").count
            if depth > 4 { enumerator.skipDescendants(); continue }
            guard url.lastPathComponent == "SKILL.md" else { continue }
            if let skill = Self.load(url: url, root: root) {
                found.append(skill)
            }
        }
        found.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        self.skills = found
        logger.info("Loaded \(found.count) skills")
    }

    static func load(url: URL, root: URL) -> SkillFile? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let (front, body) = SkillFrontmatter.split(raw)
        let folder = url.deletingLastPathComponent()
        let parts = folder.path
            .replacingOccurrences(of: root.path + "/", with: "")
            .split(separator: "/")
            .map(String.init)
        // parts == [] should not happen (SKILL.md must be in a dir).
        let isNested = parts.count >= 2
        let displayName: String
        var group: String
        if isNested {
            displayName = parts.joined(separator: ":")
            group = parts[0]
        } else if let dirName = parts.first {
            displayName = front["name"] ?? dirName
            group = Self.inferGroup(name: displayName)
        } else {
            return nil
        }
        // Prefer explicit `family:` tag from frontmatter when present.
        if let fam = front["family"]?.trimmingCharacters(in: .whitespaces), !fam.isEmpty {
            group = fam
        }
        return SkillFile(
            id: url.path,
            displayName: displayName,
            group: group,
            path: url,
            folder: folder,
            raw: raw,
            frontmatter: front,
            body: body,
            isNested: isNested
        )
    }

    /// Bucket flat (non-nested) skills by name prefix or content type.
    static func inferGroup(name: String) -> String {
        if name.hasPrefix("railway-") { return "railway" }
        if name.hasPrefix("imessage:") { return "imessage" }
        if name.hasPrefix("caveman:") || name.hasPrefix("caveman-") || name == "caveman" { return "caveman" }

        let researchWriting: Set<String> = [
            "analyze", "data-analysis", "discover", "find-data", "interview-me",
            "lit-review", "research-ideation", "strategize", "identify",
            "pre-analysis-plan", "draft-paper", "write", "humanizer",
            "proposal-write", "proposal-revise", "proofread", "review",
            "review-paper", "review-r", "paper-excellence", "devils-advocate",
            "revise", "respond-to-referee", "revision-audit", "redline",
            "consistency-check", "verify-manuscript", "validate-bib",
            "audit-replication", "data-deposit", "submit", "em-submission",
            "split-pdf", "pdf-comments", "tips-curate", "tips-integrate",
            "tips-scout", "econometrics-check", "deploy-quarto", "translate-to-quarto",
            "qa-quarto", "visual-audit", "extract-tikz", "compile-latex",
            "create-talk", "talk", "create-lecture", "slide-excellence",
            "pedagogy-review", "storyteller", "pandoc-docx", "new-project"
        ]
        if researchWriting.contains(name) { return "research" }

        let utility: Set<String> = [
            "commit", "deploy", "ship", "land-and-deploy", "checkpoint",
            "context-status", "journal", "learn", "tools", "loop",
            "schedule", "init", "update-config", "fewer-permission-prompts",
            "keybindings-help", "claude-api"
        ]
        if utility.contains(name) { return "utility" }

        return "other"
    }

    /// Save updated raw content back to disk. `skill.raw` is the source of truth that gets written.
    func save(_ skill: SkillFile, raw: String) throws {
        try raw.write(to: skill.path, atomically: true, encoding: .utf8)
        // Refresh in-memory copy.
        if let idx = skills.firstIndex(where: { $0.id == skill.id }) {
            let (front, body) = SkillFrontmatter.split(raw)
            var updated = skills[idx]
            updated.raw = raw
            updated.frontmatter = front
            updated.body = body
            skills[idx] = updated
        }
        logger.info("Saved skill \(skill.displayName, privacy: .public)")
    }

    /// Reveal skill folder in Finder.
    func revealInFinder(_ skill: SkillFile) {
        NSWorkspace.shared.activateFileViewerSelecting([skill.folder])
    }

    /// Skills grouped + sorted, suitable for sectioned list. Sub-family is the inner key.
    struct SubGroup: Identifiable, Hashable {
        let name: String
        let items: [SkillFile]
        var id: String { name }
    }

    struct Group: Identifiable, Hashable {
        let name: String
        let subgroups: [SubGroup]
        var id: String { name }
        var totalCount: Int { subgroups.reduce(0) { $0 + $1.items.count } }
    }

    var groupedSkills: [Group] {
        let byFamily = Dictionary(grouping: skills, by: { $0.group })
        let preferredFamilies = [
            "research", "writing", "review", "analysis", "submission",
            "engineering", "ops", "design", "safety", "setup", "utility",
            "railway", "gstack", "caveman", "imessage", "other"
        ]
        var ordered: [Group] = []
        var seen = Set<String>()
        for key in preferredFamilies {
            if let items = byFamily[key], !items.isEmpty {
                ordered.append(Self.buildGroup(name: key, items: items))
                seen.insert(key)
            }
        }
        for key in byFamily.keys.sorted() where !seen.contains(key) {
            ordered.append(Self.buildGroup(name: key, items: byFamily[key]!))
        }
        return ordered
    }

    private static func buildGroup(name: String, items: [SkillFile]) -> Group {
        // Bucket by `subfamily:` tag; untagged → "general" sub.
        let bySub = Dictionary(grouping: items) { (s: SkillFile) -> String in
            s.taggedSubfamily?.lowercased() ?? "general"
        }
        let subkeys = bySub.keys.sorted { a, b in
            if a == "general" { return false }
            if b == "general" { return true }
            return a < b
        }
        let subs = subkeys.map { key in
            SubGroup(name: key, items: bySub[key]!.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            })
        }
        return Group(name: name, subgroups: subs)
    }

    static func displayLabel(forGroup group: String) -> String {
        switch group {
        case "research": return "Research"
        case "writing": return "Writing"
        case "review": return "Review & Audit"
        case "analysis": return "Analysis"
        case "submission": return "Submission"
        case "engineering": return "Engineering"
        case "ops": return "Ops & Deploy"
        case "design": return "Design"
        case "safety": return "Safety"
        case "setup": return "Setup & Config"
        case "utility": return "Utility"
        case "railway": return "Railway"
        case "gstack": return "gstack"
        case "caveman": return "Caveman"
        case "imessage": return "iMessage"
        case "other": return "Other"
        default: return group.capitalized
        }
    }

    // MARK: - Tagging

    /// Build the prompt that asks Claude to tag a SKILL.md with family/subfamily/description.
    static func tagPrompt(force: Bool) -> String {
        let mode = force
            ? "Re-tag every SKILL.md (overwrite existing family/subfamily/description)."
            : "Tag only SKILL.md files that are missing `family:` or `subfamily:` in frontmatter, or where `description:` is empty."
        return """
        You are organizing my Claude Code skills library at ~/.claude/skills.

        TASK: \(mode)

        For each SKILL.md you process, add or update three frontmatter keys:
          - family: pick exactly one from the closed set below
          - subfamily: a short 1-2 word lowercase tag (e.g., "draft", "audit", "deploy", "browser")
          - description: a single tight sentence (<=200 chars) describing what the skill does. Only fill if missing.

        FAMILIES (closed set; pick one):
          research      — discovery, lit review, ideation, identification, data search
          writing       — drafting, polishing, paper sections, proposals
          review        — critique, audit, proofread, peer review, consistency check
          analysis      — data analysis, econometrics, code review of analyses
          submission    — replication packages, journal submission, redline
          engineering   — commit, ship, deploy, debug, plan, build software
          ops           — infrastructure, monitoring, CI/CD (Railway, deploy targets)
          design        — visual/UI design, mockups, design QA
          safety        — guardrails, careful mode, freeze, sandboxing
          setup         — config, install, init, keybindings
          utility       — small tools and shortcuts (commit, learn, journal, loop)
          other         — domain-specific or doesn't fit above

        RULES:
          - Preserve all other frontmatter and body content exactly.
          - Insert family/subfamily lines after `name:` if absent.
          - Quote values containing colons or special chars.
          - Idempotent: if family/subfamily already exist and look right, leave alone (unless force mode).
          - Skip plugin-bundled subskills under gstack/* if you cannot improve them.

        Start by listing every SKILL.md path under ~/.claude/skills, then process them in batches. Report a final summary table: family counts.
        """
    }
}
