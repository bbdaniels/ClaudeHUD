import Foundation
import Combine
import AppKit
import os

private let logger = Logger(subsystem: "com.claudehud", category: "VaultManager")

@MainActor
class VaultManager: ObservableObject {
    @Published var currentVault: VaultSettings?
    @Published var savedVaults: [VaultSettings] = []
    @Published var vaultFiles: [NoteFile] = []
    @Published var isVaultSelected = false

    /// Index mapping lowercased note name (without .md) to full path for wikilink resolution
    private(set) var noteIndex: [String: String] = [:]

    init() {
        loadVaultSettings()
    }

    func loadVaultSettings() {
        savedVaults = VaultSettings.loadFromDefaults()

        if let lastId = UserDefaults.standard.string(forKey: "obsidian.lastUsedVaultId"),
           let uuid = UUID(uuidString: lastId),
           let vault = savedVaults.first(where: { $0.id == uuid }) {
            switchToVault(vault)
        } else if let first = savedVaults.first {
            switchToVault(first)
        }
    }

    func switchToVault(_ vault: VaultSettings) {
        // Stop accessing previous vault
        if let current = currentVault {
            URL(fileURLWithPath: current.path).stopAccessingSecurityScopedResource()
        }

        if let bookmark = vault.bookmarkData {
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    logger.warning("Vault bookmark is stale for \(vault.name)")
                    return
                }
                guard url.startAccessingSecurityScopedResource() else {
                    logger.error("Failed to access vault: \(vault.name)")
                    return
                }
            } catch {
                logger.error("Failed to resolve bookmark: \(error.localizedDescription)")
                return
            }
        }

        currentVault = vault
        isVaultSelected = true
        UserDefaults.standard.set(vault.id.uuidString, forKey: "obsidian.lastUsedVaultId")
        loadVaultContents()
    }

    func selectVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                guard url.startAccessingSecurityScopedResource() else { return }

                var settings = VaultSettings(path: url.path, name: url.lastPathComponent)
                settings.bookmarkData = bookmark
                settings.saveToDefaults()

                savedVaults = VaultSettings.loadFromDefaults()
                switchToVault(settings)
            } catch {
                logger.error("Error creating bookmark: \(error.localizedDescription)")
            }
        }
    }

    func removeVault(_ vault: VaultSettings) {
        savedVaults.removeAll { $0.id == vault.id }
        do {
            let data = try JSONEncoder().encode(savedVaults)
            UserDefaults.standard.set(data, forKey: "obsidian.savedVaults")
        } catch {}

        if currentVault?.id == vault.id {
            if let next = savedVaults.first {
                switchToVault(next)
            } else {
                currentVault = nil
                isVaultSelected = false
                vaultFiles = []
                noteIndex = [:]
            }
        }
    }

    func loadVaultContents() {
        guard let vault = currentVault else { return }
        let vaultURL = URL(fileURLWithPath: vault.path)

        if let files = loadDirectory(at: vaultURL, relativePath: "") {
            vaultFiles = files
            rebuildNoteIndex(files)
        }
    }

    /// Resolve a wikilink name to a file path
    func resolveWikilink(_ name: String) -> String? {
        noteIndex[name.lowercased()]
    }

    // MARK: - Private

    private func loadDirectory(at url: URL, relativePath: String) -> [NoteFile]? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }

        return contents.compactMap { itemURL -> NoteFile? in
            let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let name = itemURL.lastPathComponent

            // Skip hidden dirs/files
            if name.hasPrefix(".") { return nil }

            let itemRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

            if isDir {
                let children = loadDirectory(at: itemURL, relativePath: itemRelative)
                return NoteFile(name: name, path: itemURL.path, relativePath: itemRelative,
                                isDirectory: true, children: children)
            } else {
                return NoteFile(name: name, path: itemURL.path, relativePath: itemRelative,
                                isDirectory: false, children: nil)
            }
        }
    }

    private func rebuildNoteIndex(_ files: [NoteFile]) {
        var index: [String: String] = [:]
        func walk(_ items: [NoteFile]) {
            for item in items {
                if item.isDirectory {
                    if let children = item.children { walk(children) }
                } else if item.name.hasSuffix(".md") {
                    let key = String(item.name.dropLast(3)).lowercased()
                    index[key] = item.path
                }
            }
        }
        walk(files)
        noteIndex = index
    }
}
