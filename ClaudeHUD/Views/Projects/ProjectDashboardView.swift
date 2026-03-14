import SwiftUI
import AppKit

struct ProjectDashboardView: View {
    @EnvironmentObject var projectService: ProjectService
    @EnvironmentObject var projectBriefing: ProjectBriefingService
    @EnvironmentObject var sessionHistory: SessionHistoryService
    @EnvironmentObject var vaultManager: VaultManager
    @EnvironmentObject var calendarService: CalendarService
    @Environment(\.fontScale) private var scale

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
                // Header
                HStack {
                    Text("Projects")
                        .font(.smallMedium(scale))
                        .foregroundColor(.primary)
                    Spacer()
                    if projectService.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(projectService.projects.count)")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)

                Divider().opacity(0.3)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(projectService.projects) { project in
                            ProjectCardView(project: project)
                                .environmentObject(projectBriefing)
                                .environmentObject(projectService)
                            Divider().opacity(0.15)
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
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.smallFont(scale))
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
                                    .font(.custom("Fira Code", size: 10 * scale))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            if !project.upcomingEvents.isEmpty {
                                Label("\(project.upcomingEvents.count)", systemImage: "calendar")
                                    .font(.custom("Fira Code", size: 10 * scale))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                            if !project.recentNotes.isEmpty {
                                Label("\(project.recentNotes.count)", systemImage: "doc.text")
                                    .font(.custom("Fira Code", size: 10 * scale))
                                    .foregroundColor(.secondary.opacity(0.6))
                            }
                        }
                    }
                }

                Spacer()

                if let briefing = briefing, !briefing.isLoading, briefing.error == nil {
                    Text(briefing.status)
                        .font(.custom("Fira Code", size: 9 * scale).weight(.medium))
                        .foregroundColor(statusColor(briefing.status))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(statusColor(briefing.status).opacity(0.12))
                        )
                } else if briefing?.isLoading == true {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(project.lastActivity.relativeString)
                        .font(.custom("Fira Code", size: 10 * scale))
                        .foregroundColor(.secondary.opacity(0.5))
                }

                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.4))
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

    private var statusDotColor: Color {
        guard let briefing = briefing, !briefing.isLoading, briefing.error == nil else {
            return .secondary.opacity(0.3)
        }
        return statusColor(briefing.status)
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "active": return .green
        case "stalled": return .orange
        case "wrapping-up": return .blue
        case "starting": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Project Detail (expanded)

private struct ProjectDetailView: View {
    let project: Project
    @EnvironmentObject var projectBriefing: ProjectBriefingService
    @EnvironmentObject var projectService: ProjectService
    @Environment(\.fontScale) private var scale

    private var briefing: ProjectBriefing? { projectBriefing.briefings[project.id] }
    private var projectIntel: ProjectIntel? { projectService.intel[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // === AI Briefing (always visible) ===
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
                                            title: "Priorities", items: briefing.priorities, scale: scale)
                    }
                    if !briefing.blockers.isEmpty {
                        BriefingListSection(icon: "exclamationmark.triangle", iconColor: .orange,
                                            title: "Blockers", items: briefing.blockers, scale: scale)
                    }
                    if !briefing.nextActions.isEmpty {
                        BriefingListSection(icon: "arrow.right.circle", iconColor: .green,
                                            title: "Next", items: briefing.nextActions, scale: scale)
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

            Divider().opacity(0.2).padding(.vertical, 2)

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
                        CollapsibleSection(icon: "person.2", iconColor: .purple,
                                           title: "People", count: intel.people.count, scale: scale) {
                            ForEach(intel.people.prefix(6)) { person in
                                HStack(spacing: 4) {
                                    Image(systemName: sourceIcon(person.source))
                                        .font(.system(size: 8 * scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .frame(width: 12)
                                    Text(person.name)
                                        .font(.captionFont(scale))
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 2)
                            }
                        }
                    }

                    if !intel.emails.isEmpty {
                        CollapsibleSection(icon: "envelope", iconColor: .blue,
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
        }
    }

    private func shortTime(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "h:mma"
        return fmt.string(from: date).lowercased()
    }

    private func sourceIcon(_ source: String) -> String {
        switch source {
        case "calendar": return "calendar"
        case "email": return "envelope"
        case "both": return "person.crop.circle.badge.checkmark"
        default: return "person"
        }
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
                        .font(.system(size: 8 * scale, weight: .semibold))
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
                Image(systemName: icon)
                    .font(.system(size: 9 * scale))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.captionFont(scale).weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("(\(count))")
                    .font(.custom("Fira Code", size: 9.5 * scale))
                    .foregroundColor(.secondary.opacity(0.3))
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.3))
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
    let scale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9 * scale))
                    .foregroundColor(iconColor)
                Text(title)
                    .font(.captionFont(scale).weight(.semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }

            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 4) {
                    Text("·")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(item)
                        .font(.captionFont(scale))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }
                .padding(.leading, 2)
            }
        }
    }
}
