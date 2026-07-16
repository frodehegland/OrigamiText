import SwiftUI
import PDFKit
import AppKit

/// Detail view for sidecar documents: metadata header, hash-mismatch banner,
/// then the wrapped file (inline for PDFs, "open in default app" otherwise).
struct SidecarView: View {
    let doc: LiquidDoc
    @State private var hashState: HashState = .verifying

    enum HashState: Equatable {
        case verifying
        case matches
        case mismatch
        case unreadable
    }

    private var wrappedURL: URL? {
        guard let wraps = doc.wraps else { return nil }
        return URL(fileURLWithPath: wraps.file,
                   relativeTo: doc.fileURL.deletingLastPathComponent())
            .standardizedFileURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                DocumentHeader(doc: doc)
                if let wraps = doc.wraps {
                    Label(wraps.file, systemImage: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)

            if hashState == .mismatch {
                Label("This file has changed since it was catalogued.", systemImage: "exclamationmark.triangle.fill")
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.25))
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: doc.id) { await verifyHash() }
    }

    @ViewBuilder private var content: some View {
        if let url = wrappedURL, FileManager.default.fileExists(atPath: url.path) {
            if doc.wraps?.mediaType == "application/pdf" {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            openInReader(url)
                        } label: {
                            Label("Open in Reader", systemImage: "book")
                        }
                        .help("Open this PDF in the Reader app")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    PDFKitView(url: url)
                }
            } else {
                ContentUnavailableView {
                    Label(url.lastPathComponent, systemImage: "doc")
                } description: {
                    Text(doc.wraps?.mediaType ?? "Unknown type")
                } actions: {
                    Button("Open in Default App") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("Wrapped File Missing", systemImage: "exclamationmark.triangle")
            } description: {
                Text("“\(doc.wraps?.file ?? "?")” was not found next to this document.")
            }
        }
    }

    /// Opens the PDF in the Reader app, falling back to the system default
    /// PDF application if Reader isn't installed.
    private func openInReader(_ url: URL) {
        let workspace = NSWorkspace.shared
        if let readerApp = workspace.urlForApplication(withBundleIdentifier: "com.liquid.Reader") {
            workspace.open([url], withApplicationAt: readerApp,
                           configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.open(url)
        }
    }

    private func verifyHash() async {
        hashState = .verifying
        guard let url = wrappedURL, let expected = doc.wraps?.sha256.lowercased() else { return }
        let actual = await Task.detached(priority: .utility) {
            FileHasher.sha256Hex(of: url)
        }.value
        guard let actual else {
            hashState = .unreadable
            return
        }
        hashState = (actual == expected) ? .matches : .mismatch
    }
}

struct PDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
