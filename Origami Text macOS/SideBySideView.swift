#if os(macOS)
import SwiftUI

/// Two library books side by side — two editions of a paper, a paper and
/// the one it answers — with their scrolling optionally locked together,
/// so the same place in each stays in view.
struct SideBySideRequest: Identifiable, Hashable {
    let left: String   // EPUBRecord.folder
    let right: String
    var id: String { left + "|" + right }
}

struct SideBySideView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SideBySideRequest

    @State private var leftDoc: LiquidDoc?
    @State private var rightDoc: LiquidDoc?
    @AppStorage("sideBySideSync") private var synced = true
    @State private var leftPosition = ScrollPosition(edge: .top)
    @State private var rightPosition = ScrollPosition(edge: .top)
    @State private var leftRange: CGFloat = 1
    @State private var rightRange: CGFloat = 1
    /// Which side the reader is moving; the other follows. Set by the
    /// side scrolled, released shortly after, so a follow never echoes.
    @State private var driver: Side?
    @State private var releaseDriver: Task<Void, Never>?

    enum Side { case left, right }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Side by Side").font(.headline)
                Spacer()
                Toggle("Sync Scrolling", isOn: $synced)
                    .toggleStyle(.checkbox)
                    .help("Keep both at the same point through their text")
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            HStack(spacing: 0) {
                column(leftDoc, title: record(request.left)?.title, position: $leftPosition, side: .left)
                Divider()
                column(rightDoc, title: record(request.right)?.title, position: $rightPosition, side: .right)
            }
        }
        .frame(minWidth: 1100, minHeight: 720)
        .task { await load() }
    }

    private func record(_ folder: String) -> EPUBRecord? {
        model.epubRecords.first { $0.folder == folder }
    }

    private func column(_ doc: LiquidDoc?, title: String?, position: Binding<ScrollPosition>, side: Side) -> some View {
        VStack(spacing: 0) {
            Text(title ?? "")
                .font(.subheadline.bold())
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(8)
                .background(.bar)
            if let doc {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(doc.body ?? []) { paragraph in
                            Text(paragraph.renderedText)
                                .font(paragraph.heading.map { level in
                                    level <= 1 ? .title2.bold() : .title3.bold()
                                } ?? .body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 680)
                    .frame(maxWidth: .infinity)
                }
                .scrollPosition(position)
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    max(1, geometry.contentSize.height - geometry.containerSize.height)
                } action: { _, range in
                    if side == .left { leftRange = range } else { rightRange = range }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.y
                } action: { _, offset in
                    follow(from: side, offset: offset)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The other side follows, at the same fraction through its text.
    private func follow(from side: Side, offset: CGFloat) {
        guard synced, driver == nil || driver == side else { return }
        driver = side
        releaseDriver?.cancel()
        releaseDriver = Task {
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { driver = nil }
        }
        switch side {
        case .left:
            rightPosition.scrollTo(y: offset / leftRange * rightRange)
        case .right:
            leftPosition.scrollTo(y: offset / rightRange * leftRange)
        }
    }

    private func load() async {
        for (folder, side) in [(request.left, Side.left), (request.right, Side.right)] {
            guard let record = record(folder) else { continue }
            let base = model.unpackedFolder(for: record)
            let doc = await Task.detached(priority: .userInitiated) {
                (try? OrigamiEPUBImporter.importDocument(inUnpackedFolder: base)).map {
                    AppModel.structuredDoc(from: $0, record: record, fallbackID: record.folder, base: base)
                }
            }.value
            if side == .left { leftDoc = doc } else { rightDoc = doc }
        }
    }
}
#endif
