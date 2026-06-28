import SwiftUI
import AppKit

/// Library tab: browse Claude's user-level internals (skills, agents, commands,
/// hooks, rules, style, plans, scripts, MCP servers, global guides, settings,
/// plugins). Category dropdown switches the active list; rows expose
/// Reveal-in-Finder / Open-in-VS-Code / Open-with-Claude actions.
///
/// Skills retain their existing two-tier family/subfamily grouping, sourced
/// from the shared SkillsService (so the family taxonomy stays in one place);
/// other categories render as a flat or single-group LibraryRow list.
struct LibraryView: View {
    @EnvironmentObject var library: LibraryService
    @EnvironmentObject var terminalService: TerminalService
    @Environment(\.fontScale) private var scale
    @State private var searchText: String = ""
    @State private var expandedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            content
        }
        .onAppear {
            if library.items(in: library.selectedCategory).isEmpty {
                library.reload(library.selectedCategory)
            }
        }
        .onChange(of: library.selectedCategory) { _, newCategory in
            if library.items(in: newCategory).isEmpty {
                library.reload(newCategory)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Category dropdown comes first so the user picks the surface,
            // then scopes the search to it.
            Menu {
                ForEach(CategoryGroup.allCases) { group in
                    Section(group.title) {
                        ForEach(group.categories) { cat in
                            Button {
                                library.selectedCategory = cat
                            } label: {
                                Label(cat.displayName, systemImage: cat.sfSymbol)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10 * scale, weight: .semibold))
                        .foregroundColor(.secondary)
                    Image(systemName: library.selectedCategory.sfSymbol)
                        .font(.system(size: 11 * scale))
                    Text(library.selectedCategory.displayName)
                        .font(.smallMedium(scale))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.08))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Select Library category")

            Image(systemName: "magnifyingglass")
                .font(.system(size: 11 * scale))
                .foregroundColor(.secondary)
            TextField("Search \(library.selectedCategory.displayName.lowercased())...", text: $searchText)
                .font(.smallFont(scale))
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }

            Button(action: { library.reload(library.selectedCategory) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reload from disk")

            Menu {
                Button("Open category folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([library.selectedCategory.rootURL])
                }
                if library.selectedCategory == .skills {
                    Divider()
                    Button("Tag missing skills with Claude") { runTagPass(force: false) }
                    Button("Re-tag all skills (force)") { runTagPass(force: true) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Category actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor).opacity(0.3))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let category = library.selectedCategory
        if category == .skills {
            skillsContent
        } else {
            otherCategoryContent(category)
        }
    }

    // Skills: render as a recursive folder tree directly from the filesystem
    // layout under ~/.claude/skills/. Each intermediate directory is a
    // collapsible UPPERCASE section header (matches the History tab pattern);
    // each SKILL.md is a leaf rendered as LibraryRow. No imposed taxonomy —
    // the directory hierarchy IS the organization.
    private var skillsContent: some View {
        let rows = filteredSkillTreeRows
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    emptyState(for: .skills)
                } else {
                    ForEach(rows) { row in
                        switch row.kind {
                        case .folder(let key, let title, let count):
                            sectionHeader(
                                title: title,
                                count: count,
                                isExpanded: expandedGroups.contains(key) || !searchText.isEmpty
                            ) {
                                if expandedGroups.contains(key) {
                                    expandedGroups.remove(key)
                                } else {
                                    expandedGroups.insert(key)
                                }
                            }
                            .padding(.leading, CGFloat(row.depth) * 14)
                        case .skill(let skill):
                            LibraryRow(item: LibraryView.libraryItem(from: skill))
                                .padding(.leading, CGFloat(row.depth) * 14)
                            Divider().opacity(0.15)
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    // MARK: - Skill tree

    /// One flattened render row in the Skills tree. Encodes either a folder
    /// header or a skill leaf, with its visual depth.
    private struct SkillTreeRow: Identifiable {
        enum Kind {
            case folder(key: String, title: String, count: Int)
            case skill(SkillFile)
        }
        let id: String
        let depth: Int
        let kind: Kind
    }

    /// Recursive tree node used to build the Skills folder hierarchy.
    /// Leaves are SkillFile entries that live directly inside this folder;
    /// folders are child SkillTreeNode entries keyed by subfolder name.
    private final class SkillTreeNode {
        var leaves: [SkillFile] = []
        var folders: [String: SkillTreeNode] = [:]
    }

    /// Build a flat ordered list of render rows from the recursive folder
    /// tree, honoring the current expansion state and search text. When
    /// searching, every folder is treated as expanded so matches are visible.
    private var filteredSkillTreeRows: [SkillTreeRow] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let matching: [SkillFile]
        if needle.isEmpty {
            matching = library.skillsService.skills
        } else {
            matching = library.skillsService.skills.filter { s in
                s.displayName.lowercased().contains(needle)
                    || s.summary.lowercased().contains(needle)
                    || s.body.lowercased().contains(needle)
            }
        }
        let root = SkillsService.skillsRoot.path
        let rootNode = SkillTreeNode()
        for skill in matching {
            var rel = skill.folder.path
            if rel.hasPrefix(root + "/") {
                rel = String(rel.dropFirst(root.count + 1))
            }
            let parts = rel.split(separator: "/").map(String.init)
            // parts == ["research", "discover"] for ~/.claude/skills/research/discover/
            // parts == ["learn"]                for ~/.claude/skills/learn/
            // Walk down all but the last component (creating folders), then add
            // the skill as a leaf of the deepest folder reached. The leaf
            // folder's name IS the skill's directory name — we don't need a
            // separate level for it because each skill is rendered as a row,
            // not as a folder containing the SKILL.md file.
            insertSkill(skill, parts: parts.dropLast(), into: rootNode)
        }
        // Folder-roots absorption: if a leaf's directory name matches a sibling
        // folder name at the same level, move the leaf INSIDE that folder. This
        // is what gives us `gstack/SKILL.md` (the parent skill) rendered as the
        // first row inside the GSTACK section, alongside its 33 sub-skills,
        // rather than hanging as a lone row at the root.
        absorbFolderRoots(node: rootNode)
        var rows: [SkillTreeRow] = []
        flatten(node: rootNode, depth: 0, keyPrefix: "", expanded: expandedGroups, alwaysExpand: !needle.isEmpty, into: &rows)
        return rows
    }

    /// Recursively move leaves whose directory name matches a sibling folder
    /// into that folder. Eliminates "ghost" root-level rows for skills like
    /// `gstack/SKILL.md` that belong inside their own section.
    private func absorbFolderRoots(node: SkillTreeNode) {
        var remainingLeaves: [SkillFile] = []
        for skill in node.leaves {
            let dirName = skill.folder.lastPathComponent
            if let folder = node.folders[dirName] {
                folder.leaves.append(skill)
            } else {
                remainingLeaves.append(skill)
            }
        }
        node.leaves = remainingLeaves
        for (_, child) in node.folders {
            absorbFolderRoots(node: child)
        }
    }

    private func insertSkill(_ skill: SkillFile, parts: ArraySlice<String>, into node: SkillTreeNode) {
        if parts.isEmpty {
            node.leaves.append(skill)
            return
        }
        let head = parts.first!
        let child = node.folders[head] ?? SkillTreeNode()
        insertSkill(skill, parts: parts.dropFirst(), into: child)
        node.folders[head] = child
    }

    private func flatten(node: SkillTreeNode, depth: Int, keyPrefix: String, expanded: Set<String>, alwaysExpand: Bool, into rows: inout [SkillTreeRow]) {
        let folderKeys = node.folders.keys.sorted()
        for folderName in folderKeys {
            let key = keyPrefix.isEmpty ? folderName : "\(keyPrefix)/\(folderName)"
            let child = node.folders[folderName]!
            let count = countSkills(in: child)
            rows.append(SkillTreeRow(id: "folder:\(key)", depth: depth, kind: .folder(key: key, title: folderName.uppercased(), count: count)))
            if alwaysExpand || expanded.contains(key) {
                flatten(node: child, depth: depth + 1, keyPrefix: key, expanded: expanded, alwaysExpand: alwaysExpand, into: &rows)
            }
        }
        let sortedLeaves = node.leaves.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        for skill in sortedLeaves {
            rows.append(SkillTreeRow(id: "skill:\(skill.id)", depth: depth, kind: .skill(skill)))
        }
    }

    private func countSkills(in node: SkillTreeNode) -> Int {
        var n = node.leaves.count
        for (_, child) in node.folders {
            n += countSkills(in: child)
        }
        return n
    }

    // Non-Skills categories: render with the same UPPERCASE section pattern.
    // Each `group:` value on the item becomes a collapsible section header.
    // For categories without grouping, fall back to a single un-headered list.
    private func otherCategoryContent(_ category: LibraryCategory) -> some View {
        let items = filteredItems(in: category)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    emptyState(for: category)
                } else {
                    let buckets = Dictionary(grouping: items, by: { $0.group ?? "" })
                    let keys = buckets.keys.sorted { a, b in
                        Self.groupOrder(category: category, a: a, b: b)
                    }
                    // If every item has empty group, render flat (no headers).
                    let hasAnyGroup = keys.contains { !$0.isEmpty }
                    if !hasAnyGroup {
                        ForEach(items) { item in
                            LibraryRow(item: item)
                            Divider().opacity(0.15)
                        }
                    } else {
                        ForEach(keys, id: \.self) { key in
                            let bucketItems = buckets[key] ?? []
                            let label = Self.groupLabel(category: category, key: key)
                            let sectionKey = "\(category.rawValue)/\(key)"
                            let expanded = expandedGroups.contains(sectionKey) || !searchText.isEmpty
                            sectionHeader(
                                title: label,
                                count: bucketItems.count,
                                isExpanded: expanded
                            ) {
                                if expandedGroups.contains(sectionKey) {
                                    expandedGroups.remove(sectionKey)
                                } else {
                                    expandedGroups.insert(sectionKey)
                                }
                            }
                            if expanded {
                                ForEach(bucketItems) { item in
                                    LibraryRow(item: item)
                                    Divider().opacity(0.15)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
        }
    }

    // MARK: - Group ordering and labels

    private static func groupOrder(category: LibraryCategory, a: String, b: String) -> Bool {
        let order: [String]
        switch category {
        case .agents:
            order = ["Workers", "Critics", "Referees", "Reviewers", "Orchestration", "Built-in"]
        case .plans:
            order = ["Today", "This Week", "Older"]
        case .hooks:
            order = ["Scripts",
                     "UserPromptSubmit", "PreToolUse", "PostToolUse",
                     "Notification", "PermissionRequest",
                     "PreCompact", "SessionStart", "SessionEnd"]
        case .tools:
            order = ["Claude / HUD", "Git & GitHub", "Package managers",
                     "Build tools", "Data & research", "Network", "macOS", "Other"]
        case .mcp:
            order = ["Primary", "mcp_settings.json"]
        case .memories:
            order = ["Feedback", "Project", "Reference", "User", "Note"]
        case .plugins:
            order = []
        default:
            order = []
        }
        if let ai = order.firstIndex(of: a), let bi = order.firstIndex(of: b) { return ai < bi }
        if order.contains(a) { return true }
        if order.contains(b) { return false }
        if a.isEmpty { return false }
        if b.isEmpty { return true }
        return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
    }

    private static func groupLabel(category: LibraryCategory, key: String) -> String {
        if key.isEmpty { return "Other" }
        return key
    }

    private func emptyState(for category: LibraryCategory) -> some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: category.sfSymbol)
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Nothing here yet")
                .font(.smallMedium(scale))
                .foregroundColor(.secondary)
            Text(category.emptyHint)
                .font(.captionFont(scale))
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            Text(category.rootURL.path)
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.5))
                .textSelection(.enabled)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Section + subgroup headers (match History tab's TimeSectionView)

    /// Collapsible UPPERCASE section header — the same shape History uses for
    /// Starred / Today / This Week / Older.
    private func sectionHeader(title: String, count: Int, isExpanded: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9 * scale, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.captionFont(scale).weight(.semibold))
                .foregroundColor(.secondary.opacity(0.7))
                .textCase(.uppercase)
            if !isExpanded {
                Text("\(count)")
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeInOut(duration: 0.15)) { action() } }
        .hudTip(isExpanded ? "Collapse section" : "Expand section")
    }

    /// Folder-style subgroup header — tiny icon + small code-font label.
    /// Mirrors the History tab's folder header inside TimeSectionView.
    private func subgroupHeader(name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "folder")
                .font(.system(size: 9 * scale))
                .foregroundColor(.secondary.opacity(0.6))
            Text(name)
                .font(.custom("Fira Code", size: 10 * scale))
                .foregroundColor(.secondary.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 1)
    }

    // MARK: - Filtering

    private func filteredItems(in category: LibraryCategory) -> [LibraryItem] {
        let items = library.items(in: category)
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.summary.lowercased().contains(needle)
                || $0.body.lowercased().contains(needle)
        }
    }

    // MARK: - Skill → LibraryItem bridge for the row

    static func libraryItem(from skill: SkillFile) -> LibraryItem {
        // For tree rendering we want the row label to be just the leaf name
        // ("discover"), not the colon-joined path SkillFile uses for nested
        // skills ("research:discover"). The folder hierarchy is conveyed by
        // the section headers above the row, so the row only needs the leaf.
        let leaf: String
        if let name = skill.frontmatter["name"]?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            leaf = name
        } else {
            leaf = skill.folder.lastPathComponent
        }
        return LibraryItem(
            id: skill.id,
            category: .skills,
            displayName: leaf,
            summary: skill.summary,
            path: skill.folder,
            isDirectory: true,
            frontmatter: skill.frontmatter,
            body: skill.body,
            group: skill.group,
            subgroup: skill.taggedSubfamily
        )
    }

    // MARK: - Tag pass (Skills only)

    private func runTagPass(force: Bool) {
        let folder = SkillsService.skillsRoot.path
        let prompt = SkillsService.tagPrompt(force: force)
        let command = "claude --dangerously-skip-permissions --effort high \"\(Self.shellQuote(prompt))\""
        let ghostty = "/Applications/Ghostty.app"
        let app = FileManager.default.fileExists(atPath: ghostty) ? ghostty : nil
        terminalService.launchWithCommand(command, inDirectory: folder, usingApp: app)
    }

    private static func shellQuote(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
