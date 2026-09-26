# Origami Text — User Guide

*For macOS. Origami Text also runs on iPad and Apple Vision Pro, which
share your library, pins and Map layouts through a community folder
(see §2.8).*

Origami Text is a reader for scholarly documents. Its home format is the
**Origami EPUB**: an ordinary EPUB that also carries its own metadata —
who wrote it, where it was published, how to cite it, its references —
so the reader can do more with it than show pages.

The guide has three parts:

1. **Reading** — opening a single document to read once, or adding it to
   your library.
2. **Working with your library** — the more advanced functions.
3. **Export and conversion** — making EPUBs and PDFs in a publisher's
   format.

---

## 1. Reading

### 1.1 Read a document once — without adding it

**Double-click an EPUB in the Finder** (anywhere except your community
folder). It opens in a window of its own, set in your reading theme and
type, and nothing more: it is not added to your library, nothing about it
is kept, and it leaves no trace when you close the window. This is the
way to glance at something a colleague sent.

Even in this look-only window you can:

- click a citation such as **[3]** to see what it refers to;
- open the table of contents (pinch on the trackpad);
- move through the book's chapters.

### 1.2 Add a document to your library

Choose **File ▸ Import…** (or **File ▸ Open…**) and pick a file, or drag
files onto the window. What happens depends on the kind of file:

| You import | It becomes |
|---|---|
| An **EPUB** | A book in your library, exactly as published |
| A **LaTeX** project (`.zip`, `.tex`) or **arXiv source** (`.tar.gz`) | A converted EPUB in your library |
| **ACM / JATS XML**, a **Word paper in the ACM template** | A converted EPUB in your library |
| A **web page** (`.html`), **OpenDocument** (`.odt`), a **.bib** reference list | A converted EPUB in your library |
| A **Word**, **Markdown**, **RTF**, **PDF** (with text) or **Author** document | A document you can edit and publish |
| A **zip of many EPUBs** (e.g. a whole proceedings) | Every book joins the library at once |

To import a **whole folder** of papers, choose the folder in the Import
panel: each file is converted and filed, and you get one summary at the
end. Already-imported papers are skipped, so re-running a folder never
creates duplicates.

You can also bring a paper in from the web with **File ▸ Fetch by DOI or
URL…**, and open Seed/Hypermedia (`hm://`) or Gemini (`gemini://`)
addresses directly.

### 1.3 Reading a book

Select a book in the list and it opens in the reading pane. **A book
always opens at its beginning.**

**Reading styles** — the words at the foot of the page switch between:

| Style | What it does |
|---|---|
| **Scrolling** | The book's own pages, exactly as published |
| **Full Width** | The text across the whole window |
| **Horizontal** | Pages side by side, like a printed spread — two, or more on a wide window |
| **Focus** | One section alone; the arrow keys move through |
| **Outline** | Sections folded under their headings |
| **Transcript** | For meeting transcripts: turns grouped by speaker |

**Full screen:** press **Esc** (or use the green window button). In full
screen the sidebar slides in when you move the pointer to the left edge
of the screen, and away again when you leave.

**Getting back to the library:** **Window ▸ Library (⌘L)** always brings
the main window back — even after you have closed it — as does clicking
the app's icon in the Dock.

### 1.4 Citations, notes and links

- **Click a citation** ([3], or "(Hegland 2025)") to see a card with the
  work's title, authors, year and abstract. From the card:
  - **Online** searches the web for the work;
  - **Copy to Cite** copies the reference, ready to paste into your own
    writing;
  - **Acquire** puts the work on your *To Acquire* list.
- **Footnotes and endnotes** open where you click them. Choose how their
  marks look in **Settings ▸ Reading** (superscript, bracketed, dagger or
  fold).
- **In-document links** ("see Figure 2", "Section 3") jump to their
  place. A link to a figure shows the figure itself.
- **Double-click any image** to open it in its own window, sized to the
  image.
- **Author details:** a paper's authors are listed with their
  affiliation, email and ORCID. The email and ORCID are live links.

### 1.5 Highlights and notes

Select text to **highlight** it, **tag** it, or **add a comment**. Your
annotations are yours: they are kept beside the book, never written into
it, and appear under **Annotations** in the sidebar. Right-click the
page's background to write a **note on the whole document**.

### 1.6 Finding things

- **Find** — the field at the foot of the list searches titles, authors
  and the full text of your library.
- **Where Have I Read This? (⌥⌘F)** — copy a phrase from anywhere (an
  email, a web page) and choose this command: Origami Text shows where in
  your own reading that phrase appears. It is also in every app's
  **Services** menu.

### 1.7 Making it comfortable

**Settings ▸ Reading** sets the theme (light, dark, high contrast, or
your own colours via *Edit Theme Colors…*), the typefaces, the size and
the line spacing. **Settings ▸ Assistive** holds the accessibility
options, including reading aloud.

---

## 2. Working with your library

### 2.1 The sidebar

- **Library** — every book, with **Time** (newest first), **Alpha** (by
  title), **Pinned** and **To Acquire**.
- **Journals** — books grouped by the journal or proceedings they belong
  to (Settings can rename this group). Inside a journal you also find its
  **Authors** and **Concepts**.
- **Authors** and **People** — everyone who wrote what you read.
- **Folders** — your own groupings. Use **Add Folder**, then right-click a
  book to file it.
- **Annotations** — everything you have highlighted or commented on.
- **Views** — whole-library views such as **Graphs**, **Timelines** and
  **Concept Space**. Choose which appear with **Edit Views**.

### 2.2 Pin and Set Aside

Right-click any book:

- **Pin** keeps it at the top of every list;
- **Set Aside** moves it out of the way without deleting it (bring it
  back from the *Set Aside* pill at the foot of a list);
- **Move to Trash** removes it from the library.

Pins and Set Aside travel to your iPad and Vision Pro.

### 2.3 The Map

Open a journal and choose **Map** at the top. Every article becomes a
card on a plane:

- **drag** cards to arrange them as you think about them;
- **click** a card to lift it; **double-click** to open the article;
- **right-click** to Pin or Set Aside (on iPad: tap to lift, then use the
  buttons on the card; two fingers move the plane);
- **Find** at the foot of the Map highlights the matching cards;
- **‹** at the foot returns to the list; hovering at the left edge shows
  the journal's list over the Map.

Your arrangement is saved and appears the same on your other Mac, your
iPad and — at its own depth — in the Vision Pro's space. Two devices with
the Map open at once keep each other up to date within seconds.

### 2.4 Reading side by side

Use the **Read in Parallel** menu to read two documents next to each
other; **Exit Parallel Reading** returns to one. **Back** and **Forward** move
through the documents you have opened, like a web browser.

### 2.5 The Links panel

**Show Links Panel (⌥⌘L)** shows everything the current document links
to and everything in your library that links to it.

### 2.6 Concepts and AI

Concepts are extracted from what you read and appear in **Tracked
Concepts** and **Concept Space**. The **AI** tab of Settings chooses the
model used for summaries and questions about your library. Settings ▸
**Hypermedia** connects to a Seed space to follow, read and comment.

### 2.7 Writing

**File ▸ New Document, New Note or New Book** starts your own writing.
**File ▸ Save** saves it; see §3 for publishing it.

### 2.8 Sharing between your devices

**File ▸ Choose Community Folder…** picks a folder — usually in iCloud
Drive — that your Mac, iPad and Vision Pro all use. Books placed there
appear on every device; pins, Set Aside and Map layouts follow.
**Rescan for EPUBs** (Settings ▸ Library) reads the folder again.

---

## 3. Export and conversion

### 3.1 Import to Format — a paper in a publisher's format

**File ▸ Import to Format…** takes a paper and produces it in a
publisher's format, as **LaTeX, PDF and EPUB**. Your original file is
never changed.

**What you can start from:** an EPUB; Word (`.docx`, `.doc`);
OpenDocument (`.odt`); RTF; LaTeX (a `.tex`, a project zip — including
Overleaf's download — or an arXiv source `.tar.gz`); Markdown; a web page
(`.html`); JATS XML; PDF; an Author document; or a reference list on its
own (`.bib` or Zotero's CSL-JSON).

> Tip: for LaTeX, choose the **project zip or the arXiv tarball** rather
> than a single `.tex` file — only the project brings its bibliography.

**The sheet.** After you choose a file, a sheet shows everything about the
paper, filled in from the file, and **every field can be corrected** for
this conversion:

- **Format** — the publisher:

  | Publisher | Layout |
  |---|---|
  | **ACM** (conference proceedings and 10 other ACM formats) | as chosen |
  | **IEEE conference** | two column |
  | **Springer LNCS** | one column |
  | **Elsevier journal** — preprint or two column | one or two column |
  | **Preprint (arXiv style)** | one column |

- **Paper** — title, subtitle, **date** and abstract.
- **Authors** — name, affiliation (*Institution, City, Country*), email
  and ORCID for each; add, remove and reorder. A mistyped ORCID is
  flagged.
- **Venue and identifiers** — venue, short name (e.g. *HT ’26*), dates,
  place, DOI and ISBN. The short name, dates and place fill the page's
  running head and rights line.
- **Classification** — keywords and CCS concepts.
- **Rights and output** —
  - **Rights**: Creative Commons (CC BY and its variants), rights
    retained by the authors, licensed to ACM, copyright transferred to
    ACM, or none. It starts from what the paper states, otherwise CC BY 4.0.
  - **Also write an EPUB in this style** — an Origami EPUB with the
    corrected front matter and references set in the publisher's style.
  - **Include the Visual-Meta colophon** — keeps the paper's own
    Visual-Meta section, or adds one: the paper's citation, written in
    the document so it survives printing and copying.
  - **Also compile to PDF.**

The foot of the sheet lists anything the paper lacks (an abstract,
keywords, an affiliation) so it is no surprise in the result.

**Where it goes.** You choose a folder; it receives `paper.tex`,
`refs.bib`, the images, a README, the EPUB and — if chosen — the PDF.

**Making the PDF.** The PDF needs a TeX installation (TeX Live or
MacTeX, both free). Because of the macOS sandbox, the first time you ask
for a PDF the sheet offers **Save Compile Helper…**: click it and press
**Save** without changing the folder or name. From then on PDFs are made
automatically. Without TeX, the folder's README gives the one command
that makes the PDF.

**If something fails**, the message says which part — the EPUB or the
PDF — and why; the other parts are still written.

### 3.2 A formatted reference list

Choose a `.bib` or CSL-JSON file in **Import to Format**: every entry is
set in the chosen publisher's reference style — IEEE, ACM, LNCS or
Elsevier — as a PDF and an EPUB.

### 3.3 Exporting your own writing

- **File ▸ Export…** publishes a document you have written as an Origami
  EPUB.
- **File ▸ Export as Gemtext (.gmi)…** for the Gemini network.
- **Export to XR (Author Map)…** takes a Map into Author's spatial view.
- **Export Library Manifest…** writes a list of everything in your
  library.

### 3.4 What a good source file carries

The more a paper states about itself, the less you need to type in the
sheet: authors with affiliations ending in a country, ORCIDs, abstract,
keywords, a DOI once assigned, and — for LaTeX — its `.bib` inside the
project. Papers written in **Author** carry all of this automatically.
