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
            }
        }
    }

    func loadVaultContents() {
        guard let vault = currentVault else { return }
        let vaultURL = URL(fileURLWithPath: vault.path)

        if let files = loadDirectory(at: vaultURL, relativePath: "") {
            vaultFiles = files
        }
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

    // MARK: - New project scaffold

    enum CreateProjectError: LocalizedError {
        case emptyName
        case invalidName
        case alreadyExists(String)
        case noVault
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyName:            return "Enter a project name."
            case .invalidName:          return "Name can't contain “/” or “:”, or start with a dot."
            case .alreadyExists(let n): return "A project folder named “\(n)” already exists."
            case .noVault:              return "No Obsidian vault is configured."
            case .writeFailed(let m):   return "Couldn't write the project files: \(m)"
            }
        }
    }

    /// Create a new vault project folder, scaffolded to schema conventions
    /// (see Documents/Obsidian/schema.md §Vault structure / §Canonical project
    /// model): `<vault>/<name>/` with `Tasks.md` (the human-owned source of
    /// truth, `## Active`/`## Completed`, empty `cwds:` for the human to fill),
    /// a minimal `Dashboard.md` carrying the `gen:briefing` block the cloud
    /// cleaner regenerates, and a `Technical Notes.md` stub. Non-destructive:
    /// refuses if the folder already exists (never overwrites). A non-empty
    /// `parent` (a folder name chosen in the new-project sheet) is written as
    /// `parent:` in the `Tasks.md` frontmatter, making the project a child of
    /// that one; this is the app creating a file at the user's request, the
    /// only time it writes that human-owned key. Returns the new
    /// folder URL. Caller owns the follow-up (`VaultProjectService.insertProject`
    /// to surface the row, then a background `refresh()`; the 15-min
    /// `obsidian-sync.sh` pushes the folder to `origin/main`, so it's local
    /// until then).
    static func createProject(vaultPath: URL, name rawName: String,
                              parent rawParent: String? = nil) -> Result<URL, CreateProjectError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        // Folder-name hygiene: no path separators, no leading dot (hidden /
        // off-limits per schema), no colon (legacy HFS separator + confusing).
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix(".") else {
            return .failure(.invalidName)
        }
        let folder = vaultPath.appending(path: name)
        if FileManager.default.fileExists(atPath: folder.path) {
            return .failure(.alreadyExists(name))
        }

        let today: String = {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .iso8601)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()

        let parent = rawParent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parentLine = parent.isEmpty ? "" : "parent: \(parent)\n"

        let tasks = """
        ---
        project: \(name)
        status: active
        updated: \(today)
        \(parentLine)cwds: []
        migrated-from: []
        aka: []
        ---

        # \(name) Tasks

        ## Active

        ## Completed
        """

        let dashboard = """
        ---
        project: \(name)
        status: active
        updated: \(today)
        ---

        # \(name)

        <!-- gen:briefing -->
        _No active work._
        <!-- /gen:briefing -->

        ## Tasks
        [[Tasks]]

        ## Key notes
        - [[Technical Notes]]
        """

        let techNotes = """
        ---
        project: \(name)
        updated: \(today)
        ---

        # \(name) Technical Notes

        Implementation history and non-obvious decisions. Tasks live in
        [[\(name)/Tasks]].
        """

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try tasks.write(to: folder.appending(path: "Tasks.md"),
                            atomically: true, encoding: .utf8)
            try dashboard.write(to: folder.appending(path: "Dashboard.md"),
                                atomically: true, encoding: .utf8)
            try techNotes.write(to: folder.appending(path: "Technical Notes.md"),
                                atomically: true, encoding: .utf8)
            return .success(folder)
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }
    }

    /// Extract the actionable tasks from a project's task file as `TodoItem`s
    /// for the generated daily note's "Open Items".
    ///
    /// `Tasks.md` is routed through the heading-aware parser
    /// (`VaultProjectService.parseActiveTasks`): `### ` headings become
    /// sections, the (unchecked) bullets under them become tasks, nested
    /// detail folds into its parent (counted once), `- **Title**`
    /// non-checkbox tasks are included, and done items are skipped. Each
    /// emitted item keeps its source line.
    ///
    /// Legacy flat task files (`Action Items.md`, `Revisions for *.md`, …)
    /// have no `## Active` section, so they keep the old line-by-line scan.
    func extractActiveTasks(from filePath: String, noteName: String, projectName: String?) -> [TodoItem] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }
        let canonicalProject = projectName ?? noteName

        guard filePath.hasSuffix("/Tasks.md") else {
            return extractLegacyTasks(content: content, filePath: filePath, project: canonicalProject)
        }

        var items: [TodoItem] = []
        func emit(rawTitle: String, display: String, line: Int?, section: String?) {
            items.append(TodoItem(
                title: rawTitle,
                source: .obsidian(grouping: canonicalProject),
                dueDate: nil, isOverdue: false, priority: 0,
                reminderIdentifier: nil,
                obsidianFilePath: filePath,
                obsidianLineNumber: line,
                projectName: canonicalProject,
                sectionHeading: section,
                boldTitle: display
            ))
        }

        for task in VaultProjectService.parseActiveTasks(from: content) {
            if task.isHeading {
                // Heading group → its (not-done) children are the tasks.
                for child in task.subBullets where !child.isDone {
                    emit(rawTitle: child.text,
                         display: VaultProjectService.splitBullet(child.text).title,
                         line: child.line >= 0 ? child.line : nil,
                         section: task.title)
                }
            } else if !task.isDone {
                // Flat top-level task (no heading); nested detail already
                // folded in by the parser, so it counts as a single item.
                emit(rawTitle: task.title, display: task.title,
                     line: task.line, section: nil)
            }
        }
        return items
    }

    /// Old scan for legacy (non-`Tasks.md`) flat task files: every unchecked
    /// list line is a task, `### Heading` lines are section labels.
    private func extractLegacyTasks(content: String, filePath: String, project: String) -> [TodoItem] {
        let lines = content.components(separatedBy: "\n")
        var items: [TodoItem] = []
        var currentSection: String? = nil
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("### ") { currentSection = String(trimmed.dropFirst(4)); continue }
            guard ObsidianMarkdownView.isListLine(line) else { continue }
            let parsed = ObsidianMarkdownView.parseListItem(line, lineNumber: idx)
            guard parsed.checkState == false else { continue }
            let (boldTitle, _) = parseBoldTitle(parsed.text)
            items.append(TodoItem(
                title: parsed.text,
                source: .obsidian(grouping: project),
                dueDate: nil, isOverdue: false, priority: 0,
                reminderIdentifier: nil,
                obsidianFilePath: filePath,
                obsidianLineNumber: idx,
                projectName: project,
                sectionHeading: currentSection,
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


}
