import Foundation

/// The discourse vocabulary: every way one document can relate to another.
/// This single type drives the context-menu actions, the derived draft's
/// title prefix, the byline provenance links, and the Visual-Meta fields —
/// so adding a relation here lights it up across the whole app.
nonisolated enum DocumentRelation: String, CaseIterable, Sendable {
    case cites
    case respondsTo = "responds-to"
    case extends
    case supports
    case questions
    case disagreesWith = "disagrees-with"
    case summarizes
    case revises
    case retracts

    static func from(rel: String?) -> DocumentRelation? {
        rel.flatMap(DocumentRelation.init(rawValue:))
    }

    /// The actions offered on another author's document, in menu order.
    static let discourseActions: [DocumentRelation] = [
        .respondsTo, .extends, .supports, .questions, .disagreesWith, .summarizes,
    ]

    /// Context-menu title for starting this kind of document.
    var actionTitle: String? {
        switch self {
        case .respondsTo: "Respond"
        case .extends: "Extend"
        case .supports: "Support"
        case .questions: "Question"
        case .disagreesWith: "Disagree"
        case .summarizes: "Summarize"
        default: nil
        }
    }

    /// Prefix for the derived document's title.
    var titlePrefix: String? {
        switch self {
        case .respondsTo: "Responding to "
        case .extends: "Extending "
        case .supports: "Supporting "
        case .questions: "Questioning "
        case .disagreesWith: "Disagreeing with "
        case .summarizes: "Summarizing "
        default: nil
        }
    }

    /// Label for the byline provenance link on documents carrying this
    /// relation ("Responding to <Original>").
    var bylineLabel: String? {
        switch self {
        case .respondsTo: "Responding to"
        case .extends: "Extending"
        case .supports: "Supporting"
        case .questions: "Questioning"
        case .disagreesWith: "Disagreeing with"
        case .summarizes: "Summarizing"
        case .revises: "Superseding"
        case .retracts: "Retracting"
        case .cites: nil
        }
    }

    /// Field emitted into the Visual-Meta self-citation, so readers outside
    /// the app see how documents connect. (Citations are carried by the
    /// @{references} block instead.)
    var visualMetaField: String? {
        switch self {
        case .respondsTo: "responds-to"
        case .extends: "extends"
        case .supports: "supports"
        case .questions: "questions"
        case .disagreesWith: "disagrees-with"
        case .summarizes: "summarizes"
        case .revises: "supersedes"
        case .retracts: "retracts"
        case .cites: nil
        }
    }
}
