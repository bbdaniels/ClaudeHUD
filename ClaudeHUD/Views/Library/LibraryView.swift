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
                ForEach(LibraryCategory.allCases) { cat in
                    Button {
                        library.selectedCategory = cat
                    } label: {
                        Label(cat.displayName, systemImage: cat.sfSymbol)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: library.selectedCategory.sfSymbol)
                        .font(.system(size: 11 * scale))
                    Text(library.selectedCategory.displayName)
                        .font(.smallMedium(scale))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8 * scale, weight: .semibold))
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

    // Skills: keep the family/subfamily grouped layout, sourced from
    // SkillsService (groupedSkills) so the taxonomy stays in one place.
    // Family headers render as collapsible UPPERCASE captions, matching the
    // History tab's TimeSectionView.
    private var skillsContent: some View {
        let groups = filteredSkillGroups
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    emptyState(for: .skills)
                } else {
                    ForEach(groups) { group in
                        sectionHeader(
                            title: SkillsService.displayLabel(forGroup: group.name),
                            count: group.totalCount,
                            isExpanded: expandedGroups.contains(group.name) || !searchText.isEmpty
                        ) {
                            if expandedGroups.contains(group.name) {
                                expandedGroups.remove(group.name)
                            } else {
                                expandedGroups.insert(group.name)
                            }
                        }
                        if expandedGroups.contains(group.name) || !searchText.isEmpty {
                            ForEach(group.subgroups) { sub in
                                if shouldShowSubLabel(sub: sub, in: group) {
                                    subgroupHeader(name: sub.name == "general" ? "Other" : sub.name.capitalized)
                                }
                                ForEach(sub.items) { skill in
                                    LibraryRow(item: LibraryView.libraryItem(from: skill))
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

    private func shouldShowSubLabel(sub: SkillsService.SubGroup, in group: SkillsService.Group) -> Bool {
        if group.subgroups.count == 1 && sub.name == "general" { return false }
        return true
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

    private var filteredSkillGroups: [SkillsService.Group] {
        let groups = library.skillsService.groupedSkills
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let subs = group.subgroups.compactMap { sub -> SkillsService.SubGroup? in
                let kept = sub.items.filter {
                    $0.displayName.lowercased().contains(needle)
                        || $0.summary.lowercased().contains(needle)
                        || $0.body.lowercased().contains(needle)
                }
                return kept.isEmpty ? nil : SkillsService.SubGroup(name: sub.name, items: kept)
            }
            return subs.isEmpty ? nil : SkillsService.Group(name: group.name, subgroups: subs)
        }
    }

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
        LibraryItem(
            id: skill.id,
            category: .skills,
            displayName: skill.displayName,
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
