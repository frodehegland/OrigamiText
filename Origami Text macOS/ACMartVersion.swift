import Foundation
import SwiftUI

/// Whether the reader's `acmart` — ACM's LaTeX class, part of their TeX
/// installation, not of this app — is the current release. ACM revises
/// the class several times a year (rights wording, metadata, accessibility
/// tags), and TAPS checks submissions against recent versions, so a paper
/// built with an old class can be sent back.
///
///  - Installed: read from the compiled paper's own log — "Document Class:
///    acmart 2025/08/27 v2.16 …" — the version TeX really used, wherever
///    the installation lives, without reaching outside the sandbox.
///  - Current: CTAN's package record (ctan.org/json/2.0/pkg/acmart),
///    asked at most once a day, only when a paper is formatted or the
///    reader asks.
@MainActor
enum ACMartVersion {

    struct Release: Codable, Equatable {
        var version: String
        /// yyyy-MM-dd.
        var date: String
    }

    private static let installedKey = "acmartInstalledRelease"
    private static let latestKey = "acmartLatestRelease"
    private static let latestCheckedKey = "acmartLatestChecked"

    /// The release the last ACM compile used, remembered.
    static var installed: Release? {
        get { decode(installedKey) }
        set { encode(newValue, installedKey) }
    }

    /// CTAN's current release, as last asked.
    static var latest: Release? { decode(latestKey) }

    /// Reads the release from a compile's `paper.log` and remembers it.
    @discardableResult
    static func recordInstalled(fromLogIn folder: URL) -> Release? {
        guard let log = try? String(contentsOf: folder.appendingPathComponent("paper.log"),
                                    encoding: .isoLatin1),
              let match = log.firstMatch(of: /Document Class: acmart (\d{4})\/(\d{2})\/(\d{2}) v([\d.]+)/)
        else { return nil }
        let release = Release(version: String(match.4),
                              date: "\(match.1)-\(match.2)-\(match.3)")
        installed = release
        return release
    }

    /// CTAN's current release — from the network at most once a day.
    static func refreshLatest(force: Bool = false) async -> Release? {
        if !force, let checked = UserDefaults.standard.object(forKey: latestCheckedKey) as? Date,
           Date.now.timeIntervalSince(checked) < 86_400, let known = latest {
            return known
        }
        guard let url = URL(string: "https://ctan.org/json/2.0/pkg/acmart") else { return latest }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("OrigamiText/1.0 (mailto:frode@hegland.com)",
                         forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["version"] as? [String: Any],
              let number = version["number"] as? String
        else { return latest }
        let release = Release(version: number, date: version["date"] as? String ?? "")
        encode(release, latestKey)
        UserDefaults.standard.set(Date.now, forKey: latestCheckedKey)
        return release
    }

    /// Whether `a` is an older version number than `b` ("2.16" < "2.20").
    static func isOlder(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// One line for the reader: what the last paper was built with,
    /// against CTAN's current, and what to do when it is behind.
    static func status() -> (text: String, outdated: Bool)? {
        let latest = latest
        if let supplied, let latest, !isOlder(supplied.version, than: latest.version) {
            var text = "acmart \(supplied.version) (\(readable(supplied.date))), the current release, is supplied with every ACM paper."
            if let installed, isOlder(installed.version, than: supplied.version) {
                text += " (The last paper was built before it was supplied, with \(installed.version).)"
            }
            return (text, false)
        }
        if let latest, let problem = supplyProblem {
            let used = installed.map { "acmart \($0.version) (\(readable($0.date))) was used last; " } ?? ""
            return ("\(used)\(latest.version) (\(readable(latest.date))) is current, but it could not be supplied: \(problem).", true)
        }
        guard let installed else {
            guard let latest else { return nil }
            return ("acmart \(latest.version) is current on CTAN; it will be supplied with the first ACM PDF.", false)
        }
        guard let latest else {
            return ("acmart \(installed.version) (\(readable(installed.date))) was used last.", false)
        }
        if isOlder(installed.version, than: latest.version) {
            return ("acmart \(installed.version) (\(readable(installed.date))) was used last, but \(latest.version) (\(readable(latest.date))) is current.", true)
        }
        return ("acmart \(installed.version) (\(readable(installed.date))) — up to date.", false)
    }

    private static func readable(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    fileprivate static func decode(_ key: String) -> Release? {
        UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
    }

    fileprivate static func encode(_ release: Release?, _ key: String) {
        if let release, let data = try? JSONEncoder().encode(release) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Supplying the current acmart with every paper

extension ACMartVersion {

    private static let suppliedKey = "acmartSuppliedRelease"

    /// The release Origami holds ready to supply, built from CTAN.
    static var supplied: Release? {
        get {
            guard let release = decode(suppliedKey),
                  FileManager.default.fileExists(
                    atPath: folder(for: release).appendingPathComponent("acmart.cls").path)
            else { return nil }
            return release
        }
        set { encode(newValue, suppliedKey) }
    }

    /// Why the last preparation failed, in words for the sheet.
    private(set) static var supplyProblem: String? {
        get { UserDefaults.standard.string(forKey: "acmartSupplyProblem") }
        set { UserDefaults.standard.set(newValue, forKey: "acmartSupplyProblem") }
    }

    private(set) static var isPreparing = false

    /// App Support/ACMart/<version>/ — acmart.cls, ACM-Reference-Format.bst
    /// and the source they came from.
    private static func folder(for release: Release) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ACMart", isDirectory: true)
            .appendingPathComponent(release.version, isDirectory: true)
    }

    /// Makes sure CTAN's current acmart is built and ready: fetched and
    /// built once per release, kept for every paper after. Needs TeX (to
    /// run docstrip), directly or through the current compile helper.
    @discardableResult
    static func prepareCurrent(force: Bool = false) async -> Release? {
        guard !isPreparing else { return supplied }
        isPreparing = true
        defer { isPreparing = false }
        guard let latest = await refreshLatest(force: force) else {
            return supplied
        }
        if let held = supplied, !isOlder(held.version, than: latest.version) {
            supplyProblem = nil
            return held
        }
        guard ACMLaTeX.isTeXAvailable else {
            supplyProblem = "TeX is needed to build acmart"
            return supplied
        }
        if case .unreachable = ACMLaTeX.tex, !ACMLaTeX.isHelperCurrent {
            supplyProblem = "the compile helper needs updating to build acmart"
            return supplied
        }
        guard let url = URL(string: "https://mirrors.ctan.org/macros/latex/contrib/acmart.zip"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let zip = try? ZipReader(data: data),
              let dtx = zip.entry("acmart/acmart.dtx"),
              let ins = zip.entry("acmart/acmart.ins"),
              let bst = zip.entry("acmart/ACM-Reference-Format.bst")
        else {
            supplyProblem = "CTAN's acmart could not be downloaded"
            return supplied
        }
        let target = folder(for: latest)
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try dtx.write(to: target.appendingPathComponent("acmart.dtx"))
            try ins.write(to: target.appendingPathComponent("acmart.ins"))
            try bst.write(to: target.appendingPathComponent("ACM-Reference-Format.bst"))
        } catch {
            supplyProblem = "acmart could not be saved: \(error.localizedDescription)"
            return supplied
        }
        guard await ACMLaTeX.buildACMartClass(in: target),
              let built = release(ofClassIn: target) else {
            supplyProblem = "acmart could not be built from CTAN's source"
            return supplied
        }
        supplied = built
        supplyProblem = nil
        return built
    }

    /// The release a built acmart.cls declares: "\ProvidesClass{acmart}
    /// [2026/08/16 v2.20 …]".
    static func release(ofClassIn folder: URL) -> Release? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("acmart.cls"),
                                     encoding: .utf8),
              let match = text.firstMatch(of: /ProvidesClass\{acmart\}\s*\[(\d{4})\/(\d{2})\/(\d{2}) v([\d.]+)/)
        else { return nil }
        return Release(version: String(match.4), date: "\(match.1)-\(match.2)-\(match.3)")
    }

    /// Copies the held acmart into a paper's folder, where TeX prefers it
    /// to the installed one. Not part of the ACM upload: TAPS typesets
    /// with its own copy. Returns the release supplied.
    @discardableResult
    static func supply(into paperFolder: URL) -> Release? {
        guard let release = supplied else { return nil }
        let source = folder(for: release)
        for name in ["acmart.cls", "ACM-Reference-Format.bst"] {
            let from = source.appendingPathComponent(name)
            let to = paperFolder.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: from, to: to)
        }
        return release
    }
}

/// The Import to Format sheet's line under "Also compile to PDF": the
/// installed acmart against CTAN's current, with a Check Now.
struct ACMartStatusLine: View {
    @State private var status: (text: String, outdated: Bool)?
    @State private var checking = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let status {
                Label(status.text, systemImage: status.outdated
                      ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(status.outdated ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The acmart version is checked when the PDF is made.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if helperOutdated {
                // A helper saved before it could build acmart: replacing
                // it is one save, in the same place.
                Button("Update Compile Helper\u{2026}") {
                    if ACMLaTeX.installHelper() { refresh(force: true) }
                }
                .controlSize(.small)
            }
            Button(checking ? "Checking\u{2026}" : "Check Now") {
                refresh(force: true)
            }
            .controlSize(.small)
            .disabled(checking)
            .help("Ask CTAN for the current acmart, and fetch and build it if Origami Text's copy is older")
        }
        .task { refresh(force: false) }
    }

    private var helperOutdated: Bool {
        if case .unreachable = ACMLaTeX.tex {
            return ACMLaTeX.isHelperInstalled && !ACMLaTeX.isHelperCurrent
        }
        return false
    }

    /// The status now, then after CTAN is asked and — when Origami's copy
    /// is behind — the current release is fetched and built.
    private func refresh(force: Bool) {
        checking = true
        status = ACMartVersion.status()
        Task {
            await ACMartVersion.prepareCurrent(force: force)
            status = ACMartVersion.status()
            checking = false
        }
    }
}
