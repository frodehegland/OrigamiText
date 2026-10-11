import SwiftUI

/// A meeting series (or a correspondence) as its timeline: the people
/// across it with their share of the speaking, its meetings newest first
/// by the date each took place, and the terms that recur. Opening a
/// meeting opens it as any paper opens. The people and terms come from
/// the series analysis the Mac keeps beside the EPUBs
/// (Dialogue/<series>/series.json).
struct MeetingSeriesList: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var analysis: SeriesAnalysis?

    private var isLetters: Bool {
        model.dialogueRecords(inSeries: name).first?.dialogue?.kind == .letter
    }

    var body: some View {
        let all = model.dialogueRecords(inSeries: name)
        let meetings = all.filter { record in
            model.matchesFind(([record.title] + (record.dialogue?.participants ?? []).map(\.name))
                .joined(separator: " "))
        }
        List(selection: epubListSelection(model)) {
            if let people = analysis?.people, !people.isEmpty {
                Section {
                    ForEach(people.prefix(12), id: \.person) { person in
                        SeriesPersonRow(person: person, meetingCount: meetings.count)
                    }
                } header: {
                    Text("People")
                }
            }
            Section {
                ForEach(meetings) { record in
                    MeetingRow(record: record, isLetter: isLetters)
                }
            } header: {
                Text(isLetters ? "Letters" : "Meetings")
            }
            if let terms = analysis?.terms, !terms.isEmpty {
                Section {
                    Text(terms.prefix(24).map(\.term).joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    Text("Recurring")
                }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        // The analysis is brought current, then read — again whenever the
        // series gains a meeting.
        .task(id: all.map(\.id)) {
            model.refreshDialogueAnalyses()
            await load()
            try? await Task.sleep(for: .seconds(2))
            await load()
        }
    }

    private func load() async {
        guard let folder = model.index.folderURL else { return }
        let series = name
        analysis = await Task.detached(priority: .utility) { () -> SeriesAnalysis? in
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            return DialogueFiles.readSeries(series, in: folder)
        }.value
    }
}

/// One meeting on the timeline: its number and when it took place, its
/// title, and who spoke — bold until opened, as the Inbox's arrivals are.
private struct MeetingRow: View {
    @Environment(AppModel.self) private var model
    let record: EPUBRecord
    let isLetter: Bool

    private var when: String {
        guard let date = record.dialogue?.eventDate else { return record.dateISO ?? "" }
        let hasTime = (record.dialogue?.date?.count ?? 0) > 10
        return hasTime
            ? date.formatted(date: .abbreviated, time: .shortened)
            : date.formatted(date: .abbreviated, time: .omitted)
    }

    var body: some View {
        let info = record.dialogue
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 6) {
                if let number = info?.number {
                    Text("No. \(number)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(when)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Text(record.title)
                .font(.system(size: 14))
                .fontWeight(model.isUnopened(record) ? .bold : .regular)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
            let names = (info?.participants ?? []).map(\.name)
            if !names.isEmpty {
                Text(names.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .overlay(alignment: .trailing) {
            if model.epubListSelectionIDs.contains(record.id) {
                Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
            }
        }
        .tag(record.id)
        .contextMenu { EPUBPileMenu(record: record) }
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// One person across the series: how many of its meetings they spoke in,
/// and their share of everything said, as a quiet bar.
private struct SeriesPersonRow: View {
    let person: SeriesAnalysis.Person
    let meetingCount: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Text("\(person.meetings.count) of \(max(meetingCount, person.meetings.count)) · \(Int((person.share * 100).rounded()))%")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(person.name)
                    .font(.system(size: 13))
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: max(2, proxy.size.width * person.share))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(height: 3)
        }
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// Library ▸ Meetings (or Letters): the series, as Proceedings lists its
/// journals — each with how many meetings it holds — and, last, the ones
/// that name no series. A click opens the series: its timeline, people
/// and recurring terms.
struct DialogueSeriesListView: View {
    @Environment(AppModel.self) private var model
    let kind: DialogueInfo.Kind

    var body: some View {
        let series = model.dialogueSeries(kind).filter(model.matchesFind)
        let unlabeled = model.unlabeledDialogueCount(kind)
        if series.isEmpty && unlabeled == 0 {
            ContentUnavailableView {
                Label(kind == .transcript ? "No Meetings Yet" : "No Letters Yet",
                      systemImage: kind == .transcript ? "person.2" : "envelope")
            } description: {
                Text(kind == .transcript
                     ? "Meeting transcripts from Author arrive here, by series."
                     : "Correspondences from Author arrive here.")
            }
        } else {
            List {
                ForEach(series, id: \.self) { name in
                    row(name, count: model.dialogueRecords(inSeries: name).count,
                        icon: kind == .transcript ? "person.2" : "envelope")
                }
                if unlabeled > 0 {
                    row(AppModel.unlabeled(kind), count: unlabeled, icon: "tray")
                }
            }
        }
    }

    private func row(_ name: String, count: Int, icon: String) -> some View {
        Button {
            model.sidebarSelection = .epubPublication(name)
        } label: {
            HStack {
                Label(name == AppModel.unlabeled(kind) ? "Unlabeled" : name, systemImage: icon)
                Spacer()
                Text("\(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
    }
}

