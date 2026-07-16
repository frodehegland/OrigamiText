import Foundation

/// A demonstration custom context-menu module: one type, one registry
/// line in ContextActionRegistry. "Make Red" appears whenever text is
/// selected, while reading and while editing, and deliberately does
/// nothing to the document — it only flashes a note so the wiring is
/// visible. Delete this file (and its registry line) when done looking.
struct MakeRedContextAction: ContextActionProvider {

    static func actions(for target: ContextTarget, mode: ContextMode,
                        model: AppModel) -> [ContextAction] {
        guard case .selection(let text, _) = target else { return [] }
        return [
            ContextAction(id: "make-red", title: "Make Red",
                          systemImage: "paintbrush") {
                let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
                model.showNote("Make Red would act on “\(words.prefix(40))\(words.count > 40 ? "…" : "")” (\(mode == .reading ? "reading" : "editing"))")
            },
        ]
    }
}
