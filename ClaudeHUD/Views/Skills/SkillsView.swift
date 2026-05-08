import SwiftUI
import AppKit

struct SkillsView: View {
    @EnvironmentObject var service: SkillsService
    @EnvironmentObject var terminalService: TerminalService
    @Environment(\.fontScale) private var scale
    @State private var searchText: String = ""
    @State private var collapsedGroups: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            list
        }
        .onAppear {
            if service.skills.isEmpty { service.reload() }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11 * scale))
                .foregroundColor(.secondary)
            TextField("Search skills...", text: $searchText)
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
            Button(action: { service.reload() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Reload from disk")

            Menu {
                Button("Tag missing skills with Claude") {
                    runTagPass(force: false)
                }
                Button("Re-tag all skills (force)") {
                    runTagPass(force: true)
                }
                Divider()
                Button("Open skills folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([SkillsService.skillsRoot])
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Skill library actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(.textBackgroundColor).opacity(0.3))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filteredGroups) { group in
                    groupHeader(group: group)
                    if !collapsedGroups.contains(group.name) {
                        ForEach(group.subgroups) { sub in
                            if shouldShowSubLabel(sub: sub, in: group) {
                                subgroupHeader(name: sub.name)
                            }
                            ForEach(sub.items) { skill in
                                row(skill)
                                Divider().opacity(0.12)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func groupHeader(group: SkillsService.Group) -> some View {
        Button(action: {
            if collapsedGroups.contains(group.name) {
                collapsedGroups.remove(group.name)
            } else {
                collapsedGroups.insert(group.name)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: collapsedGroups.contains(group.name) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9 * scale))
                    .foregroundColor(.secondary)
                Text(SkillsService.displayLabel(forGroup: group.name))
                    .font(.smallMedium(scale))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(group.totalCount)")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Show subfamily header only if there's actual subdivision (more than one named sub, or the lone one isn't "general").
    private func shouldShowSubLabel(sub: SkillsService.SubGroup, in group: SkillsService.Group) -> Bool {
        if group.subgroups.count == 1 && sub.name == "general" { return false }
        return true
    }

    private func subgroupHeader(name: String) -> some View {
        HStack {
            Text(name == "general" ? "Other" : name.capitalized)
                .font(.captionFont(scale))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.leading, 22)
                .padding(.vertical, 3)
            Spacer()
        }
        .background(Color.secondary.opacity(0.025))
    }

    private func row(_ skill: SkillFile) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: skill.isNested ? "puzzlepiece.extension" : "wand.and.stars")
                .font(.system(size: 11 * scale))
                .foregroundColor(.secondary)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(skill.displayName)
                        .font(.smallMedium(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if skill.taggedFamily == nil {
                        Text("untagged")
                            .font(.system(size: 9 * scale))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.orange.opacity(0.12))
                            )
                    }
                }
                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("(no description)")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.5))
                        .italic()
                }
            }

            Spacer()

            Button(action: { editWithClaude(skill) }) {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 13 * scale))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Open with Claude")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filteredGroups: [SkillsService.Group] {
        let groups = service.groupedSkills
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return groups }
        let needle = searchText.lowercased()
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

    // MARK: - Actions

    private func editWithClaude(_ skill: SkillFile) {
        let folder = skill.folder.path
        let prompt = "Read @SKILL.md and give a brief 3-bullet summary: (1) what this skill does, (2) when it triggers, (3) any rough edges or things worth tightening. Then stop and wait for instructions. Do not edit anything yet."
        let command = "claude --dangerously-skip-permissions --effort high \"\(Self.shellQuote(prompt))\""
        let ghostty = "/Applications/Ghostty.app"
        let app = FileManager.default.fileExists(atPath: ghostty) ? ghostty : nil
        terminalService.launchWithCommand(command, inDirectory: folder, usingApp: app)
    }

    private func runTagPass(force: Bool) {
        let folder = SkillsService.skillsRoot.path
        let prompt = SkillsService.tagPrompt(force: force)
        let command = "claude --dangerously-skip-permissions --effort high \"\(Self.shellQuote(prompt))\""
        let ghostty = "/Applications/Ghostty.app"
        let app = FileManager.default.fileExists(atPath: ghostty) ? ghostty : nil
        terminalService.launchWithCommand(command, inDirectory: folder, usingApp: app)
    }

    /// Escape characters with special meaning inside shell double-quotes:
    /// backslash, dollar sign, backtick, double-quote.
    private static func shellQuote(_ s: String) -> String {
        s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
