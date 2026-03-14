import SwiftUI

struct WhatsNextView: View {
    @EnvironmentObject var remindersService: RemindersService
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale

    let date: Date
    let isToday: Bool

    @State private var expanded = true
    @State private var obsidianTodos: [TodoItem] = []
    @State private var expandedGroups: Set<String> = []

    private var allItems: [TodoItem] {
        let combined = remindersService.todos + obsidianTodos
        return combined.sorted { a, b in
            if a.isOverdue != b.isOverdue { return a.isOverdue }
            switch (a.dueDate, b.dueDate) {
            case let (ad?, bd?): return ad < bd
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return false
            }
        }
    }

    /// Group items by source badge, preserving order of first appearance
    private var groupedItems: [(key: String, items: [TodoItem])] {
        var groups: [(key: String, items: [TodoItem])] = []
        var seen: Set<String> = []
        for item in allItems {
            let key = item.sourceBadge
            if seen.contains(key) {
                if let idx = groups.firstIndex(where: { $0.key == key }) {
                    groups[idx].items.append(item)
                }
            } else {
                seen.insert(key)
                groups.append((key, [item]))
            }
        }
        return groups
    }

    var body: some View {
        if !allItems.isEmpty {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    // Header
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } }) {
                        HStack(spacing: 5) {
                            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9 * scale, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.4))
                                .frame(width: 10)
                            Image(systemName: "checklist")
                                .font(.system(size: 11 * scale))
                                .foregroundColor(.orange)
                            Text("What's Next")
                                .font(.captionFont(scale).weight(.semibold))
                                .foregroundColor(.secondary.opacity(0.7))
                            Text("\(allItems.count)")
                                .font(.custom("Fira Code", size: 10 * scale))
                                .foregroundColor(.secondary.opacity(0.4))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(groupedItems, id: \.key) { group in
                                ProjectGroupView(
                                    projectName: group.key,
                                    items: group.items,
                                    isExpanded: expandedGroups.contains(group.key),
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if expandedGroups.contains(group.key) {
                                                expandedGroups.remove(group.key)
                                            } else {
                                                expandedGroups.insert(group.key)
                                            }
                                        }
                                    },
                                    onComplete: { item in completeItem(item) }
                                )
                            }
                        }
                        .padding(.leading, 14)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)

                Divider().opacity(0.3)
            }
            .task(id: "\(date.timeIntervalSince1970)") {
                obsidianTodos = vaultManager.scanTodos(for: date, includeRecent: isToday)
                // Auto-expand first group
                if expandedGroups.isEmpty, let first = groupedItems.first {
                    expandedGroups.insert(first.key)
                }
            }
        }
    }

    private func completeItem(_ item: TodoItem) {
        withAnimation(.easeOut(duration: 0.25)) {
            switch item.source {
            case .reminder:
                if let id = item.reminderIdentifier {
                    remindersService.completeReminder(id: id)
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        remindersService.loadReminders(for: date)
                    }
                }
            case .obsidian:
                vaultManager.toggleObsidianTodo(item)
                obsidianTodos = vaultManager.scanTodos(for: date, includeRecent: isToday)
            }
        }
    }
}

// MARK: - Project Group (collapsible)

private struct ProjectGroupView: View {
    let projectName: String
    let items: [TodoItem]
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onComplete: (TodoItem) -> Void
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: onToggleExpand) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.4))
                        .frame(width: 10)
                    Text(projectName)
                        .font(.captionFont(scale).weight(.medium))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text("\(items.count)")
                        .font(.custom("Fira Code", size: 9 * scale))
                        .foregroundColor(.secondary.opacity(0.3))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(items) { item in
                    TodoRowView(item: item) {
                        onComplete(item)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Todo Row

private struct TodoRowView: View {
    let item: TodoItem
    let onComplete: () -> Void
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button(action: onComplete) {
                Image(systemName: "square")
                    .font(.system(size: 12 * scale))
                    .foregroundColor(item.isOverdue ? .red : .secondary)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(item.title))
                    .font(.captionFont(scale))
                    .foregroundColor(item.isOverdue ? .primary : .primary.opacity(0.85))
                    .lineLimit(2)

                if let due = item.dueDate {
                    Text(dueDateString(due))
                        .font(.custom("Fira Code", size: 9 * scale))
                        .foregroundColor(item.isOverdue ? .red.opacity(0.7) : .secondary.opacity(0.4))
                }
            }

            Spacer()

            if item.isOverdue {
                Text("overdue")
                    .font(.custom("Fira Code", size: 9 * scale))
                    .foregroundColor(.red.opacity(0.7))
            }
        }
        .padding(.vertical, 2)
    }

    private func dueDateString(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mma"
            return fmt.string(from: date).lowercased()
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}
