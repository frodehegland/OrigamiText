import SwiftUI
import AppKit
import ImagePlayground

/// The cartoon style applied to contact photos, chosen once in Settings so
/// every author in the community is drawn in the same visual language.
enum PortraitStyle: String, CaseIterable, Identifiable {
    case animation
    case illustration
    case sketch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .animation: "Animation — 3D cartoon"
        case .illustration: "Illustration — 2D cartoon"
        case .sketch: "Sketch — hand-drawn"
        }
    }

    var playgroundStyle: ImagePlaygroundStyle {
        switch self {
        case .animation: .animation
        case .illustration: .illustration
        case .sketch: .sketch
        }
    }

    static var current: PortraitStyle {
        PortraitStyle(rawValue: UserDefaults.standard.string(forKey: AppSettings.portraitStyleKey) ?? "")
            ?? .animation
    }
}

/// Portrait images for people: the photo the user provided, kept untouched,
/// and the cartoon portrait Image Playground drew from it. Both live as PNGs
/// in the app container, keyed by the person's canonical id, so a style
/// change can always re-draw every portrait from its original.
@MainActor @Observable
final class PersonPortraitStore {
    /// People whose cartoon is being drawn right now.
    private(set) var generatingIDs: Set<String> = []
    /// The most recent generation failure per person, for the form to show.
    private(set) var errors: [String: String] = [:]
    /// Progress of a style change re-drawing every portrait.
    private(set) var isRestyling = false
    private(set) var restyleDone = 0
    private(set) var restyleTotal = 0

    /// Bumped whenever an image file changes; reading it inside the image
    /// accessors is what lets views refresh without observing the cache.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [String: NSImage?] = [:]

    private let directory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = base.appendingPathComponent("PersonPortraits", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - Reading

    /// The cartoon portrait, if one has been generated.
    func portrait(for personID: String) -> NSImage? {
        image(at: portraitURL(for: personID))
    }

    /// The untouched photo the user provided.
    func original(for personID: String) -> NSImage? {
        image(at: originalURL(for: personID))
    }

    func hasOriginal(for personID: String) -> Bool {
        _ = revision
        return FileManager.default.fileExists(atPath: originalURL(for: personID).path)
    }

    // MARK: - The pipeline

    /// Adopts a photo for the person: stores it untouched, then asks Image
    /// Playground to draw the cartoon portrait in the user's chosen style.
    func adoptPhoto(_ photo: NSImage, for personID: String) {
        guard let data = pngData(from: photo) else {
            errors[personID] = "That image could not be read."
            return
        }
        try? data.write(to: originalURL(for: personID), options: .atomic)
        try? FileManager.default.removeItem(at: portraitURL(for: personID))
        invalidate(personID)
        generatePortrait(for: personID)
    }

    /// Draws (or re-draws) the cartoon from the stored original. The photo
    /// itself is never altered, so this can run again after a style change.
    func generatePortrait(for personID: String) {
        guard !generatingIDs.contains(personID),
              let original = original(for: personID)?
                  .cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        generatingIDs.insert(personID)
        errors[personID] = nil
        let style = PortraitStyle.current
        Task {
            do {
                let cartoon = try await Self.stylize(original, style: style)
                try savePortrait(cartoon, for: personID)
            } catch {
                errors[personID] = "Could not create the cartoon portrait: \(error.localizedDescription)"
            }
            generatingIDs.remove(personID)
            invalidate(personID)
        }
    }

    /// Forgets both images; the person shows as initials again.
    func removeImages(for personID: String) {
        try? FileManager.default.removeItem(at: originalURL(for: personID))
        try? FileManager.default.removeItem(at: portraitURL(for: personID))
        errors[personID] = nil
        invalidate(personID)
    }

    /// Re-draws every portrait from its stored original — the style setting
    /// changed, and consistency across the community is the point.
    func restyleAllPortraits() {
        guard !isRestyling else { return }
        let ids = allOriginalIDs()
        guard !ids.isEmpty else { return }
        isRestyling = true
        restyleDone = 0
        restyleTotal = ids.count
        let style = PortraitStyle.current
        Task {
            for id in ids {
                if let original = original(for: id)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    do {
                        let cartoon = try await Self.stylize(original, style: style)
                        try savePortrait(cartoon, for: id)
                        errors[id] = nil
                    } catch {
                        errors[id] = "Could not create the cartoon portrait: \(error.localizedDescription)"
                    }
                }
                restyleDone += 1
                invalidate(id)
            }
            isRestyling = false
        }
    }

    /// One call to Image Playground: the photo as the basis, edit-existing
    /// so the result stays as close to the person as the model allows.
    private static func stylize(_ photo: CGImage, style: PortraitStyle) async throws -> CGImage {
        let creator = try await ImageCreator()
        var options = ImagePlaygroundOptions()
        options.creationStrategy = .editExisting
        creator.options = options
        let concepts: [ImagePlaygroundConcept] = [.image(photo)]
        for try await created in creator.images(for: concepts,
                                                style: style.playgroundStyle,
                                                limit: 1) {
            return created.cgImage
        }
        throw ImageCreator.Error.creationFailed
    }

    // MARK: - Files

    private func originalURL(for personID: String) -> URL {
        directory.appendingPathComponent("\(sanitized(personID))-original.png")
    }

    private func portraitURL(for personID: String) -> URL {
        directory.appendingPathComponent("\(sanitized(personID))-portrait.png")
    }

    /// Person ids are ORCID iDs or UUID strings — already file-safe; this
    /// only guards against a stray separator.
    private func sanitized(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func allOriginalIDs() -> [String] {
        let suffix = "-original.png"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) }.map { String($0.dropLast(suffix.count)) }
    }

    private func image(at url: URL) -> NSImage? {
        _ = revision
        let key = url.lastPathComponent
        if let cached = cache[key] { return cached }
        let image = NSImage(contentsOf: url)
        cache[key] = image
        return image
    }

    private func invalidate(_ personID: String) {
        cache[originalURL(for: personID).lastPathComponent] = nil
        cache[portraitURL(for: personID).lastPathComponent] = nil
        revision += 1
    }

    private func savePortrait(_ cartoon: CGImage, for personID: String) throws {
        let rep = NSBitmapImageRep(cgImage: cartoon)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ImageCreator.Error.creationFailed
        }
        try data.write(to: portraitURL(for: personID), options: .atomic)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

/// A person's face wherever they appear: the cartoon portrait when one
/// exists, else the photo awaiting its cartoon, else initials in a circle.
struct PersonAvatarView: View {
    @Environment(AppModel.self) private var model
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(.quaternary)
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var avatarImage: NSImage? {
        guard let person = model.people.person(named: name) else { return nil }
        return model.portraits.portrait(for: person.id)
            ?? model.portraits.original(for: person.id)
    }

    private var initials: String {
        let words = name.split(separator: " ")
        let first = words.first?.first.map(String.init) ?? ""
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        let joined = (first + last).uppercased()
        return joined.isEmpty ? "?" : joined
    }
}
