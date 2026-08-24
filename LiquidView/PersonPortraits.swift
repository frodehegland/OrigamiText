import SwiftUI
import AppKit
import CoreImage
import ImagePlayground
import Vision

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
            ?? .illustration
    }

    /// The one description every portrait is drawn from, so the whole
    /// community is framed the same way. User-editable in Settings;
    /// an emptied field falls back to the default.
    static let defaultConcept = "Headshot, professional portrait for publication of this academic person with a neutral grey background"

    static var concept: String {
        let stored = UserDefaults.standard.string(forKey: AppSettings.portraitPromptKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultConcept : stored
    }

    /// The description bot portraits are drawn from. Bots are always
    /// illustration, monochrome, on dark grey — a visual language of
    /// their own, so a stand-in is never mistaken for a community member.
    static let botConcept = "Monochrome illustration headshot, black and white professional portrait for publication of this person, against a dark grey background"
}

/// Portrait images for people: the photo the user provided, kept untouched,
/// and the cartoon portrait Image Playground drew from it. Both live as PNGs
/// in the app container, keyed by the person's localID — stable even as an
/// ORCID is adopted - so a style change can always re-draw every portrait
/// from its original.
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

    /// Whether this Mac lets the app draw cartoons without UI. Some systems
    /// support Image Playground's sheet but refuse programmatic creation —
    /// there the form falls back to the system sheet, seeded with the photo.
    private(set) var supportsAutomaticGeneration = true

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
        Task {
            do {
                _ = try await ImageCreator()
                supportsAutomaticGeneration = true
            } catch {
                supportsAutomaticGeneration = false
            }
        }
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

    /// The photo as generation sees it: re-framed around the head with even
    /// margin, so every cartoon comes out with the same passport-photo
    /// framing no matter how the photo was shot. Falls back to the photo
    /// itself when no face is found.
    func framedOriginal(for personID: String) -> NSImage? {
        _ = revision
        let key = "framed-" + sanitized(personID)
        if let cached = cache[key] { return cached }
        var framed: NSImage?
        if let photo = original(for: personID)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil),
           let framedCG = Self.headshotFrame(photo) {
            framed = NSImage(cgImage: framedCG, size: .zero)
        }
        cache[key] = framed
        return framed
    }

    // MARK: - The pipeline

    /// Adopts a photo for the person: stores it untouched. Drawing the
    /// cartoon is a separate step — the form decides whether that happens
    /// instantly or on request.
    func adoptPhoto(_ photo: NSImage, for personID: String) {
        guard let data = pngData(from: photo) else {
            errors[personID] = "That image could not be read."
            return
        }
        try? data.write(to: originalURL(for: personID), options: .atomic)
        try? FileManager.default.removeItem(at: portraitURL(for: personID))
        invalidate(personID)
        // Warm the head-framed rendition so processing starts without a pause.
        _ = framedOriginal(for: personID)
    }

    /// Adopts a cartoon the user accepted in the system Image Playground
    /// sheet — the fallback path when automatic creation is refused.
    func adoptSheetPortrait(from url: URL, for personID: String) {
        guard let image = NSImage(contentsOf: url), let data = pngData(from: image) else {
            errors[personID] = "The generated image could not be read."
            return
        }
        try? data.write(to: portraitURL(for: personID), options: .atomic)
        try? FileManager.default.removeItem(at: url)
        errors[personID] = nil
        invalidate(personID)
    }

    /// Draws (or re-draws) the cartoon from the stored original. The photo
    /// itself is never altered, so this can run again after a style change.
    func generatePortrait(for personID: String) {
        guard !generatingIDs.contains(personID),
              let original = generationSource(for: personID) else { return }
        generatingIDs.insert(personID)
        errors[personID] = nil
        let style = PortraitStyle.current
        Task {
            do {
                let cartoon = try await Self.stylize(original, style: style.playgroundStyle,
                                                     concept: PortraitStyle.concept)
                try savePortrait(cartoon, for: personID)
            } catch ImageCreator.Error.notSupported {
                // This Mac refuses headless creation; the form offers the
                // system sheet instead, so this is not an error to show.
                supportsAutomaticGeneration = false
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
        guard !isRestyling, supportsAutomaticGeneration else { return }
        let ids = allOriginalIDs()
        guard !ids.isEmpty else { return }
        isRestyling = true
        restyleDone = 0
        restyleTotal = ids.count
        let style = PortraitStyle.current
        Task {
            for id in ids {
                if let original = generationSource(for: id) {
                    do {
                        let cartoon = try await Self.stylize(original, style: style.playgroundStyle,
                                                             concept: PortraitStyle.concept)
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

    /// The generated cartoon follows the composition of its source, so the
    /// head-with-margin framing is imposed on the photo before generation:
    /// find the face, crop a square around the head, pad with neutral grey.
    private static func headshotFrame(_ photo: CGImage) -> CGImage? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: photo, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results, !faces.isEmpty else { return nil }
        // The largest face is the sitter; smaller ones are background.
        guard let face = faces.max(by: {
            $0.boundingBox.width * $0.boundingBox.height
                < $1.boundingBox.width * $1.boundingBox.height
        }) else { return nil }

        // Everything below works in CGContext coordinates (origin bottom
        // left), which is also how Vision reports its normalized box.
        let width = CGFloat(photo.width)
        let height = CGFloat(photo.height)
        let faceRect = CGRect(x: face.boundingBox.minX * width,
                              y: face.boundingBox.minY * height,
                              width: face.boundingBox.width * width,
                              height: face.boundingBox.height * height)
        // Vision's box covers eyebrows to chin; the head with hair sits
        // higher and needs air around it. 2.6× face height with the centre
        // lifted gives full head plus even margin.
        let side = faceRect.height * 2.6
        let center = CGPoint(x: faceRect.midX,
                             y: faceRect.midY + faceRect.height * 0.15)
        let crop = CGRect(x: center.x - side / 2,
                          y: center.y - side / 2,
                          width: side, height: side)

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: Int(side.rounded()),
                                      height: Int(side.rounded()),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Where the crop reaches past the photo, neutral grey continues the
        // backdrop the portrait prompt asks for.
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(photo, in: CGRect(x: -crop.minX, y: -crop.minY,
                                       width: width, height: height))
        return context.makeImage()
    }

    /// What generation starts from: the head-framed rendition when a face
    /// was found, else the photo as provided.
    private func generationSource(for personID: String) -> CGImage? {
        (framedOriginal(for: personID) ?? original(for: personID))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// One call to Image Playground: the photo as the basis, edit-existing
    /// so the result stays as close to the person as the model allows.
    private static func stylize(_ photo: CGImage, style: ImagePlaygroundStyle,
                                concept: String) async throws -> CGImage {
        let creator = try await ImageCreator()
        let concepts: [ImagePlaygroundConcept] = [.image(photo), .text(concept)]
        // Edit-existing keeps the result closest to the person, but the
        // strategy option only exists from macOS 27 (the options type
        // itself arrived at 26.4); macOS 26 generates from the photo
        // without it and simply strays a little further.
        if #available(macOS 27.0, *) {
            if let result = try await stylizeEditExisting(creator: creator,
                                                          concepts: concepts,
                                                          style: style) {
                return result
            }
        } else {
            for try await created in creator.images(for: concepts,
                                                    style: style,
                                                    limit: 1) {
                return created.cgImage
            }
        }
        throw ImageCreator.Error.creationFailed
    }

    @available(macOS 27.0, *)
    private static func stylizeEditExisting(creator: ImageCreator,
                                            concepts: [ImagePlaygroundConcept],
                                            style: ImagePlaygroundStyle) async throws -> CGImage? {
        var options = ImagePlaygroundOptions()
        options.creationStrategy = .editExisting
        for try await created in creator.images(for: concepts,
                                                style: style,
                                                options: options,
                                                limit: 1) {
            return created.cgImage
        }
        return nil
    }

    // MARK: - Bot portraits

    /// Draws a bot's portrait from its stored photo: always illustration,
    /// whatever the community style, and finished monochrome on dark grey.
    /// The concept asks for that language; the finish guarantees it.
    /// Returns false when nothing was drawn — the photograph may have been
    /// refused ("unable to use that image"), and the caller can offer the
    /// search again; the refusal reason waits in `errors`.
    @discardableResult
    func generateBotPortrait(for personID: String) async -> Bool {
        guard !generatingIDs.contains(personID),
              let original = generationSource(for: personID) else { return false }
        generatingIDs.insert(personID)
        errors[personID] = nil
        var drawnAndSaved = false
        do {
            let drawn = try await Self.stylize(original, style: .illustration,
                                               concept: PortraitStyle.botConcept)
            try savePortrait(Self.monochromeOnDarkGrey(drawn), for: personID)
            drawnAndSaved = true
        } catch ImageCreator.Error.notSupported {
            // This Mac refuses headless creation; the caller offers the
            // system sheet instead, so this is not an error to show.
            supportsAutomaticGeneration = false
        } catch ImageCreator.Error.unsupportedInputImage {
            errors[personID] = "Image Playground could not use that photograph — choose another."
        } catch ImageCreator.Error.faceInImageTooSmall {
            errors[personID] = "The face in that photograph is too small to work from — choose another."
        } catch {
            errors[personID] = "Could not create the portrait: \(error.localizedDescription)"
        }
        generatingIDs.remove(personID)
        invalidate(personID)
        return drawnAndSaved
    }

    /// Adopts a bot portrait accepted in the system Image Playground sheet
    /// — the fallback path — applying the bot finish before saving.
    func adoptBotSheetPortrait(from url: URL, for personID: String) {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            errors[personID] = "The generated image could not be read."
            return
        }
        try? savePortrait(Self.monochromeOnDarkGrey(cg), for: personID)
        try? FileManager.default.removeItem(at: url)
        errors[personID] = nil
        invalidate(personID)
    }

    /// The bot finish: everything monochrome, and the subject lifted out
    /// and set against dark grey. When no subject mask can be made, the
    /// desaturated image stands as drawn.
    nonisolated static func monochromeOnDarkGrey(_ image: CGImage) -> CGImage {
        let source = CIImage(cgImage: image)
        let mono = source.applyingFilter("CIPhotoEffectMono")
        var finished = mono
        if let mask = subjectMask(of: image) {
            let grey = CIImage(color: CIColor(red: 0.16, green: 0.16, blue: 0.17))
                .cropped(to: source.extent)
            finished = mono.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: grey,
                kCIInputMaskImageKey: mask,
            ])
        }
        return CIContext().createCGImage(finished, from: source.extent) ?? image
    }

    /// The image's subject as a soft mask, via Vision's foreground
    /// segmentation; nil when nothing lifts cleanly.
    private nonisolated static func subjectMask(of image: CGImage) -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        guard let result = request.results?.first,
              let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances,
                                                                  from: handler)
        else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }

    /// A photo made monochrome before adoption, so generation works in
    /// the bot's visual language from the start.
    nonisolated static func desaturated(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let mono = CIImage(cgImage: cg).applyingFilter("CIPhotoEffectMono")
        guard let out = CIContext().createCGImage(mono, from: mono.extent) else { return image }
        return NSImage(cgImage: out, size: .zero)
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
        cache["framed-" + sanitized(personID)] = nil
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

/// The floating card a byline name answers on hover: who the person is —
/// portrait, affiliation, identity — and their letters in the library,
/// newest first, each openable.
struct PersonHoverCard: View {
    @Environment(AppModel.self) private var model
    let person: Person
    /// Called when a letter is opened, so the presenter can dismiss.
    var onNavigate: (() -> Void)? = nil

    private static let letterLimit = 6

    var body: some View {
        let letters = model.index.byID.values
            .filter { $0.doc.creditedAuthor.caseInsensitiveCompare(person.displayName) == .orderedSame }
            .sorted { $0.doc.listedDate > $1.doc.listedDate }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                PersonAvatarView(name: person.displayName, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName)
                        .font(.headline)
                    if !person.affiliation.isEmpty {
                        Text(person.affiliation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if !person.orcid.isEmpty {
                        Text(person.orcid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !person.emails.isEmpty {
                Text(person.emails.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let publicProfile = person.publicProfile, !publicProfile.isEmpty {
                Text(publicProfile)
                    .font(.caption)
                    .lineLimit(4)
            }
            if let personality = model.personality(for: person.displayName) {
                Divider()
                Label("Personality", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Text(personality)
                    .font(.caption)
                    .lineLimit(5)
                    .help("Built on this Mac from their letters — nothing leaves it")
            }
            Divider()
            Text("Letters")
                .font(.subheadline.weight(.semibold))
            if letters.isEmpty {
                Text("No letters in the library yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(letters.prefix(Self.letterLimit)) { entry in
                    Button {
                        model.openInLibrary(entry.doc)
                        onNavigate?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: entry.doc.isSidecar ? "doc.richtext" : "doc.text")
                                .foregroundStyle(.secondary)
                            Text(entry.doc.title)
                                .lineLimit(1)
                            Spacer()
                            Text(entry.doc.listedDateText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if letters.count > Self.letterLimit {
                    Text("and \(letters.count - Self.letterLimit) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

/// A person's face wherever they appear: the cartoon portrait when one
/// exists, else the photo awaiting its cartoon, else initials in a circle.
struct PersonAvatarView: View {
    @Environment(AppModel.self) private var model
    let name: String
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
        Group {
            if let image = avatarImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    shape.fill(.quaternary)
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }

    private var avatarImage: NSImage? {
        guard let person = model.people.person(named: name) else { return nil }
        // Portraits are keyed by localID — the one identifier that never
        // changes, even when an ORCID is adopted mid-edit.
        return model.portraits.portrait(for: person.localID)
            ?? model.portraits.original(for: person.localID)
    }

    private var initials: String {
        let words = name.split(separator: " ")
        let first = words.first?.first.map(String.init) ?? ""
        let last = words.count > 1 ? words.last?.first.map(String.init) ?? "" : ""
        let joined = (first + last).uppercased()
        return joined.isEmpty ? "?" : joined
    }
}
