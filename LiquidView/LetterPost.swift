import SwiftUI
import AppKit

/// The letter post: how published letters travel between community
/// members without a server. Carriers are pluggable; the first is Apple
/// Mail, scripted through Apple events — the user's existing accounts do
/// the carrying, letters queue in Mail's own outbox when offline, and no
/// password or account detail ever touches Origami Text. macOS asks once
/// for permission to control Mail.
///
/// Sending: a published letter goes as one message per letter, the
/// .origamitext file attached, To: filled from its "for the attention
/// of" names, everyone else in the People directory CC'd.
///
/// Receiving: on the schedule, Mail is asked for recent messages
/// carrying .origamitext attachments and saves each new one straight
/// into the community folder — Mail does the writing, so the folder's
/// read-only scope in this app is never an obstacle — and the folder
/// watcher and index take it from there. The rest of the app never
/// knows mail exists.

extension AppSettings {
    static let letterPostCarrierKey = "letterPostCarrier"
    static let letterPostSendTimingKey = "letterPostSendTiming"
    /// Minutes from midnight for the daily send.
    static let letterPostSendTimeKey = "letterPostSendTime"
    /// Minutes between checks for arriving letters; 0 means only manually.
    static let letterPostReceiveIntervalKey = "letterPostReceiveInterval"
    static let letterPostPendingKey = "letterPostPendingSends"
    static let letterPostLastReceiveKey = "letterPostLastReceive"
    static let letterPostLastDailySendKey = "letterPostLastDailySend"
}

/// Who carries the letters. More carriers may follow — direct SMTP/IMAP
/// for members without Apple Mail, perhaps others.
enum LetterCarrier: String, CaseIterable, Identifiable {
    case off = "Off"
    case appleMail = "Apple Mail"
    var id: String { rawValue }

    static var current: LetterCarrier {
        LetterCarrier(rawValue: UserDefaults.standard.string(forKey: AppSettings.letterPostCarrierKey) ?? "")
            ?? .off
    }
}

/// When published letters are sent.
enum LetterSendTiming: String, CaseIterable, Identifiable {
    case immediately = "When published"
    case daily = "Daily at a set time"
    case manually = "Only manually"
    var id: String { rawValue }

    static var current: LetterSendTiming {
        LetterSendTiming(rawValue: UserDefaults.standard.string(forKey: AppSettings.letterPostSendTimingKey) ?? "")
            ?? .immediately
    }
}

// MARK: - The Apple Mail carrier

/// Apple Mail, scripted. Each call builds one AppleScript and runs it;
/// the first ever run makes macOS ask the user to allow Origami Text to
/// control Mail.
@MainActor
enum MailCarrier {

    struct CarrierError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// One letter, one message: subject, a short covering line, the
    /// .origamitext file attached, and Mail sends it — visibly in the
    /// user's Sent mailbox afterwards, like any letter they wrote.
    static func send(subject: String, body: String, to: [String], cc: [String],
                     attachment: URL) throws {
        guard !to.isEmpty else {
            throw CarrierError(message: "No community member has an email address yet — add them to contact records.")
        }
        var lines: [String] = []
        lines.append("tell application \"Mail\"")
        lines.append("set theMessage to make new outgoing message with properties {subject:\(quoted(subject)), content:\(quoted(body + "\n\n")), visible:false}")
        lines.append("tell theMessage")
        for address in to {
            lines.append("make new to recipient at end of to recipients with properties {address:\(quoted(address))}")
        }
        for address in cc {
            lines.append("make new cc recipient at end of cc recipients with properties {address:\(quoted(address))}")
        }
        lines.append("end tell")
        lines.append("tell content of theMessage")
        lines.append("make new attachment with properties {file name:(POSIX file \(quoted(attachment.path)))} at after the last paragraph")
        lines.append("end tell")
        // Mail needs a beat to take the attachment in before sending.
        lines.append("delay 1")
        lines.append("send theMessage")
        lines.append("end tell")
        _ = try run(script: lines.joined(separator: "\n"))
    }

    /// Asks Mail for recent inbox messages carrying .origamitext
    /// attachments and saves each one the folder doesn't already hold —
    /// Mail performs the writes. Returns the saved file names.
    static func receiveLetters(into folder: URL, existingNames: [String],
                               lookBackDays: Int) throws -> [String] {
        let existingList = existingNames.map(quoted).joined(separator: ", ")
        let script = """
        set savedNames to {}
        set existingNames to {\(existingList)}
        set cutoffDate to (current date) - (\(max(1, lookBackDays)) * days)
        tell application "Mail"
            set recentMessages to (every message of inbox whose date received > cutoffDate)
            repeat with theMessage in recentMessages
                repeat with theAttachment in mail attachments of theMessage
                    set attachmentName to name of theAttachment
                    if attachmentName ends with ".origamitext" and attachmentName is not in existingNames then
                        try
                            save theAttachment in POSIX file (\(quoted(folder.path + "/")) & attachmentName)
                            set end of savedNames to attachmentName
                            set end of existingNames to attachmentName
                        end try
                    end if
                end repeat
            end repeat
        end tell
        set AppleScript's text item delimiters to linefeed
        return savedNames as text
        """
        let result = try run(script: script)
        return result.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private static func run(script source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw CarrierError(message: "The Mail script could not be built.")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "Mail did not answer."
            let number = errorInfo[NSAppleScript.errorNumber] as? Int
            if number == -1743 {
                throw CarrierError(message: "macOS declined: allow Origami Text to control Mail in System Settings → Privacy & Security → Automation.")
            }
            throw CarrierError(message: message)
        }
        return result.stringValue ?? ""
    }

    /// AppleScript string literal: quoted, backslashes and quotes escaped.
    private static func quoted(_ string: String) -> String {
        "\"" + string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

// MARK: - The store

/// Runs the letter post: remembers which published letters still await
/// sending, sends them on the chosen schedule, and checks for arriving
/// letters. Lives on AppModel like the other stores.
@MainActor @Observable
final class LetterPostStore {
    private weak var model: AppModel?
    private(set) var isWorking = false
    /// What the last send and the last check came to, for Settings.
    private(set) var lastSendReport = ""
    private(set) var lastCheckReport = ""
    private(set) var pendingSendIDs: [String] =
        UserDefaults.standard.stringArray(forKey: AppSettings.letterPostPendingKey) ?? []

    /// How far back the inbox is searched. Generous, because skipping
    /// already-held letters makes re-reading cheap.
    private let lookBackDays = 14

    func attach(_ model: AppModel) {
        guard self.model == nil else { return }
        self.model = model
        startScheduler()
    }

    // MARK: Sending

    /// Every publish lands here: the letter joins the queue, and leaves
    /// at once, at the daily hour, or when Send Now is clicked.
    func notePublished(_ doc: LiquidDoc) {
        guard LetterCarrier.current == .appleMail else { return }
        if !pendingSendIDs.contains(doc.id) {
            pendingSendIDs.append(doc.id)
            persistPending()
        }
        if LetterSendTiming.current == .immediately {
            sendPending()
        }
    }

    /// Sends every queued letter that still exists in Published. A letter
    /// leaves the queue only once Mail accepts it, so a failure simply
    /// waits for the next pass.
    func sendPending() {
        guard LetterCarrier.current == .appleMail, !isWorking, let model else { return }
        guard !pendingSendIDs.isEmpty else {
            lastSendReport = "Nothing waiting to send."
            return
        }
        isWorking = true
        defer { isWorking = false }
        var sent = 0
        var failure: String?
        for id in pendingSendIDs {
            guard let doc = model.drafts.published.first(where: { $0.id == id }) else {
                // Gone from Published — nothing to send anymore.
                pendingSendIDs.removeAll { $0 == id }
                continue
            }
            let file = model.drafts.publishedFolder
                .appendingPathComponent(id).appendingPathExtension(LiquidDoc.fileExtension)
            let (to, cc) = recipients(for: doc)
            do {
                try MailCarrier.send(
                    subject: "Origami Letter: \(doc.title)",
                    body: "A letter from \(doc.displayAuthor): “\(doc.title)”. The attached file opens in Origami Text; its address is [\(doc.id)].",
                    to: to, cc: cc, attachment: file)
                pendingSendIDs.removeAll { $0 == id }
                sent += 1
            } catch {
                failure = error.localizedDescription
            }
        }
        persistPending()
        let when = Date.now.formatted(date: .omitted, time: .shortened)
        lastSendReport = if let failure {
            "Sent \(sent), then: \(failure)"
        } else {
            sent == 0 ? "Nothing waiting to send." : "Sent \(sent) \(sent == 1 ? "letter" : "letters") at \(when)."
        }
        if sent > 0 { model.showNote(lastSendReport) }
    }

    /// To: the people the letter is for the attention of; CC: the rest of
    /// the People directory — everyone with an email address except the
    /// author themselves. With no attention names, everyone is To.
    private func recipients(for doc: LiquidDoc) -> (to: [String], cc: [String]) {
        guard let model else { return ([], []) }
        let attention = Set(doc.attention.map { $0.lowercased() })
        var to: [String] = []
        var cc: [String] = []
        for person in model.people.people {
            guard let email = person.emails.first(where: { !$0.isEmpty }) else { continue }
            guard !model.authorIdentity.matches(author: person.displayName) else { continue }
            if attention.contains(person.displayName.lowercased()) {
                to.append(email)
            } else {
                cc.append(email)
            }
        }
        if to.isEmpty {
            to = cc
            cc = []
        }
        return (to, cc)
    }

    // MARK: Receiving

    /// Asks Mail for arriving letters and lets it file them into the
    /// community folder; the folder watcher picks them up from there.
    func checkForLetters() {
        guard LetterCarrier.current == .appleMail, !isWorking, let model else { return }
        guard let folder = model.index.folderURL else {
            lastCheckReport = "Choose a community folder first."
            return
        }
        isWorking = true
        defer { isWorking = false }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        do {
            let saved = try MailCarrier.receiveLetters(into: folder,
                                                       existingNames: existing,
                                                       lookBackDays: lookBackDays)
            let when = Date.now.formatted(date: .omitted, time: .shortened)
            lastCheckReport = saved.isEmpty
                ? "No new letters at \(when)."
                : "\(saved.count) new \(saved.count == 1 ? "letter" : "letters") at \(when)."
            if !saved.isEmpty {
                model.showNote(lastCheckReport)
            }
            UserDefaults.standard.set(Date.now, forKey: AppSettings.letterPostLastReceiveKey)
        } catch {
            lastCheckReport = error.localizedDescription
        }
    }

    // MARK: The schedule

    /// A minute-by-minute pulse while the app runs: the daily send fires
    /// once when its time has passed, and checks run whenever the chosen
    /// interval has elapsed. Nothing runs while the carrier is off.
    private func startScheduler() {
        Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self.tick()
            }
        }
    }

    private func tick() {
        guard LetterCarrier.current == .appleMail else { return }
        let defaults = UserDefaults.standard

        if LetterSendTiming.current == .daily, !pendingSendIDs.isEmpty {
            let minutes = defaults.object(forKey: AppSettings.letterPostSendTimeKey) as? Int ?? 17 * 60
            let now = Date.now
            let calendar = Calendar.current
            let nowMinutes = calendar.component(.hour, from: now) * 60
                + calendar.component(.minute, from: now)
            let lastDay = defaults.object(forKey: AppSettings.letterPostLastDailySendKey) as? Date
            let firedToday = lastDay.map { calendar.isDate($0, inSameDayAs: now) } ?? false
            if nowMinutes >= minutes, !firedToday {
                defaults.set(now, forKey: AppSettings.letterPostLastDailySendKey)
                sendPending()
            }
        }

        let interval = defaults.object(forKey: AppSettings.letterPostReceiveIntervalKey) as? Int ?? 30
        if interval > 0 {
            let last = defaults.object(forKey: AppSettings.letterPostLastReceiveKey) as? Date ?? .distantPast
            if Date.now.timeIntervalSince(last) >= Double(interval) * 60 {
                checkForLetters()
            }
        }
    }

    private func persistPending() {
        UserDefaults.standard.set(pendingSendIDs, forKey: AppSettings.letterPostPendingKey)
    }
}

// MARK: - Settings

/// Settings → Sharing: the carrier, when letters go, how often to look
/// for arriving ones, and the levers to do either right now.
struct SharingSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.letterPostCarrierKey) private var carrier = LetterCarrier.off.rawValue
    @AppStorage(AppSettings.letterPostSendTimingKey) private var sendTiming = LetterSendTiming.immediately.rawValue
    @AppStorage(AppSettings.letterPostSendTimeKey) private var sendTimeMinutes = 17 * 60
    @AppStorage(AppSettings.letterPostReceiveIntervalKey) private var receiveInterval = 30

    private var mailChosen: Bool { carrier == LetterCarrier.appleMail.rawValue }

    var body: some View {
        Form {
            Section {
                Picker("Share letters through", selection: $carrier) {
                    ForEach(LetterCarrier.allCases) { choice in
                        Text(choice.rawValue).tag(choice.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Apple Mail carries the letters: your existing mail accounts do the sending and receiving, and no password or account detail ever touches Origami Text. The first use asks your permission for Origami Text to control Mail. Other services may follow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if mailChosen {
                Section("Sending") {
                    Picker("Send published letters", selection: $sendTiming) {
                        ForEach(LetterSendTiming.allCases) { timing in
                            Text(timing.rawValue).tag(timing.rawValue)
                        }
                    }
                    if sendTiming == LetterSendTiming.daily.rawValue {
                        DatePicker("Send at", selection: sendTimeBinding,
                                   displayedComponents: .hourAndMinute)
                    }
                    LabeledContent("Waiting to send") {
                        Text("\(model.letterPost.pendingSendIDs.count)")
                    }
                    HStack {
                        Button("Send Now") { model.letterPost.sendPending() }
                            .disabled(model.letterPost.pendingSendIDs.isEmpty || model.letterPost.isWorking)
                        if !model.letterPost.lastSendReport.isEmpty {
                            Text(model.letterPost.lastSendReport)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Picker("Check for arriving letters", selection: $receiveInterval) {
                        Text("Every 15 minutes").tag(15)
                        Text("Every 30 minutes").tag(30)
                        Text("Every hour").tag(60)
                        Text("Only manually").tag(0)
                    }
                    HStack {
                        Button("Check Now") { model.letterPost.checkForLetters() }
                            .disabled(model.letterPost.isWorking)
                        if !model.letterPost.lastCheckReport.isEmpty {
                            Text(model.letterPost.lastCheckReport)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Receiving")
                } footer: {
                    Text("Each published letter goes as one message with the .origamitext file attached — To: the people it is for the attention of, CC: everyone else in People with an email address. Arriving letters are filed straight into the community folder. Both happen only while Origami Text is running; letters sent while you are offline wait in Mail's outbox.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// The daily hour as a date, stored as minutes from midnight.
    private var sendTimeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: sendTimeMinutes / 60,
                                      minute: sendTimeMinutes % 60,
                                      second: 0, of: .now) ?? .now
            },
            set: { date in
                sendTimeMinutes = Calendar.current.component(.hour, from: date) * 60
                    + Calendar.current.component(.minute, from: date)
            }
        )
    }
}
