import SwiftUI

/// The comments a Hypermedia space holds on a document, threaded, shown
/// under the letter in the reader — and the place to add one. Fetched
/// when the reader arrives; the space is the record, nothing is kept.
struct HypermediaCommentsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppSettings.connectionPortraitsKey) private var showPortraits = true
    let canonicalID: String

    @State private var draft = ""
    @State private var replyingTo: HypermediaComment?
    @State private var isPosting = false
    @State private var postError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.hypermedia.refreshComments(for: canonicalID) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Fetch the comments again")
            }
            content
            composer
        }
        .task(id: canonicalID) {
            await model.hypermedia.loadCommentsIfNeeded(for: canonicalID)
        }
        .onChange(of: canonicalID) {
            draft = ""
            replyingTo = nil
            postError = nil
        }
    }

    private var state: HypermediaSpaces.Comments? { model.hypermedia.comments[canonicalID] }

    private var title: String {
        if case .loaded(let threads)? = state {
            let n = threads.reduce(0) { $0 + $1.count }
            return n == 1 ? "1 Comment" : "\(n) Comments"
        }
        return "Comments"
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .none, .loading?:
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.6)
                Text("Fetching comments…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .failed(let message)?:
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .loaded(let threads)?:
            if threads.isEmpty {
                Text("No comments on this document yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(threads) { comment in
                        CommentThread(comment: comment, depth: 0, showPortraits: showPortraits,
                                      canReply: model.hypermedia.identity != nil) { target in
                            replyingTo = target
                        }
                    }
                }
            }
        }
    }

    // MARK: Writing

    /// Below the thread: a place to speak, once there is an account to
    /// speak as.
    @ViewBuilder private var composer: some View {
        if model.hypermedia.identity == nil {
            HStack(spacing: 10) {
                Text("Create an account to comment here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Create an Account…") {
                    model.settingsTab = .hypermedia
                    openSettings()
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let replyingTo {
                    HStack(spacing: 6) {
                        Text("Replying to \(replyingTo.authorName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Cancel") { self.replyingTo = nil }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .underline()
                    }
                }
                TextEditor(text: $draft)
                    .font(.callout)
                    .frame(minHeight: 64, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if draft.isEmpty {
                            Text(replyingTo == nil ? "Write a comment as \(model.hypermedia.accountName)…" : "Write a reply…")
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 10) {
                    Button(isPosting ? "Posting…" : (replyingTo == nil ? "Post Comment" : "Post Reply")) {
                        post()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting)
                    if isPosting { ProgressView().scaleEffect(0.6) }
                    if let postError {
                        Label(postError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private func post() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isPosting else { return }
        isPosting = true
        postError = nil
        Task {
            do {
                try await model.hypermedia.postComment(text: text, on: canonicalID, replyTo: replyingTo)
                draft = ""
                replyingTo = nil
                // The space indexes the blob on arrival; a moment later the
                // list has it.
                try? await Task.sleep(for: .milliseconds(800))
                await model.hypermedia.refreshComments(for: canonicalID)
            } catch {
                postError = error.localizedDescription
            }
            isPosting = false
        }
    }
}

/// One comment and, indented beneath it, its replies.
private struct CommentThread: View {
    let comment: HypermediaComment
    let depth: Int
    let showPortraits: Bool
    let canReply: Bool
    let onReply: (HypermediaComment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if showPortraits {
                    PersonAvatarView(name: comment.authorName, size: 24)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(comment.authorName)
                            .font(.callout.weight(.medium))
                        if let created = comment.created {
                            Text(created, format: .dateTime.year().month(.abbreviated).day())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if canReply {
                            Button("Reply") { onReply(comment) }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(Array(comment.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(markdown(paragraph))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(depth == 0 ? 0.5 : 0.3),
                        in: RoundedRectangle(cornerRadius: 8))
            if !comment.replies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(comment.replies) { reply in
                        CommentThread(comment: reply, depth: depth + 1, showPortraits: showPortraits,
                                      canReply: canReply, onReply: onReply)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    /// Inline markdown as the fetcher wrote it: emphasis, code, and links
    /// — hm:// links included, which the reader opens itself.
    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
