import SwiftUI
import AppKit

struct TodayView: View {
    @EnvironmentObject var calendarService: CalendarService
    @EnvironmentObject var briefingService: BriefingService
    @EnvironmentObject var vaultManager: VaultManager
    @EnvironmentObject var projectService: ProjectService
    @EnvironmentObject var remindersService: RemindersService
    @Environment(\.fontScale) private var scale
    @State private var dayOffset = 0

    private var selectedDate: Date {
        Calendar.current.date(byAdding: .day, value: dayOffset, to: Calendar.current.startOfDay(for: Date()))!
    }

    private var isToday: Bool { dayOffset == 0 }

    private func headerString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt.string(from: date)
    }

    private var timeEvents: [CalendarEvent] {
        calendarService.todayEvents.filter { !$0.isAllDay }
    }

    private var allDayEvents: [CalendarEvent] {
        calendarService.todayEvents.filter { $0.isAllDay }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !calendarService.accessGranted {
                Spacer()
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Calendar access required")
                    .font(.smallFont(scale))
                    .foregroundColor(.secondary)
                    .padding(.top, 6)
                Text("Grant access in System Settings → Privacy → Calendars")
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                Spacer()
            } else if calendarService.todayEvents.isEmpty {
                // Even with no events, show WhatsNext + nav
                ScrollView {
                    // Date header with nav (minimal)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Button(action: { dayOffset -= 1 }) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9 * scale, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .buttonStyle(.borderless)

                        Text(headerString(for: selectedDate))
                            .font(.smallMedium(scale))
                            .foregroundColor(.primary)

                        Button(action: { dayOffset += 1 }) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9 * scale, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                        .buttonStyle(.borderless)

                        if !isToday {
                            Button(action: { dayOffset = 0 }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 9 * scale))
                                    Text("today")
                                        .font(.captionFont(scale).weight(.medium))
                                }
                                .foregroundColor(.blue)
                            }
                            .buttonStyle(.borderless)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    WhatsNextView(date: selectedDate, isToday: isToday)

                    if remindersService.todos.isEmpty {
                        // Truly empty — show placeholder
                        VStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.system(size: 28))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(isToday ? "No events today" : "No events")
                                .font(.smallFont(scale))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                    }
                }
            } else {
                ScrollView {
                    // "Your Day" summary
                    DaySummaryView(timeEvents: timeEvents, allDayEvents: allDayEvents, date: selectedDate, isToday: isToday, dayOffset: $dayOffset)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 6)

                    Divider().opacity(0.3)

                    WhatsNextView(date: selectedDate, isToday: isToday)

                    LazyVStack(spacing: 0) {
                        // All-day events
                        if !allDayEvents.isEmpty {
                            ForEach(allDayEvents) { event in
                                AllDayEventRow(event: event)
                            }
                            Divider().opacity(0.3).padding(.vertical, 4)
                        }

                        // Timed events
                        ForEach(timeEvents) { event in
                            EventRow(event: event)
                            Divider().opacity(0.3)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: dayOffset) {
            let date = selectedDate
            calendarService.loadEvents(for: date)
            remindersService.loadReminders(for: date)
            vaultManager.ensureDailyNote(for: date)
            let obsidianTodos = vaultManager.scanTodos(for: date, includeRecent: Calendar.current.isDateInToday(date))
            let allTodos = remindersService.todos + obsidianTodos
            briefingService.clearDaySummary()
            briefingService.generateDaySummary(
                events: calendarService.todayEvents,
                date: date,
                todos: allTodos
            )
            briefingService.preloadAll(
                events: calendarService.todayEvents,
                vaultPath: vaultManager.currentVault?.path,
                projects: projectService.projects
            )
        }
    }
}

// MARK: - Day Summary

private struct DaySummaryView: View {
    let timeEvents: [CalendarEvent]
    let allDayEvents: [CalendarEvent]
    let date: Date
    let isToday: Bool
    @Binding var dayOffset: Int
    @EnvironmentObject var briefingService: BriefingService
    @EnvironmentObject var calendarService: CalendarService
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Date header with nav
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button(action: { dayOffset -= 1 }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.borderless)

                Text(headerString())
                    .font(.smallMedium(scale))
                    .foregroundColor(.primary)

                Button(action: { dayOffset += 1 }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.borderless)

                if !isToday {
                    Button(action: { dayOffset = 0 }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 9 * scale))
                            Text("today")
                                .font(.captionFont(scale).weight(.medium))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()
                Text(dayShape)
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }

            // LLM-generated summary
            if let daySummary = briefingService.daySummary {
                if let text = daySummary.text {
                    Text(text)
                        .font(.custom("Fira Sans", size: 12 * scale))
                        .foregroundColor(.secondary.opacity(0.85))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if daySummary.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading your day...")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Day shape label

    private var dayShape: String {
        if timeEvents.isEmpty { return "" }

        let total = timeEvents.count
        if total <= 2 { return "light" }
        if total >= 5 { return "packed" }
        return "\(total) events"
    }

    private func headerString() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt.string(from: date)
    }
}

// MARK: - All Day Event Row

private struct AllDayEventRow: View {
    let event: CalendarEvent
    @Environment(\.fontScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: event.calendarColor))
                .frame(width: 6, height: 6)
            Text(event.title)
                .font(.captionFont(scale))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            Text("all day")
                .font(.captionFont(scale))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

// MARK: - Event Row (expandable)

struct EventRow: View {
    let event: CalendarEvent
    @State private var expanded = false
    @Environment(\.fontScale) private var scale

    private var isPast: Bool { event.endDate < Date() }
    private var isNow: Bool { event.startDate <= Date() && event.endDate > Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Compact row
            HStack(spacing: 8) {
                // Time
                Text(compactTimeRange())
                    .font(.custom("Fira Code", size: 10.5 * scale).weight(.medium))
                    .foregroundColor(isNow ? .green : isPast ? .secondary.opacity(0.4) : .secondary)
                    .frame(width: 72, alignment: .trailing)

                // Color dot
                Circle()
                    .fill(Color(hex: event.calendarColor))
                    .frame(width: 7, height: 7)

                // Title + location
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title)
                        .font(.smallFont(scale))
                        .foregroundColor(isPast ? .secondary.opacity(0.5) : .primary)
                        .lineLimit(1)

                    if let location = compactLocation() {
                        Text(location)
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary.opacity(0.6))
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Expand indicator (if has attendees or details)
                if !event.attendees.isEmpty || event.zoomLink != nil {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.4))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture {
                if !event.attendees.isEmpty || event.zoomLink != nil || event.notes != nil {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                }
            }

            // Expanded detail
            if expanded {
                EventDetailView(event: event)
                    .padding(.leading, 66)
                    .padding(.trailing, 4)
                    .padding(.bottom, 8)
            }
        }
        .opacity(isPast ? 0.6 : 1.0)
    }

    /// Format like "3–4p" or "3:30–4p" or "9a–12p"
    private func compactTimeRange() -> String {
        func short(_ date: Date) -> (h: Int, m: Int, pm: Bool) {
            let cal = Calendar.current
            let h = cal.component(.hour, from: date)
            let m = cal.component(.minute, from: date)
            return (h > 12 ? h - 12 : (h == 0 ? 12 : h), m, h >= 12)
        }

        let s = short(event.startDate)
        let e = short(event.endDate)
        let suf = { (pm: Bool) -> String in pm ? "p" : "a" }

        let startMin = s.m > 0 ? ":\(String(format: "%02d", s.m))" : ""
        let endMin = e.m > 0 ? ":\(String(format: "%02d", e.m))" : ""

        // Omit start suffix if same as end
        let startSuf = s.pm == e.pm ? "" : suf(s.pm)

        return "\(s.h)\(startMin)\(startSuf)–\(e.h)\(endMin)\(suf(e.pm))"
    }

    private func compactLocation() -> String? {
        if event.zoomLink != nil { return "Zoom" }
        if let loc = event.location, !loc.isEmpty {
            if loc.contains("zoom.us") { return "Zoom" }
            if loc.contains("meet.google") { return "Google Meet" }
            if loc.contains("teams.microsoft") { return "Teams" }
            return String(loc.prefix(40))
        }
        return nil
    }
}

// MARK: - Event Detail (expanded)

struct EventDetailView: View {
    let event: CalendarEvent
    @EnvironmentObject var briefingService: BriefingService
    @EnvironmentObject var vaultManager: VaultManager
    @EnvironmentObject var projectService: ProjectService
    @Environment(\.fontScale) private var scale

    @State private var showPeople = false
    @State private var showThreads = false
    @State private var showNotes = false

    private var briefing: EventBriefing? { briefingService.briefings[event.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Zoom / meeting link
            if let link = event.zoomLink {
                Button(action: {
                    if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 10 * scale))
                        Text("Join meeting")
                            .font(.captionFont(scale))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(.borderless)
            }

            // Location (full, if not just a link)
            if let loc = event.location, !loc.isEmpty,
               !loc.contains("zoom.us"), !loc.contains("meet.google"), !loc.contains("teams.microsoft") {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "mappin")
                        .font(.system(size: 10 * scale))
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(loc)
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary)
                }
            }

            // Calendar name
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(hex: event.calendarColor))
                    .frame(width: 6, height: 6)
                Text(event.calendarName)
                    .font(.captionFont(scale))
                    .foregroundColor(.secondary.opacity(0.5))
            }

            // INTEL SUMMARY
            if let briefing = briefing {
                if let summary = briefing.summary {
                    Text(summary)
                        .font(.custom("Fira Sans", size: 11.5 * scale))
                        .foregroundColor(.secondary.opacity(0.8))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } else if briefing.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Preparing briefing...")
                            .font(.captionFont(scale))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                } else if briefing.emailThreads.isEmpty && briefing.relatedNotes.isEmpty {
                    Text("No related intel found")
                        .font(.captionFont(scale))
                        .foregroundColor(.secondary.opacity(0.4))
                        .padding(.top, 4)
                }
            }

            // COLLAPSIBLE SECTIONS (available even while summary is loading)
            if let briefing = briefing {
                // People
                if !event.attendees.isEmpty {
                    CollapsibleSection(
                        title: "People",
                        icon: "person.2",
                        color: .secondary,
                        isExpanded: $showPeople
                    ) {
                        ForEach(event.attendees.filter { !ContactService.isCurrentUser($0) }) { person in
                            HStack(spacing: 4) {
                                Image(systemName: statusIcon(person.status))
                                    .font(.system(size: 9 * scale))
                                    .foregroundColor(statusColor(person.status))
                                    .frame(width: 12)
                                Text(ContactService.resolvedName(for: person))
                                    .font(.captionFont(scale))
                                    .foregroundColor(.primary)
                                if let org = ContactService.resolvedOrg(for: person) {
                                    Text("(\(org))")
                                        .font(.custom("Fira Code", size: 9 * scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                }
                                if person.status == "organizer" {
                                    Text("organizer")
                                        .font(.custom("Fira Code", size: 9 * scale))
                                        .foregroundColor(.secondary.opacity(0.4))
                                }
                            }
                        }
                    }
                }

                // Email threads
                if !briefing.emailThreads.isEmpty {
                    CollapsibleSection(
                        title: "Threads (\(briefing.emailThreads.count))",
                        icon: "envelope",
                        color: .blue,
                        isExpanded: $showThreads
                    ) {
                        ForEach(briefing.emailThreads) { thread in
                            EmailThreadRow(thread: thread)
                        }
                    }
                }

                // Related notes
                if !briefing.relatedNotes.isEmpty {
                    CollapsibleSection(
                        title: "Notes (\(briefing.relatedNotes.count))",
                        icon: "doc.text",
                        color: .orange,
                        isExpanded: $showNotes
                    ) {
                        ForEach(briefing.relatedNotes) { note in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.name)
                                    .font(.captionFont(scale))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                if !note.preview.isEmpty {
                                    Text(note.preview)
                                        .font(.custom("Fira Sans", size: 10.5 * scale))
                                        .foregroundColor(.secondary.opacity(0.5))
                                        .lineLimit(1)
                                }
                            }
                            .padding(.leading, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                FloatingNoteWindowManager.shared.openWindow(
                                    for: NoteFile(name: URL(fileURLWithPath: note.path).lastPathComponent,
                                                  path: note.path,
                                                  relativePath: note.name,
                                                  isDirectory: false,
                                                  children: nil))
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            briefingService.generateBriefing(
                for: event,
                vaultPath: vaultManager.currentVault?.path,
                projects: projectService.projects
            )
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "accepted", "organizer": return "checkmark.circle.fill"
        case "declined": return "xmark.circle.fill"
        case "tentative": return "questionmark.circle"
        default: return "circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "accepted", "organizer": return .green
        case "declined": return .red
        case "tentative": return .orange
        default: return .secondary
        }
    }
}

// MARK: - Collapsible Section

private struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.fontScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.4))
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.system(size: 9 * scale))
                        .foregroundColor(color)
                    Text(title)
                        .font(.captionFont(scale).weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                content()
                    .padding(.leading, 14)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Email Thread Row (expandable)

private struct EmailThreadRow: View {
    let thread: EmailThread
    @EnvironmentObject var briefingService: BriefingService
    @State private var expanded = false
    @State private var fullBody: String?
    @Environment(\.fontScale) private var scale

    private var displayBody: String {
        fullBody ?? thread.snippet
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header (always visible)
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(thread.subject)
                        .font(.captionFont(scale))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(thread.participants)
                            .font(.custom("Fira Sans", size: 10.5 * scale))
                            .foregroundColor(.secondary.opacity(0.5))
                            .lineLimit(1)
                        if !thread.date.isEmpty {
                            Text("·")
                                .foregroundColor(.secondary.opacity(0.3))
                            Text(thread.date)
                                .font(.custom("Fira Sans", size: 10.5 * scale))
                                .foregroundColor(.secondary.opacity(0.5))
                        }
                    }
                }
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9 * scale, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.3))
            }
            .padding(.leading, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                if expanded && fullBody == nil {
                    Task {
                        fullBody = await briefingService.fetchFullBody(messagePk: thread.messagePk)
                    }
                }
            }

            // Body (expanded)
            if expanded {
                if displayBody.isEmpty {
                    Text("Loading...")
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.secondary.opacity(0.4))
                        .padding(.leading, 2)
                        .padding(.top, 2)
                } else {
                    Text(displayBody)
                        .font(.custom("Fira Sans", size: 11 * scale))
                        .foregroundColor(.secondary.opacity(0.7))
                        .lineSpacing(2)
                        .padding(.leading, 2)
                        .padding(.top, 2)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - Color from Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
