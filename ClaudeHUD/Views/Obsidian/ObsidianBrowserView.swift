import SwiftUI
import AppKit

struct ObsidianBrowserView: View {
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""
    @State private var expandedFolders: Set<String> = []

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
                // Vault selector + actions
                HStack(spacing: 6) {
                    VaultSelectorMenu()
                        .environmentObject(vaultManager)

                    Spacer()

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

                // Search bar
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
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredFiles) { file in
                                if file.isDirectory {
                                    ObsidianFolderView(
                                        folder: file,
                                        expandedFolders: $expandedFolders,
                                        level: 0
                                    )
                                } else {
                                    ObsidianFileRow(file: file)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { vaultManager.loadVaultContents() }
    }

    private var filteredFiles: [NoteFile] {
        if searchText.isEmpty {
            return vaultManager.vaultFiles.sorted { a, b in
                if a.isDirectory && !b.isDirectory { return true }
                if !a.isDirectory && b.isDirectory { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }

        let terms = searchText.lowercased().split(separator: " ")
        return flattenFiles(vaultManager.vaultFiles)
            .filter { $0.name.lowercased().containsAllTerms(terms) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 11 * scale))
                Text(vaultManager.currentVault?.name ?? "Select Vault")
                    .font(.smallFont(scale))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8 * scale))
                    .foregroundColor(.secondary)
            }
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
                    Text(folder.name)
                        .font(.smallFont(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(folder.children?.count ?? 0)")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.5))
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
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }) { child in
                    if child.isDirectory {
                        ObsidianFolderView(folder: child, expandedFolders: $expandedFolders, level: level + 1)
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
    @State private var isHovered = false
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.system(size: 11 * scale))
                .foregroundColor(.secondary)
            Text(file.name.replacingOccurrences(of: ".md", with: ""))
                .font(.smallFont(scale))
                .foregroundColor(.primary)
                .lineLimit(1)
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
