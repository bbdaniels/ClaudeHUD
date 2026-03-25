import Foundation

struct TodoItem: Identifiable {
    let id = UUID()
    let title: String
    let source: Source
    let dueDate: Date?
    let isOverdue: Bool
    let priority: Int // 0 = none, 1–4 EKReminder priority

    // Completion identifiers
    let reminderIdentifier: String?
    let obsidianFilePath: String?
    let obsidianLineNumber: Int?

    // Tasks.md extensions
    let projectName: String?  // from frontmatter or folder name
    let boldTitle: String?    // from **bold**: prefix, for compact display

    enum Source {
        case reminder(listName: String)
        case obsidian(noteName: String)
    }

    var sourceBadge: String {
        switch source {
        case .reminder(let list): return list
        case .obsidian(let note): return note
        }
    }

    /// Compact display: bold title if available, otherwise full title
    var displayTitle: String {
        boldTitle ?? title
    }
}
