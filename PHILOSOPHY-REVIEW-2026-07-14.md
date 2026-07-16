# Philosophy Review — Transcript Lifting, Manifests, and Provenance
*Origami Text, 14 July 2026. A review of the functionality added in this session against three commitments: visible information (Visual-Meta), augmenting the user, and community engagement and dialog.*

---

## What was reviewed

- Transcript import typing (`documentType: "transcript"`)
- Lift to New (reader context menu and draft-editor context menu)
- `onBehalfOf` provenance: model field, byline, export declaration, Visual-Meta emission
- The Transcripts view
- The Transcript button / way back to the source
- Library Manifest export

## Verdict in one paragraph

The mechanics are sound and the *format* work is faithful to the philosophy: every new fact (transcript type, on-behalf-of, the lift citation) is recorded in the document itself, travels in the Visual-Meta appendix, survives round-trips through the tolerant decoder, and is documented in the spec. Where the session initially fell short was the *surface*: several of these facts were recorded honestly but displayed nowhere, which is the precise failure mode Visual-Meta exists to prevent — information that is true but hidden. Four such gaps were found and fixed during this review (below).

---

## 1. Visible information / Visual-Meta

**What aligns well:**

- **On-behalf-of is a first-class, on-the-page fact.** It lives in the JSON, in the byline ("Frode Hegland on behalf of Tom Haymes"), in the export dialog as an explicit human choice, and in the Visual-Meta block as `on-behalf-of = {Name}` with an explanation in the field key. A stranger with a text editor can discover whose words a document carries. This mirrors the `ai-on-behalf-of` precedent exactly, which is the right kind of consistency.
- **The lift records its own provenance twice, in two registers.** Structurally as a span-scoped `cites` link (machines find the exact statement), and as a human-readable body line — "Spoken by X in 'Title', date [address]" — that survives any export, print, or copy-paste. Metadata on the same level as content, as on a printed page.
- **Self-referential provenance is suppressed.** "Frode Hegland on behalf of Frode Hegland" no longer appears anywhere: not at lift time, not in bylines, not at export. One speaks for oneself; saying so would be noise, and noise is also a form of hiding.
- **The manifest is a snapshot, not a shadow database.** It is dated in its own title, states its own nature and limits in its first paragraph, lists unreadable files rather than hiding them, and defers explicitly to the folder as the authority. Its entries are clickable addresses in *text*, deliberately not structured links, so a 500-entry manifest cannot deform the Document Web or drown backlink counts. This is the visible-truth architecture defended on principle.

**Issues found and fixed in this review:**

1. **`onBehalfOf` was invisible on one's own documents.** The reader suppresses the byline for documents you authored, so the very person who published on someone's behalf never saw that declaration again. Fixed: "On behalf of *Name*" now shows on your own documents' byline row.
2. **The way back to the transcript was author-only.** The Transcript button lives in the authoring actions row, which only the author sees; other readers had to notice the source line in the body. Fixed: every reader now gets a "Lifted from *Transcript Title*" link in the byline, in the same idiom as "Responding to…" provenance links.
3. **A declared `documentType` was recorded but never displayed.** Declared at export, emitted to Visual-Meta — and visible nowhere in the reader. Fixed: the byline row now carries a small type tag ("Transcript", "RFC", or an unknown token verbatim, honoring the open vocabulary).
4. **A lifted draft did not say whose words it carried.** The fact sat silently in the file until the export dialog. Fixed: the draft editor header now shows "on behalf of *Name*" beside the author field.

## 2. Augmenting the user

- **Lift to New is a genuine augmentation move**: it converts a moment of recognition ("that statement matters") into a durable, addressable, citable artifact in two clicks, with the bookkeeping — id, citation, span, provenance, date inheritance — done by the system. The user does the thinking; the tool does the accounting. This is the Engelbart division of labor.
- **It works at the point of reading *and* the point of editing.** The same action exists in the reader (speaker label) and in the draft editor (context menu on a statement), so the capability is where the user's attention already is, rather than requiring a mode switch.
- **The Transcripts view earns its place** by answering a real recurring question ("what conversations does this library hold, and who spoke?") rather than decorating. Its tolerance — recognizing pre-typing transcripts by their recurring speakers — means the user's older material is not second-class.
- **One honest tension: context menus are hidden affordances.** Both lift entry points are right-click discoveries, and this session itself demonstrated the cost (the "I cannot see anything when ctrl-clicking" detour). A philosophy of visible information should eventually extend to visible *capability*. Recommendation below.

## 3. Community engagement and dialog

- **Lifting is structurally dialogic.** A lifted statement points back to the conversation it came from (span-scoped citation), names the speaker as the one to credit, and names the publisher as the one accountable. That is the full provenance triangle — *who said it, who carried it, where it lives* — and it makes transcript voices into first-class participants in the library's discourse web, connected to People, author pages, and backlinks.
- **On-behalf-of publishing is an act of community service made legible.** "Exported by Frode Hegland on behalf of Tom Haymes" gives credit where the words originated while keeping accountability with the publisher, and makes the speaker's name searchable — their contributions are findable even though they never touched the app.
- **The manifest is a communal artifact.** Saved into the shared folder it becomes a dated, human-readable record of the community's growth that any member (or any AI reader, via its self-describing preamble) can consult; produced periodically it forms a visible history. It engages the community without governing it — the folder stays sovereign.
- **Gap, noted not fixed: the lifted speaker doesn't know.** The natural dialogic completion of a lift would be to offer adding the speaker to the document's `attention` list ("for the attention of Tom Haymes"), so publishing on someone's behalf also *addresses* them. The mechanism exists and would be one line at lift time — but it changes what a lift means, so it is a decision for you rather than a silent default.

## Recommendations

1. **Visible lift affordance** *(declined for now, by decision)*. A small hover affordance on statement paragraphs would make lifting discoverable without the right-click ritual.
2. **Attention-on-lift** *(implemented, same day)*. Lifting now places the speaker on the new document's attention list — publishing on someone's behalf also addresses them. The "offer" is the visible, one-click-removable attention chip in the draft editor, not a dialog. Suppressed when lifting one's own words.
3. **visionOS parity for speaker affordances** *(implemented, same day)*. Speaker names in the Vision reader are now tappable — a sheet lists everything that person has said across the library, each statement opening its meeting. The Vision library gained an All Documents / Transcripts filter using the Mac view's rule. And the Knowledge Space now *persists* its arrangement — every card's x, y, and z survive sessions, saved on each placement and reconciled through revision chains, so a document superseded on the Mac inherits the position its predecessor was given by hand.
4. **Manifest cadence as ritual, not automation.** Resist any future temptation to auto-produce manifests; a monthly hand-produced snapshot into the community folder is a *practice*, and practices are community glue in a way cron jobs are not.

## Changes made during this review

| File | Change |
|---|---|
| `DocumentDetailView.swift` | Byline: "On behalf of *Name*" now visible on own documents; "Lifted from *Title*" link for every reader; document-type tag on the page. |
| `DraftEditorView.swift` | Draft header shows "on behalf of *Name*" for lifted drafts. |

All changes build cleanly (macOS and visionOS targets).
