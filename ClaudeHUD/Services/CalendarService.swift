import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "CalendarService")

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let location: String?
    let notes: String?
    let calendarName: String
    let calendarColor: String // hex
    let isAllDay: Bool
    let organizer: PersonInfo?
    let attendees: [PersonInfo]
    let zoomLink: String?
}

struct PersonInfo: Identifiable {
    let id = UUID()
    let name: String
    let email: String
    let status: String // accepted, declined, tentative, pending
}

@MainActor
class CalendarService: ObservableObject {
    @Published var todayEvents: [CalendarEvent] = []
    @Published var accessGranted = false
    @Published var displayDate: Date = Date()
    @Published var excludedCalendarIDs: Set<String> {
        didSet { saveExcluded(); loadEvents(for: displayDate) }
    }

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?

    /// All calendars the user has in EventKit
    var allCalendars: [EKCalendar] {
        store.calendars(for: .event).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func isExcluded(_ calendar: EKCalendar) -> Bool {
        excludedCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func toggleCalendar(_ calendar: EKCalendar) {
        if excludedCalendarIDs.contains(calendar.calendarIdentifier) {
            excludedCalendarIDs.remove(calendar.calendarIdentifier)
        } else {
            excludedCalendarIDs.insert(calendar.calendarIdentifier)
        }
    }

    private func saveExcluded() {
        UserDefaults.standard.set(Array(excludedCalendarIDs), forKey: "calendar.excludedIDs")
    }

    private static func loadExcluded() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "calendar.excludedIDs") ?? [])
    }

    init() {
        self.excludedCalendarIDs = Self.loadExcluded()
        requestAccess()
    }

    func requestAccess() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            Task { @MainActor in
                self?.accessGranted = granted
                if granted {
                    self?.loadToday()
                    self?.startWatching()
                } else {
                    logger.warning("Calendar access denied: \(error?.localizedDescription ?? "")")
                }
            }
        }
    }

    func loadToday() {
        loadEvents(for: Date())
    }

    func loadEvents(for date: Date) {
        displayDate = date
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!

        let predicate = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
        let ekEvents = store.events(matching: predicate)
            .filter { !excludedCalendarIDs.contains($0.calendar.calendarIdentifier) }

        todayEvents = ekEvents.map { convert($0) }
            .sorted { $0.startDate < $1.startDate }
    }

    private func startWatching() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.loadEvents(for: self.displayDate)
            }
        }
    }

    private func convert(_ event: EKEvent) -> CalendarEvent {
        let organizer: PersonInfo? = event.organizer.map {
            PersonInfo(
                name: $0.name ?? "Unknown",
                email: extractEmail(from: $0.url),
                status: "organizer"
            )
        }

        let attendees: [PersonInfo] = (event.attendees ?? []).map { participant in
            let status: String = switch participant.participantStatus {
            case .accepted: "accepted"
            case .declined: "declined"
            case .tentative: "tentative"
            case .pending: "pending"
            default: "unknown"
            }
            return PersonInfo(
                name: participant.name ?? "Unknown",
                email: extractEmail(from: participant.url),
                status: status
            )
        }

        // Extract zoom/meet link from location or notes
        let zoomLink = extractMeetingLink(location: event.location, notes: event.notes)

        // Convert calendar color to hex
        let color = event.calendar.cgColor
        let hex = cgColorToHex(color)

        return CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled",
            startDate: event.startDate,
            endDate: event.endDate,
            location: event.location,
            notes: event.notes,
            calendarName: event.calendar.title,
            calendarColor: hex,
            isAllDay: event.isAllDay,
            organizer: organizer,
            attendees: attendees,
            zoomLink: zoomLink
        )
    }

    private func extractEmail(from url: URL) -> String {
        // EKParticipant.url is like "mailto:email@example.com"
        let s = url.absoluteString
        if s.hasPrefix("mailto:") {
            return String(s.dropFirst(7))
        }
        return s
    }

    private func extractMeetingLink(location: String?, notes: String?) -> String? {
        let patterns = [
            #"https://[a-z]+\.zoom\.us/j/\S+"#,
            #"https://meet\.google\.com/\S+"#,
            #"https://teams\.microsoft\.com/\S+"#,
        ]
        for text in [location, notes].compactMap({ $0 }) {
            for pattern in patterns {
                if let range = text.range(of: pattern, options: .regularExpression) {
                    return String(text[range])
                }
            }
        }
        return nil
    }

    private func cgColorToHex(_ color: CGColor?) -> String {
        guard let color = color,
              let components = color.components,
              components.count >= 3 else { return "#888888" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
