# Origami Text — What We Have Built

*Origami Text is a macOS app for reading, writing, and thinking in **Origami Documents** (`.origamitext`) — a plain-text document format owned by its community. Free and open source (MIT), initiated by Frode Hegland at the [Future Text Lab](https://futuretextlab.info). The full format specification lives in [ORIGAMI-DOCUMENT-FORMAT.md](ORIGAMI-DOCUMENT-FORMAT.md).*

## The idea in one breath

- Documents are **plain UTF-8 files in a shared folder** — any sync (iCloud, Dropbox, git) is the network. No server, no accounts, no lock-in.
- Every document **carries its own metadata, in human-readable form, inside itself**. Nothing essential lives in a database or a hidden layer.
- Published documents are **never rewritten**. New versions, responses, corrections, and retractions are *new documents that point at old ones* — the record only grows.
- A person with a text editor must be able to read everything in fifty years. Every convention we add degrades gracefully to plain text.

## Addressing: cite now, resolves later

- Every document has a **short human-readable address** that is also its filename: `f.hegla.093252x` (author initial, surname, creation time). Anyone who knows the author and the moment can *derive* the address before the document arrives — forward citation works.
- **People are addresses too**: `f.hegla` is the shared prefix of one author's documents. Names in any script work — 王小明 becomes `w.wangx`.
- **Paragraphs are addressable**: `f.hegla.093252x#p3` points at one paragraph, and citations land there with a highlight flash.
- Type an address in brackets and it becomes a live link; type `[disagrees-with:…]` and the link carries its meaning.

## Writing and publishing

- A clean **draft editor**: each line a paragraph, `#` headings styled as you type, plain markdown underneath.
- **Paste BibTeX and it becomes a citation**; every citation carries its full BibTeX record inside the link, so provenance travels with the connection.
- A **discourse vocabulary** built in: respond to, extend, support, question, disagree with, summarize, revise, or retract any document — one menu action starts the reply, and the relationship is recorded in the document itself.
- **Human dates**: meeting notes carry the meeting's date, a transcription can carry 329 BCE — while the machine timestamp stays immutable.
- Declare **who a document is for** (`attention`), **what it is** (RFC, personal, project, meeting, article — an open vocabulary), and **whether AI produced it on your behalf** — AI production is never silent; the byline says so.
- On export, every document gains a **Visual-Meta appendix** ([visual-meta.info](https://visual-meta.info)): its citation, references, and field key written *on the page*, as they would be in print — readable by any person or AI without our software.
- **Publishing is just exporting into the shared folder.** The published copy is the immutable record; your draft retires.

## Reading and the visible web of thought

- A **reader** where citations are live, backlinks are known, and a cited passage **unfolds in place** beneath the paragraph that cites it (stretchtext transclusion).
- **Transpointing windows**, in honor of Ted Nelson: two connected documents side by side with **beams drawn between the exact linked passages**, tracking as you scroll.
- The **Document Web**: an ego-centered radial map of any document's neighborhood — documents as cards, typed colored connections, click to re-center, double-click to read.
- The **open view**: full documents standing as columns in space with lines running to the precise paragraphs they cite — the diagram Nelson drew, running live on your library.
- **Sidecars make any file a citizen**: a PDF (or anything) wrapped in a small `.origamitext` gains an address, links, and a place in the web — with hash verification so you know when the file changed.
- Quotes copied from Visual-Meta PDFs in Reader **paste as full citations**, identity and all.

## The library

- Point the app at a **community folder** and it indexes everything: lookup, backlinks, revision chains, retractions, a creation timeline — rescanning automatically as files arrive.
- **Revisions resolve forward**: cite a document and readers are always taken to its latest version, while history stays intact and inspectable.
- **Retraction is visible, never destructive**: retracted documents are dimmed and flagged, not deleted.
- **Insight views over the whole library**: every author and who cites whom; the *hot paragraphs* the community keeps pointing at; a health dashboard of unresolved links, duplicates, and unreadable files.
- **People are first-class**: a local directory with ORCID search anchors names to canonical academic identities. Muting is local and private — who you decline to hear is never written into the shared record.
- **Imports meet writers where they are**: Markdown, Word (.docx/.doc), and Author (.liquid) documents become drafts.

## Capture and the letter post

- **Notes are captured in the moment**: an iPhone companion takes them by voice or by hand, names them from their first four words, stamps the place they were made (a place name, never coordinates), and writes them straight into the shared folder as ordinary documents (`documentType: note`). The Mac and the headset read them the moment the folder syncs.
- **Letters travel by the letter post**: published letters go out through scripted Apple Mail — the author's existing accounts do the carrying, and no password or server ever touches the app — and arriving `.origamitext` attachments are saved into the community folder automatically. The carrier is a pluggable seam; Mail is simply the first.
- **Filing is a private judgement**: any document files under Work, Personal, a folder of your own, or Archived — the one folder that hides its documents from the timeline and the library's lists. Like muting and read-state, filing is local and never written into the shared record.

## AI that reads with you — entirely on your Mac

- Four views written by the **on-device model** (Apple Intelligence): an **Insights report** on what the community is thinking; the **Themes** threading the conversation; the **Open Questions** nobody has settled; the **Disagreements**, each with its two sides named.
- **No text ever leaves the Mac.** The model reads documents' text, never their metadata; every claim it makes is verified against the index before display.
- **The prompts are yours**: every AI view's prompt is editable in Settings.
- **Bots stand in for known thinkers**: created from a name, identified by the on-device model, each bot judges the library's documents as its person might — agree, disagree, neutral, with the reason in their voice. A bot is itself a document (`documentType: bot`) in the shared folder, its judgements on the record like everything else, and never mistakable for the person: the name always says "bot".

## The Hallway View — reading a journal in space (visionOS)

Named 2026-08-25, this is the Vision Pro's answer to a journal: a
walkable corridor whose depth IS time.

- **The room is quiet by default**: a journal's articles stand as small
  cards, pinned first, the set-aside in a faded row. Selection is
  additive and sticky; a selected card wears an ember border.
- **Citations live on the timeline**: select an article and its cited
  works rise on a dated wall — every citation at its publication year's
  exact depth, and held there: a drag slides it in X and Y only, mid-
  gesture included. Select a citation and what IT cites rises behind
  it (from the citation graph the Mac researched), each at its own
  year. Whisper-faint ember lines carry the weave; double-tapping a
  citation opens its record — title, authors, year, abstract, DOI —
  with **Acquire** listing it in the Mac's Time view (ember dot,
  download link) as a book to obtain.
- **Timeflows flank the corridor**: data diagrams on the very same
  year-to-depth axis — Sankey widths or cylinder graphs standing as
  real tubes in the room, lanes or overlaid, their key outside the
  plot, coloured with Paul Tol's muted colour-blind-safe scheme. Eight
  verified sample series from the last 150 years are one tap away, the
  Ask-for-Data dialog fetches more, and the Mac's Time Flows sidebar
  curates the same shelf.
- **History underfoot**: the physical floor carries a chosen history —
  world, hypertext, hypertext people, environmental, space, computing,
  or discoveries — each event lying at its year's depth.
- **The body is the interface**: arm chips command it all, a fist
  carries the whole space, a two-hand pinch stretches the corridor's
  depth (the rows gathering toward walking height), and readings open
  in-situ on glass panels dragged anywhere by their handles.

Everything travels through the community folder, so the Mac curates
and the headset shows.

## Built to be extended by the community

- **Library views are exchangeable modules**: a new way of seeing the library is one Swift file — write a SwiftUI view, describe it in a `LibraryViewModule`, add one registry line, and it appears in the sidebar. Share the file and others can install it.
- The app is the **reference implementation**, not the owner: the format is fully specified in one self-contained document, and everything the app writes is documented there. Feed the spec to an AI and start building your own.

## Why this matters

- **Your writing outlives any app** — including this one. Plain text, self-describing, on your own disk.
- **Dialogue becomes visible structure**: responses, disagreements, and revisions are recorded connections you can see and traverse, not threads lost in email.
- **Citations are precise and alive**: to the paragraph, with full provenance, resolving to the latest version.
- **Privacy by architecture**: no server sees your library, no AI call leaves the machine, and reader preferences stay local.
- **The record is honest**: append-only history, visible retraction, declared AI production, authorship as an open claim in an open format.

---

*Questions, objections, and the format's future belong to the community — the format is provisional pending that discussion, and it is designed to grow through it. The Future Text Lab: https://futuretextlab.info*
