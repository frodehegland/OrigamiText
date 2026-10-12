#if os(macOS)
import SwiftUI

/// What a book's own records add to its authored map beyond the document:
/// each node's label (the map's `nodes` list), and which views declare a
/// y-up space (§10.3), so they are drawn the right way up. The Map itself
/// is ReaderMapView.
struct AuthoredMapExtras: Sendable {
    var labels: [String: String] = [:]
    var yUpViews: Set<String> = []
    /// A map whose members are joined by what they are, not by what their
    /// definitions mention — the library's citations, as Author's Document
    /// Space joins documents to their tags: each member to those it links
    /// to. Selecting either end draws the line. Nil: Author's mention rules.
    var connections: [String: Set<String>]? = nil
    /// Members drawn as pills, as the Document Space draws its tags.
    var pills: Set<String> = []
    /// Members a double-click opens (the Document Space's documents).
    var openable: Set<String> = []
    /// The Show menu's narrowing, in place of Only Concepts in the Text
    /// when the map has no text: its title, and the members it leaves out.
    var narrowing: (title: String, leavesOut: Set<String>)? = nil
    /// What Layout calls the arrangement the map opened with.
    var originalLayoutName = "Author\u{2019}s Layout"
    /// Named arrangements the map's own data can take, offered in the
    /// Shapes list — each a way of seeing, with captions for its groups.
    var shapes: [MapShape] = []
}

/// One of the Shapes list's arrangements: where every member stands, the
/// captions naming its groups, and a sentence on the thinking behind it.
struct MapShape: Identifiable, Sendable {
    struct Caption: Sendable {
        var title: String
        var point: CGPoint
    }
    var id: String { group + "/" + title }
    /// The thinker or tradition the shape comes from, as the list heads it.
    var group: String
    var title: String
    var explanation: String
    var positions: [String: CGPoint]
    var captions: [Caption] = []
}
#endif
