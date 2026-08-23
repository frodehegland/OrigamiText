import SwiftUI
import EventKit

/// The one door to Apple Calendar the app keeps: a single event store,
/// asked once for permission, holding a year behind and a year ahead
/// as plain values. The Calendar view reads it whole; the Timeline and
/// the Journal borrow their days from it. Read-only throughout — the
/// events remain Calendar's own.
@MainActor
@Observable
final class CalendarFeed {
    static let shared = CalendarFeed()

    /// One event, carried as plain values so no view holds EventKit
    /// objects of its own.
    struct Item: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let calendarName: String
        let color: Color
    }

    private let store = EKEventStore()
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    /// Every event in the span, oldest first.
    private(set) var items: [Item] = []
    /// The dates the items cover.
    private(set) var span: ClosedRange<Date>?
    @ObservationIgnored private var begun = false

    /// Ask once, load, and stay current. Callers call freely — the
    /// Calendar view, the Timeline, the Journal — and only the first
    /// call does the work.
    func begin() {
        guard !begun else { return }
        begun = true
        Task {
            if status == .notDetermined {
                let granted = (try? await store.requestFullAccessToEvents()) ?? false
                status = granted ? .fullAccess
                                 : EKEventStore.authorizationStatus(for: .event)
            }
            reload()
            // Calendar's own changes arrive as they happen.
            let changes = NotificationCenter.default
                .notifications(named: .EKEventStoreChanged)
                .map { _ in () }
            for await _ in changes { reload() }
        }
    }

    /// Two years of the reader's calendars, as values. One EventKit
    /// fetch answers for at most four years; a year each way sits
    /// well inside that.
    private func reload() {
        guard status == .fullAccess else { return }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let from = calendar.date(byAdding: .year, value: -1, to: today),
              let to = calendar.date(byAdding: .year, value: 1, to: today) else { return }
        span = from...to
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        items = store.events(matching: predicate).compactMap { event in
            guard let start = event.startDate else { return nil }
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A recurring event repeats one identifier; the start date
            // tells its occurrences apart.
            return Item(
                id: (event.eventIdentifier ?? event.calendarItemIdentifier)
                    + "@\(start.timeIntervalSinceReferenceDate)",
                title: title.isEmpty ? "New Event" : title,
                start: start,
                end: event.endDate ?? start,
                isAllDay: event.isAllDay,
                location: event.location,
                calendarName: event.calendar?.title ?? "",
                color: (event.calendar?.cgColor).map { Color(cgColor: $0) } ?? .accentColor)
        }
        .sorted { $0.start < $1.start }
    }
}
