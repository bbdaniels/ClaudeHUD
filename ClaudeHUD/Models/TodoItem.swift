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
}
