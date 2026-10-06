#if os(macOS)
import SwiftUI

/// What a book's own records add to its authored map beyond the document:
/// each node's label (the map's `nodes` list), and which views declare a
/// y-up space (§10.3), so they are drawn the right way up. The Map itself
/// is ReaderMapView.
struct AuthoredMapExtras: Sendable {
    var labels: [String: String] = [:]
    var yUpViews: Set<String> = []
}
#endif
