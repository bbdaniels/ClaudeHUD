import EventKit
import Foundation
import os

private let logger = Logger(subsystem: "com.claudehud", category: "RemindersService")

@MainActor
class RemindersService: ObservableObject {
    @Published var todos: [TodoItem] = []
    @Published var accessGranted = false

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var currentDate: Date = Date()

    init() {
        requestAccess()
    }

    func requestAccess() {
        store.requestFullAccessToReminders { [weak self] granted, error in
            Task { @MainActor in
                self?.accessGranted = granted
                if granted {
                    self?.loadReminders(for: Date())
                    self?.startWatching()
                } else {
                    logger.warning("Reminders access denied: \(error?.localizedDescription ?? "")")
                }
            }
        }
    }

    func loadReminders(for date: Date) {
        guard accessGranted else { return }
        currentDate = date

        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        let isToday = cal.isDateInToday(date)

        let predicate: NSPredicate
        if isToday {
            // Today: incomplete reminders due today + all overdue
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil,
                ending: endOfDay,
                calendars: nil
            )
        } else {
            // Other days: incomplete reminders due that day only
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: startOfDay,
                ending: endOfDay,
                calendars: nil
            )
        }

        store.fetchReminders(matching: predicate) { [weak self] ekReminders in
            let items = (ekReminders ?? []).compactMap { reminder -> TodoItem? in
                guard !reminder.isCompleted else { return nil }
                let due = reminder.dueDateComponents?.date
                let overdue: Bool
                if let due {
                    overdue = due < startOfDay
                } else {
                    overdue = false
                }

                return TodoItem(
                    title: reminder.title ?? "Untitled",
                    source: .reminder(listName: reminder.calendar.title),
                    dueDate: due,
                    isOverdue: overdue,
                    priority: reminder.priority,
                    reminderIdentifier: reminder.calendarItemIdentifier,
                    obsidianFilePath: nil,
                    obsidianLineNumber: nil
                )
            }

            Task { @MainActor in
                self?.todos = items
            }
        }
    }

    func completeReminder(id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            logger.warning("Could not find reminder with id \(id)")
            return
        }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            logger.info("Completed reminder: \(reminder.title ?? "")")
        } catch {
            logger.error("Failed to complete reminder: \(error.localizedDescription)")
        }
    }

    private func startWatching() {
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.loadReminders(for: self.currentDate)
            }
        }
    }
}
