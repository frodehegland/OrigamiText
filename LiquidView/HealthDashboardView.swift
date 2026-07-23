import SwiftUI

/// Library housekeeping: unresolved links, duplicates, missing sidecar
/// files, unreadable files, and unlinked documents in one place.
struct HealthDashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let report = model.healthReport
        List {
            Section("Overview") {
                LabeledContent("Documents", value: "\(report.documentCount)")
                LabeledContent("Superseded revisions", value: "\(report.supersededCount)")
                LabeledContent("Issues") {
                    if report.issueCount == 0 {
                        Label("None", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("\(report.issueCount)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                }
            }

            if !report.unresolvedLinks.isEmpty {
                Section("Unresolved Links (\(report.unresolvedLinks.count))") {
                    ForEach(report.unresolvedLinks) { unresolved in
                        Button {
                            model.openInLibrary(unresolved.sourceDoc)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(unresolved.sourceDoc.title)
                                    .lineLimit(1)
                                Text("\(unresolved.rel ?? "link") → \(unresolved.to)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("This link's target is not in the community folder. Click to open the citing document.")
                    }
                }
            }

            if !report.duplicates.isEmpty {
                Section("Duplicate IDs (\(report.duplicates.count))") {
                    ForEach(report.duplicates) { entry in
                        healthRow(entry: entry,
                                  detail: "Multiple files claim this ID; the newest is shown.",
                                  systemImage: "doc.on.doc")
                    }
                }
            }

            if !report.missingSidecarFiles.isEmpty {
                Section("Missing Wrapped Files (\(report.missingSidecarFiles.count))") {
                    ForEach(report.missingSidecarFiles) { entry in
                        healthRow(entry: entry,
                                  detail: "Wraps “\(entry.doc.wraps?.file ?? "?")”, which was not found.",
                                  systemImage: "doc.questionmark")
                    }
                }
            }

            if !report.unreadableFiles.isEmpty {
                Section("Unreadable Files (\(report.unreadableFiles.count))") {
                    ForEach(report.unreadableFiles) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.fileURL.lastPathComponent)
                                .lineLimit(1)
                            Text(file.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if !report.unlinked.isEmpty {
                Section("Unlinked Documents (\(report.unlinked.count))") {
                    ForEach(report.unlinked) { entry in
                        healthRow(entry: entry,
                                  detail: "No links in or out — an island in the community.",
                                  systemImage: "circle.dashed")
                    }
                }
            }
        }
    }

    private func healthRow(entry: IndexEntry, detail: String, systemImage: String) -> some View {
        Button {
            model.openInLibrary(entry.doc)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.doc.title)
                        .lineLimit(1)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension HealthDashboardView {
    /// The Health view as an exchangeable module.
    @MainActor static let module = LibraryViewModule(
        id: "health",
        name: "Health",
        systemImage: "checkmark.seal",
        makeContent: { AnyView(HealthDashboardView()) }
    )
}
