# Views are yours to make

Origami Text treats ways of seeing a library as **view modules**: single Swift files, and the app treats your view exactly as it treats ours.

This follows Doug Engelbart's NLS, where a document could be seen through many *view specifications* without changing the document. The documents are plain, self-describing; the views multiply. When someone in your community thinks of a new way of looking — a reading-order timeline, a disagreement map, a view for teaching — they can build it and hand it to everyone else as one file.

**Where this stands today:** Origami Text has just pivoted to EPUB + Visual-Meta as its document form, and the first generation of view modules (built against the earlier JSON documents) has been retired. The module mechanism itself — the registry, the sidebar routing, the exchange — remains and works; the registry is simply empty while views are rebuilt against the EPUB library. The built-in ways in (Chronological, Authors, Journals, People, Concepts) are currently wired directly. If you want to build a view now, the mechanism below is live and yours to use.

## Writing a view

A view module is a SwiftUI view plus a short declaration. Three steps:

1. **Write your view in one file.** The library comes to you through the environment: the document index, every link and backlink, and ready-made derivations. Navigation is the same three calls every built-in view uses — open a document, open it at a paragraph, open two documents side by side with visible connections. Your view has no privileged access and needs none.

2. **Declare the module at the bottom of the file** — an id, a sidebar name, an icon, and how to build its panes.

3. **Register it — one line** in `LibraryViewRegistry.modules` (LibraryViewModule.swift). Sidebar entry, selection, and routing follow automatically.

```swift
import SwiftUI

/// My View: <what it shows, and the cognitive job it does>.
struct MyCommunityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.index.timeline) { entry in
                Button {
                    model.openInLibrary(entry.doc)
                } label: {
                    Text(entry.doc.title)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("My View")
    }
}

extension MyCommunityView {
    @MainActor static let module = LibraryViewModule(
        id: "my-view",
        name: "My View",
        systemImage: "sparkles",
        makeContent: { AnyView(MyCommunityView()) }
    )
}
```

A starter version of this template is one click away in the app: Settings → View Modules → Copy Starter Module.

## Sharing a view

Send the file. Installing is dropping it into the project and adding its registry line — views are ordinary source code in the open repository, which means every view anyone runs is code anyone can read. Contribute yours by pull request, and it ships to the whole community in the next build.

## One request

When you propose a view, say what cognitive work it does — what it helps a person notice, remember, or compare. "It would look good" is not a reason; "it lets you see who is disagreeing with whom across a month" is.
