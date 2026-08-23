import SwiftUI
import AppKit

/// The context-menu architecture: every ctrl-click in the app resolves to
/// a ContextTarget — what the pointer is on — and one builder answers what
/// can be done to it. Views never hand-build their menus; they name the
/// target and render the shared answer (plus any view-local extras, like
/// sheets only that view can present). New actions added here appear on
/// every surface at once: SwiftUI context menus and AppKit text-view
/// menus render from the same list.
enum ContextTarget {
    /// Selected words, with the document they were selected in when known.
    case selection(text: String, doc: LiquidDoc?)
    /// Special text: a name the system knows (speaker, author).
    case person(name: String)
    /// Special text: a document address, possibly paragraph-scoped.
    case address(id: String, fragment: String?)
    /// A paragraph, in its document.
    case paragraph(LiquidDoc.Paragraph, in: LiquidDoc)
    /// A whole document.
    case document(LiquidDoc)
    /// No text at all: the place itself.
    case background
}

/// Whether the click happened while reading or while writing — the same
/// target can deserve different verbs in each.
enum ContextMode {
    case reading
    case editing
}

/// One thing that can be done to a target.
struct ContextAction: Identifiable {
    let id: String
    let title: String
    var systemImage: String?
    var isDestructive = false
    let perform: @MainActor () -> Void
}

/// Custom context menus are modules, like views: write one type, add one
/// registry line, and its actions appear on every surface — reader,
/// editor, rows, empty space — for the targets and modes it answers.
@MainActor
protocol ContextActionProvider {
    /// Actions to append for this target in this mode; return [] to pass.
    static func actions(for target: ContextTarget, mode: ContextMode,
                        model: AppModel) -> [ContextAction]
}

/// The installed custom providers, in menu order after the built-ins.
@MainActor
enum ContextActionRegistry {
    static let providers: [any ContextActionProvider.Type] = [
        // Add custom menu modules here — one line per module.
    ]
}

@MainActor
enum ContextActionBuilder {

    /// The single answer to "what can be done here": the built-ins for
    /// the target and mode, then every registered custom provider's
    /// contribution. Order is menu order.
    static func actions(for target: ContextTarget, mode: ContextMode,
                        model: AppModel) -> [ContextAction] {
        var all = builtInActions(for: target, mode: mode, model: model)
        for provider in ContextActionRegistry.providers {
            all.append(contentsOf: provider.actions(for: target, mode: mode, model: model))
        }
        return all
    }

    private static func builtInActions(for target: ContextTarget, mode: ContextMode,
                                       model: AppModel) -> [ContextAction] {
        switch target {

        case .selection(let text, let doc):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            var actions: [ContextAction] = []
            if let doc {
                actions.append(ContextAction(id: "copy-quote", title: "Copy as Quote",
                                             systemImage: "quote.opening") {
                    let year = doc.date?.yearText ?? doc.created.formatted(.dateTime.year())
                    CitationClipboard.write(OrigamiCitation(
                        to: doc.id, fragment: nil, rel: "cites",
                        quotedText: trimmed, author: doc.displayAuthor, year: year,
                        bibtex: OrigamiReading.bibTeXEntry(for: doc, quote: trimmed)))
                })
            }
            // The selected words as a person: offered when the library
            // knows the name (special text discovered, not marked up).
            if model.people.person(named: trimmed) != nil || model.knowsAuthor(named: trimmed) {
                actions.append(contentsOf: builtInActions(for: .person(name: trimmed),
                                                          mode: mode, model: model))
            }
            // The selected words as an address.
            if let match = LiquidAddress.matches(in: trimmed).first {
                actions.append(contentsOf: builtInActions(
                    for: .address(id: match.id, fragment: match.fragment),
                    mode: mode, model: model))
            }
            return actions

        case .person(let name):
            return [
                ContextAction(id: "person-page", title: "Profile",
                              systemImage: "person.text.rectangle") {
                    model.openAuthorPage(named: name)
                },
            ]

        case .address(let id, let fragment):
            guard let entry = model.index.byID[LiquidAddress.canonical(id)] else { return [] }
            return [
                ContextAction(id: "open-address", title: "Open “\(entry.doc.title)”",
                              systemImage: "arrow.right.doc.on.clipboard") {
                    model.openInLibrary(entry.doc, fragment: fragment)
                },
                ContextAction(id: "cite-address", title: "Copy to Cite",
                              systemImage: "quote.closing") {
                    model.copyCitation(doc: entry.doc)
                },
            ]

        case .paragraph(let paragraph, let doc):
            var actions: [ContextAction] = []
            // Paragraph ids shift while a draft is edited; the address is
            // only offered where it is stable — in reading mode.
            if mode == .reading {
                actions.append(ContextAction(id: "copy-paragraph-address",
                                             title: "Copy Paragraph Address",
                                             systemImage: "number") {
                    copyToPasteboard("[\(doc.id)#\(paragraph.id)]")
                })
            }
            if paragraph.speaker != nil {
                actions.append(ContextAction(id: "lift", title: "Lift to New",
                                             systemImage: "arrow.up.doc") {
                    model.liftStatement(paragraph, from: doc)
                })
            }
            return actions

        case .document(let doc):
            var actions: [ContextAction] = [
                ContextAction(id: "cite-doc", title: "Copy to Cite",
                              systemImage: "quote.closing") {
                    model.copyCitation(doc: doc)
                },
                ContextAction(id: "export-doc", title: "Export a Copy…",
                              systemImage: "square.and.arrow.up") {
                    model.exportDocument(doc)
                },
                ContextAction(id: "export-epub", title: "Export as EPUB…",
                              systemImage: "book.closed") {
                    model.exportEPUB(doc)
                },
                ContextAction(id: "show-in-finder", title: "Show in Finder",
                              systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
                },
                ContextAction(id: "copy-letter-file", title: "Copy Letter",
                              systemImage: "doc.on.doc") {
                    DocumentFileActions.copyFile(of: doc)
                },
            ]
            // Declaring a transcript: statements gain their structural
            // speakers and the document its type, so lifting, speaker
            // attribution, and Summary & Notes all know it. Always
            // offered — a vanished option reads as a bug, and processing
            // an already-attributed transcript is harmless: it simply
            // attributes anything new.
            actions.append(ContextAction(id: "process-transcript",
                                         title: "Process Transcript",
                                         systemImage: "text.bubble") {
                model.processTranscript(doc)
            })
            // The reply family — the discourse verbs — on other people's
            // documents: respond, extend, support, question, disagree,
            // summarize. One list here, every surface at once.
            if !model.authorIdentity.matches(author: doc.author) {
                for relation in DocumentRelation.discourseActions {
                    actions.append(ContextAction(
                        id: "discourse-\(relation.rawValue)",
                        title: relation.actionTitle ?? relation.rawValue,
                        systemImage: "arrowshape.turn.up.left") {
                        model.startDiscourse(relation, about: doc)
                    })
                }
            }
            return actions

        case .background:
            return [
                ContextAction(id: "new-doc", title: "New Document",
                              systemImage: "square.and.pencil") {
                    model.newDraft()
                },
                ContextAction(id: "import", title: "Import…",
                              systemImage: "square.and.arrow.down") {
                    model.importDocumentFile()
                },
            ]
        }
    }

    /// The citation text convention (§4): “Quote” (Author, Year) [address].
    static func quote(_ text: String, from doc: LiquidDoc) -> String {
        let year = doc.date?.yearText ?? doc.created.formatted(.dateTime.year())
        return "“\(text)” (\(doc.displayAuthor), \(year)) [\(doc.id)]"
    }

    static func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: AppKit rendering (text-view menus)

    /// Menu items for an NSMenu, inserted by NSTextView delegates. The
    /// host object keeps the closures alive for the menu's lifetime.
    static func menuItems(for target: ContextTarget, mode: ContextMode,
                          model: AppModel) -> [NSMenuItem] {
        actions(for: target, mode: mode, model: model).map { action in
            let item = NSMenuItem(title: action.title,
                                  action: #selector(ContextActionTrampoline.fire(_:)),
                                  keyEquivalent: "")
            let trampoline = ContextActionTrampoline(action.perform)
            item.target = trampoline
            item.representedObject = trampoline   // retain alongside the item
            return item
        }
    }
}

/// The reply family as a labeled menu — the same discourse verbs the
/// document context menu offers, for surfaces that want them under one
/// visible "Reply" button. One verb list (DocumentRelation
/// .discourseActions) feeds both, so additions appear everywhere at once.
struct ReplyMenu: View {
    @Environment(AppModel.self) private var model
    let doc: LiquidDoc

    var body: some View {
        Menu {
            ForEach(DocumentRelation.discourseActions, id: \.self) { relation in
                Button(relation.actionTitle ?? relation.rawValue) {
                    model.startDiscourse(relation, about: doc)
                }
            }
        } label: {
            Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        .help("Start a linked reply: respond, extend, support, question, disagree, or summarize")
    }
}

/// The letter as a file — the verbs the Letters list taught, for any row
/// menu: reveal the .origamitext in Finder, or copy the file itself for
/// pasting anywhere.
struct DocumentFileActions: View {
    let doc: LiquidDoc

    var body: some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([doc.fileURL])
        }
        Button("Copy Letter") {
            Self.copyFile(of: doc)
        }
    }

    static func copyFile(of doc: LiquidDoc) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([doc.fileURL as NSURL])
    }
}

/// Bridges a Swift closure to an NSMenuItem target/action pair.
final class ContextActionTrampoline: NSObject {
    private let perform: @MainActor () -> Void
    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    @objc func fire(_ sender: Any?) { MainActor.assumeIsolated { perform() } }
}

// MARK: SwiftUI rendering

/// Renders the shared actions inside any SwiftUI `.contextMenu`.
/// Views append their view-local items (sheet presenters) after it.
struct ContextActionItems: View {
    @Environment(AppModel.self) private var model
    let target: ContextTarget
    var mode: ContextMode = .reading

    var body: some View {
        ForEach(ContextActionBuilder.actions(for: target, mode: mode, model: model)) { action in
            Button(role: action.isDestructive ? .destructive : nil) {
                action.perform()
            } label: {
                if let systemImage = action.systemImage {
                    Label(action.title, systemImage: systemImage)
                } else {
                    Text(action.title)
                }
            }
        }
    }
}

extension AppModel {
    /// Whether the name is known to the library as an author, a speaker,
    /// or someone letters are addressed to — how plain selected words are
    /// recognised as a person.
    func knowsAuthor(named name: String) -> Bool {
        let target = name.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return false }
        return index.byID.values.contains {
            $0.doc.author.caseInsensitiveCompare(target) == .orderedSame
                || $0.doc.creditedAuthor.caseInsensitiveCompare(target) == .orderedSame
                || $0.doc.attention.contains { recipient in
                    recipient.caseInsensitiveCompare(target) == .orderedSame
                }
                || ($0.doc.body ?? []).contains { paragraph in
                    paragraph.speaker?.caseInsensitiveCompare(target) == .orderedSame
                }
        }
    }
}
