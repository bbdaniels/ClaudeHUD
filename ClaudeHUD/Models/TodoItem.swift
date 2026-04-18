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

    // Project identity & in-file organization
    let projectName: String?     // Canonical = Obsidian folder name. nil for Reminders.app items.
    let sectionHeading: String?  // `### Heading` within `## Active`. nil when no section.
    let boldTitle: String?       // from **bold**: prefix, for compact display

    enum Source {
        case reminder(listName: String)
        case obsidian(grouping: String)  // Display-only label. Never a folder path.
    }

    /// Top-level grouping key: project name if present, else source grouping.
    var groupKey: String {
        if let name = projectName, !name.isEmpty { return name }
        switch source {
        case .reminder(let list): return list
        case .obsidian(let group): return group
        }
    }

    var sourceBadge: String { groupKey }

    /// Compact display: bold title if available, otherwise full title
    var displayTitle: String {
        boldTitle ?? title
    }
}
