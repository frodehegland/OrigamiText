import SwiftUI
import EventKit

/// Apple Calendar, read in place: every event on every calendar the
/// system knows, listed by day — the past year behind, the year ahead
/// in front — each with its hour, its calendar's colour and name, and
/// its place. The events come through the app's one CalendarFeed; the
/// system asks the reader's permission before the first look.
struct CalendarEventsView: View {
    private var feed = CalendarFeed.shared

    /// One day's events, gathered under its heading.
    private struct Day: Identifiable {
        let date: Date
        let events: [CalendarFeed.Item]
        var id: Date { date }
    }

    private var days: [Day] {
        let calendar = Calendar.current
        var byDay: [Date: [CalendarFeed.Item]] = [:]
        for item in feed.items {
            byDay[calendar.startOfDay(for: item.start), default: []].append(item)
        }
        return byDay.keys.sorted().map { date in
            Day(date: date, events: byDay[date, default: []].sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
                return $0.start < $1.start
            })
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.events) { item in
                                eventRow(item, past: isPast(day.date))
                            }
                        } header: {
                            dayHeader(day.date)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                headerBar(proxy)
            }
            // The list opens on today, not on last year's first morning.
            .onChange(of: days.isEmpty) {
                scrollToToday(proxy, animated: false)
            }
        }
        .background(AppGreys.page)
        .overlay { unavailableOverlay }
        .task { feed.begin() }
        .navigationTitle("Calendar")
    }

    // MARK: - The list

    private func headerBar(_ proxy: ScrollViewProxy) -> some View {
        HStack {
            Text(spanText)
                .font(.callout)
                .foregroundStyle(AppGreys.quietText)
            Spacer()
            Button("Today") { scrollToToday(proxy, animated: true) }
                .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(AppGreys.page)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var spanText: String {
        guard feed.status == .fullAccess, let span = feed.span else { return "" }
        let count = feed.items.count
        let events = count == 1 ? "1 event" : "\(count) events"
        return events + " · "
            + span.lowerBound.formatted(date: .abbreviated, time: .omitted)
            + " – "
            + span.upperBound.formatted(date: .abbreviated, time: .omitted)
    }

    private func dayHeader(_ date: Date) -> some View {
        Text(headingText(date))
            .font(.headline)
            .foregroundStyle(isPast(date) ? AppGreys.quietText : AppGreys.heading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .background(AppGreys.page)
            .id(date)
    }

    private func headingText(_ date: Date) -> String {
        let formatted = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        return Calendar.current.isDateInToday(date) ? "Today — " + formatted : formatted
    }

    private func eventRow(_ item: CalendarFeed.Item, past: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(item.isAllDay ? "all day"
                 : item.start.formatted(date: .omitted, time: .shortened))
                .font(.callout.monospacedDigit())
                .foregroundStyle(AppGreys.quietText)
                .frame(width: 70, alignment: .trailing)
            // The calendar's colour, as Calendar itself wears it.
            Circle()
                .fill(item.color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3 }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .foregroundStyle(past ? AppGreys.quietText : AppGreys.text)
                if let detail = detailText(item) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppGreys.quietText)
                }
            }
            Spacer(minLength: 12)
            Text(item.calendarName)
                .font(.caption)
                .foregroundStyle(AppGreys.quietText)
        }
        .padding(.vertical, 5)
    }

    /// The quiet second line: where the event ends when that is not
    /// obvious, and where it happens when it says.
    private func detailText(_ item: CalendarFeed.Item) -> String? {
        var parts: [String] = []
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: item.start)
        // An all-day event's end rests on the following midnight; step
        // one second back so a one-day event names no second day.
        let lastMoment = item.isAllDay ? item.end.addingTimeInterval(-1) : item.end
        let lastDay = calendar.startOfDay(for: lastMoment)
        if lastDay > startDay {
            parts.append("to " + lastDay.formatted(date: .abbreviated, time: .omitted))
        } else if !item.isAllDay, item.end > item.start {
            parts.append("to " + item.end.formatted(date: .omitted, time: .shortened))
        }
        if let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines),
           !location.isEmpty {
            parts.append(location)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder private var unavailableOverlay: some View {
        if feed.status == .fullAccess {
            if days.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "calendar",
                    description: Text("Nothing stands on your calendars from a year past to a year ahead."))
                .allowsHitTesting(false)
            }
        } else if feed.status != .notDetermined {
            ContentUnavailableView {
                Label("Calendar Access Needed", systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text("Knowledge Space reads your events from Apple Calendar. Grant access under Privacy & Security ▸ Calendars.")
            } actions: {
                #if os(macOS)
                Button("Open System Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                        NSWorkspace.shared.open(url)
                    }
                }
                #endif
            }
        }
    }

    /// A day gone by reads quieter — over, not in play.
    private func isPast(_ day: Date) -> Bool {
        day < Calendar.current.startOfDay(for: Date())
    }

    /// Today's heading to the top — or the nearest day ahead, when
    /// today itself is empty.
    private func scrollToToday(_ proxy: ScrollViewProxy, animated: Bool) {
        let today = Calendar.current.startOfDay(for: Date())
        guard let anchor = days.first(where: { $0.date >= today })?.date
                ?? days.last?.date else { return }
        if animated {
            withAnimation { proxy.scrollTo(anchor, anchor: .top) }
        } else {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}

extension CalendarEventsView {
    @MainActor static let module = LibraryViewModule(
        id: "calendar-events",
        name: "Calendar",
        systemImage: "calendar",
        makeContent: { AnyView(DocumentListView()) },
        makeDetail: { _ in AnyView(CalendarEventsView()) },
        hidesDocumentList: true
    )
}
