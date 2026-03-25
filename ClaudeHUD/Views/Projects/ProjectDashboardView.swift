import SwiftUI
import AppKit

struct ProjectDashboardView: View {
    @EnvironmentObject var projectService: ProjectService
    @EnvironmentObject var projectBriefing: ProjectBriefingService
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var vaultManager: VaultManager
    @EnvironmentObject var calendarService: CalendarService
    @Environment(\.fontScale) private var scale
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            if projectService.projects.isEmpty && !projectService.isLoading {
                Spacer()
                Image(systemName: "briefcase")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("No projects found")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                Text("Add project folders to your Obsidian vault")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.top, 4)
                Spacer()
            } else {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary)
                    TextField("Search projects...", text: $searchText)
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

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredProjects) { project in
                            ProjectCardView(project: project)
                                .environmentObject(projectBriefing)
                                .environmentObject(projectService)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            projectService.refresh()
        }
    }

    private var filteredProjects: [Project] {
        if searchText.isEmpty { return projectService.projects }
        let q = searchText.lowercased()
        return projectService.projects.filter {
            $0.name.lowercased().contains(q)
        }
    }
}

// MARK: - Project Card

private struct ProjectCardView: View {
    let project: Project
    @EnvironmentObject var projectBriefing: ProjectBriefingService
    @EnvironmentObject var projectService: ProjectService
    @State private var expanded = false
    @Environment(\.fontScale) private var scale

    private var briefing: ProjectBriefing? { projectBriefing.briefings[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(width: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.smallMedium(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let briefing = briefing, !briefing.isLoading, briefing.error == nil, !briefing.summary.isEmpty {
                        Text(briefing.summary)
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(2)
                    } else {
                        HStack(spacing: 6) {
                            if !project.recentSessions.isEmpty {
                                Label("\(project.recentSessions.count)", systemImage: "terminal")
                                    .font(.codeFont(scale))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            if !project.upcomingEvents.isEmpty {
                                Label("\(project.upcomingEvents.count)", systemImage: "calendar")
                                    .font(.codeFont(scale))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            if !project.recentNotes.isEmpty {
                                Label("\(project.recentNotes.count)", systemImage: "doc.text")
                                    .font(.codeFont(scale))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                        }
                    }
                }

                Spacer()

                if briefing?.isLoading == true {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(project.lastActivity.relativeString)
                        .font(.codeFont(scale))
                        .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            }

            if expanded {
                ProjectDetailView(project: project)
                    .environmentObject(projectBriefing)
                    .environmentObject(projectService)
                    .padding(.leading, 20)
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
            }
        }
    }

}

// MARK: - Project Detail (expanded)

private struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var projectBriefing: ProjectBriefingService
    @EnvironmentObject var projectService: ProjectService
    @EnvironmentObject var vaultManager: VaultManager
    @Environment(\.fontScale) private var scale
    @State private var projectTasks: [TodoItem] = []

    private var briefing: ProjectBriefing? { projectBriefing.briefings[project.id] }
    private var projectIntel: ProjectIntel? { projectService.intel[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // === Authoritative Tasks from Tasks.md ===
            if !projectTasks.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                            .font(.system(size: 9 * scale))
                            .foregroundColor(.orange)
                        Text("Tasks")
                            .font(.captionFont(scale).weight(.semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text("\(projectTasks.count)")
                            .font(.custom("Fira Code", size: 10 * scale))
                            .foregroundColor(.secondary.opacity(0.6))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                    }

                    ForEach(projectTasks) { task in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Button(action: { completeTask(task) }) {
                                Image(systemName: "square")
                                    .font(.system(size: 12 * scale))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)

                            Text(LocalizedStringKey(task.displayTitle))
                                .font(.captionFont(scale))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                        }
                        .padding(.leading, 2)
                    }
                }
                Divider().opacity(0.3).padding(.vertical, 2)
            }

            // === AI Briefing ===
            if let briefing = briefing {
                if briefing.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Analyzing project...")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                } else if let error = briefing.error {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 9 * scale))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                } else {
                    if !briefing.priorities.isEmpty {
                        BriefingListSection(icon: "arrow.up.circle", iconColor: .blue,
                                            title: "Priorities", items: briefing.priorities,
                                            projectPath: project.obsidianPath, scale: scale)
                    }
                    if !briefing.blockers.isEmpty {
                        BriefingListSection(icon: "exclamationmark.triangle", iconColor: .orange,
                                            title: "Blockers", items: briefing.blockers,
                                            projectPath: project.obsidianPath, scale: scale)
                    }
                    if !briefing.nextActions.isEmpty {
                        BriefingListSection(icon: "arrow.right.circle", iconColor: .green,
                                            title: "Next", items: briefing.nextActions,
                                            projectPath: project.obsidianPath, scale: scale)
                    }

                    Button(action: {
                        projectBriefing.invalidate(projectId: project.id)
                        projectBriefing.generateBriefing(for: project)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9 * scale))
                            Text("Refresh")
                                .font(.captionFont(scale))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
                }
            }

            Divider().opacity(0.3).padding(.vertical, 2)

            // === People & Emails (lazy loaded) ===
            if let intel = projectIntel {
                if intel.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading emails...")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                } else {
                    if !intel.people.isEmpty {
                        CollapsibleSection(icon: "person.2", iconColor: .secondary.opacity(0.5),
                                           title: "People", count: intel.people.count, scale: scale) {
                            ForEach(intel.people.prefix(6)) { contact in
                                HStack(spacing: 4) {
                                    Image(systemName: contactSourceIcon(contact))
                                        .font(.system(size: 8 * scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .frame(width: 12)
                                    Text(contact.name)
                                        .font(.captionFont(scale))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    if !contact.org.isEmpty {
                                        Text("(\(contact.org))")
                                            .font(.custom("Fira Code", size: 9 * scale))
                                            .foregroundColor(.secondary.opacity(0.5))
                                    }
                                }
                                .padding(.leading, 2)
                            }
                        }
                    }

                    if !intel.emails.isEmpty {
                        CollapsibleSection(icon: "envelope", iconColor: .secondary.opacity(0.5),
                                           title: "Emails", count: intel.emails.count, scale: scale) {
                            ForEach(intel.emails.prefix(4)) { email in
                                ProjectEmailRow(email: email, scale: scale)
                            }
                        }
                    }
                }
            }

            // === Today's events (always visible if any) ===
            if !project.upcomingEvents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                            .font(.system(size: 9 * scale))
                            .foregroundColor(.green)
                        Text("Today")
                            .font(.captionFont(scale).weight(.semibold))
                            .foregroundColor(.secondary.opacity(0.6))
                    }

                    ForEach(project.upcomingEvents) { event in
                        HStack(spacing: 6) {
                            Text(event.title)
                                .font(.captionFont(scale))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(shortTime(event.startDate))
                                .font(.custom("Fira Code", size: 9.5 * scale))
                                .foregroundColor(.secondary.opacity(0.4))
                        }
                        .padding(.leading, 2)
                    }
                }
            }

            // === Notes (collapsed by default) ===
            if !project.recentNotes.isEmpty {
                CollapsibleSection(icon: "doc.text", iconColor: .secondary.opacity(0.5),
                                   title: "Notes", count: project.recentNotes.count, scale: scale) {
                    ForEach(project.recentNotes) { note in
                        HStack(spacing: 6) {
                            Text(note.name)
                                .font(.captionFont(scale))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(note.modified.relativeString)
                                .font(.custom("Fira Code", size: 9.5 * scale))
                                .foregroundColor(.secondary.opacity(0.4))
                        }
                        .padding(.leading, 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            FloatingNoteWindowManager.shared.openWindow(
                                for: NoteFile(
                                    name: note.name + ".md",
                                    path: note.path,
                                    relativePath: note.name,
                                    isDirectory: false,
                                    modificationDate: nil,
                                    children: nil
                                )
                            )
                        }
                    }
                }
            }

            // === Sessions (collapsed by default) ===
            if !project.recentSessions.isEmpty {
                CollapsibleSection(icon: "terminal", iconColor: .secondary.opacity(0.5),
                                   title: "Sessions", count: project.recentSessions.count, scale: scale) {
                    ForEach(project.recentSessions.prefix(5)) { session in
                        HStack(spacing: 6) {
                            Text(session.preview)
                                .font(.captionFont(scale))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(session.timestamp.relativeString)
                                .font(.custom("Fira Code", size: 9.5 * scale))
                                .foregroundColor(.secondary.opacity(0.4))
                        }
                        .padding(.leading, 2)
                    }
                }
            }

        }
        .onAppear {
            projectService.loadIntel(for: project)
            projectBriefing.generateBriefing(for: project)
            loadProjectTasks()
        }
    }

    private func loadProjectTasks() {
        guard let taskFile = vaultManager.findTaskFile(in: project.obsidianPath) else {
            projectTasks = []
            return
        }
        projectTasks = vaultManager.extractActiveTasks(
            from: taskFile, noteName: project.name, projectName: project.name
        )
    }

    private func completeTask(_ item: TodoItem) {
        withAnimation(.easeOut(duration: 0.25)) {
            vaultManager.toggleObsidianTodo(item)
            loadProjectTasks()
        }
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mma"
        return fmt.string(from: date).lowercased()
    }

    private func contactSourceIcon(_ contact: Contact) -> String {
        if contact.sources.contains(.calendar) && contact.sources.contains(.email) {
            return "person.crop.circle.badge.checkmark"
        } else if contact.sources.contains(.calendar) {
            return "calendar"
        } else if contact.sources.contains(.email) {
            return "envelope"
        }
        return "person"
    }
}

// MARK: - Expandable Email Row

private struct ProjectEmailRow: View {
    let email: ProjectEmail
    let scale: CGFloat
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(email.subject)
                        .font(.captionFont(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(email.from)
                            .font(.custom("Fira Sans", size: 10.5 * scale))
                            .foregroundColor(.secondary.opacity(0.5))
                            .lineLimit(1)
                        Text("·")
                            .foregroundColor(.secondary.opacity(0.3))
                        Text(email.date)
                            .font(.custom("Fira Sans", size: 10.5 * scale))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
                Spacer()
                if !email.body.isEmpty {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.3))
                }
            }
            .padding(.leading, 2)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                if !email.body.isEmpty {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }

            // Expanded body
            if expanded {
                Text(email.body.prefix(800))
                    .font(.custom("Fira Sans", size: 11 * scale))
                    .foregroundColor(.secondary.opacity(0.8))
                    .lineLimit(12)
                    .padding(.leading, 4)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Collapsible Section

private struct CollapsibleSection<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let count: Int
    let scale: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.4))
                    .frame(width: 10)
                Image(systemName: icon)
                    .font(.system(size: 9 * scale))
                    .foregroundColor(iconColor)
                Text("\(count)")
                    .font(.custom("Fira Code", size: 10 * scale))
                    .foregroundColor(.secondary.opacity(0.6))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.1)))
                Text(title)
                    .font(.captionFont(scale).weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }

            if isExpanded {
                content()
            }
        }
    }
}

// MARK: - Briefing List Section

private struct BriefingListSection: View {
    let icon: String
    let iconColor: Color
    let title: String
    let items: [String]
    let projectPath: String
    let scale: CGFloat

    @State private var dismissed: Set<Int> = []
    @State private var pushed: Set<Int> = []
    @State private var expandedItem: Int? = nil

    private var visibleItems: [(offset: Int, element: String)] {
        Array(items.enumerated()).filter { !dismissed.contains($0.offset) }
    }

    var body: some View {
        if !visibleItems.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: icon)
                        .font(.system(size: 9 * scale))
                        .foregroundColor(iconColor)
                    Text(title)
                        .font(.captionFont(scale).weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }

                ForEach(visibleItems, id: \.offset) { idx, item in
                    BriefingItemRow(
                        text: item,
                        isPushed: pushed.contains(idx),
                        isExpanded: expandedItem == idx,
                        scale: scale,
                        onTapBullet: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expandedItem = expandedItem == idx ? nil : idx
                            }
                        },
                        onPush: { pushToObsidian(item, idx: idx, checked: false) },
                        onDismiss: {
                            pushToObsidian(item, idx: idx, checked: true)
                            withAnimation(.easeOut(duration: 0.2)) { _ = dismissed.insert(idx) }
                        },
                        onDone: {
                            pushToObsidian(item, idx: idx, checked: true)
                            withAnimation(.easeOut(duration: 0.2)) { _ = dismissed.insert(idx) }
                        }
                    )
                }
            }
        }
    }

    private func pushToObsidian(_ item: String, idx: Int, checked: Bool = false) {
        // Guard against double-tap
        if !checked && pushed.contains(idx) { return }
        if checked && dismissed.contains(idx) { return }

        let tasksPath = (projectPath as NSString).appendingPathComponent("Tasks.md")
        let fm = FileManager.default
        let checkbox = checked ? "[x]" : "[ ]"

        if fm.fileExists(atPath: tasksPath) {
            if var content = try? String(contentsOfFile: tasksPath, encoding: .utf8) {
                // Don't add if already present (check raw text)
                guard !content.contains("] \(item)") else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if !checked { _ = pushed.insert(idx) }
                        expandedItem = nil
                    }
                    return
                }
                // Insert under ## Active heading
                if let activeRange = content.range(of: "## Active") {
                    let insertPoint = content.index(activeRange.upperBound, offsetBy: 0)
                    // Find end of the ## Active line
                    if let lineEnd = content[insertPoint...].firstIndex(of: "\n") {
                        content.insert(contentsOf: "\n- \(checkbox) \(item)", at: lineEnd)
                    } else {
                        content += "\n- \(checkbox) \(item)"
                    }
                } else {
                    content += "\n- \(checkbox) \(item)"
                }
                try? content.write(toFile: tasksPath, atomically: true, encoding: .utf8)
            }
        } else {
            // Create a new Tasks.md with standard template
            let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            let today = fmt.string(from: Date())
            let content = """
            ---
            project: \(projectName)
            status: active
            updated: \(today)
            ---

            # Tasks

            ## Active

            - \(checkbox) \(item)

            ## Completed

            ## Context

            """
            try? content.write(toFile: tasksPath, atomically: true, encoding: .utf8)
        }

        withAnimation(.easeOut(duration: 0.2)) {
            if !checked { _ = pushed.insert(idx) }
            expandedItem = nil
        }
    }
}

// MARK: - Briefing Item Row (tap bullet to expand actions)

private struct BriefingItemRow: View {
    let text: String
    let isPushed: Bool
    let isExpanded: Bool
    let scale: CGFloat
    let onTapBullet: () -> Void
    let onPush: () -> Void
    let onDismiss: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if isExpanded {
                HStack(spacing: 2) {
                    Button(action: onDone) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9 * scale, weight: .semibold))
                            .foregroundColor(.green)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .help("Done")

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9 * scale, weight: .semibold))
                            .foregroundColor(.red.opacity(0.6))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .help("Skip")

                    Button(action: onPush) {
                        Image(systemName: "plus")
                            .font(.system(size: 9 * scale, weight: .semibold))
                            .foregroundColor(.blue)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.borderless)
                    .help("Add to notes")
                }
            } else {
                Button(action: onTapBullet) {
                    Image(systemName: "square")
                        .font(.system(size: 11 * scale))
                        .foregroundColor(.secondary.opacity(0.4))
                        .frame(width: 14)
                }
                .buttonStyle(.borderless)
            }

            Text(text)
                .font(.captionFont(scale))
                .foregroundColor(.primary)
                .lineLimit(2)

            if isPushed {
                Text("added")
                    .font(.custom("Fira Code", size: 9 * scale))
                    .foregroundColor(.blue.opacity(0.5))
            }
        }
        .padding(.leading, 2)
    }
}

