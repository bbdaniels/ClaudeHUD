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

    // MARK: - Daily Note Generation

    /// Create today's daily note if it doesn't exist, populated with unchecked todos from project notes
    func ensureDailyNote(for date: Date) {
        guard let vault = currentVault else { return }
        guard Calendar.current.isDateInToday(date) else { return }

        let vaultPath = vault.path
        let fm = FileManager.default
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: date)
        let dailyDir = (vaultPath as NSString).appendingPathComponent("Daily Notes")
        let dailyPath = (dailyDir as NSString).appendingPathComponent("\(dateStr).md")

        // Don't overwrite existing
        guard !fm.fileExists(atPath: dailyPath) else { return }

        // Ensure Daily Notes directory exists
        try? fm.createDirectory(atPath: dailyDir, withIntermediateDirectories: true)

        // Scan all top-level vault folders for unchecked todos
        let skipFolders: Set<String> = ["Templates", "Daily Notes", "Attachments", "Assets", "Archive"]
        guard let folders = try? fm.contentsOfDirectory(atPath: vaultPath) else { return }
        var sections: [(project: String, todos: [String])] = []

        for folder in folders.sorted() {
            let folderPath = (vaultPath as NSString).appendingPathComponent(folder)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard !folder.hasPrefix("."), !skipFolders.contains(folder) else { continue }

            // Use the project's task file (Tasks.md preferred, with fallback)
            guard let taskFile = findTaskFile(in: folderPath) else { continue }
            let taskItems = extractActiveTasks(from: taskFile, noteName: folder, projectName: folder)
            let projectTodos = taskItems.map(\.title)

            if !projectTodos.isEmpty {
                sections.append((folder, projectTodos))
            }
        }

        // Build the daily note content
        let displayFmt = DateFormatter()
        displayFmt.dateFormat = "EEEE, MMMM d, yyyy"
        var content = "# \(displayFmt.string(from: date))\n\n"

        if sections.isEmpty {
            content += "- [ ] \n"
        } else {
            content += "## Open Items\n\n"
            for section in sections {
                content += "### \(section.project)\n"
                for todo in section.todos.prefix(8) {
                    content += "- [ ] \(todo)\n"
                }
                content += "\n"
            }
        }

        content += "## Notes\n\n"

        try? content.write(toFile: dailyPath, atomically: true, encoding: .utf8)
        logger.info("Created daily note: \(dateStr) with \(sections.map(\.todos.count).reduce(0, +)) todos from \(sections.count) projects")
    }

    // MARK: - Todo Scanning

    /// Scan Obsidian vault for unchecked todos on the given date
    func scanTodos(for date: Date, includeRecent: Bool = false) -> [TodoItem] {
        guard let vault = currentVault else { return [] }
        let vaultPath = vault.path
        var items: [TodoItem] = []

        // Primary: today's daily note
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let dateStr = fmt.string(from: date)
        let dailyNotePath = (vaultPath as NSString).appendingPathComponent("Daily Notes/\(dateStr).md")
        let noteName = dateStr

        let dailyNoteItems = extractTodos(from: dailyNotePath, noteName: noteName)
        items += dailyNoteItems

        // Scan Tasks.md (or legacy task files) from each project folder
        if includeRecent {
            let fm = FileManager.default
            let skipFolders: Set<String> = ["Templates", "Daily Notes", "Attachments", "Assets", "Archive"]
            if let folders = try? fm.contentsOfDirectory(atPath: vaultPath) {
                // Collect titles already in daily note to avoid duplicates
                let existingTitles = Set(dailyNoteItems.map(\.title))
                for folder in folders {
                    let folderPath = (vaultPath as NSString).appendingPathComponent(folder)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: folderPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    guard !folder.hasPrefix("."), !skipFolders.contains(folder) else { continue }

                    guard let taskFile = findTaskFile(in: folderPath) else { continue }

                    let taskItems = extractActiveTasks(from: taskFile, noteName: folder, projectName: folder)
                    for item in taskItems where !existingTitles.contains(item.title) {
                        items.append(item)
                    }
                }
            }
        }

        // Tertiary (today only): recently modified .md files — but only if no daily note exists
        if includeRecent && dailyNoteItems.isEmpty {
            let fm = FileManager.default
            let cutoff = Date().addingTimeInterval(-86400)
            let excludePrefixes = ["Daily Notes/", "Templates/", ".obsidian/"]

            if let enumerator = fm.enumerator(atPath: vaultPath) {
                var recentFiles: [(path: String, mod: Date)] = []
                while let rel = enumerator.nextObject() as? String {
                    guard rel.hasSuffix(".md"),
                          !rel.hasPrefix("."),
                          !excludePrefixes.contains(where: { rel.hasPrefix($0) }) else { continue }
                    let full = (vaultPath as NSString).appendingPathComponent(rel)
                    if let attrs = try? fm.attributesOfItem(atPath: full),
                       let mod = attrs[.modificationDate] as? Date,
                       mod > cutoff {
                        recentFiles.append((full, mod))
                    }
                }
                recentFiles.sort { $0.mod > $1.mod }
                for file in recentFiles.prefix(3) {
                    let name = URL(fileURLWithPath: file.path).deletingPathExtension().lastPathComponent
                    let fileItems = extractTodos(from: file.path, noteName: name)
                    items += Array(fileItems.prefix(5))
                }
            }
        }

        return items
    }

    /// Toggle an Obsidian todo checkbox from unchecked to checked
    func toggleObsidianTodo(_ item: TodoItem) {
        guard let filePath = item.obsidianFilePath,
              let lineNumber = item.obsidianLineNumber else { return }

        // 1. Toggle in the daily note (or whichever file the item came from)
        let url = URL(fileURLWithPath: filePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        var lines = content.components(separatedBy: "\n")
        guard lineNumber < lines.count else { return }

        lines[lineNumber] = lines[lineNumber].replacingOccurrences(of: "[ ] ", with: "[x] ")
        let newContent = lines.joined(separator: "\n")
        try? newContent.write(to: url, atomically: true, encoding: .utf8)

        // 2. Cross-update the source Tasks.md (or legacy task file)
        guard let vault = currentVault else { return }
        if case .obsidian(let projectName) = item.source {
            let projectPath = (vault.path as NSString).appendingPathComponent(projectName)

            // Find the project's task file
            guard let taskFile = findTaskFile(in: projectPath),
                  taskFile != filePath else { return } // Don't double-update if item came from the task file itself

            guard let srcContent = try? String(contentsOfFile: taskFile, encoding: .utf8) else { return }
            var srcLines = srcContent.components(separatedBy: "\n")

            // For Tasks.md: move item from ## Active to ## Completed
            if taskFile.hasSuffix("/Tasks.md") {
                let fmt = DateFormatter()
                fmt.dateFormat = "yyyy-MM-dd"
                let today = fmt.string(from: Date())

                // Find and remove the matching line in ## Active
                var removedLine: String?
                for (srcIdx, srcLine) in srcLines.enumerated() {
                    guard srcLine.contains("[ ] ") else { continue }
                    guard ObsidianMarkdownView.isListLine(srcLine) else { continue }
                    let parsed = ObsidianMarkdownView.parseListItem(srcLine, lineNumber: srcIdx)
                    if parsed.checkState == false && parsed.text == item.title {
                        removedLine = srcLine
                        srcLines.remove(at: srcIdx)
                        break
                    }
                }

                // Append to ## Completed section
                if let removed = removedLine {
                    let completedLine = removed
                        .replacingOccurrences(of: "[ ] ", with: "[x] ")
                        + " (\(today))"

                    // Find the ## Completed heading and insert after it
                    if let completedIdx = srcLines.firstIndex(where: {
                        $0.trimmingCharacters(in: .whitespaces).hasPrefix("## Completed")
                    }) {
                        srcLines.insert(completedLine, at: completedIdx + 1)
                    } else {
                        // No ## Completed section — append one
                        srcLines.append("")
                        srcLines.append("## Completed")
                        srcLines.append(completedLine)
                    }

                    // Update the updated: field in frontmatter
                    for (i, line) in srcLines.enumerated() {
                        if line.hasPrefix("updated:") {
                            srcLines[i] = "updated: \(today)"
                            break
                        }
                    }

                    let newSrcContent = srcLines.joined(separator: "\n")
                    try? newSrcContent.write(toFile: taskFile, atomically: true, encoding: .utf8)
                }
            } else {
                // Legacy file: just toggle in place
                for (srcIdx, srcLine) in srcLines.enumerated() {
                    guard srcLine.contains("[ ] ") else { continue }
                    guard ObsidianMarkdownView.isListLine(srcLine) else { continue }
                    let parsed = ObsidianMarkdownView.parseListItem(srcLine, lineNumber: srcIdx)
                    if parsed.checkState == false && parsed.text == item.title {
                        srcLines[srcIdx] = srcLine.replacingOccurrences(of: "[ ] ", with: "[x] ")
                        let newSrcContent = srcLines.joined(separator: "\n")
                        try? newSrcContent.write(toFile: taskFile, atomically: true, encoding: .utf8)
                        return
                    }
                }
            }
        }
    }

    // MARK: - Tasks.md Support

    /// Known task file names in priority order
    private static let taskFileNames = [
        "Tasks.md",
        "Action Items.md",
        "To-Do List.md",
        "Revision To-Do List.md"
    ]

    /// Find the task file in a project folder (Tasks.md preferred, with legacy fallback)
    func findTaskFile(in folderPath: String) -> String? {
        let fm = FileManager.default
        // Check standard names first
        for name in Self.taskFileNames {
            let path = (folderPath as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: path) { return path }
        }
        // Fallback: "Revisions for *.md" pattern
        if let files = try? fm.contentsOfDirectory(atPath: folderPath) {
            for file in files where file.hasPrefix("Revisions for ") && file.hasSuffix(".md") {
                return (folderPath as NSString).appendingPathComponent(file)
            }
        }
        return nil
    }

    /// Parse **bold**: prefix from task text, returning (boldTitle, cleanText)
    private func parseBoldTitle(_ text: String) -> (boldTitle: String?, cleanText: String) {
        // Match **Title**: rest of text
        guard let starRange = text.range(of: "**"),
              let endRange = text.range(of: "**:", range: starRange.upperBound..<text.endIndex) else {
            return (nil, text)
        }
        let title = String(text[starRange.upperBound..<endRange.lowerBound])
        let rest = String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (title, rest.isEmpty ? title : text)
    }

    /// Move any [x] items from ## Active to ## Completed in a Tasks.md file
    func sweepCompletedFromActive(in filePath: String) {
        guard filePath.hasSuffix("/Tasks.md") else { return }
        guard var content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return }
        let lines = content.components(separatedBy: "\n")

        // Find section boundaries
        var activeStart: Int?
        var activeEnd: Int?
        var completedIdx: Int?
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## Active") { activeStart = idx }
            else if activeStart != nil && activeEnd == nil && trimmed.hasPrefix("## ") { activeEnd = idx }
            if trimmed.hasPrefix("## Completed") { completedIdx = idx }
        }
        guard let aStart = activeStart else { return }
        let aEnd = activeEnd ?? lines.count

        // Collect checked items from Active
        var checkedLines: [String] = []
        var keptLines = lines
        // Walk backwards so indices stay valid during removal
        for idx in stride(from: aEnd - 1, through: aStart + 1, by: -1) {
            let trimmed = keptLines[idx].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- [x]") || trimmed.hasPrefix("- [X]") {
                checkedLines.insert(keptLines[idx], at: 0)
                keptLines.remove(at: idx)
            }
        }

        guard !checkedLines.isEmpty else { return }

        // Insert under ## Completed (adjust index since we removed lines above)
        if let cIdx = completedIdx {
            // Recalculate after removals
            let newCompletedIdx = keptLines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("## Completed")
            }) ?? cIdx
            for (offset, line) in checkedLines.enumerated() {
                keptLines.insert(line, at: newCompletedIdx + 1 + offset)
            }
        } else {
            // No ## Completed section — add one
            keptLines.append("")
            keptLines.append("## Completed")
            keptLines.append(contentsOf: checkedLines)
        }

        let newContent = keptLines.joined(separator: "\n")
        try? newContent.write(toFile: filePath, atomically: true, encoding: .utf8)
    }

    /// Extract tasks from the ## Active section of a Tasks.md file
    func extractActiveTasks(from filePath: String, noteName: String, projectName: String?) -> [TodoItem] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n")
        var items: [TodoItem] = []
        var currentHeading = noteName
        var inActiveSection = false
        let isTasksMd = filePath.hasSuffix("/Tasks.md")

        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // For Tasks.md files, only parse the ## Active section
            if isTasksMd {
                if trimmed.hasPrefix("## Active") {
                    inActiveSection = true
                    continue
                }
                if inActiveSection && trimmed.hasPrefix("## ") {
                    break // Hit ## Completed or ## Context — stop
                }
                guard inActiveSection else { continue }
            }

            // Track ### headings as group names
            if trimmed.hasPrefix("### ") {
                currentHeading = String(trimmed.dropFirst(4))
                continue
            }

            guard ObsidianMarkdownView.isListLine(line) else { continue }
            let parsed = ObsidianMarkdownView.parseListItem(line, lineNumber: idx)
            guard parsed.checkState == false else { continue }

            let (boldTitle, _) = parseBoldTitle(parsed.text)

            items.append(TodoItem(
                title: parsed.text,
                source: .obsidian(noteName: currentHeading),
                dueDate: nil,
                isOverdue: false,
                priority: 0,
                reminderIdentifier: nil,
                obsidianFilePath: filePath,
                obsidianLineNumber: idx,
                projectName: projectName,
                boldTitle: boldTitle
            ))
        }
        return items
    }

    /// Extract todos from a file, tracking headings as group names for daily notes
    private func extractTodos(from filePath: String, noteName: String) -> [TodoItem] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n")
        var items: [TodoItem] = []
        var currentHeading = noteName

        for (idx, line) in lines.enumerated() {
            // Track ### headings as project group names
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") {
                currentHeading = String(trimmed.dropFirst(4))
                continue
            }

            guard ObsidianMarkdownView.isListLine(line) else { continue }
            let parsed = ObsidianMarkdownView.parseListItem(line, lineNumber: idx)
            guard parsed.checkState == false else { continue }

            let (boldTitle, _) = parseBoldTitle(parsed.text)

            items.append(TodoItem(
                title: parsed.text,
                source: .obsidian(noteName: currentHeading),
                dueDate: nil,
                isOverdue: false,
                priority: 0,
                reminderIdentifier: nil,
                obsidianFilePath: filePath,
                obsidianLineNumber: idx,
                projectName: nil,
                boldTitle: boldTitle
            ))
        }
        return items
    }

    // MARK: - Private

    private func loadDirectory(at url: URL, relativePath: String) -> [NoteFile]? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            return nil
        }

        return contents.compactMap { itemURL -> NoteFile? in
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDir = resourceValues?.isDirectory ?? false
            let modDate = resourceValues?.contentModificationDate
            let name = itemURL.lastPathComponent

            // Skip hidden dirs/files
            if name.hasPrefix(".") { return nil }

            let itemRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"

            if isDir {
                let children = loadDirectory(at: itemURL, relativePath: itemRelative)
                return NoteFile(name: name, path: itemURL.path, relativePath: itemRelative,
                                isDirectory: true, modificationDate: modDate, children: children)
            } else {
                return NoteFile(name: name, path: itemURL.path, relativePath: itemRelative,
                                isDirectory: false, modificationDate: modDate, children: nil)
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
