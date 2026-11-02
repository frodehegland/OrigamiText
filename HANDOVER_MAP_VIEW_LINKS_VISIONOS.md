# Handover: map-view links on visionOS (Origami Text Vision)

2 November 2026. From the Author session that built Copy Layout.

## What the writer does

In Author, on the Mac, iPad or Vision Pro, the writer arranges the Map and chooses **Save View**. Saved views travel in the document, so they are on every device. On the Mac, the writer selects words and makes a local link. The link dialog now has a **Views** tab beside Headings and Images. The linked words open the Map in that view. (Copy Layout, then paste into Write, makes the same kind of marker.)

When the document is exported as an Origami EPUB, the marker stays in the text. A reader that knows about it opens the book's Map **in that view** when the marker is clicked.

The Mac reader does this already (commit `a470726`). This handover covers the same thing for **Origami Text Vision**.

## What arrives in the EPUB

**In the text** (AuthorKit `460fa8e` and later):

```html
<a class="ot-map-view" role="button" tabindex="0"
   data-map-view="VIEW-6F1C…" data-origami-action="open-map-view">&lt;Islands&gt;</a>
```

- With an older AuthorKit, the same anchor arrives as just `<a data-map-view="VIEW-…">…</a>`. The importer treats both the same way.
- A marker whose view is not in the record is exported as its plain words, with no anchor.

**In the record** (`origami.json` → `map.views`, or `visual-meta.json` → `map.views` for older exports):

```json
{ "id": "VIEW-6F1C…", "name": "Islands",
  "space": { "units": "points", "convention": "right-handed-y-up" },
  "nodes": [ { "ref": "C-…", "x": 120.0, "y": -340.0, "z": 0.0 } ] }
```

- `MAP-1` (named "Map") is the main Map, and each saved view is `VIEW-<id>`. With exactly **one** saved view, that view comes **first**, so it is the default a reader opens. With several, `MAP-1` comes first and the views follow.
- `ref` is a published concept id: an entry in `concepts` (and in `map.nodes`).
- **y is up.** Author negates the canvas y before export. The Mac reader uses `extras.yUpViews` (filled in `AppModel.authoredMapExtras`) to flip it back for drawing. Do the same here, or keep y as it is if the visionOS map is already y-up.
- `z` is Knowledge Space depth in metres. 0 means not set, and the reader chooses a default depth.

## What already works on visionOS (nothing to do)

- `OrigamiEPUBImport.swift` is compiled into the Vision target. Its `<a>` case turns the marker into the link token `[<Islands>](origami-mapview:VIEW-6F1C…)`.
- `VisionReaderView` already loads `map.views` into `doc.layouts` (`OrigamiVision.swift`, in `structuredDoc`, `doc.layouts = result.layouts`). Each `LiquidDoc.Layout` has a `name`, `positions` (each with `id`, `x`, `y`, `z`) and `sourceID`. `sourceID` is the `VIEW-…` id to match against.

## What to build

1. **Catch the link.** In `VisionReaderView.handle(_:doc:)` (`OrigamiVision.swift`, about line 5219), add a case before `return false`:

   ```swift
   if url.scheme == "origami-mapview" {
       let raw = String(url.absoluteString.dropFirst("origami-mapview:".count))
       openMapView(raw.removingPercentEncoding ?? raw, doc: doc)
       return true
   }
   ```

   Today the link falls through to `.systemAction`, which does nothing useful for a custom scheme.

2. **A per-book map to open.** This is the real work. visionOS has library-wide spaces (`KnowledgeSpaceView`, `AuthorsSpaceView`, the immersive "arms" space), but nothing like the Mac's `ReaderMapView`, which shows one book's authored map. `ReaderMapView.swift` and `OrigamiReadingView.swift` are not in the Vision target.

   The suggested shape is a volume or window, `WindowGroup(id: "bookmap", for: BookMapTarget.self)`, where `BookMapTarget` holds the document id and the view id. It would:
   - Show the book's concepts (`doc.concepts`) as cards. Place them by the chosen layout (`doc.layouts.first { $0.sourceID == viewID }`), falling back to the first layout.
   - Scale points down to the volume, as `KnowledgeSpaceView` does with Author's Map.
   - Draw `doc.mapConnections`.
   - Offer every authored view in the map's **Layout** list, the way the Mac now does (commit `77acdb9`). The author's views are under Layout; Views is for the reader's own saved views. The first view (`doc.layouts[0]`) is the default.

   `openMapView` would then call `openWindow(id: "bookmap", value: BookMapTarget(docID: doc.id, viewID: viewID))`.

3. **Keep it read-only**, as the Mac reader's Map is. Anything the reader rearranges is the reader's own, never written into the book. On the Mac this goes through `ReaderMapStore`, keyed by the book's address and the view id.

## Mac reference implementation

These files are in the Mac target only. Copy the behaviour, not the code.

- `OrigamiReadingView.swift`: `openMapView(_:)` sets `requestedMapViewID` and shows the map. Both URL handlers catch `origami-mapview`.
- `ReaderMapView.swift`: `initialViewID` is matched against `doc.layouts[…].sourceID` in `appear()`, before positions load.
- `OrigamiEPUBImport.swift`: the `data-map-view` branch at the top of `case "a":`. This file is shared, so it is already done for visionOS.

## How to check

1. In Author: open a document with defined concepts, save a Map view, use Layout ▸ Copy Layout, paste it into Write and name it, then Export ▸ EPUB.
2. Unzip the EPUB. The content should contain `data-map-view="VIEW-…"`, and `origami.json` should list that id under `map.views`.
3. Open the EPUB in Origami Text Vision. Pinch the marker: the book's map should open in that view, with the concepts placed as on the Mac.

## Status of the other pieces

| Piece | Commit | State |
| --- | --- | --- |
| Author (Mac): Copy Layout and export | `653e7e5b` | pushed (`map-node-model`) |
| AuthorKit: the button-role control | `460fa8e` | local in `AuthorKit-work`, not pushed; Author still pins `42f7c6b` |
| Origami Text (Mac): importer and click | `a470726` | local, not pushed |
| Author Mobile (visionOS): Copy Layout | — | not built; see below |

**Copying on Author Mobile and pasting on the Mac is not built yet.** Author Mobile keeps the same saved views (`customLayouts`) in the same document file, encoded the same way, so node ids match across devices. Two small pieces are missing:

- A Copy Layout command in Author Mobile that puts the layout JSON on the pasteboard.
- On the Mac, recognising that JSON when it arrives through Universal Clipboard as plain text. The custom pasteboard type is not guaranteed to cross devices.

Once a layout is pasted on the Mac, everything above applies unchanged.
