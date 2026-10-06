# Chapter 1 — App Shell, Library, Native Documents and Writing

Read first, and treat as normative where they apply (paths relative to the repository root):
[README.md](../README.md) (what the app is), [ORIGAMI-TEXT-OVERVIEW.md](../ORIGAMI-TEXT-OVERVIEW.md) (intent),
[ORIGAMI-DOCUMENT-FORMAT.md](../ORIGAMI-DOCUMENT-FORMAT.md) (the `.origamitext` format, called "the spec" below),
[LIQUID-DOCUMENT-FORMAT.md](../LIQUID-DOCUMENT-FORMAT.md) (a rename notice only — see §9),
[VIEW-MODULES.md](../VIEW-MODULES.md) (view modules), [USER-GUIDE.md](../USER-GUIDE.md) (where the in-app guide lives).

Sibling chapters: 02 (EPUB reading), 03 (annotations, identity, network), 04 (import/export),
05 (references, citations, people), 06 (maps, views, AI). This chapter does not repeat them.

All source paths below are inside `Origami Text macOS/`.

---

## 1. Purpose of this layer

This layer is the application frame: the single main window with sidebar / list / detail columns, menus and
keyboard routing, navigation history, and persistence of every small preference. It also owns the
**library index** (a merged, in-memory index over two feeds: `.origamitext` JSON files in a shared "community
folder", and every EPUB on the app's shelf, re-imported as structured documents), the **native document model**
(`LiquidDoc`, the in-memory form of an Origami Document), and **writing** (drafts, the Markdown-ish editor,
publishing with a Visual-Meta appendix).

Important context for a rebuilder: the app began as a `.origamitext` reader/writer and is now primarily an EPUB
reader (`AppModel.openFile` comment: "Origami Text is an EPUB reader now"). The `.origamitext` machinery is
still fully present and still feeds the index, the writing tools and most view modules, but much of its sidebar
UI is retired (§2.4). Build both; the EPUB shelf is the main user-facing library.

---

## 2. Architecture

### 2.1 Main types

| Type | File | Role |
|---|---|---|
| `OrigamiTextMacApp` | `OrigamiTextMacApp.swift` | Entry point. Creates one `AppModel`, declares scenes and menus. |
| `AppDelegate` | `OrigamiTextMacApp.swift` | Finder file opens (buffered until the model exists), global key monitor (⌘L, ⌘0, Esc), Dock reopen, Services provider, save-on-quit. |
| `AppModel` | `AppModel.swift` (≈8.5k lines) | The single observable app state object. Owns index, history, folder access, shelf, drafts, filing, read state, most preferences. Every navigation goes through it. |
| `LibraryIndex` | `LibraryIndex.swift` | Merged index: `byID`, `backlinks`, `revisionOf`, `timeline`, `supersededIDs`, `retractedIDs`, `unreadableFiles`, `revision` counter. |
| `LibraryScanner` | `LibraryIndex.swift` | Pure functions: `scan(folder:)` (read JSON files), `derive(docs:duplicateIDs:)` (compute maps), `requestICloudDownloads`. |
| `FolderWatcher` | `FolderWatcher.swift` | Recursive file-system watch, 0.5 s debounce. |
| `LiquidDoc` (+ `Paragraph`, `Link`, `Wrapped`, `Asset`, `Table`, `Concept`, `Layout`, `MapConnection`, `Reference`) | `LiquidDoc.swift` | The document model and tolerant decoder. |
| `LiquidDoc` writing extension | `LiquidDocWriting.swift` | JSON encoder, file naming, body text ⇄ paragraphs, link detection, display-side markdown, bot documents, ACM/LaTeX export (the latter covered in chapter 04). |
| `LiquidAddress` | `LiquidAddress.swift` | Address generation, validation, canonicalisation, detection in text. |
| `LiquidDate` | `LiquidDate.swift` | Human-assigned date with precision and BCE. |
| `DocumentRelation` | `DocumentRelation.swift` | The discourse vocabulary and its labels. |
| `VisualMeta`, `AuthorIdentity` | `VisualMeta.swift` | Appendix generator; user identity matching. |
| `DraftStore`, `DraftEditor` | `DraftStore.swift` | User's own documents on disk (Drafts / Published / Archived) and the editing buffer. |
| `ContentView` | `ContentView.swift` | Root layout: split view or focus layout, sheets, toasts, periodic tasks. |
| `SidebarView`, `SidebarCatalog`, `SidebarPlace` | `SidebarView.swift` | Left column. |
| List views | `DocumentListView.swift`, `DraftListView.swift` | Middle column lists. |
| `DocumentDetailView`, `ParagraphView`, `DocumentHeader` | `DocumentDetailView.swift` | Native reader for `.origamitext` documents. |
| `LibraryViewModule`, `LibraryViewRegistry` | `LibraryViewModule.swift` | Pluggable views. |
| `ModuleExchange`, `ModuleArchive` | `ModuleExchange.swift`, `ModuleSources.json` | Sharing view-module source. |
| `ViewSpecification` | `ViewSpecification.swift` | "Citation for a view" JSON format. |
| `SettingsView` + tabs, `AppSettings` (key names) | `SettingsView.swift` | Settings window. |

### 2.2 State ownership

- Exactly one `AppModel` exists for the process; it is injected into every scene through the environment
  (`.environment(model)`). Views never own document state; they bind to model properties.
- `AppModel` holds sub-stores as `let` properties: `index` (`LibraryIndex`), `drafts` (`DraftStore`),
  `people` (`PersonDirectory`), `profiles`, `locations`, `portraits`, `bots`, `letterPost`, `places`,
  `readingSearch`, `referenceStore`, `hypermedia`. Those other stores are covered by chapters 03/05/06.
- Derived lists are computed properties recomputed on read (`filteredEntries`, `inboxEntries`,
  `timelineGroups`, `epubEntries`, `shownEPUBRecords`...). Expensive derivations are cached keyed on
  `index.revision` or similar stamps.
- A transient toast: `showNote(text)` sets `transientNote`; it clears after 3 s unless replaced (token check).
  Rendered as a capsule at the bottom of the window with an opacity transition.

### 2.3 Windows and scenes (`OrigamiTextMacApp.body`)

| Scene | Id / type | Default size | Notes |
|---|---|---|---|
| Main window | `WindowGroup("Origami Text", id: "main")` | 1240×864 | Routes all external events to itself (`handlesExternalEvents(preferring: ["*"])`). On first task: `restoreFolderAccess()`, `restoreReaderLibrary()`. |
| Annotation | `WindowGroup(for: LiftedAnnotation)` | 560×440 | Chapter 03. |
| Figure | `WindowGroup(for: FigureWindowValue)` | — | Full screen disabled; floats ("associated" role). |
| Edit Document | `Window(id: "epub-editor")` | 900×940 | Only in DEBUG/EDITOR builds (`DocumentEditorView`, publisher corrections). |
| Where Have I Read This? | `Window(id: "readingSearch")` | 720×560 | Phrase search (chapter 03/06). |
| Hold Up a Page | `Window(id: "pageCamera")` | — | Never restored at launch. |
| Settings | `Settings` | width 1040 | §6. |
| Quick-view EPUB windows | created imperatively (`AppModel.showQuickView`) | 1020×940, autosave name `EPUBQuickView` | A look-only reader for EPUBs outside the library (chapter 02). |

Single-window discipline (macOS specific, but the rule is portable: **one library window**):
- `captureMainWindow`: the first window captured is "the" main window; any second library window that appears
  (restored duplicate, system-spawned window) is closed immediately.
- Window tabbing is disabled; the full-screen capability is re-added afterwards (`TabBarRemover`).
- The main window is clamped to ≤ 80 % of the screen's visible width, centred within a 10 % margin each side,
  after every resize / screen change / full-screen exit (`keepMainWindowInset`, `clampToInset`). Not applied in
  full screen.
- Launch race: when a double-clicked EPUB opens a quick-view window while the library is not visible, the main
  window is made transparent and any attempt by the system to make it key within 6 s closes it
  (`beginLaunchFoldWatch`, `launchRaisedWindow`). Portable equivalent: "opening a file from the OS must not also
  pop the library window".
- Window ▸ Library (⌘L), ⌘0 and a Dock click with no windows: `showLibraryOrOpenWindow()` — show the list
  column, select `.allDocuments`, exit full screen, bring the window forward, or open a fresh one if it was closed.

### 2.4 Navigation model

**Sidebar selection** is one value of `enum SidebarItem` (`AppModel.swift`). Default at launch:
`.epubsTimeline`. Changing it records `previousSidebarSelection` (used by ⌘W on an editor).

The enum still contains every historical place. What the sidebar actually renders (`SidebarView.body`):

| Section (header) | Rows (label → item) | Condition |
|---|---|---|
| (title) | "Origami Text" button | With a venue in focus shows a chevron; click = `leaveVenueFocus()`. |
| EPUB | Inbox → `.epubsInbox` (bold while `inboxHasUnopened`; the list is `AppModel.inboxEPUBRecords`: added in the last 30 days by `openedAt`, never fewer than the 20 newest, newest first; a row is bold while `isUnopened` — the Inbox's own `inboxOpenedEPUBs` mark, set on every open whoever the author, seeded from `readDocumentIDs`); Pinned → `.epubsTopOfPile`; Authors → `.authors`; *Papers label* → `.epubsTimeline` (context menu: "Unread" toggle); *Venue label* → `.epubJournals`; *user's surname* → `.myEPUBs`; To Acquire → `.acquisitions` | To Acquire only when the acquisitions list is non-empty. |
| Hypermedia | one row per followed space → `.hypermediaSpace(domain)`; Timeline, Pinned; "Add Space"/"Edit" (opens Settings ▸ Hypermedia) | Timeline/Pinned only when documents have been read from spaces. |
| Folders | one row per EPUB folder → `.epubFolder(name)`; "Add Folder" | — |
| XR | Graphs → `.timeFlows`; Timelines → `.timelines` | — |
| Views | Annotations; People (+ each curated person, "Add Person"); Concept Space; Tracked Concepts (+ each concept, "Add Concept"); every shown view module → `.view(id)`; "Edit Views" (opens Settings ▸ View Modules) | Module rows filtered by `hiddenViewIDs`. |
| Foot (outside the list) | Intro (opens Introduction), Settings, Contact (mailto frode@hegland.com, subject "Origami Text Feedback") | — |

With a venue (journal / proceedings) in focus (`.epubPublication`, `.epubPublicationAuthor`,
`.epubPublicationTopic`), the list shows **only** that venue's section: its name, an Authors disclosure
(sortable by first name, last name, or series rank; pin / set aside per author) and a Concepts/Topics disclosure
grouped by category (after AI analysis — chapter 06). Esc (not in full screen) or the title button leaves the
focus and lands on `.epubJournals`.

Section fold state persists in `collapsedSidebarSections` (array of section titles). On first run "XR" and
"Views" are folded once (flag `sidebarFoldsXRAndViews`).

The sidebar binds selection through a filter: the model's selection is shown only if the list has a row for it
(`hasRow(for:)`); otherwise the list shows no selection (macOS Lists stop responding when their selection names a
missing row). Choosing a row clears `openEPUB` (leaves the book reader) and sets the selection.

Retired places still reachable by code (no sidebar row): `.inbox`, `.timeline`, `.transcripts`, `.extracts`,
`.filed*`, `.drafts`, `.published`, `.notes*`, `.transcriptDrafts`, `.transcriptsPublished`,
`.bookDrafts`, `.booksPublished`, `.allDocuments`, `.archived`, `.epubsAll`, `.epubsInbox`,
`.epubsAlphabetical`, `.epubsSetAside`. For example `newDraft()` selects `.drafts`; `openInLibrary` opens a shelf
book (found by `epubRecord(forAddress:)`) in the EPUB reader through `openEPUB(address:fragment:)`, leaving
the selection where it is, and selects `.allDocuments` only for anything else. `SidebarCatalog` keeps the old section arrays (Dialog, Outgoing, Notes, Transcripts, Books)
but `sections` returns only `[("", received)]`.

**List column** (`ContentView.listPane`) maps the selection to a list view:

| Selection | List view |
|---|---|
| `.epubsAll` / `.epubsInbox` / `.myEPUBs` / `.epubsTimeline` / `.epubsAlphabetical` / `.epubsSetAside` / `.epubFolder(n)` | `EPUBLibraryListView(mode:)` |
| `.epubsTopOfPile` | `PinnedFacesView` |
| `.epubJournals` / `.epubPublication(n)` / `.epubPublicationAuthor` / `.epubPublicationTopic` | `JournalsListView` / `JournalBooksListView` / `PublicationFilteredListView` |
| `.authors` / `.epubAuthor(n)` | `AuthorsListView` / `AuthorBooksListView` |
| `.annotations`, `.people`, `.person`, `.concepts`, `.concept`, `.conceptSpace`, `.timeFlows`, `.timelines`, `.acquisitions`, hypermedia items | their own views (chapters 03/05/06) |
| `.notes`, `.noteLocations`, `.notePeople`, `.filedNotes` | note lists |
| `.drafts` / `.transcriptDrafts` / `.bookDrafts` | `DraftListView(kind:)` |
| `.published` / `.transcriptsPublished` / `.booksPublished` | `PublishedListView(kind:)` |
| `.archived` | `ArchivedListView` |
| `.inbox` / `.timeline` / `.filed…` / `.transcripts` / `.extracts` | `InboxListView` / `TimelineListView` / `LettersListView` / `TranscriptsView` / `ExtractsListView` |
| `.view(id)` | `module.makeContent()`; unknown id → `DocumentListView` |
| anything else (e.g. `.allDocuments`) | `DocumentListView` (all index entries) |

**Detail column** (`ContentView.detailPane`), first match wins:
1. `openEPUB != nil` → the EPUB reader (chapter 02).
2. Notes selections → the draft editor if the selected note is being edited, else a read-only note view.
3. `.archived` → `ArchivedDocumentView`.
4. Draft selections → `DraftEditorView` for `draftEditor`, else an empty state ("Select a draft, or create a new
   document (⌘N).").
5. `current` and `parallelDoc` both set → `ParallelReadingView` (transpointing pair).
6. Selected module has `makeDetail` returning a view → that view.
7. `current` set → `DocumentDetailView`.
8. Empty state "No Document Selected".

**Layout variants** (`ContentView.body`):
- Full screen, or `isListHidden`: no split view at all — only the detail pane (or a venue's wide Map face), plus,
  in full screen, a **peek sidebar**: a 16-pt invisible strip on the left edge; hovering shows the sidebar
  (300 pt) as a floating panel, and choosing a place unfolds a 240-pt list beside it (840 pt for To Acquire).
  It hides 400 ms after the pointer leaves; opening anything dismisses it.
- A module with `hidesDocumentList = true`: two columns (sidebar, detail).
- `wideListMode` (toggle in the find bar) or a venue Map face: two columns (sidebar, list).
- Otherwise three columns. List column width min 260 / ideal 380 / max 900 (760/760/1200 for To Acquire).
  Sidebar width min 340 / ideal 360 / max 560 (constant — changing it at runtime crashes macOS 27).
- Column visibility is forced back to "all" whenever anything collapses it, without animation.
- The find bar ("Find" field, wide-list toggle, New Document button) sits at the foot of the list column,
  except where a venue view provides its own.

**History** (`AppModel.history`, `historyPosition`): a browser-style back/forward list of `Destination
{doc, fragment}`.
- `open(doc, fragment, span)`: clears `openEPUB`; commits the pending "read" mark of the previous document; if
  `doc` is unread it becomes `pendingRead`; if it differs from the current destination, truncates forward
  history, appends, clears `parallelDoc`. Then `deliverFragment`.
- `deliverFragment`: when `fragment` names a paragraph in the body, publishes
  `FragmentRequest{docID, paragraphID, span, token}`; otherwise toast "Paragraph “x” was not found in “title”."
  Sidecars ignore fragments.
- `goBack()` first asks the open book's own back handler (`readerBackHandler`), then steps history.
  `goForward()` steps forward. Both commit pending read marks.

**Link following** (`follow(to:fragment:rel:span:)`), in order:
1. `resolve(target, rel)`: if `rel == "revises"` use the target as is, else `index.latestRevision(of:)`; look up
   `byID`. Found → `open`.
2. A published copy in `drafts.published` with that id → select `.published`, open it.
3. A draft with that id → select `.drafts`, open its editor.
4. A person address (`^[a-z0-9]+\.[a-z0-9]+$`) matching some indexed author's person prefix → select
   `.view("authors")` and set `selectedAuthor`. (See discrepancy D10: no module with id `authors` is registered.)
5. A PDF in the Reader Library whose filename identity key derives this id → open in the external Reader app
   (bundle id `com.liquid.Reader`, else system default).
6. If no Reader Library is set and the user has never been asked (`readerLibraryPrompted`), ask once for the
   folder and retry step 5.
7. Otherwise beep.

**URL scheme** `origamitext://open/<address>[#fragment]` (`handleURL`): file URLs go to `openFile`. For the
scheme: if the path names a shelf EPUB record or the user guide id, open that book (chapter 02). Otherwise
canonicalise, validate, toast "That document is not in the community folder yet." when it does not resolve, and
`follow`. Other link kinds (`gemini:`, `hm:`, EPUB links, DOIs, probed downloads) are claimed by
`AppModel.claimLink` (`RemoteEPUB.swift`, chapter 04); anything unclaimed goes to the system browser.

**File opens** (`openFile(at:)`) route by extension: folder → batch import; `epub` → join the shelf if inside
the community folder or the app's own EPUB store, else a look-only quick view; `zip`, `tex`, `xml`, `html`,
`odt`, `bib`, `ris`, `enw`, `gmi`, `json`, Word/Markdown/PDF/RTF/Typst/AsciiDoc/rST/`liquid` → importers
(chapter 04); anything else beeps with a list of supported kinds. Note: **`.origamitext` is not in this list**
(discrepancy D2). Several files arriving together: a citing document (`tex md markdown txt typ adoc asciidoc
rst`) with bibliography files (`bib ris enw`, CSL-JSON, EndNote XML) imports with them as companions
(`openFiles`).

### 2.5 Menus and keys (`OrigamiTextMacApp.commands`, `AppDelegate`)

| Menu item | Shortcut | Action |
|---|---|---|
| About Origami Text | — | About panel with Future Text Lab credits and link. |
| New Document | ⌘N | `newDraft()` (§5.8). |
| New Note | ⇧⌘N | `newNote()` |
| New Book | ⇧⌘B | `newBook()` |
| New Author | ⌥⌘N | Blank person form (chapter 05). |
| Open… | ⌘O | Multi-select open panel; `openFiles(importing: false)`. |
| Import… | ⇧⌘I | Multi-select, folders allowed; `openFiles(importing: true)`. |
| Fetch by DOI or URL…, Import Reference Dataset…, Import to Format…, Import Annotations…, Browse Catalogues…, Open Gemini URL… | — | Chapters 04/05. |
| Export to XR (Author Map)… | — | Sheet; `exportToXR` (§5.12). |
| Export Library Manifest… | — | §5.11. |
| Choose Community Folder… | ⇧⌘O | §5.1. |
| Hold Up a Page… | — | Camera window. |
| Close | ⌘W | With a draft editor open in the main window: `closeEditor()`; else close the key window. |
| Save | ⌘S | `saveDraft()`; enabled only with unsaved changes. |
| Export… | ⇧⌘E | `exportDraft()` → EPUB (see D14). |
| Export as Gemtext (.gmi)… | — | Chapter 04. |
| Show/Hide Documents | — | `toggleListColumn()`. |
| Show/Hide Links Panel | ⌥⌘L | Inspector (hidden in full screen, restored after). |
| Sort By (Date / Title), Show Superseded | — | `sortOrder`, `showSuperseded` (session only, not persisted). |
| Library | ⌘L | `showLibraryOrOpenWindow()`. |
| Where Have I Read This? | ⌥⌘F | Opens the search window with the clipboard text. Also a macOS Service (Info.plist `NSServices`, message `findInMyReading`). |
| Go ▸ Back / Forward | ⌘[ / ⌘] | `goBack` / `goForward`. |
| Go ▸ Read in Parallel | — | Submenu of `parallelCandidates`; "Exit Parallel Reading". |
| Help ▸ Origami Text Guide | — | `openUserGuide()`. |
| Help ▸ Future Text Lab Website | — | https://futuretextlab.info |

Global key monitor (works even while a text view has focus): ⌘L and ⌘0 → Library. Esc (no ⌘⌥⌃, key window
without a sheet): if a venue is in focus and not full screen, leave the venue; else toggle full screen.

---

## 3. Data on disk

"App Support" below means the per-user application data directory (`Application Support` inside the sandbox
container on macOS). Portable: `%APPDATA%/OrigamiText`, `~/.local/share/origami-text`, IndexedDB/OPFS on web.

### 3.1 Folders and files the app owns

| Path | Format | Written by | Purpose |
|---|---|---|---|
| `App Support/Drafts/<id>.origamitext` | Origami JSON | `DraftStore.save/create` | Editable drafts (letters, notes, books, transcripts). |
| `App Support/Published/<id>.origamitext` | Origami JSON with appendix | `DraftStore.markPublished` | Read-only published records. |
| `App Support/Archived/<id>.origamitext` | Origami JSON | `DraftStore.archive` (file moved whole) | Shelved drafts. |
| `App Support/EPUBs/library.json` | JSON array of `EPUBRecord` (pretty, sorted keys) | `persistEPUBRecords` | **The shelf manifest.** A failed write beeps and toasts. |
| `App Support/EPUBs/<folder>.epub` | EPUB | import | The canonical stored copy of each shelf book. |
| `App Support/EPUBs/<folder>/` | unpacked EPUB | import | Derived cache the reader serves from; rebuildable from the `.epub`. Missing `.epub`s are re-packed from it at launch (`ensureStoredEPUBs`). |
| `App Support/EPUBs/Annotations/`, `…/Analyses/`, `CitationGraph.json`, `RetractionWatch.json`, `Replications.json` | JSON | other chapters | Annotation sidecars (03), AI analyses (06), reference data (05). |
| `App Support/ViewModules/<id>.origamiview` | `ModuleArchive` JSON | `ModuleExchange.importModule` | Imported view modules ("awaiting build"). |
| `App Support/ZZStructure.json` | `{cells, dimensions, connections}` JSON | `ZZStructure.save` | The zzStructure weave (§5.15). |
| `App Support/People.json`, `PersonPortraits/`, `AuthorProfiles.json`, `Locations.json`, `PlaceDirectory.json`, `Gemtext/`, `EPUBMapLayout.json`, `ReferenceStatus.json`, `ACMart/` | various | other chapters | Listed for completeness. |
| temp dir `EPUBQuickView-<uuid>/` | unpacked EPUB | quick view | Deleted when its window closes. |
| temp dir `Introducing Origami Text.epub`, `Introduction.epub`, `<title>.epub` | EPUB | guide/intro export | Staging copies before import. |

### 3.2 Files the app reads and writes in the community folder

The community folder is any user-chosen folder (typically iCloud Drive / Dropbox). Everything below is shared
across devices by whatever syncs the folder.

| File | Direction | Format / meaning |
|---|---|---|
| `**/*.origamitext` | read (recursive) | Origami documents (§4). Hidden files and package contents skipped. |
| `**/*.epub` | read (recursive) | Imported to the shelf on every scan; new ones arrive unread. |
| `<folder>.epub` mirrored | write | `mirrorShelfToCommunityFolder()`: shelf books the folder lacks are published into it (chapter 02 details). |
| `origami-standing.json` | read/write | `{pinned:[fileName], setAside:[fileName], concepts:[String]?, modified:Date}` — pins and set-asides keyed by community file name (`EPUBRecord.folder`), last-writer-wins by `modified`. Written on every change; adopted on every scan and every 4 s (`ContentView` loop). |
| `origami-acquisitions.json` | read/write | `{wanted:[{id,title,author,year?,doi?,added}], modified}` — books asked for from the headset. |
| `_publication-analyses.json`, `_document-extractions.json`, `_seed-links.json`, `origami-citation-graph.json`, `origami-sankey.json`, floor-history files, `origami-concept-overrides.json`, `origami-map-layout.json`, `origami-spatial-notes.json` | read/write | Owned by chapters 05/06. Legacy `publicationAnalyses` UserDefaults data is migrated into `_publication-analyses.json` once. |
| `People.json`, `Localities.json` | read/write | Shared contact directory and gazetteer (chapter 05). On choosing a folder the user's own person record is created if missing and the directory attached (`shareContacts`). |
| `sample--*.origamitext` | write/delete | DEBUG-only sample community (§5.13). |
| `.check/RUN-FORMAT-SELFTEST` → `.check/out/`, `.check/report.txt` | read/write | DEBUG-only format self-test trigger. |
| `.<name>.icloud` placeholders | read | Each is asked to download by its real name before scanning (`requestICloudDownloads`). |

### 3.3 Other locations

| Location | Use |
|---|---|
| Reader Library folder (user-chosen, read-only bookmark) | PDFs indexed by the identity key in their filename (§4.4). |
| App Group `<TeamID>.com.liquid.author.shared` (`OrigamiText.entitlements`; used in `OverviewPictures.swift` as `9Q5N4A727S.com.liquid.author.shared`) | Shared with the sibling app Author: Overview pictures cache (chapter 02/06). |
| Keychain service `hypermedia.identity`, account `signing-key`; Hypothesis token under `https://api.hypothes.is` | Chapter 03. Read only at signing time. |
| Bundle resources | `ModuleSources.json`, `OrigamiTextUserGuide.md`, optional `Introduction.epub`, bundled spec Markdown files. |

### 3.4 UserDefaults state (not user-visible settings)

Settings shown in the Settings window are in §6. These keys hold app state:

| Key | Type | Meaning |
|---|---|---|
| `communityFolderBookmark` | data | Security-scoped bookmark of the community folder. |
| `readerLibraryBookmark`, `readerLibraryPrompted` | data, bool | Reader Library folder (read-only scope); whether the user was asked once. |
| `readDocumentIDs` | [String] | Ids of documents (and shelf records) opened. Complement = unread. |
| `filedFolders` | {id: folder} | Filing of `.origamitext` documents. |
| `filingFolders` | [String] | Default `["Work","Personal","Archived"]`; new folders inserted before Archived. |
| `archivedLetterIDs`, `archivedNoteIDs` | [String] | Legacy; migrated into `filedFolders` as "Archived" then removed. |
| `hiddenViewIDs` | [String] | Module ids switched off. Absent → all modules except `defaultShownIDs`. |
| `mutedAuthors` | [String] | Muted names (case-insensitive match). |
| `epubFolders`, `epubFiling` | [String], {recordID: folder} | Shelf folders. |
| `epubTopOfPile`, `epubSetAside` | [String] (sorted) | Pinned / set-aside record ids (mirrored to `origami-standing.json`). |
| `viewPeople`, `viewConcepts` | [String] | Curated People and Tracked Concepts rows. |
| `venueAliases` | {String: String} | Merged venue names (chapter 05). |
| `collapsedSidebarSections`, `sidebarFoldsXRAndViews`, `expandedTopicCategories` | various | Sidebar fold state. |
| `libraryTimelineUnreadOnly`, `libraryAlphabeticalUnreadOnly` | bool | "Unread" narrowing of Papers / Alphabetical. |
| `papersSortKey` ("date") / `papersSortAscending` (false); `mineSortKey` ("date") / `mineSortAscending` (false) | String/bool | Title/Date tabs. |
| `authorsSortKey` ("name"), `authorsSortAscending` | String/bool | Authors list sort. |
| `pubAuthorsSortMode` ("first" / "last" / "rank"), `pubTopicsSortMode` ("count") | String | Venue focus lists. |
| `sideBySideSync` (true) | bool | Side by Side scroll lock. |
| `introGuideVersion` | int | Built-in guide edition last written (current 6). |
| `bundledIntroductionStamp`, `bundledIntroductionRecordID` | double, String | Bundled Introduction.epub version and its shelf record. |
| `openSourceDocStamp-<resource>` | double | Modification time of a bundled Markdown doc last converted. |
| `introShownOnce` | bool | Written at launch; never read (D17). |
| `interatlasAppPath`, `liquidAppPath` | String? | Apps receiving scene links (Settings ▸ Library). |
| `editorMode` | bool | Hidden flag enabling Editor Mode in publisher builds. |
| `marginNotePositions`, `bookmarks*`, `readingPosition*`, `readerMode`, `publicationAnalyses`, `sourceArchivesFolder`, `formatSheet.lastJournal`, `knowledgeSpace.anchors`, `personalGlossary`, `trailProgress`, `h-view`/`i-view` keys, `selectedModelID`, `llmEndpoints`, `OverviewPictures*`, `ThemeColorOverrides`, `themeColorOverridesTick`, `annotationKindNames`, `annotationKindColors`, `textColoringMode`, `textColorRules`, `homeLocation`, `workLocation`, `locationAliases` | various | Owned by other chapters; listed so a rebuild does not collide with them. |

Notification names used across the layer: only `OverviewPicturesChanged` (posted when a portrait is adopted).
Everything else is observation of `AppModel` properties plus OS window notifications.

---

## 4. The native document model

Normative format: [ORIGAMI-DOCUMENT-FORMAT.md](../ORIGAMI-DOCUMENT-FORMAT.md). This section records what the code
actually does, including fields the spec does not mention.

### 4.1 `LiquidDoc` fields

Spec fields (`LiquidDoc.swift`): `format`, `id`, `title`, `author`, `created` (Date), `body: [Paragraph]?`,
`links: [Link]`, `wraps: Wrapped?`, `attention: [String]`, `date: LiquidDate?`, `aiOnBehalf: Bool`,
`onBehalfOf: String?`, `documentType: String?`.

Extra JSON fields read and written by this implementation but **not in the spec** (D3):

| JSON key | Model | Shape |
|---|---|---|
| `location` | `location: String?` | Free-form place name where the document was made. |
| `sourceURL` | `sourceURL: String?` | Canonical origin URL (e.g. `hm://…`). Enables threaded Hypermedia comments under the document. |
| `publication` | `publication: String?` | Journal/proceedings name. |
| `concepts` | `[Concept]` | `{id, name, description?, tag?, citationIdentifiers?, urls?}` |
| `layouts` | `[Layout]` | `{index, name, positions:[{id,x,y,z}], id?}` — `index` defaults to position+1, `name` to "Layout n". |
| `connections` | `[MapConnection]` | `{from, to}` |
| `references` | `[Reference]` | `{id, bibtex}` — external citation records (no library address). |
| `tables` | `[Table]` | `{identifier, rowCount, columnCount, cells:[[{value, formula?}]]}` |
| `assets` | `[Asset]` | `{id, filename, mediaType, dataBase64, alt?, link?, citationKey?}` — referenced from body as `![alt](asset:<id>)`. |
| `body[].tableID` | `Paragraph.tableID` | The paragraph stands for a table; its `text` holds a pipe-table fallback. |

In-memory-only fields (never written to `.origamitext`, filled by EPUB import, lost on a JSON round trip):
`subtitle`, `journal`, `doi`, `affiliations`, `acmReference`, `authorORCIDs`, `authorEmails`,
`authorAffiliations`, `authors`, `abstract`, `keywords`, `isbn`, `ccsConcepts`, `license`, `licenseURI`,
`language`, `forms`, `authorForms`, `bibliographyConventions`; `Paragraph.stretchID`, `boxID`, `provenance`;
`Concept.userDefinition`, `markedForms`; `Reference.citedAs`, `number`, `forms`; `Table.Cell.columnSpan`.
`fileURL` is the load location.

Derived properties:
- `listedDate = date?.sortDate ?? created` — what lists sort and filter by.
- `listedDateText = date?.displayText ?? created` (abbreviated date).
- `displayAuthor`: `"AI on behalf of <author>"` if `aiOnBehalf`; else `"<author> on behalf of <onBehalfOf>"`
  when `onBehalfOf` differs (case-insensitive) from `author`; else `author`.
- `creditedAuthor`: `onBehalfOf` when non-empty and different from `author`, else `author` — used wherever
  documents are grouped by person. Identity logic (unread, muting, attention) uses plain `author`.
- `isSidecar = wraps != nil`; `hasUnfamiliarFormatVersion = format != "origami/0.1"` (badge only).
- `DocumentType` recommended tokens: `letter note book rfc personal project meeting transcript extract article
  external` (plus `bot` and `manifest` written elsewhere). Unknown tokens kept verbatim.

### 4.2 Decoding rules (`LiquidDoc.decode(data:fileURL:)`)

Implement exactly; errors carry the listed messages (they appear greyed in "Unreadable Files"):

1. Parse JSON into a shape with every field optional; unknown keys ignored. Failure → "Not valid JSON: …".
2. `format` required; must start with `origami/0` else "Unsupported format".
3. `id` required; canonicalise (trim spaces, lowercase); must pass `isValid` (§4.3).
4. `title`, `author`, `created` required. `created` parses as ISO 8601 with or without fractional seconds.
5. Exactly one of `body` / `wraps` ("A document may have “body” or “wraps”, not both" / "…needs either…").
6. Each paragraph needs `id` and `text` ("Paragraph n is missing its “id” or “text”"). `heading` clamped to 1…3.
   `speaker` trimmed, empty → nil. `tableID` empty → nil.
7. Links: missing `to` or invalid address after canonicalisation → link silently dropped. `fragment`, `rel`,
   `bibtex`, `span` copied.
8. `wraps` needs `file` and `sha256`.
9. `attention`: trimmed, empties removed. `date`: parsed by `LiquidDate(isoString:)`, unparseable → dropped.
   `onBehalfOf`, `location`, `publication`, `sourceURL`: trimmed, empty → nil. `documentType`: trimmed,
   lowercased, empty → nil.
10. Concepts without `id`/`name`, positions without `id`, connections without both ends, references without
    `id` or with empty `bibtex`, tables without `identifier`, assets without `id` or `dataBase64` → skipped.

### 4.3 Addressing (`LiquidAddress.swift`)

```
nameComponents(author):
  parts = author split on " "
  initialSource = sanitize(parts.first)
  lastSource    = sanitize(parts.count > 1 ? parts.last : parts.first)
  initial = initialSource.isEmpty ? "x"   : first char of initialSource
  surname = lastSource.isEmpty    ? "doc" : first 5 chars of lastSource
sanitize(s) = transliterate to Latin, fold diacritics, lowercase, keep ASCII letters/digits only
personPrefix(author) = initial + "." + surname

makeID(author, created, isTaken):
  hhmmss = created formatted "HHmmss" in UTC, POSIX locale
  days   = floor(created.unixSeconds / 86400)          (integer truncation)
  dayChar = "abcdefghijklmnopqrstuvwxyz0123456789"[((days % 36) + 36) % 36]
  preferred = initial "." surname "." hhmmss dayChar
  if !isTaken(preferred) return preferred
  up to 64 times: candidate = initial "." surname "." 6 random chars of the alphabet; return if free
  else return initial "." surname "." first 8 chars of a lowercased UUID
```

Example: "Frode Hegland", 2026-07-11T09:32:52Z → `f.hegla.093252x`.

- `isValid(id)`: non-empty, no `#`, no `/`, no whitespace or newline.
- `canonical(id)`: trim spaces, lowercase.
- `isPersonAddress(id)`: regex `^[a-z0-9]+\.[a-z0-9]+$`.
- Collision callers: `DraftStore.create` checks only existing drafts; `exportLibraryManifest` and transcript
  summaries check index + drafts; `LibraryIndex.isIDTaken` checks index and the existence of
  `<folder>/<id>.origamitext` (D19).

**Addresses in text** (`matches(in:)`): three regexes tried in order; later matches overlapping an earlier
match's range are discarded.

| Order | Pattern | Groups |
|---|---|---|
| 1 | `origamitext://open/([A-Za-z0-9][A-Za-z0-9.-]{0,80})(?:#([A-Za-z0-9_.-]+))?` | id, fragment |
| 2 | `\[(?:([a-z][a-z-]{1,24}):)?([A-Za-z0-9][A-Za-z0-9.-]{2,80})(?:#([A-Za-z0-9_.-]+))?\]` | rel, id, fragment |
| 3 | `([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:#([A-Za-z0-9_.-]+))?` | legacy UUID, fragment |

Ids from matches are canonicalised. Note form 2 requires ids of 3–81 characters and a lowercase rel of 2–25
characters.

### 4.4 Identity-key file names

- `identityFileName(extension:)` → `"<Title>(<Author-With-Hyphens>-<YYYY-MM-DDTHH_MM_SSZ>).<ext>"`. Title is
  trimmed, `/` and `:` → `-`, empty → "Untitled", truncated so the whole name stays ≤ 240 characters. Used as
  the default name for EPUB export.
- `identityKeyID(inFileName:)`: regex `\((.+?)-(\d{4}-\d{2}-\d{2}T\d{2}_\d{2}_\d{2}Z)\)`; author = group 1 with
  `-` → space; created = group 2 with `_` → `:`; returns `makeID(author, created)` (no collision check). Used to
  index Reader Library PDFs.
- `suggestedExportFileName`: `"<slug>--<id>.origamitext"`, or `"<id>.origamitext"` when the slug is empty
  (D1). `fileSlug(title)`: "Untitled" (case-insensitive) → ""; lowercase words split on non-letter/non-digit,
  joined by `-` while the result stays ≤ 24 characters; a single over-long first word is cut to 24.

### 4.5 Dates (`LiquidDate.swift`)

- Stored: `year` (astronomical: 1 BCE = 0, 329 BCE = −328), optional `month` 1–12, optional `day` 1–31 (only
  kept when month present). Out-of-range month/day in the initialiser become nil.
- Parse `^(-?\d{1,6})(?:-(\d{1,2}))?(?:-(\d{1,2}))?$` (after trimming). Out-of-range month/day in the string → fail.
- Write: year as 4 digits with leading zeros (`-0328` for negatives), then `-MM`, then `-DD`.
- `sortDate`: days-from-civil (Howard Hinnant) on the proleptic Gregorian calendar with missing month/day = 1,
  at 12:00 UTC.
- Display: `yearText` = "2026" or "329 BCE"; `monthYearText` = "July 2026"; `displayText` = "7 July 2026".
- UI entry (`DateAssignmentPopover` in `DraftEditorView.swift`): precision Day / Month / Year, day and month
  pickers, a year field (> 0), CE/BCE; "Use Creation Date" clears it; seeded from the existing date or the UTC
  creation day.

### 4.6 Relations (`DocumentRelation.swift`)

| rel | Action title | New-draft title prefix | Byline label | Visual-Meta field |
|---|---|---|---|---|
| `cites` | — | — | — | — (goes to references block) |
| `responds-to` | Respond | "Responding to " | Responding to | `responds-to` |
| `extends` | Extend | "Extending " | Extending | `extends` |
| `supports` | Support | "Supporting " | Supporting | `supports` |
| `questions` | Question | "Questioning " | Questioning | `questions` |
| `disagrees-with` | Disagree | "Disagreeing with " | Disagreeing with | `disagrees-with` |
| `summarizes` | Summarize | "Summarizing " | Summarizing | `summarizes` |
| `revises` | — | — | Superseding | `supersedes` |
| `retracts` | — | — | Retracting | `retracts` |

`discourseActions` (menu order) = respond, extend, support, question, disagree, summarize. Edge colours
(`RelStyle` in `ParallelReadingView.swift`): cites blue, responds-to green, revises orange, relates-to purple,
extends teal, supports mint, questions yellow, summarizes indigo, disagrees-with and retracts red, other grey.
`relates-to` has a colour but no `DocumentRelation` case (D5).

### 4.7 Writing rules (`LiquidDocWriting.swift`)

- `jsonData()`: pretty-printed, **keys sorted**, slashes not escaped. `created` written as ISO 8601 without
  fractional seconds. Optional fields omitted when empty/nil/false (`links` omitted when empty; `aiOnBehalf`
  only when true). Paragraph keys: `id, heading?, text, speaker?, tableID?`. Link keys: `to, fragment?, rel?,
  bibtex?, span?`.
- Body editing text: each paragraph as one line, prefixed `# `/`## `/`### ` by heading level, joined with a
  blank line (`\n\n`).
- `parseBody(from:)`: split on newlines, trim spaces, skip blank lines; a leading `### `/`## `/`# ` (checked
  longest first) sets the heading and is removed; ids assigned `p1…pn` on **every** parse (matches spec §6).
- `detectedLinks(in:)`: every address match in every paragraph except person addresses, deduplicated by
  `id#fragment`; `rel = match.rel ?? "cites"`; for a paragraph-scoped match, `span` = the preceding quotation:
  the last `”` before the match, at most 80 characters before it with no other curly quote between, and its
  opening `“`; trimmed; empty → nil.
- Display-side: `effectiveHeading = heading ?? markdown prefix level`; `displayText` strips a markdown heading
  prefix when `heading` is nil, else strips a leading `"<speaker>:"`. `renderedText` = inline markdown
  (whitespace preserved) + auto-linked web URLs + every address turned into an `origamitext://open/<id>#frag`
  link; all links drawn in the body colour with a single underline.
- `visualMetaParagraphIDs`: from the first paragraph whose display text starts with "Visual-Meta Appendix" or
  whose text contains `@{visual-meta-start}`, to the end.

### 4.8 Visual-Meta appendix (`VisualMeta.swift`)

`appendingAppendix(to:identity:)`:
- Sidecars and bodies already containing `@{visual-meta-start}` are returned unchanged (idempotent).
- Appends paragraphs with ids `vm1, vm2, …`: `---`; H2 "Visual-Meta Appendix — Notes for a Human or AI
  Reader"; an intro; H3 sections HOW TO LOCATE IT, HOW TO USE IT, CONVENTIONS, FIELD KEY (Author-specific) with
  fixed prose (copy verbatim from the source); a versioning paragraph (`visual-meta-intro/2026-07`); then the
  machine block as **one** paragraph.
- Machine block:

```
@{visual-meta-start}
@{visual-meta-header-start}
@visual-meta{
version = {1.1},
generator = {Origami Text 1.0},
}
@{visual-meta-header-end}
@{visual-meta-bibtex-self-citation-start}
@article{<citeKey>,
author = {…},
title = {…},
[day = {d},] [month = {jan…dec},] year = {y}, [era = {1},]
<relation fields: first link per relation, e.g. responds-to = {address}>
[attention = {A and B}] [ai-on-behalf-of = {author}] [on-behalf-of = {name}]
[document-type = {…}] [location = {…}]
[personal-title / orcid / affiliation — only when identity.matches(author)]
origami-id = {id},
vm-id = {created ISO 8601}
}
@{visual-meta-bibtex-self-citation-end}
[@{references-start} … @{references-end}]
@{visual-meta-end}
```

  Fields are joined with `,\n`. Dates: with a human `date`, day/month only at that precision, year = display
  year, `era = {1}` for BCE; otherwise day/month/year of `created` in UTC. Cite key = alphanumeric lowercase last
  word of author + year + alphanumeric lowercase first title word (`untitled<year>` if empty). References block:
  each link's `bibtex` (first per target) with `origami-id = {to}` injected before the closing brace (unless
  already present), then each external `Reference.bibtex` verbatim, separated by blank lines.
- Escaping: `\` → `\textbackslash{}`, `~` → `\textasciitilde{}`, `^` → `\textasciicircum{}`,
  `& % $ # _ { }` → backslash-prefixed; everything else raw UTF-8.
- The returned document keeps concepts, layouts, connections, references but **drops tables, assets,
  sourceURL, publication** (D6).
- `AuthorIdentity.matches(author:)`: trimmed, case-insensitive equality with the user's name.

### 4.9 Sidecars (`SidecarView.swift`)

Wrapped file URL = `wraps.file` resolved relative to the sidecar's folder. On display, SHA-256 of the file is
computed off the main thread and compared lowercase: mismatch → banner "This file has changed since it was
catalogued."; unreadable → no banner. PDFs render inline with an "Open in Reader" button; other types offer
"Open in Default App"; missing file → "Wrapped File Missing". Fragments ignored.

### 4.10 Bot documents (`BotDocument` in `LiquidDocWriting.swift`)

`documentType = "bot"`, title `"<Name> bot"`, author = title, file `slug--id.origamitext`. Body: "An AI stand-in
for Name (years)."; optional summary; a fixed machine-written disclaimer; H2 "Judgements"; one paragraph per
judgement sorted by judged id: `"Would agree — "`/`"Would disagree — "`/`"Neutral — "` + reason + ` [docID]`,
with links rel `supports`/`disagrees-with`/`cites`. `parse` reverses this tolerantly. Behaviour of bots is in
chapter 06.

---

## 5. Features

### 5.1 Community folder

- **User sees:** File ▸ Choose Community Folder… (⇧⌘O) or Settings ▸ Library. The path is shown; "Rescan for
  EPUBs" forces a scan.
- **Rules:** the choice is stored as a security-scoped bookmark (`communityFolderBookmark`) and restored at
  launch (`restoreFolderAccess`). Choosing: save bookmark, start access, `index.setFolder(url)` (JSON scan +
  watcher), `shareContacts`, start a second watcher for EPUBs, run the EPUB scan.
- **JSON scan** (`LibraryScanner.scan`, background): request iCloud downloads; enumerate recursively skipping
  hidden files and package contents; decode every `*.origamitext` (extension compared lowercase); on decode
  failure record `UnreadableFile{url, reason}`; on duplicate id keep the file with the later modification date
  and flag the id. Results are applied only if no newer scan started (generation counter).
- **EPUB scan** (`scanCommunityFolderForEPUBs`): cancels a running scan; for each `*.epub` prepares the import
  off the main thread (unzip only if the source is newer than the unpack), folds results into the shelf,
  persists the manifest and rebuilds the EPUB index once; then `finishCommunityScan`: mirror the shelf into the
  folder, adopt standing, read acquisitions / analyses / extractions / Seed links, citation-graph mirror and
  background fetches (chapters 05/06).
- **Watching:** FSEvents with 0.3 s latency, then 0.5 s debounce, callback → rescan. Both the index and the
  EPUB scan watch the same folder independently.
- **Edge cases:** iCloud placeholders; files arriving mid-scan (next watcher event rescans); unreadable files
  never crash, they list under "Unreadable Files".
- Files: `AppModel.swift` (Community folder access), `LibraryIndex.swift`, `FolderWatcher.swift`.

### 5.2 The merged index

- `LibraryIndex` holds two feeds: `scannedDocs` (community JSON) and `epubDocs` (shelf books re-imported as
  `LiquidDoc`s by `AppModel.rebuildEPUBIndex`, chapter 02). `rebuild()` concatenates **JSON first, EPUB last**,
  so on a shared id the EPUB document wins, silently (no duplicate flag).
- `derive(docs:)`: for every doc, `byID[id] = IndexEntry(doc, hasDuplicate)`; for every link,
  `backlinks[to].append({fromID, rel, fragment})`; `rel == "revises"` → `revisionOf[to] = doc.id` (last one
  wins); `rel == "retracts"` → `retractedIDs.insert(to)`. `timeline` = all entries sorted ascending by
  `listedDate`. `supersededIDs = keys(revisionOf)`. `revision += 1` on every rebuild.
- `latestRevision(of:)`: follow `revisionOf` forward with a visited set; on a cycle return the input.
- EPUB index rebuilds are debounced 250 ms, superseded by newer requests mid-flight, and memoised per book by a
  content stamp (`modDate:size:recordID:dateISO` of `content/paper.html`).
- `upsertEPUBDocument` adds one book without re-deriving the others' imports.

### 5.3 Document lists (`.origamitext` entries)

- `visibleEntries`: all `byID` values minus muted authors, minus documents filed under "Archived", minus
  superseded ids unless `showSuperseded`; then Find narrowing.
- **Find** matches title, author, `onBehalfOf`, or any paragraph text, case-insensitively.
  `searchNarrowed` rule (used by every list): if the query matches nothing, the list is returned **whole** and
  the system beep sounds once per distinct query.
- `filteredEntries`: sorted by title (localized, case-insensitive ascending) or by `listedDate` descending.
- **Row** (`DocumentRow`): person icon when addressed to the user (`attention` matches identity); title bold if
  unread, else medium; red octagon if retracted; document icon if sidecar; yellow triangle if duplicate id;
  second line "displayAuthor · date" (date = human date text, else created date, with time in the timeline).
  Retracted rows at 55 % opacity.
- **Selection = navigation**: selecting a row id opens the index entry, else a published copy, else an EPUB
  record (`AppModel.listSelection`).
- **Inbox** (`inboxEntries`, retired from the sidebar): entries by others — all unread, then the 20 most recently
  read; EPUB records by others not already present are inserted at the top. A soft bar separates unread from
  read. Dropping EPUBs/importables onto it imports them.
- **Timeline** (`timelineGroups`): letters (index + own published copies not archived), newest first, grouped by
  `date.monthYearText` or created "Month Year".
- Files: `DocumentListView.swift` (`DocumentListView`, `InboxListView`, `TimelineListView`, `DocumentRow`,
  `UnreadableFilesSection`), `AppModel.swift` (List filtering and sorting).

### 5.4 Read / unread state

- A document is unread when its author is not the user (`authorIdentity.matches`) and its id is not in
  `readDocumentIDs`. The user's own documents are never unread.
- Opening marks **lazily**: the document becomes `pendingRead` and is marked read only when another document
  takes the reading pane or history moves (so it does not vanish from an Unread list while being read).
  Quitting mid-read leaves it unread.
- "Unread" button in the reader: removes the id and cancels any pending mark.
- Shelf records: `isUnread(record)` uses a listing document (id = record id, author = record author); opening a
  stored EPUB marks it read immediately. "Own author" for the inbox also accepts token-subset matches ("Frode
  Hegland" ⊂ "Frode Alexander Hegland").
- `hasUnreadInbox` drives bold Inbox (retired row).

### 5.5 Filing, muting, attention, correspondents

- Filing (`.origamitext`): `filedFolders[id] = folder`; private, never written into files. "Archived" is the only
  folder with meaning: archived documents leave the Timeline and other lists. Menu "File" lists New…, the
  folders (checkmark on the current), and "Unfile". New folder: modal name prompt; duplicate names
  (case-insensitive) reuse the existing spelling.
- Muting: `mutedAuthors`; muted authors' documents are removed from library lists; files untouched. Edited in
  Settings ▸ Author ▸ Muted People.
- Attention: `attentionEntries` = entries whose `attention` contains a name matching the user.
- `topCorrespondents` (max 10): counts interactions — for each document, links from the user's documents
  credit the target's `creditedAuthor`; links from others to the user's documents credit the source;
  `attention` on the user's documents credits each name; documents addressed to the user credit the author.
  Sorted by count desc then name; padded with other library authors alphabetically.
- Test account (Settings ▸ Author): while on, `authorName` and identity become `testAccountName` (default "Test
  Reader"), name only.
- `authorName` = test name, else stored `authorName`, else the OS full user name.

### 5.6 The EPUB shelf lists (`EPUBLibraryListView`)

The main library in today's UI. Records come from `epubRecords` (manifest), newest `openedAt` first. Modes:

| Mode | Records |
|---|---|
| all | shown (not set aside), pinned first |
| folder(n) | shown and filed under n, pinned first |
| inbox | shown and unread, pinned first |
| topOfPile | shown and pinned |
| timeline (Papers) | shown, optionally unread only; Title/Date tabs (`papersSortKey/Ascending`); pinned first |
| alphabetical | shown, optionally unread only, by title |
| setAside | the set-aside records |
| myEPUBs | records by the user's name; Title/Date tabs (`mineSortKey/Ascending`) |

- Date sort uses the record's `dateISO` (ISO 8601), else `openedAt`. Title sort is localized
  case-insensitive; a second click on the active tab reverses.
- Find splits results into "Title, Author or Venue" and "In the Text" (a passage with the words bolded and a
  count of places); choosing an in-text hit opens the book already searching for the words.
- Row: pin glyph (ember orange, RGB 0.72/0.42/0.06) when pinned; title bold when unread, custom
  title font if set; author, "· folder" when filed and not inside that folder; the user's whole-document
  annotation in italics (chapter 03).
- Selection: a single click opens the book (and, on a venue/pinned Map face, switches back to the documents
  face); ⌘-click builds a multi-selection without opening (for "Export n with DOI Names…").
- Context menu: File Under (folders, New Folder…), Remove from Folder, Copy to Cite, Read Beside "<open book>"
  (Side by Side), Pin, Set Aside / Bring Back, (DEBUG/EDITOR: Show in Finder, Show PDF, Save a Copy as EPUB…,
  Export with DOI Name(s)…, Edit Document…), Move to Trash.
- Pins and set-asides persist locally and in `origami-standing.json` (§3.2). Set Aside closes the book if open.
- Empty states have specific texts (e.g. "Nothing Unread", "No EPUBs by You").
- A just-imported book is revealed: leave venue focus, clear Find, clear Unread-only if the book is read,
  select Papers, scroll to and select its row after 150 ms.

### 5.7 Native reader (`DocumentDetailView.swift`)

- Sidecars → `SidecarView`. Otherwise: in a window the header lives in a resizable right column
  (`readerHeaderColumnWidth`, default 250, min 180, leaves ≥ 420 pt for text); in full screen the header is
  above the text and the text is flanked by outbound (left) and inbound (right) connection columns. Text width:
  full screen `fullScreenContentWidth` (default 760), right-column layout 960, top layout 620.
- Order of content: optional transcript Summary & Notes block; a red "This document has been retracted by its
  author." banner; body paragraphs excluding the appendix; a "Hide Metadata"/"Metadata" toggle
  (`hideVisualMeta`) and the appendix at half size; threaded Hypermedia comments when `sourceURL` starts with
  `hm://`; footer with location (context menu "Location") and date (context menu "Timeline").
- Paragraph rendering (`ParagraphView`): a paragraph of ≥ 3 characters all in `-—–` → horizontal rule; a
  `tableID` with a matching table → read-only grid, first row as header; else optional speaker label, then text.
  Top padding by effective heading 20/14/10. Inbound citation count badge ("Cited by n documents") from
  backlinks whose fragment equals the paragraph id.
- Fragment arrival: wait 80 ms, scroll the paragraph to the top (0.3 s), yellow 35 % paragraph highlight, and
  for span-scoped links a stronger 85 % yellow on the first case/diacritic/width-insensitive match of the span;
  after 300 ms fade out over 1.5 s. A span that does not occur leaves only the paragraph highlight.
- Controls (others' documents only for the first row): Unread, File menu; Bot Check (when bots exist, others'
  documents), Emotions (on-device model labels paragraph ids positive/negative; ids not in the document dropped;
  ids on both sides dropped; tint green/red 16 %), Flow (display-only line breaking: blank line after
  sentence-ending periods between a letter and a capital, newline after in-sentence commas not next to digits,
  around parentheses; headings untouched).
- Context menus: header — Copy to Cite, Export as EPUB…, discourse actions (others' documents); paragraph —
  Copy to Cite (with paragraph), Copy Link to Paragraph (`[id#pN]` to the clipboard), discourse actions.
- Link handling: `origamitext-transclude://<address>/<paragraphID>#<fragment>` toggles a transclusion;
  everything else goes to `claimLink`, then the browser.
- Transclusion (`TransclusionView.swift`): after every non-self, non-person address in a paragraph a thin
  space + "⧉" link is inserted (secondary colour, primary when open). Open state key
  `"<paragraphID>|<address>#<fragment>"`. The unfolded quote resolves through `latestRevision`; quotes the
  addressed paragraph (or the first paragraph for whole-document citations); messages for "not in the community
  folder yet", "no text body", or "Paragraph … was not found; it may have changed in a revision."; attribution
  line "— Title · Author, Year" opens the source at the fragment.
- Header (`DocumentHeader`): author and date for others' documents, provenance links for each discourse
  relation ("Responding to <Original>"…), "Superseding" link, and for own published documents Supersede /
  Follow Up actions; a "What changed?" dialog compares with the superseded version (`RevisionDeltaView`).

### 5.8 Writing: drafts and the editor

- **Create** (`DraftStore.create`): id from `makeID(author, now)` with collision check against drafts only;
  title "Untitled", empty body, saved immediately to `Drafts/<id>.origamitext`.
- **⌘N** (`newDraft`): if words are selected in a native reader text view: in a transcript (the paragraph's
  speaker, or the nearest earlier speaker) → lift an extract on the speaker's behalf; otherwise ask "New Reply"
  with a pop-up of discourse kinds, start that discourse draft and put the quote (citation convention) plus a
  blank line in the body. With nothing selected: a new draft with `documentType = "letter"`.
- **⇧⌘N** note (`documentType "note"`, selects Notes), **⇧⌘B** book (`"book"`, selects book drafts).
- **Derived drafts** (`startDerivedDraft`): Supersede → copy body minus appendix, title "Title (v2)" (or
  increments "(vN)"), link `revises`; Follow Up → empty, "Title (follow up)", `responds-to`; discourse
  (`startDiscourse`) → empty, prefix + title, that rel; Use as Template → copy body, "Title (new)", no link;
  Retract → body "This document retracts “Title” [id].", title "Retraction of Title", `retracts`. Derived drafts
  carry no `documentType` (D18).
- **Editor buffer** (`DraftEditor`): title, author, bodyText, attention, onBehalfOf, date, assets, plus
  `pendingReferences[address] = bibtex` (from pastes) and `referenceOverrides[id] = bibtex` (from Preflight).
  `buildDocument()`: parse body; re-attach `speaker` to paragraphs starting with a speaker name the original
  already knew; keep original links and add detected links not already present (same `to`+`fragment`) and not
  pointing at itself; attach pending BibTeX to links lacking one; apply overrides to links and references; empty
  title → "Untitled"; keep `aiOnBehalf`, `documentType`, concepts, layouts, connections, assets.
  (`location`, `sourceURL`, `publication`, `tables` are not carried — unclear from source whether intended.)
- **Saving:** ⌘S; automatically 800 ms after the title stops changing, when the title loses focus, when the
  editor disappears, before another draft opens, and at quit (`applicationWillTerminate`). Saving also writes the
  editor's author name back as the default author.
- **⌘W** (`closeEditor`): an empty untouched draft (all paragraphs blank, title empty or "Untitled", no
  attention) is deleted; otherwise saved; then the previous sidebar selection is restored.
- **Delete** moves the file to the OS Trash. **Archive** moves the file to `Archived/` unchanged;
  **Un-Archive** moves it back.
- **Editor UI** (`DraftEditorView.swift`): title field (28 pt heading font; "Untitled" preselected on a new
  document; Tab jumps to the body; "Suggest" asks the language model for a one-line title when the title is
  unset and the body is non-empty); author field; "On Behalf Of…" menu + popover; date button (popover §4.5);
  "Attention of" popover (checkboxes for ranked correspondents, then all library authors and People records,
  plus "New…" which creates a person); attention chips removable by click; transcript speakers as chips (Profile,
  Contact Record, Add to People, Associate with Record); the body editor; an image strip; foot hint "One paragraph
  per line. Start a line with #, ##, or ### for a heading."; "Preflight References…"; "Insert Image…"; Archive.
  Transcript drafts get a side column with publish/archive and Summary & Notes.
- **Body editor** (`MarkdownTextEditor.swift`): plain text is the source of truth. Styling per edited paragraph:
  serif body 17 pt; heading lines 28/23/19 pt bold; with `hideHeadingMarkers` (default on) the `# ` markers are
  shrunk to near-zero width; inline emphasis `*`/`**`/`***` and `_` forms rendered with markers hidden
  (regexes `(?<!\*)(\*{1,3})(?![\s*])(.+?)(?<!\s)\1(?!\*)` and
  `(?<![\w_])(_{1,3})(?![\s_])(.+?)(?<!\s)\1(?![\w_])`). The caret never rests inside a hidden marker; deleting
  into a hidden marker removes the whole marker (heading) or the marker pair (emphasis). No restyle during IME
  composition. `![alt](asset:id)` lines with a known image render as inline images and serialise back to the
  marker.
- **Smart paste** (in order): (1) an Origami citation on the clipboard (private flavour or HTML link) → its
  bracketed insertion text, registering its BibTeX; (2) a Reader "Copy Quote/Cite" → healed quotation with
  attribution, synthesised BibTeX registered under the derived id; (3) text starting with `@` that parses as
  BibTeX → one citation line per entry `“Title” (First Author[ et al.], Year) [derived-id]` (or the DOI/URL when
  no `vm-id`), each raw entry registered under its derived id (`makeID(firstAuthor, vm-id)`); (4) anything else
  unchanged. Converted pastes get a preceding blank line when not at a line start.
- **Images** (`DraftEditor.insertImage`): asset id `img-<8 hex>`, extension from the name or sniffed (JPEG
  `FF D8 FF`, PNG `89 50 4E 47`, GIF `47 49 46`, default png), base64 bytes stored in the document, marker
  paragraph appended.
- **Preflight** (`PreflightModel`, `PreflightView`): compares each link/reference BibTeX with Crossref (when
  `verifyReferencesCrossref`), status pending/checking/verified/differs/notFound/unavailable; "differs" when
  title/author/year disagree or the found record has a DOI the reference lacks; per-field "use" and "Use All
  Found"; Apply writes overrides.
- Context menu in the editor: the app's shared context actions plus spelling items only; "Lift to New" on
  statements starting with a known speaker name.

### 5.9 Publishing and export

- **Export as EPUB** (`exportEPUB`, ⇧⌘E and draft menus): save panel with the identity file name; write via
  `OrigamiEPUBExporter` (chapter 04). If the document is a draft it is **published**: append the Visual-Meta
  appendix, write `Published/<id>.origamitext`, delete the draft, close the editor, select books-published for
  books, open the published copy, toast "Published “Title” as an EPUB".
- **Export a Copy… (.origamitext)** (`exportDocument`, from the Published list): save panel named
  `suggestedExportFileName`, content type `info.futuretextlab.origami-doc`; accessory: segmented "This document
  is:" (None + every `DocumentType` + any unknown existing token; default the existing type or Letter);
  checkbox "Produced by AI on behalf of <author>"; when `onBehalfOf` differs from the author, a checked "Exported
  by <author> on behalf of <name>". On OK: apply choices; drop a self-referential `onBehalfOf`; append appendix;
  write. If the document is a draft, publish it as above and hand it to the letter post (chapter 03). Location
  stamping exists but `refreshPlace` is disabled (no location permission).
- Publishing is "exporting into the shared folder" by the user's choice of save location; the app does not
  force the community folder.

### 5.10 Retraction, supersession, transcripts (in-place edits)

- Retraction and supersession create new documents (§5.8); the index derives `retractedIDs` and
  `supersededIDs`. Superseded documents are hidden unless "Show Superseded" is on.
- `setDocumentType(doc, type)` and `processTranscript(doc)` **rewrite the file in place**, wherever it lives
  (draft, published copy or community folder) and also replace `document-type = {old}` inside an embedded
  appendix. `processTranscript` attributes `speaker` to paragraphs whose "Name:" prefix recurs ≥ 2 times, is an
  existing speaker, or is a known person. Both rebuild the document from a subset of fields (D15).
- Transcript summaries: saved as a new document that `summarizes` the transcript — into the transcript's folder
  with appendix when the transcript is in the library, else as a draft; earlier summaries by the same author go
  to the Trash.

### 5.11 Library manifest

`exportLibraryManifest`: requires a community folder. A new document (`documentType "manifest"`) titled
"Library Manifest — <folder>, <date>" with an intro paragraph (counts of documents and distinct authors), one
paragraph per timeline entry `"Title — displayAuthor, date[ · type][ · superseded][ · retracted] [id]"`, and a
"Files not readable at snapshot time" section. Appendix appended; saved where the user chooses.

### 5.12 Export to XR (Author Map)

Choose an Author `.liquid` document (copied, not modified) and a destination. Nodes: chosen documents (key = id,
phrase = title, description = byline/date/id + first 300 characters of the first non-heading paragraph, url
`origamitext://open/<id>`, z 0) and chosen people (key `person:<name>`, tag person, z 0.4). Optional connections:
links between chosen documents, author → document, speaker → document. Written by `AuthorMapExporter`
(chapter 06).

### 5.13 Sample community (DEBUG only, `SampleCommunity.swift`)

Writes nine documents by five fictional authors (Alice Winter, Ben Okafor, Chiyo Tanaka, David Lem, Esther
Marchetti) plus the user — letters, a response for the user's attention, a disagreement, a superseding revision,
a transcript, an extract on Chiyo's behalf, an RFC, an AI-produced summary — dated 21 to 2 days ago, into the
community folder named `sample--<suggestedExportFileName>`. Remove deletes top-level files whose names start with
`sample--` and rescans.

### 5.14 Views: modules, Connections web, ZigZag

- **Module contract** (`LibraryViewModule`): `id` (stable, lowercase-hyphenated), `name`, `systemImage`,
  `makeContent()` (list column), optional `makeDetail(model)` (may return nil to fall back to the reader),
  `hidesDocumentList`, `showInAppetite` (`.text` = receive selected words, `.note` = receive the document).
  "Show in <View>" stores a one-shot `ShowInPayload{viewID, text?, docID}` and selects the view; the view takes
  it with `takeShowInPayload(for:)`.
- **Registry** (21 modules, sidebar order): ask-library, sphere-weave, connections, weave, authors-circle,
  the-stranger, geometries, glossary, glossary-space, k-nav, ai-insights, themes, open-questions,
  agreements, disagreements, the-deal, z, zigzag, zz-structure, citation-tree, lineage. Fresh-install shown
  set: **ask-library, glossary, lineage**. DEBUG asserts unique ids. Places, Attentions, Trails, Hot
  Paragraphs and Health are left out of the registry: they read what only Knowledge Space's notes carry
  (locations, addressees, trail documents, paragraph links, the community folder) and on a shelf of books
  could show only their empty state. Their files stay. Contents of each view: chapter 06.
- **Exchange** (`ModuleExchange.swift`): `.origamiview` = JSON `{format:"origami-view-module/1", id, name,
  systemImage, fileName, source}`. Import accepts a `.origamiview` or a bare `.swift` (id/name/systemImage scraped
  with `<label>:\s*"([^"]+)"`, falling back to the file name / `puzzlepiece.extension`). Imported modules not in
  the build are "awaiting build". Export as Swift shows the registry line `<DeclaringType>.module,` (nearest
  `struct|extension|enum|class` before `static let module`); export as `.origamiview` names `<id>.origamiview`.
  Bundled source snapshot: `ModuleSources.json` = `{format:"origami-view-sources/1", modules:{id:{file,
  source}}}` (stale, D9).
- **Connections** (`DocumentWeb.swift`, `DocumentWebView.swift`, id `connections`): centre = current document if
  indexed, else the newest timeline entry. Ring 1 = neighbours (outgoing links to indexed docs, then backlink
  sources), deduplicated, first 12. Ring 2 = neighbours of ring-1 nodes not yet included, total cap 16, each
  remembering its parent. Edges = every link among included nodes (excluding self). Up to 4 unresolved targets of
  the centre shown as dashed ghosts. Layout: centre in the middle; ring 1 at radius 0.30·min(w,h) evenly spaced
  from −π/2 (ghosts share the slots); ring 2 at 0.46 fanned around the parent angle with 0.34 rad steps. Edges
  straight, shortened 54 pt each end, arrowheads, coloured by rel; edge midpoint dot opens the pair in parallel
  reading; click a card to re-centre, double-click to read. "Open" mode shows the centre plus up to 4 ring-1
  documents as columns with beams to cited paragraphs.
- **ZigZag** (`ZigZagView.swift`, id `zigzag`): two of four dimensions crossing at a focused document — d.time
  (timeline order), d.author (same author, by `listedDate` then id), d.type (same `documentType`, else
  transcript/letter), d.discourse (previous = first discourse-link target through `latestRevision`, next = first
  discourse backlink source). Arrow keys move along the across/down dimension; picking the same dimension for both
  axes advances the other; double-click reads.
- **zzStructure** (`ZZStructure.swift`, `ZZNavigatorView.swift`, id `zz-structure`): Ted Nelson's structure
  under Restriction R (≤ 1 posward and ≤ 1 negward neighbour per cell per dimension). Cells: document (by
  address), dimension, view, namespaceHead, clone, plain; ids UUIDv7 (48-bit ms timestamp, version 7, variant
  10). System dimensions with fixed UUIDs `00000000-0000-7000-8000-00000000D001…D011` (dimensions, namespaces,
  namespace-members, namespace-siblings, views, clones, user-views, axis-x/y/z, anchor); a dimension's cell is
  the same UUID with C in place of D. `link(a, poswardTo: b, along: d, splice:)` maintains mirrored records,
  throws on occupied slots unless splicing (A→C becomes A→B→C); `unlink` heals nothing; `rank(through:along:)`
  walks negward to the head (or detects a ring) then posward, limit 512. Views: H (x rank as crossbar, y ranks as
  columns) and I (transpose); a cell placed at two coordinates is a dashed "virtual copy". Saved layouts are clone
  cells on d.user-views with axis/anchor links; `.zzlayout` = `{format:"origami-zz-layout/1", view, x:{id,name},
  y, z?, anchorDocument?, anchorCell?}`. Load verifies and repairs mirrors (posward authoritative); missing file →
  bootstrap. Keys: arrows move, ⌥↑/⌥↓ along Z, Tab swaps H/I.

### 5.15 Side by Side, parallel reading

- Side by Side (`SideBySideView.swift`): two shelf books (by `EPUBRecord.folder`) as plain text columns
  (max 680 pt); "Sync Scrolling" (`sideBySideSync`, default on) keeps the other side at the same fraction of its
  scrollable height; the side being scrolled drives, released 250 ms after the last scroll.
- Parallel reading (transpointing): `parallelCandidates` from `ParallelReading.candidates` (chapter 06);
  `enterParallel`, `exitParallel`; any navigation clears it.

### 5.16 Built-in guide and Introduction

- `ensureUserGuide()` (1 s after launch): `OrigamiTextUserGuide.md` from the bundle → Markdown import → EPUB →
  shelf record with fixed id `origami-text-user-guide`; re-converted when the bundled file's modification time
  differs from `openSourceDocStamp-OrigamiTextUserGuide`. Help ▸ Origami Text Guide opens it. Bundled specs
  (Settings ▸ Open Source) work the same with ids `origami-spec-<resource lowercased>`.
- `openIntroduction()`: at launch (when no book, document or draft is open) and from the sidebar's Intro
  button. Uses bundled `Introduction.epub` (re-imported when its modification time changes, record id kept in
  `bundledIntroductionRecordID`); without it, falls back to `openIntroGuide()`, which exports the built-in guide
  (`IntroGuide.swift`, id `origami-text-intro`, version 6, title "Introducing Origami Text", author "Future Text
  Lab", date 2026-08-23, type book, four concepts) through the EPUB exporter and replaces older editions.

### 5.17 View Specification (`ViewSpecification.swift`)

A "citation for a view". JSON object `{format:"viewspec/0.1", kind, generator, location, view:{…}, address}`,
pretty-printed with sorted keys; `view` omitted when empty. `address` = location + `?` + `key=value` pairs
sorted by key for scalar values only (strings percent-escaped to unreserved characters; whole numbers without
`.0`; booleans `true/false`; arrays of scalars comma-joined; objects/null omitted). `parse` takes the substring
from the first `{` to the last `}`, requires `format` starting `viewspec/`, `kind`, `location`. The reading view's
spec: kind `origami-reading`, location `<docID>#<paragraphID>`, view `{style, closed?[], open?[], focus?}`.

### 5.18 Text colouring (`TextColoring.swift`)

Modes off / grammar / meaning / argument / keyStatement (stored as `textColoringMode`). Categories and default
colours (all enabled, hex):

| Group | Category → colour |
|---|---|
| Grammar | noun #1F5FA8, verb #C4342B, adjective #4E86C6, adverb #E08A3C, pronoun #7B4FA6, determiner #8FB3D9, preposition #6E9B76, conjunction #B58A9B, number #A98600, interjection #C9A227 |
| Meaning | person #B03A5B, place #2E7D5B, organization #4A5AB8, time #A98600, quantity #E08A3C |
| Argument | context #7A8CA3, claim #1F5FA8, evidence #2E7D5B, method #2A8A8A, comparison #C99A2E, concession #8A7AAF, refutation #C4342B, originality #7B3FA6 |
| Key statement | keyStatement #D2691E |

Grammar paints parts of speech from an on-device tagger; Meaning paints named entities, then time (date
detector + a period lexicon), then quantities; Argument paints cue phrases by precedence (longest first, word
boundaries); Key Statement paints the sentence a language model picked. Words already coloured or linked keep
their colour; earlier passes win. Rules persist as JSON under `textColorRules`; unknown stored categories reset to
defaults. Use and UI: chapter 02.

---

## 6. Settings

Tabs (`SettingsTab`): Author, Editor, Reading, Overview, Assistive, Annotations, Layout, Library, Hypermedia,
AI, View Modules, Open Source. Window width 1040.

| Setting | Key | Default | Effect |
|---|---|---|---|
| **Author** Name | `authorName` | "" (falls back to OS full name) | Default author; identity for unread/attention/own documents. |
| Title | `authorTitle` | "" (None; Dr., Prof., Prof. Dr., Mr., Ms., Mrs., Mx.) | `personal-title` in own Visual-Meta. |
| ORCID | `authorORCID` | "" | `orcid` in own Visual-Meta. |
| Affiliation | `authorAffiliation` | "" | `affiliation` in own Visual-Meta. |
| Act as test account | `testAccountActive` | false | Swap identity (name only). Disables the fields above. |
| Test name | `testAccountName` | "Test Reader" | The test identity. |
| Cartoon style | `portraitStyle` | `illustration` (animation/illustration/sketch) | Contact portraits (chapter 05). |
| Portrait prompt | `portraitPrompt` | `PortraitStyle.defaultConcept` | Chapter 05. |
| Portrait instant processing | `portraitInstantProcessing` | false (read in `PersonFormView.swift`) | Chapter 05. |
| Muted People | `mutedAuthors` | [] | Hide authors from lists. |
| Share general location | `shareGeneralLocation` | true (read as `?? true`) | Retired: no UI, `refreshPlace` disabled. |
| **Editor** Hide # heading markers | `hideHeadingMarkers` | true | Markers collapsed in the editor (still saved). |
| Verify references with Crossref | `verifyReferencesCrossref` | true | Preflight source. |
| Full screen text width | `fullScreenContentWidth` | 760 (480–1200, step 20) | Text measure in full screen (reader and editor). |
| **Reading** Theme | `readerTheme` | `highContrast` | App-wide colours (chapter 02). Edit Theme Colors → `ThemeColorOverrides`, tick `themeColorOverridesTick`. |
| Left / Right Margin | `readerLeftMarginMode` / `readerRightMarginMode` | `annotation` / `outline` | Chapter 02. |
| Auto Hide Margins after 4 sec | `readerMarginsAutoHide` | true | Chapter 02. |
| Citations | `origamiCitationStyle` | `authorDate` (numeric, superscript) | Chapter 02. |
| Endnotes & Footnotes | `origamiNoteStyle` | `superscript` (bracketed, dagger, stretch) | Chapter 02. |
| Notes open | `notesOpenAsPopup` | true | Chapter 02. |
| Reopen books where I left off | `reopenWhereLeftOff` | false | Chapter 02. |
| Selection | `selectionContextStyle` | `custom` (system) | Chapter 02/03. |
| Context Panel Online | `contextLocalOnly`, `contextOnlineWikipedia`, `contextOnlineOpenAlex`, `contextOnlineSemanticScholar` | false, true, true, true | Chapter 05. |
| Triple-click selects the sentence | `tripleClickSelectsSentence` | true | Chapter 02. |
| Look up cited works online | `lookupCitedWorks` | true | Chapter 05. |
| OpenAlex API key | `openAlexAPIKey` | "" | Chapter 05. |
| Retraction Watch / FORRT / Crossref notices / Unpaywall / OpenCitations | `referencesRetractionWatch`, `referencesReplications`, `referencesCrossrefNotices`, `referencesOpenAccess`, `referencesCitationCounts` | all true | Chapter 05. |
| Body / Headings font | `readerBodyFont` / `readerHeadingFont` | "Times New Roman" / "Georgia" | Everywhere words render. |
| **Overview** Names, Defined concepts, Marked, Bold, Highlights, Comments, Citations, Lighter headings | `overviewShowNames`, `overviewShowConcepts`, `overviewShowMarked`, `overviewShowBold`, `overviewShowHighlights`, `overviewShowComments`, `overviewShowCitations`, `overviewLighterHeadings` | true ×6, false, false | Chapter 02. |
| Pictures | `OverviewPicturesEnabled`, `OverviewPicturesHidden`, `OverviewPicturesDisabledKinds` | unclear from source | Chapter 02. |
| **Assistive** Voice engine | `readAloud.engine` | "apple" (qwen3 on Apple silicon) | Chapter 02. |
| System voice | `readAloud.voiceID` | "" (default) | Chapter 02. |
| Speed | `readAloud.rate` | 1.0 (0.5–2.0) | Chapter 02. |
| Qwen3 speaker / style | `readAloud.qwen3.speaker` / `readAloud.qwen3.instruct` | "Ryan" / "Speak naturally." | Chapter 02. |
| **Annotations** kind names / colours | `annotationKindNames` / `annotationKindColors` | built-in | Chapter 03. |
| **Layout** Title Font | `listTitleFont` | "" (system) | Title typeface in all lists (13 pt). |
| Author portraits on connection cards | `connectionPortraits` | true | Reading margin cards. |
| Call the venues shelf | `venueShelfLabel` | "Journals" (or "Proceedings") | Sidebar label. |
| Call the library list | `papersListLabel` | "Papers" (or "Articles") | Sidebar label. |
| Reader header column width | `readerHeaderColumnWidth` | 250 | Set by dragging the seam (§5.7). |
| **Library** Community Folder | `communityFolderBookmark` | none | §5.1. |
| Reader Library | `readerLibraryBookmark` | none | §2.4 step 5. |
| Search my documents and EPUBs / Search Reader's PDFs | `findInReading.searchesLibrary` / `findInReading.searchesPDFs` | true / true | Where Have I Read This? |
| Interatlas / Liquid view links app | `interatlasAppPath` / `liquidAppPath` | nil (browser) | Scene link routing. |
| Reference datasets | (store files) | none | Chapter 05. |
| **Hypermedia** spaces, account, Hypothesis | `hypermedia.spaces`, `hypermedia.account.name`, `hypermedia.account.uid`, `hypothesis.username`, `hypothesis.publicAnnotationsEnabled` | none | Chapter 03. |
| **AI** Model | `selectedModelID`, `llmEndpoints` | "apple" | Chapter 06. |
| Summary / Issues / Person Profiles prompt | `aiReadingSummaryPrompt` / `aiReadingIssuesPrompt` / `aiPersonProfilePrompt` | built-in defaults | Chapter 06. |
| Relevance to | `aiRelevanceTopic` | "" | Chapter 06. |
| Build person profiles continually | `aiPersonProfilesEnabled` | true | Chapter 06. |
| Module prompts (no UI here) | `aiInsightsPrompt`, `aiThemesPrompt`, `aiOpenQuestionsPrompt`, `aiDisagreementsPrompt`, `aiAgreementsPrompt`, `aiStrangerChallengePrompt`, `aiStrangerSupportPrompt` | module defaults | Chapter 06. |
| **View Modules** shown | `hiddenViewIDs` | all but ask-library, glossary, lineage | Sidebar Views rows. Also Import Module, Share (Swift / `.origamiview`), Copy Starter Module. |
| **Open Source** | — | — | Opens bundled specs as shelf EPUBs; "Copy as Prompt". |
| Editor Mode (hidden) | `editorMode` | false | Publisher builds only. |

---

## 7. Platform notes

| Apple API / feature | Used for | Portable replacement |
|---|---|---|
| SwiftUI `App`, `WindowGroup`, `NavigationSplitView`, `Settings`, `@Observable`, `@AppStorage` | Scenes, three-column layout, observable state, preferences | Any reactive UI (React/Svelte, Qt/QML, Compose, WinUI). A single store object + a key/value preference store (localStorage, JSON file, registry). |
| AppKit `NSWindow`, `NSEvent` local monitor, `NSAlert`, `NSOpenPanel`/`NSSavePanel` accessory views, `NSTextView` | Window discipline, global keys, prompts, file dialogs, the rich editor | Electron/Tauri window APIs; DOM keydown at window level; native dialogs (`<input type=file>`, File System Access API); CodeMirror 6 / ProseMirror for the Markdown editor with hidden-marker decorations. |
| Security-scoped bookmarks, App Sandbox (`ENABLE_APP_SANDBOX`, user-selected files read-write, outgoing network, camera) | Persistent folder access | Store the absolute path (desktop) or a persisted `FileSystemDirectoryHandle` (web, re-prompt for permission). |
| FSEvents (`FolderWatcher`) | Folder watch | chokidar / `fs.watch` recursive, inotify, `ReadDirectoryChangesW`, `FileObserver`; keep the 0.5 s debounce. |
| `NSFileManager.startDownloadingUbiquitousItem`, `.icloud` placeholders | iCloud Drive downloads | Not needed elsewhere; Dropbox/OneDrive have their own "files on demand". Skip or treat as no-op. |
| `NSWorkspace.trashItem` | Recoverable deletes | OS trash libraries (`trash` npm, `send2trash`), or an app-level trash folder. |
| `String.applyingTransform(.toLatin)` + diacritic folding | Address transliteration | ICU `Any-Latin; Latin-ASCII` transform (`icu4j`, PyICU, `Intl` lacks it; use `transliteration` npm or `any-ascii`). Results must match for non-Latin names to produce the same address — test with 王小明 → `w.wangx`. |
| `ISO8601DateFormatter` | Dates | Any RFC 3339 parser accepting optional fractional seconds. |
| `AttributedString(markdown:)` inline-only, `NSDataDetector` links | Rendering paragraphs | markdown-it / marked with inline rules only; linkify-it. |
| `NaturalLanguage` (`NLTagger`, `NLLanguageRecognizer`) | Text colouring, language detection | spaCy, compromise, wink-nlp; franc/cld3 for language. |
| FoundationModels (`SystemLanguageModel`, `LanguageModelSession`) | Emotions, title suggestion, summaries | Route through a pluggable LLM client (Ollama, OpenAI-compatible). Note: `DocumentDetailView.judgeEmotions` calls Apple's model directly, unlike the rest of the app. |
| CryptoKit SHA-256 | Sidecar verification | Web Crypto `subtle.digest`, OpenSSL, `hashlib`. |
| PDFKit | Inline PDF for sidecars | pdf.js, PDFium. |
| NSServices (Info.plist) | "Where Have I Read This?" from other apps | OS share targets / context-menu extensions; optional. |
| Info.plist document types & UTIs | File associations (EPUB viewer; zip, gmi, tex, Word, Markdown, RTF/RTFD, PDF, XML/HTML/XHTML, ODT, BibTeX, gzip/tar, RIS, EndNote, Typst, AsciiDoc, rST as "Alternate" viewer); exported UTI `info.futuretextlab.origami-doc` (`.origamitext`, conforms to JSON); URL scheme `origamitext` | Desktop file associations and protocol handlers (Electron `setAsDefaultProtocolClient`, Windows registry, `.desktop` MIME entries, Android intent filters). Consider also associating `.origamitext` (the macOS app does not, D2). |
| App Group `com.liquid.author.shared` | Shared cache with Author | A shared folder path both apps agree on. |
| Keychain | Signing keys / tokens | OS credential stores (libsecret, Windows Credential Manager, Android Keystore). |
| `NSFullUserName()` | Default author | OS account display name or ask at first run. |

macOS-27-specific workarounds (no move transitions over platform views, constant column widths, layout swaps
without animation, `NSApplicationCrashOnExceptions = false`) are not behaviour and need not be ported.

---

## 8. Rebuild order and acceptance checks

### 8.1 Order

1. `LiquidDate`, `LiquidAddress`, `DocumentRelation` (pure, no I/O).
2. `LiquidDoc` model, tolerant decoder, encoder, body text conversions, link detection.
3. `VisualMeta` generator.
4. `LibraryScanner.derive` and `scan`, `LibraryIndex` with `latestRevision`, folder watcher.
5. `AppModel` core: history, `open`/`follow`/`resolve`, URL handling, read state, filing, muting, toasts,
   preferences.
6. Shell: window with sidebar / list / detail, find bar, menus and shortcuts, full-screen focus layout and peek.
7. Native reader (paragraph rendering, fragments and spans, transclusion, appendix toggle, sidecars).
8. `DraftStore`, `DraftEditor`, editor UI and smart paste, publishing/export.
9. EPUB shelf lists and standing sync (depends on chapter 02's importer).
10. View module registry and exchange; Connections, ZigZag, zzStructure.
11. Settings window; guide/introduction bootstrapping.

### 8.2 Acceptance checks

Addressing and dates:
- `makeID("Frode Hegland", 2026-07-11T09:32:52Z)` = `f.hegla.093252x`.
- `makeID("Mark Anderson", 2026-07-02T11:00:00Z)` starts `m.ander.110000`; `makeID("Madonna", t)` uses
  `m.madon`; `makeID("", t)` uses `x.doc`.
- With `isTaken` always true for the preferred id, the result matches `^f\.hegla\.[a-z0-9]{6}$`.
- `canonical("  F.Hegla.093252X ")` = `f.hegla.093252x`; `isValid("a b")`, `isValid("a#b")`, `isValid("a/b")`
  are false.
- `matches(in: "see [responds-to:f.hegla.093252x#p3] and origamitext://open/m.ander.110000b")` returns two
  matches (URL form first, since patterns run in order): (`m.ander.110000b`, nil, nil) and (`f.hegla.093252x`, `p3`, `responds-to`).
- `isPersonAddress("f.hegla")` true; `isPersonAddress("f.hegla.093252x")` false.
- `LiquidDate(isoString: "-0328")` → displayText "329 BCE", isoString "-0328"; `"2026-13"` → nil;
  `"2026-07"` → "July 2026". `sortDate` of `"2026"` < `"2026-07-07"`.
- `identityKeyID(inFileName: "Notes(Frode-Hegland-2026-07-11T09_32_52Z)")` = `f.hegla.093252x`.
- `fileSlug("Meeting Summary for the Lab, July")` = `meeting-summary-for-the` (≤ 24); `fileSlug("Untitled")` = "".

Decoding and encoding:
- The spec's three §11 fixtures decode; the retraction makes `f.hegla.100000a` retracted; a `revises` link
  from B to A makes `latestRevision(A) = B` and A superseded.
- A file with both `body` and `wraps` is listed as unreadable with "A document may have “body” or “wraps”, not
  both"; malformed JSON lists as "Not valid JSON: …"; neither crashes.
- `format: "origami/0.9"` opens (flagged unfamiliar); `"origami/1.0"` is rejected.
- `heading: 7` decodes as 3; a link with `to: "a b"` is dropped; `date: "yesterday"` is dropped.
- Unknown top-level keys are ignored. Encoding then decoding a document preserves every spec field and the
  extra fields of §4.1; output keys are sorted.
- `parseBody("# Title\n\nText\n\n## Sub")` → p1 (h1 "Title"), p2 ("Text"), p3 (h2 "Sub"); `bodyEditingText`
  of that result reproduces the input.
- `detectedLinks` on `“Use Cases” (Frode Hegland, 2026) [f.hegla.101500k#p3]` yields rel `cites`, fragment
  `p3`, span `Use Cases`.

Visual-Meta:
- Appending twice yields one appendix. The machine block is a single paragraph and contains `origami-id = {id}`
  and `vm-id = {created}`; a BCE date yields `era = {1}`; identity fields appear only when the author matches.
- `escaped("50% & #1_{x}")` = `50\% \& \#1\_\{x\}`.

Index and navigation:
- Two files with the same id: the newer modification date wins; the row shows the duplicate badge.
- Following a citation to a superseded document opens the newest revision; following a `revises` link opens the
  old one.
- A fragment that does not exist shows the "not found" toast and still opens the document.
- Opening an unread document keeps it unread until another document is opened; "Unread" restores bold.
- Find with no hits leaves the list whole and beeps once per query.
- Muting an author hides their documents; filing under Archived hides a document from the timeline but other
  folders do not.

Writing:
- ⌘N with nothing selected creates `Drafts/<id>.origamitext` with title "Untitled" and `documentType "letter"`;
  ⌘W on it untouched deletes it.
- Pasting a BibTeX entry with `vm-id` and `author` inserts `“Title” (Author, Year) [derived-id]` and the saved
  document's link to that id carries the BibTeX.
- Exporting a draft moves it from Drafts to Published with an appendix; the Published copy opens read-only.
- Supersede on "Title (v2)" proposes "Title (v3)" with a `revises` link to the original.

Shell:
- Only one library window can exist; ⌘L reopens it after it was closed.
- `origamitext://open/<id>#p2` opens that document at p2 (or toasts when absent).
- The sidebar remembers folded sections across launches; "XR" and "Views" start folded on first run.
- With no `hiddenViewIDs` stored, only Ask, Glossary and Lineage appear among module rows.

---

## 9. Discrepancies between docs and code

| # | Topic | Docs say | Code does |
|---|---|---|---|
| D1 | File name | Spec §3/§10: file is `<id>.origamitext`; files must not be renamed. | Exports use `<slug>--<id>.origamitext` (`suggestedExportFileName`); sample files `sample--<slug>--<id>`. Drafts/Published/Archived use `<id>.origamitext`. `isIDTaken` only checks `<id>.origamitext`. |
| D2 | Opening `.origamitext` | README/overview: the app reads and writes `.origamitext`. | `openFile` has no case for `origamitext` (beeps); Info.plist exports the UTI but declares no document type for it; `importableExtensions`' comment ("anything else is treated as a native Origami Document") is stale. `.origamitext` enters only via the community folder scan and the app's own stores. |
| D3 | Extra fields | Spec §10: writers emit only documented fields. | Writer/decoder use undocumented `location`, `sourceURL`, `publication`, `concepts`, `layouts`, `connections`, `references`, `tables`, `assets`, `body[].tableID`. Many EPUB-derived fields are never serialised. |
| D4 | Concept fields | Comments call concepts compatible with Author's (userDefinition). | `userDefinition`, `markedForms` are neither decoded nor encoded. |
| D5 | `relates-to` | Spec §5 lists it. | No `DocumentRelation` case; only a colour in `RelStyle`. |
| D6 | Appendix keeps fields | Code comment: "Everything the document carries rides through". | `appendingAppendix` drops `tables`, `assets`, `sourceURL`, `publication`. |
| D7 | Field key prose | Appendix explains `JSON`, `tag`, `showInFind`, `note`, and a `@{glossary}` block. | This generator never writes those. |
| D9 | Bundled module sources | `ModuleExchange`: "Regenerate ModuleSources.json when a module changes". | The JSON holds 17 ids including `authors`, `lift-weave` (not registered) and lacks e.g. ask-library, glossary, lineage, citation-tree, so those cannot be exported. |
| D10 | Dead view routes | — | `follow` (person address), `openAuthorPage` route to `.view("authors")`; `openLocations` to `.view("location")`; neither id is in the registry, so the list falls back to `DocumentListView` with no sidebar row. |
| D11 | Duplicates across feeds | Spec §9: flag duplicates. | A JSON document and an EPUB with the same id: EPUB wins silently. |
| D12 | Rules | Spec §6: a paragraph of dashes (`---`, 3+). | Also accepts em and en dashes. |
| D13 | Version check | Spec: open any `origami/0.x`. | Prefix test `origami/0` (also accepts e.g. `origami/01`). |
| D14 | Export target | `DraftEditorView` toolbar help: "Export as .origamitext (⇧⌘E)"; `exportDraft` comment: books → EPUB, others → `.origamitext`. | ⇧⌘E and draft "Export…" always write an EPUB; `.origamitext` export is only "Export a Copy…" on Published. |
| D15 | Append-only | Spec §1, §10: nobody rewrites a published document. | `setDocumentType` and `processTranscript` rewrite files in place, including community and published copies; `setDocumentType` also drops `location`, `sourceURL`, `publication`, concepts, layouts, connections, references, tables, assets. |
| D16 | Overview / README | Overview describes Dialog/Outgoing sidebar sections, imports becoming drafts, AI via Apple Intelligence only; README describes LIQUID-DOCUMENT-FORMAT.md as "the interoperable sibling format". | Those sidebar sections are retired; batch imports become EPUBs; AI goes through a selectable model; LIQUID-DOCUMENT-FORMAT.md is a rename notice. |
| D17 | Introduction at launch | Key name `introShownOnce` implies once. | The Introduction opens at every launch where nothing else is open; the key is written but never read. |
| D18 | Document type of replies | Overview: "the relationship is recorded"; spec recommends `letter` as default kind. | Discourse/supersede/retract drafts are created with no `documentType` (only plain ⌘N gets `letter`; export later defaults the picker to Letter). |
| D19 | Collision scope | Spec §3: detect collisions against the local library. | `DraftStore.create` checks only existing drafts, not the index. |
