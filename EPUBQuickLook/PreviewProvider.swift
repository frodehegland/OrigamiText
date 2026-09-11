//
//  PreviewProvider.swift
//  EPUBQuickLook
//
//  Created by Frode Hegland on 11/09/2026.
//

import QuickLookUI
import UniformTypeIdentifiers

/// The Finder's spacebar preview for EPUBs: a data-based Quick Look
/// extension — the system renders the HTML reply itself, so the book's
/// first spine document shows with its own stylesheet and images
/// (see EPUBPreviewBuilder), no unpacking and no in-process WebKit.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let built = try EPUBPreviewBuilder(fileURL: request.fileURL).build()
        let reply = QLPreviewReply(dataOfContentType: .html,
                                   contentSize: CGSize(width: 820, height: 1000)) { reply in
            reply.title = built.title
            reply.stringEncoding = .utf8
            reply.attachments = built.attachments
            return built.html
        }
        return reply
    }
}
