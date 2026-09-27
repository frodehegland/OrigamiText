#if os(macOS)
import AppKit
import SwiftUI

/// A book's equations, for citing and copying (Profile 1.0 §7.7.1): each
/// with its number and section, its TeX, and Copy LaTeX / Copy MathML /
/// Copy Link. Opened on one equation (a click on it in the page) or on
/// the whole list (the document menu's Equations…).
struct EquationsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The unpacked book.
    let base: URL
    /// The book's library address, for links.
    let bookAddress: String
    /// The equation to open on, when a click chose one.
    var focus: String? = nil
    /// Goes to an equation in the reading.
    let onGo: (String) -> Void

    @State private var entries: [EquationEntry] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Equations").font(.headline)
                if loaded { Text("\(entries.count)").foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if loaded && entries.isEmpty {
                ContentUnavailableView(
                    "No Equations",
                    systemImage: "function",
                    description: Text("This document carries no MathML equations."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(entries) { entry in
                        row(entry)
                            .id(entry.id)
                            .listRowBackground(entry.id == focus ? Color.accentColor.opacity(0.12) : nil)
                    }
                    .onChange(of: loaded) {
                        if let focus { proxy.scrollTo(focus, anchor: .center) }
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 440)
        .task {
            let folder = base
            entries = await Task.detached(priority: .userInitiated) {
                OrigamiEPUBImporter.equationIndex(inUnpackedFolder: folder)
            }.value
            loaded = true
        }
    }

    private func row(_ entry: EquationEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.label.map { "(\($0))" } ?? entry.display.rawValue.capitalized)
                    .font(.callout.bold())
                if let heading = entry.heading {
                    Text(heading).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            if let tex = entry.tex {
                Text(tex)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(4)
            } else {
                Text("No TeX travels with this equation; Copy MathML gives it exactly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Copy LaTeX") { copy(entry.tex ?? "", as: .string) }
                    .disabled(entry.tex == nil)
                Button("Copy MathML") {
                    if let source = OrigamiEPUBImporter.mathMLSource(for: entry, inUnpackedFolder: base) {
                        copy(source, as: .string)
                    } else {
                        model.showNote("The equation\u{2019}s MathML could not be read.")
                    }
                }
                Button("Copy Link") {
                    model.copyParagraphLink(bookAddress: bookAddress,
                                            title: entry.label.map { "Equation \($0)" } ?? "Equation",
                                            fragment: entry.href ?? entry.id)
                }
                Button("Go") {
                    dismiss()
                    onGo(entry.href ?? entry.id)
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func copy(_ text: String, as type: NSPasteboard.PasteboardType) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: type)
        model.showNote("Copied")
    }
}
#endif
