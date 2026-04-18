import SwiftUI

struct WhatsNextView: View {
    @EnvironmentObject var remindersService: RemindersService
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale

    let date: Date
    let isToday: Bool

    @State private var expanded = true
    @State private var obsidianTodos: [TodoItem] = []
    @State private var expandedProjects: Set<String> = []
    @State private var expandedSections: Set<String> = []

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

    /// Two-level grouping: project → section → tasks. Preserves first-appearance order.
    private var projectBuckets: [ProjectBucket] {
        var out: [ProjectBucket] = []
        var projIdx: [String: Int] = [:]
        for item in allItems {
            let projKey = item.groupKey
            let pi: Int
            if let existing = projIdx[projKey] {
                pi = existing
            } else {
                pi = out.count
                projIdx[projKey] = pi
                out.append(ProjectBucket(id: projKey, name: projKey, sections: []))
            }
            let secKey = item.sectionHeading ?? ""
            if let si = out[pi].sections.firstIndex(where: { $0.id == secKey }) {
                out[pi].sections[si].items.append(item)
            } else {
                out[pi].sections.append(
                    SectionBucket(id: secKey, heading: item.sectionHeading, items: [item])
                )
            }
        }
        return out
    }

    var body: some View {
        // Always render the outer container so `.task` always attaches on first appearance.
        // A view that only exists inside an `if !allItems.isEmpty` branch never attaches its
        // task when the branch is false, so obsidianTodos would never load on a cold start.
        VStack(spacing: 0) {
            if !allItems.isEmpty {
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
                                .foregroundColor(.secondary.opacity(0.6))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)

                    if expanded {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(projectBuckets) { bucket in
                                ProjectGroupView(
                                    bucket: bucket,
                                    isExpanded: expandedProjects.contains(bucket.id),
                                    expandedSections: $expandedSections,
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if expandedProjects.contains(bucket.id) {
                                                expandedProjects.remove(bucket.id)
                                            } else {
                                                expandedProjects.insert(bucket.id)
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
        }
        .task(id: "\(date.timeIntervalSince1970)") {
            obsidianTodos = vaultManager.scanTodos(for: date, includeRecent: isToday)
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

// MARK: - Grouping models

private struct SectionBucket: Identifiable {
    let id: String           // section heading, or "" for the ungrouped bucket
    let heading: String?     // nil for the ungrouped (pre-section) bucket
    var items: [TodoItem]
}

private struct ProjectBucket: Identifiable {
    let id: String
    let name: String
    var sections: [SectionBucket]
    var totalCount: Int { sections.reduce(0) { $0 + $1.items.count } }
}

/// Stable key combining project and section ids for the shared expanded-sections set.
private func sectionKey(_ projectId: String, _ sectionId: String) -> String {
    "\(projectId)\u{1F}\(sectionId)"
}

// MARK: - Project Group (collapsible, with optional section sub-groups)

private struct ProjectGroupView: View {
    let bucket: ProjectBucket
    let isExpanded: Bool
    @Binding var expandedSections: Set<String>
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
                    Text(bucket.name)
                        .font(.captionFont(scale).weight(.medium))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text("\(bucket.totalCount)")
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.6))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(bucket.sections) { section in
                        if section.heading == nil {
                            // Pre-section flat items — render directly under the project.
                            ForEach(section.items) { item in
                                TodoRowView(item: item) { onComplete(item) }
                            }
                            .padding(.leading, 14)
                        } else {
                            SectionGroupView(
                                projectId: bucket.id,
                                section: section,
                                expandedSections: $expandedSections,
                                onComplete: onComplete
                            )
                        }
                    }
                }
            }
        }
        .padding(.vertical, 1)
    }
}

// MARK: - Section Group (collapsible sub-group within a project)

private struct SectionGroupView: View {
    let projectId: String
    let section: SectionBucket
    @Binding var expandedSections: Set<String>
    let onComplete: (TodoItem) -> Void
    @Environment(\.fontScale) private var scale

    private var key: String { sectionKey(projectId, section.id) }
    private var isExpanded: Bool { expandedSections.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedSections.remove(key)
                    } else {
                        expandedSections.insert(key)
                    }
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 7 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.35))
                        .frame(width: 10)
                    Text(section.heading ?? "")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("\(section.items.count)")
                        .font(.custom("Fira Code", size: 9 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 14)

            if isExpanded {
                ForEach(section.items) { item in
                    TodoRowView(item: item) { onComplete(item) }
                }
                .padding(.leading, 28)
            }
        }
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
                Text(LocalizedStringKey(item.displayTitle))
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
