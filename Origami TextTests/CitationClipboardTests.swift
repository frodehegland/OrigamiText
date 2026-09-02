import Testing
@testable import Origami_Text

// MARK: - Citation clipboard contract tests
//
// These tests lock down the data contract between Origami Text and Author.
// The two apps exchange citations via a shared pasteboard protocol: private
// JSON (full fidelity), Author's native dict type, HTML hyperlink, and plain
// text. Three string constants and one URL scheme are the load-bearing joints
// — a silent change to any of them breaks the flow in one direction without
// any compile error. The tests here make that loud.
//
// If a test here fails after a refactor, do NOT update the expected value
// without also updating Author. The contract is cross-app.

struct CitationClipboardTests {

    // MARK: - Contract constants

    @Test func pasteboardTypeNameIsStable() {
        // Author reads this type by name when it sees a paste.
        #expect(CitationClipboard.typeName == "info.futuretextlab.origami-citation")
    }

    @Test func webCarrierPrefixIsStable() {
        // Author and Origami Text both write and parse this prefix.
        // EPUBReaderView also intercepts it as a back-link.
        #expect(OrigamiCitation.webCarrierPrefix == "https://origamitext.app/o/")
    }

    // MARK: - URL construction

    @Test func urlUsesOrigamiScheme() {
        let c = makeCitation(to: "urn:uuid:abc-123", quotedText: "hello")
        #expect(c.url.hasPrefix("origamitext://open/"))
    }

    @Test func webURLUsesCarrierPrefix() {
        let c = makeCitation(to: "urn:uuid:abc-123", quotedText: "hello")
        #expect(c.webURL.hasPrefix(OrigamiCitation.webCarrierPrefix))
    }

    @Test func urlEncodesQuotedText() {
        let c = makeCitation(to: "abc", quotedText: "hello world")
        #expect(c.url.contains("?q=hello%20world"))
        #expect(c.webURL.contains("?q=hello%20world"))
    }

    @Test func urlAppendsFragment() {
        let c = makeCitation(to: "abc", fragment: "para-42", quotedText: "")
        #expect(c.url.hasSuffix("#para-42"))
        #expect(c.webURL.hasSuffix("#para-42"))
    }

    @Test func urlOmitsEmptyQuote() {
        let c = makeCitation(to: "abc", quotedText: "")
        #expect(!c.url.contains("?q="))
        #expect(!c.webURL.contains("?q="))
    }

    // MARK: - parse(href:) — both URL schemes

    @Test func parseOrigamiScheme() throws {
        let href = "origamitext://open/urn:uuid:abc-123?q=hello%20world#para-42"
        let parsed = try #require(CitationClipboard.parse(href: href))
        #expect(parsed.to == "urn:uuid:abc-123")
        #expect(parsed.fragment == "para-42")
        #expect(parsed.quote == "hello world")
    }

    @Test func parseWebCarrierScheme() throws {
        let href = "https://origamitext.app/o/urn:uuid:abc-123?q=hello#para-42"
        let parsed = try #require(CitationClipboard.parse(href: href))
        #expect(parsed.to == "urn:uuid:abc-123")
        #expect(parsed.fragment == "para-42")
        #expect(parsed.quote == "hello")
    }

    @Test func parseRejectsUnrelatedURL() {
        #expect(CitationClipboard.parse(href: "https://example.com/foo") == nil)
        #expect(CitationClipboard.parse(href: "https://origamitext.app/other/abc") == nil)
        #expect(CitationClipboard.parse(href: "") == nil)
    }

    @Test func parseHandlesNoFragmentNoQuery() throws {
        let href = "origamitext://open/some-doc-id"
        let parsed = try #require(CitationClipboard.parse(href: href))
        #expect(parsed.to == "some-doc-id")
        #expect(parsed.fragment == nil)
        #expect(parsed.quote == nil)
    }

    @Test func parseRoundTripsWithCitationURL() throws {
        // A citation built here must parse back to the same address.
        let c = makeCitation(to: "urn:uuid:test-doc", fragment: "p-7", quotedText: "some text")
        let parsed = try #require(CitationClipboard.parse(href: c.url))
        #expect(parsed.to == "urn:uuid:test-doc")
        #expect(parsed.fragment == "p-7")
        #expect(parsed.quote == "some text")
    }

    @Test func parseRoundTripsWithWebURL() throws {
        let c = makeCitation(to: "urn:uuid:test-doc", fragment: "p-7", quotedText: "some text")
        let parsed = try #require(CitationClipboard.parse(href: c.webURL))
        #expect(parsed.to == "urn:uuid:test-doc")
        #expect(parsed.fragment == "p-7")
        #expect(parsed.quote == "some text")
    }

    // MARK: - insertionText — the paste form Author and OT draft editors consume

    @Test func insertionTextFormat() {
        let c = makeCitation(to: "doc-id", fragment: "para-1",
                             quotedText: "The sky is blue", author: "Hegland", year: "2025")
        // Format: "Quote" (Author, Year) [address#fragment]
        #expect(c.insertionText == "\u{201C}The sky is blue\u{201D} (Hegland, 2025) [doc-id#para-1]")
    }

    @Test func insertionTextWithNoFragment() {
        let c = makeCitation(to: "doc-id", quotedText: "Words", author: "Smith", year: "2024")
        #expect(c.insertionText == "\u{201C}Words\u{201D} (Smith, 2024) [doc-id]")
    }

    // MARK: - marker (visible in Word/Pages)

    @Test func markerWithAuthorAndYear() {
        let c = makeCitation(to: "x", author: "Hegland", year: "2025")
        #expect(c.marker == "(Hegland, 2025)")
    }

    @Test func markerFallsBackToSource() {
        let c = makeCitation(to: "x", author: "", year: "")
        #expect(c.marker == "(source)")
    }

    @Test func markerWithYearOnly() {
        let c = makeCitation(to: "x", author: "", year: "2025")
        #expect(c.marker == "(2025)")
    }

    // MARK: - JSON round-trip (the private pasteboard flavour)

    @Test func jsonRoundTripPreservesAllFields() throws {
        let original = OrigamiCitation(
            to: "urn:uuid:abc", fragment: "p-1", rel: "cites",
            quotedText: "test quote", author: "Smith", year: "2024",
            bibtex: "@article{key, title={T}}", documentTitle: "My Paper",
            documentFilename: "paper.epub", annotation: "my note")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OrigamiCitation.self, from: data)
        #expect(decoded.to == original.to)
        #expect(decoded.fragment == original.fragment)
        #expect(decoded.rel == original.rel)
        #expect(decoded.quotedText == original.quotedText)
        #expect(decoded.author == original.author)
        #expect(decoded.year == original.year)
        #expect(decoded.bibtex == original.bibtex)
        #expect(decoded.documentTitle == original.documentTitle)
        #expect(decoded.documentFilename == original.documentFilename)
        #expect(decoded.annotation == original.annotation)
    }

    @Test func jsonRoundTripWithNilOptionals() throws {
        let original = makeCitation(to: "id", quotedText: "q")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OrigamiCitation.self, from: data)
        #expect(decoded.fragment == nil)
        #expect(decoded.bibtex == nil)
        #expect(decoded.documentTitle == nil)
        #expect(decoded.documentFilename == nil)
        #expect(decoded.annotation == nil)
    }

    // MARK: - address property

    @Test func addressWithFragment() {
        let c = makeCitation(to: "doc", fragment: "para-5")
        #expect(c.address == "doc#para-5")
    }

    @Test func addressWithoutFragment() {
        let c = makeCitation(to: "doc")
        #expect(c.address == "doc")
    }
}

// MARK: - Helpers

private func makeCitation(
    to: String,
    fragment: String? = nil,
    quotedText: String = "",
    author: String = "",
    year: String = ""
) -> OrigamiCitation {
    OrigamiCitation(to: to, fragment: fragment, rel: "cites",
                    quotedText: quotedText, author: author, year: year,
                    bibtex: nil, documentTitle: nil, documentFilename: nil)
}
