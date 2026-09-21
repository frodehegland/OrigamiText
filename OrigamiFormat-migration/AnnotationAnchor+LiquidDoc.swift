import Foundation

// The anchoring ladder itself moved into OrigamiFormat, cut free of
// `LiquidDoc` so Reader can run the same cascade over EPUB elements. This
// is the ten lines that put it back in touch with Origami Text's own model,
// so every existing call site — `AnnotationAnchor.resolve(_:in: doc)`,
// `AnnotationAnchor.target(in: doc, paragraphID:exact:)` — compiles and
// behaves exactly as before.

extension AnnotationAnchor {

    /// Origami Text's paragraphs as the ladder wants them.
    static func units(of doc: LiquidDoc) -> [AnchoredParagraph] {
        (doc.body ?? []).map { AnchoredParagraph(id: $0.id, text: $0.text) }
    }

    /// What names this document to anything outside Origami Text: its DOI
    /// where it has one, else the address only this library understands.
    ///
    /// Note the gap, which is deliberate and recorded rather than papered
    /// over: without a DOI this is a *local* name, so a book annotated here
    /// and in Reader still will not join up — Reader names it by the
    /// content hash of the file. Closing that needs Origami Text to hash
    /// the book it opened; then this becomes
    /// `DocumentIdentity.canonical(doi: doc.doi, contentHash: hash, localName: doc.id)`
    /// and the two apps agree for every document, not only the published
    /// ones. Existing sidecars keep resolving either way:
    /// `DocumentIdentity.normalised` folds the old
    /// `origamitext://open/<address>` form onto the same key.
    static func source(of doc: LiquidDoc) -> String {
        DocumentIdentity.canonical(doi: doc.doi, localName: doc.id)
    }

    static func resolve(_ annotation: WebAnnotation, in doc: LiquidDoc) -> Resolution? {
        resolve(annotation, in: units(of: doc))
    }

    static func target(in doc: LiquidDoc, paragraphID: String,
                       exact: String? = nil) -> WebAnnotation.Target {
        target(source: source(of: doc), in: units(of: doc),
               paragraphID: paragraphID, exact: exact)
    }
}
