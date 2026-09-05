//
//  Origami_TextTests.swift
//  Origami TextTests
//
//  Created by Frode Hegland on 19/07/2026.
//

import Testing
@testable import Origami_Text

struct Origami_TextTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
        // Swift Testing Documentation
        // https://developer.apple.com/documentation/testing
    }

}

// MARK: - EPUB accessibility metadata
//
// Every EPUB Origami Text produces carries EPUB Accessibility 1.1
// discovery metadata (schema.org vocabulary in the OPF), and the claims
// must be derived from the actual converted content, never boilerplate.
// The load-bearing rule: one <img> without a non-empty alt withdraws both
// the alternativeText feature and the accessModeSufficient=textual claim.
// Mirrors Author's OrigamiTextExporter.buildOPF — keep the two in step.

struct AccessibilityMetadataTests {

    private func facts(hasImages: Bool = false, allAlt: Bool = true,
                       math: Bool = false, headings: Bool = true)
        -> OrigamiEPUBExporter.AccessibilityFacts {
        OrigamiEPUBExporter.AccessibilityFacts(
            hasImages: hasImages, allImagesHaveAltText: allAlt,
            contentHasMathML: math, hasSectionHeadings: headings)
    }

    @Test func textOnlyDocumentClaimsTextualSufficiency() {
        let xml = OrigamiEPUBExporter.accessibilityMetadataXML(facts())
        #expect(xml.contains("<meta property=\"schema:accessMode\">textual</meta>"))
        #expect(!xml.contains(">visual</meta>"))
        #expect(xml.contains("<meta property=\"schema:accessModeSufficient\">textual</meta>"))
        #expect(!xml.contains("textual,visual"))
        for feature in ["tableOfContents", "readingOrder", "structuralNavigation", "ARIA"] {
            #expect(xml.contains("<meta property=\"schema:accessibilityFeature\">\(feature)</meta>"))
        }
        #expect(!xml.contains(">alternativeText</meta>"))
        #expect(!xml.contains(">MathML</meta>"))
        #expect(xml.contains("<meta property=\"schema:accessibilityHazard\">none</meta>"))
        #expect(xml.contains("schema:accessibilitySummary"))
    }

    @Test func flatDocumentWithdrawsStructuralNavigation() {
        let xml = OrigamiEPUBExporter.accessibilityMetadataXML(facts(headings: false))
        #expect(!xml.contains(">structuralNavigation</meta>"))
        #expect(xml.contains(">readingOrder</meta>"))
        #expect(xml.contains(">tableOfContents</meta>"))
    }

    @Test func imagesWithAltTextClaimAlternativeText() {
        let xml = OrigamiEPUBExporter.accessibilityMetadataXML(facts(hasImages: true))
        #expect(xml.contains("<meta property=\"schema:accessMode\">visual</meta>"))
        #expect(xml.contains("<meta property=\"schema:accessModeSufficient\">textual</meta>"))
        #expect(xml.contains("<meta property=\"schema:accessModeSufficient\">textual,visual</meta>"))
        #expect(xml.contains(">alternativeText</meta>"))
        #expect(xml.contains("All images have alternative text."))
    }

    @Test func missingAltTextWithdrawsClaims() {
        let xml = OrigamiEPUBExporter.accessibilityMetadataXML(
            facts(hasImages: true, allAlt: false))
        // The two claims a single undescribed image withdraws:
        #expect(!xml.contains("<meta property=\"schema:accessModeSufficient\">textual</meta>"))
        #expect(!xml.contains(">alternativeText</meta>"))
        // What stays true regardless:
        #expect(xml.contains("<meta property=\"schema:accessModeSufficient\">textual,visual</meta>"))
        #expect(xml.contains("Some images lack alternative text."))
    }

    @Test func mathMLClaimFollowsContent() {
        let xml = OrigamiEPUBExporter.accessibilityMetadataXML(facts(math: true))
        #expect(xml.contains("<meta property=\"schema:accessibilityFeature\">MathML</meta>"))
        #expect(xml.contains("Mathematics is expressed in MathML."))
    }

    @Test func summaryIsXMLEscaped() {
        // The summary is fixed prose today, but the helper must escape —
        // this pins the invariant on the metadata lines as a whole.
        let xml = OrigamiEPUBExporter.accessibilityMetadataXML(facts())
        #expect(!xml.contains("& "))
    }

    // MARK: End-to-end through the exporter

    /// A minimal document with one section heading and one image whose
    /// only alternative text is `alt` (empty means none anywhere).
    private func makeDoc(alt: String) -> LiquidDoc {
        LiquidDoc(
            format: "origamitext",
            id: "test-a11y",
            title: "Accessibility Test",
            author: "Tester",
            created: Date(timeIntervalSince1970: 0),
            body: [
                LiquidDoc.Paragraph(id: "p1", heading: 1, text: "Introduction"),
                LiquidDoc.Paragraph(id: "p2", heading: nil, text: "![\(alt)](asset:img1)"),
            ],
            links: [],
            wraps: nil,
            assets: [LiquidDoc.Asset(id: "img1", filename: "figure.png",
                                     mediaType: "image/png",
                                     dataBase64: Data("png".utf8).base64EncodedString(),
                                     alt: nil)],
            fileURL: URL(fileURLWithPath: "/tmp/test-a11y.origamitext"))
    }

    /// The exporter stores every zip entry uncompressed, so package.opf
    /// is searchable in the raw .epub bytes.
    private func export(_ doc: LiquidDoc) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("a11y-\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: url) }
        try OrigamiEPUBExporter.write(doc: doc, resolve: { _ in nil }, to: url)
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func exportedEPUBCarriesTruthfulClaims() throws {
        let epub = try export(makeDoc(alt: "A labelled figure"))
        #expect(epub.contains("<meta property=\"schema:accessMode\">visual</meta>"))
        #expect(epub.contains("<meta property=\"schema:accessModeSufficient\">textual</meta>"))
        #expect(epub.contains(">alternativeText</meta>"))
        #expect(epub.contains(">structuralNavigation</meta>"))
        #expect(epub.contains("All images have alternative text."))
    }

    @Test func exportedEPUBWithdrawsClaimsForCaptionlessImage() throws {
        // The brief's negative acceptance test: a captionless image must
        // not claim alternativeText nor accessModeSufficient=textual,
        // and the summary must say some images lack alternative text.
        let epub = try export(makeDoc(alt: ""))
        #expect(!epub.contains("<meta property=\"schema:accessModeSufficient\">textual</meta>"))
        #expect(!epub.contains(">alternativeText</meta>"))
        #expect(epub.contains("Some images lack alternative text."))
    }
}
