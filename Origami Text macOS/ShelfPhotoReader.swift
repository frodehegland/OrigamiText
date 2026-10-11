import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Reads a photograph of a bookshelf: the words on each spine, and the
/// spine's own picture. Spines stand upright, so their words run up or
/// down the photo — it is read three ways (as taken, turned right,
/// turned left), and in each the words that share a band across the
/// turned picture are one band. A spine's title and author often stand
/// side by side across it, so one spine can be two neighbouring bands:
/// the bands come back in their order, for the lookup to try each with
/// its neighbour. The same band read two ways keeps its clearer reading.
nonisolated enum ShelfPhotoReader {

    struct Spine: Sendable {
        var text: String
        var confidence: Float
        var crop: CGImage?
        /// Which way the picture was turned to read it, and the band's
        /// place across that turned picture — neighbours are next.
        var run = 0
        var position = 0
    }

    /// The bands of a photograph: one list per way it was read, each in
    /// order across the picture.
    static func spines(in url: URL) -> [[Spine]] {
        guard let image = loadImage(url) else { return [] }
        var all: [Spine] = []
        for (run, degrees) in [90.0, -90.0, 0.0].enumerated() {
            guard let turned = degrees == 0 ? image : rotate(image, degrees: degrees) else { continue }
            all += bands(in: turned).enumerated().map { position, band in
                var band = band
                band.run = run
                band.position = position
                return band
            }
        }
        // One spine read twice — turned right and turned left, or upright
        // when its words run across: the clearer reading stands.
        var kept: [Spine] = []
        for spine in all.sorted(by: { $0.confidence > $1.confidence }) {
            let words = Set(BookLookup.words(spine.text).filter { $0.count >= 3 })
            guard !words.isEmpty else { continue }
            let repeated = kept.contains { other in
                let theirs = Set(BookLookup.words(other.text).filter { $0.count >= 3 })
                let shared = words.intersection(theirs).count
                return Double(shared) >= 0.6 * Double(min(words.count, theirs.count))
            }
            if !repeated { kept.append(spine) }
        }
        return Dictionary(grouping: kept, by: \.run)
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.position < $1.position } }
    }

    /// The photograph upright (its EXIF orientation applied), no larger
    /// than Vision needs.
    private static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4032,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func rotate(_ image: CGImage, degrees: Double) -> CGImage? {
        let width = image.height, height = image.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: CGFloat(degrees * .pi / 180))
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    /// The picture's lines of words gathered into bands: lines whose
    /// heights overlap by half lie along one spine.
    private static func bands(in image: CGImage) -> [Spine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observations = request.results else { return [] }

        struct Line { var text: String; var confidence: Float; var box: CGRect }
        let lines: [Line] = observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first, best.confidence >= 0.45,
                  best.string.filter(\.isLetter).count >= 3 else { return nil }
            return Line(text: best.string, confidence: best.confidence, box: observation.boundingBox)
        }.sorted { $0.box.midY > $1.box.midY }

        var groups: [[Line]] = []
        for line in lines {
            if let last = groups.indices.last {
                let union = groups[last].reduce(CGRect.null) { $0.union($1.box) }
                let overlap = min(union.maxY, line.box.maxY) - max(union.minY, line.box.minY)
                if overlap >= 0.5 * min(union.height, line.box.height) {
                    groups[last].append(line)
                    continue
                }
            }
            groups.append([line])
        }

        return groups.compactMap { group in
            let ordered = group.sorted { $0.box.minX < $1.box.minX }
            let text = ordered.map(\.text).joined(separator: " ")
            guard BookLookup.words(text).filter({ $0.count >= 3 }).count >= 1 else { return nil }
            let confidence = ordered.map(\.confidence).reduce(0, +) / Float(ordered.count)
            let union = ordered.reduce(CGRect.null) { $0.union($1.box) }
                .insetBy(dx: -0.01, dy: -0.012)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let rect = CGRect(x: union.minX * w, y: (1 - union.maxY) * h,
                              width: union.width * w, height: union.height * h).integral
            return Spine(text: text, confidence: confidence, crop: image.cropping(to: rect))
        }
    }

    /// A spine's picture as a JPEG, for the unsure list.
    static func saveJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}
