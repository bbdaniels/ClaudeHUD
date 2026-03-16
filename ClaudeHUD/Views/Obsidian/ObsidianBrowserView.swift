import SwiftUI
import AppKit

struct ObsidianBrowserView: View {
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""
    @State private var contentQuery = ""  // debounced version for content search
    @State private var expandedFolders: Set<String> = []
    @State private var sortByDate = false

    var body: some View {
        VStack(spacing: 0) {
            if !vaultManager.isVaultSelected && vaultManager.savedVaults.isEmpty {
                // No vault configured
                Spacer()
                Image(systemName: "archivebox")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No vault selected")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                Button("Select Vault") { vaultManager.selectVault() }
                    .font(.smallFont(scale))
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                Spacer()
            } else {
                // Search bar + actions
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                    TextField("Search notes...", text: $searchText)
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

                    VaultSelectorMenu()
                        .environmentObject(vaultManager)

                    Button(action: { sortByDate.toggle() }) {
                        Image(systemName: sortByDate ? "clock.fill" : "textformat.abc")
                            .font(.system(size: 13 * scale))
                            .foregroundColor(sortByDate ? .accentColor : .secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(sortByDate ? "Sorted by date (click for A-Z)" : "Sorted A-Z (click for date)")

                    Button(action: { createNewNote() }) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13 * scale))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("New note")

                    Button(action: { openDailyNote() }) {
                        Image(systemName: "calendar")
                            .font(.system(size: 13 * scale))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Today's note")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(.textBackgroundColor).opacity(0.3))

                Divider().opacity(0.3)

                // File list
                if filteredFiles.isEmpty {
                    Spacer()
                    Text(searchText.isEmpty ? "Empty vault" : "No matches")
                        .font(.smallFont(scale))
                        .foregroundColor(.secondary)
                    Spacer()
                } else if searchText.isEmpty {
                    // Browse mode: show folder tree
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredFiles.enumerated()), id: \.element.file.id) { idx, entry in
                                if entry.file.isDirectory {
                                    ObsidianFolderView(
                                        folder: entry.file,
                                        expandedFolders: $expandedFolders,
                                        level: 0,
                                        sortByDate: sortByDate
                                    )
                                } else {
                                    ObsidianFileRow(file: entry.file, snippet: entry.snippet)
                                }
                                if idx < filteredFiles.count - 1 {
                                    Divider().opacity(0.3)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                } else {
                    // Search mode: group results by parent folder
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(searchGroups, id: \.folder) { group in
                                SearchFolderGroup(folder: group.folder, files: group.files)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vaultManager.loadVaultContents() }
        .task(id: searchText) {
            if searchText.isEmpty {
                contentQuery = ""
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            contentQuery = searchText
        }
    }

    private func noteSort(_ a: NoteFile, _ b: NoteFile) -> Bool {
        if a.isDirectory && !b.isDirectory { return true }
        if !a.isDirectory && b.isDirectory { return false }
        if sortByDate {
            let aDate = a.latestModification ?? .distantPast
            let bDate = b.latestModification ?? .distantPast
            return aDate > bDate
        }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private var filteredFiles: [(file: NoteFile, snippet: String?)] {
        if searchText.isEmpty {
            return vaultManager.vaultFiles.sorted(by: noteSort).map { ($0, nil) }
        }

        let terms = searchText.lowercased().split(separator: " ")
        let doContentSearch = !contentQuery.isEmpty

        return flattenFiles(vaultManager.vaultFiles)
            .compactMap { file -> (file: NoteFile, snippet: String?)? in
                if file.name.lowercased().containsAllTerms(terms) {
                    let snippet = doContentSearch ? Self.contentSnippet(path: file.path, query: contentQuery) : nil
                    return (file, snippet)
                }
                if doContentSearch, let snippet = Self.contentSnippet(path: file.path, query: contentQuery) {
                    return (file, snippet)
                }
                return nil
            }
            .sorted { noteSort($0.file, $1.file) }
    }

    /// Search results grouped by parent folder.
    private var searchGroups: [(folder: String, files: [(file: NoteFile, snippet: String?)])] {
        let grouped = Dictionary(grouping: filteredFiles) { entry -> String in
            let url = URL(fileURLWithPath: entry.file.path)
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent
        }
        return grouped.map { (folder: $0.key, files: $0.value) }
            .sorted {
                if sortByDate {
                    let aDate = $0.files.compactMap { $0.file.modificationDate }.max() ?? .distantPast
                    let bDate = $1.files.compactMap { $0.file.modificationDate }.max() ?? .distantPast
                    return aDate > bDate
                }
                return $0.folder.localizedCaseInsensitiveCompare($1.folder) == .orderedAscending
            }
    }

    /// Extract a ~80-char snippet around the first match of `query` in the file at `path`.
    private static func contentSnippet(path: String, query: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let content = String(data: data, encoding: .utf8) else { return nil }
        guard let range = content.range(of: query, options: .caseInsensitive) else { return nil }

        let center = content.distance(from: content.startIndex, to: range.lowerBound)
        let start = max(0, center - 40)
        let end = min(content.count, center + query.count + 40)
        let startIdx = content.index(content.startIndex, offsetBy: start)
        let endIdx = content.index(content.startIndex, offsetBy: end)
        var snippet = String(content[startIdx..<endIdx])
            .replacingOccurrences(of: "\n", with: " ")
        if start > 0 { snippet = "…" + snippet }
        if end < content.count { snippet += "…" }
        return snippet
    }

    private func flattenFiles(_ files: [NoteFile]) -> [NoteFile] {
        var result: [NoteFile] = []
        for file in files {
            if file.isDirectory, let children = file.children {
                result.append(contentsOf: flattenFiles(children))
            } else if !file.isDirectory {
                result.append(file)
            }
        }
        return result
    }

    private func openDailyNote() {
        if let url = URL(string: "obsidian://daily") {
            NSWorkspace.shared.open(url)
        }
    }

    private func createNewNote() {
        if let vault = vaultManager.currentVault,
           let encoded = vault.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "obsidian://new?vault=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Search Folder Group (collapsible)

struct SearchFolderGroup: View {
    let folder: String
    let files: [(file: NoteFile, snippet: String?)]
    @State private var expanded = true
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Image(systemName: expanded ? "folder.fill" : "folder")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                    Text("\(files.count)")
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                    Text(folder)
                        .font(.captionFont(scale).weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer()
                    if let date = files.compactMap({ $0.file.modificationDate }).max() {
                        Text(date.relativeString)
                            .font(.custom("Fira Code", size: 10 * scale))
                            .foregroundColor(.secondary.opacity(0.4))
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(files, id: \.file.id) { entry in
                    ObsidianFileRow(file: entry.file, snippet: entry.snippet)
                        .padding(.leading, 16)
                    Divider().opacity(0.3)
                }
            }
        }
    }
}

// MARK: - Vault Selector Menu

struct VaultSelectorMenu: View {
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale

    var body: some View {
        Menu {
            ForEach(vaultManager.savedVaults) { vault in
                Button(action: { vaultManager.switchToVault(vault) }) {
                    HStack {
                        Text(vault.name)
                        if vault.id == vaultManager.currentVault?.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button(action: { vaultManager.selectVault() }) {
                Label("Add Vault", systemImage: "plus")
            }

            if !vaultManager.savedVaults.isEmpty {
                Divider()
                ForEach(vaultManager.savedVaults) { vault in
                    Button(action: { vaultManager.removeVault(vault) }) {
                        Label("Remove \(vault.name)", systemImage: "minus")
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13 * scale))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Folder View (collapsible)

struct ObsidianFolderView: View {
    let folder: NoteFile
    @Binding var expandedFolders: Set<String>
    let level: Int
    let sortByDate: Bool
    @State private var isHovered = false
    @Environment(\.fontScale) private var scale

    private var isExpanded: Bool { expandedFolders.contains(folder.path) }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { toggleExpanded() }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 12)
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 12 * scale))
                        .foregroundColor(.secondary)
                    Text("\(folder.children?.count ?? 0)")
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                    Text(folder.name)
                        .font(.smallMedium(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let date = folder.latestModification {
                        Text(date.relativeString)
                            .font(.custom("Fira Code", size: 10 * scale))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .padding(.leading, CGFloat(level) * 16)
                .background(isHovered ? Color.secondary.opacity(0.08) : Color.clear)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded, let children = folder.children {
                ForEach(children.sorted { a, b in
                    if a.isDirectory && !b.isDirectory { return true }
                    if !a.isDirectory && b.isDirectory { return false }
                    if sortByDate {
                        return (a.latestModification ?? .distantPast) > (b.latestModification ?? .distantPast)
                    }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }) { child in
                    if child.isDirectory {
                        ObsidianFolderView(folder: child, expandedFolders: $expandedFolders, level: level + 1, sortByDate: sortByDate)
                    } else {
                        ObsidianFileRow(file: child)
                            .padding(.leading, CGFloat(level + 1) * 16)
                    }
                }
            }
        }
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedFolders.remove(folder.path)
        } else {
            expandedFolders.insert(folder.path)
        }
    }
}

// MARK: - File Row

struct ObsidianFileRow: View {
    let file: NoteFile
    var snippet: String? = nil
    @State private var isHovered = false
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11 * scale))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(file.name.replacingOccurrences(of: ".md", with: ""))
                        .font(.smallFont(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    if let date = file.modificationDate {
                        Text(date.relativeString)
                            .font(.custom("Fira Code", size: 10 * scale))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                if let snippet {
                    Text(snippet)
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.accentColor.opacity(0.8))
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isHovered ? Color.secondary.opacity(0.08) : Color.clear)
        .cornerRadius(5)
        .contentShape(Rectangle())
        .onTapGesture {
            FloatingNoteWindowManager.shared.openWindow(for: file)
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Open in Obsidian") { openInObsidian() }
        }
    }

    private func openInObsidian() {
        let encoded = file.relativePath.encodedForObsidianURL()
        if let vault = VaultSettings.loadFromDefaults().first,
           let vaultName = vault.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "obsidian://open?vault=\(vaultName)&file=\(encoded)") {
            NSWorkspace.shared.open(url)
        }
    }
}
