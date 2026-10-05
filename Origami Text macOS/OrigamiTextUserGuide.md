---
title: Origami Text User Guide
subtitle: For macOS
author: Future Text Lab
date: 2026-10-05
---

# Origami Text User Guide

*For Origami Text on macOS, version 1.1. Origami Text also runs on iPad and
Apple Vision Pro, which share your library through a community folder
(section 13).*

Origami Text is a reader for scholarly documents. Its home format is the
**Origami EPUB**: an ordinary EPUB, readable in any EPUB reader, that also
carries records about itself — who wrote it, where it was published, how to
cite it, what it cites, its glossary and its map. Because the book knows
these things, the reader can do far more with it than show pages: follow a
term through a paper, see which of its references cite each other, warn you
when a cited work has been retracted, and answer questions about your whole
library.

This guide covers everything the app does on the Mac. Read sections 1 to 6
to get going; the rest you can look up when you need it.

1. Getting started
2. Bringing documents in
3. Your library
4. Reading
5. Selecting text: the dot, its menu and Context
6. Citations and the References page
7. Highlights, comments and notes
8. AI
9. Views
10. Writing and exporting
11. Import to Format: a paper in a publisher's format
12. Finding things
13. Sharing between your devices, and Hypermedia
14. Settings, tab by tab
15. Keyboard shortcuts
16. What goes online, and when
17. Troubleshooting and contact

---

## 1. Getting started

### 1.1 The window

The main window has three parts:

- **The sidebar** on the left: your library's places (Pinned, Authors,
  Papers, Journals, Folders, Views…) and, at its foot, **Intro**,
  **Settings** and **Contact**.
- **The list** in the middle: the books in the place you chose.
- **The reading pane** on the right: the book you are reading, with the
  **foot bar** of reading words along its bottom edge.

**Intro**, at the foot of the sidebar, opens the introduction to Origami
Text. It also opens by itself when you start the app with nothing else open.

### 1.2 Your first books

Choose **File ▸ Import…** (⇧⌘I) and pick an EPUB — or drag EPUBs onto the
window. Each joins your library and appears under **Papers**. Select one and
it opens in the reading pane. Section 2 lists everything else you can bring
in.

### 1.3 Getting back to the library

**Window ▸ Library** (⌘L) always brings the main window back, even after
you have closed it, as does clicking the app's icon in the Dock.

### 1.4 This guide

This guide is itself an Origami EPUB on your shelf: open it any time with
**Help ▸ Origami Text Guide**. It is updated with each new version of the
app, and the copy on your shelf is replaced when it is.

---

## 2. Bringing documents in

### 2.1 Import

Choose **File ▸ Import…** (⇧⌘I) or **File ▸ Open…** (⌘O), or drag files
onto the window.

| You import | It becomes |
|---|---|
| An **EPUB** | A book in your library, exactly as published |
| A **LaTeX** project (`.zip`, `.tex`) or **arXiv source** (`.tar.gz`) | A converted EPUB in your library |
| **ACM / JATS XML**, or a **Word paper in the ACM template** | A converted EPUB in your library |
| A **web page** (`.html`, `.xhtml`) or **OpenDocument** (`.odt`) | A converted EPUB in your library |
| A reference list: **BibTeX** (`.bib`), **RIS** (`.ris`), **EndNote** (`.enw` or EndNote XML), **CSL-JSON** | A converted EPUB in your library |
| A **Markdown**, **Typst** (`.typ`), **AsciiDoc** (`.adoc`) or **reStructuredText** (`.rst`) paper | A converted EPUB in your library |
| A **Word**, **RTF**, **PDF** (with text) or **Author** document | A document you can edit and publish |
| A **zip of many EPUBs** (a whole proceedings, say) | Every book joins the library at once |

**A paper and its bibliography together.** Choose or drop a paper (LaTeX,
Markdown, Typst, AsciiDoc or reStructuredText) together with its
bibliography file, and it imports as one document, every citation linked to
a reference list built from that file. Otherwise the paper's own
bibliography is used — the one it names, or one kept beside it. When that
file sits beside the paper, Origami Text asks once for access to its folder.

**Word papers in the ACM template** are read by their paragraph styles —
title, authors, affiliations, abstract, CCS concepts, keywords, headings,
figures, tables and references. ACM's own CCS code, which the template keeps
in the document's properties, is read too. If ACM's TAPS HTML for the paper
(same name, `.html`) sits beside the `.docx`, Origami also takes the DOI,
the ACM Reference Format, the licence, ORCIDs and equations from it.

**Author documents** import with their citations linked: each citation in
the text becomes a link to its reference.

**Equations** in LaTeX, JATS and Markdown (`$…$`, `$$…$$`) become real
mathematics (MathML). An equation using a command the converter does not
know is kept as readable text.

**A whole folder:** choose a folder in the Import panel. Every paper in it is
converted and filed, and you get one summary at the end. Papers already in
your library are skipped, so importing a folder again never makes
duplicates.

### 2.2 From the web and other places

- **File ▸ Fetch by DOI or URL…** brings in a paper from the web: type a DOI
  (such as `10.1145/3603163.3609048`) or an address. Origami looks for a
  free, legal copy — an EPUB, a PDF, or the full text at Europe PMC or
  arXiv.
- **File ▸ Browse Catalogues…** browses online catalogues of books.
- **File ▸ Open Gemini URL…** opens a `gemini://` page; Seed/Hypermedia
  (`hm://`) addresses open directly too (section 13).
- **File ▸ Import Reference Dataset…** adds a large bibliography (such as the
  ACM Hypertext series dataset). Citation cards then show its records and
  citation counts.
- **File ▸ Import Annotations…** brings in highlights and comments exported
  from another copy of Origami Text.
- **File ▸ Hold Up a Page…** uses the camera to read a printed page.

---

## 3. Your library

### 3.1 The sidebar

| Place | What it holds |
|---|---|
| **Pinned** | The books (and authors) you have pinned |
| **Authors** | Everyone who wrote what you read, sorted by the **Name**, **Papers** or **Date** tab |
| **Papers** | Every book, sorted by the **Title** or **Date** tab — click the chosen tab again to reverse the order. Settings ▸ Layout can call this **Articles** |
| **Journals** | Books grouped by the journal or proceedings they belong to. Settings ▸ Layout can call this **Proceedings** |
| *Your name* | The papers you wrote |
| **To Acquire** | Works you have asked to get (it appears when there is something on it) |
| **Hypermedia** | The Seed spaces you follow (section 13) |
| **Folders** | Your own groupings; **Add Folder** makes one |
| **XR** | Graphs and Timelines for the Vision Pro |
| **Views** | Annotations, People, Concept Space, Tracked Concepts and the library views (section 9) |

Right-click **Papers** to show only unread books.

### 3.2 A book's menu

Right-click any book in a list:

- **File Under ▸** a folder, or **New Folder…**; **Remove from Folder**;
- **Copy to Cite** — its citation, ready to paste into your writing;
- **Read Beside "…"** — read it next to the book that is open (section 4.11);
- **Pin** — keep it at the top of every list;
- **Set Aside** — move it out of the way without deleting it; it waits behind
  the **Set Aside** pill at the foot of the list until you **Bring Back** it;
- **Move to Trash**.

Pins and Set Aside travel to your iPad and Vision Pro.

### 3.3 Journals and proceedings

Choosing a journal focuses the sidebar on it alone: its name, its
**Authors** (with sort buttons — first name, last name, or most papers across
the series) and its **Concepts**. The **AI Analyse** pill reads the whole
journal and gathers its topics. Click **Origami Text** at the top of the
sidebar, or press **Esc**, to see every place again.

Right-click a journal for **Re-Generate AI Analysis**, and to merge two names
for the same venue (**Is the Same As ▸**) or separate them again
(**Separate ▸**).

### 3.4 The journal Map

Open a journal and choose **Map** above the list. Every article becomes a
card on a plane:

- **drag** cards to arrange them as you think about them;
- **click** a card to lift it and read its abstract; **double-click** to open
  the article;
- **right-click** to Pin or Set Aside;
- **⌘A** selects every card; dragging one then moves them all;
- **Find**, at the Map's foot, lights up the matching cards;
- the **view menu** at the foot rearranges the cards: **Default** (your own
  arrangement), **Topics**, **Authors**, **People**, **Author Rank**, and any
  views you have saved with **Save Current View…**. **Share View ▸** puts a
  saved view in the community folder for your other devices;
- **Topics**, at the foot, shows the topic bar: up to twelve topic magnets
  along the top, each article standing under the one it belongs to. Edit a
  magnet's name to change it; click one to see threads to its articles.

Your Default arrangement appears the same on your other Mac, your iPad and,
at its own depth, in the Vision Pro.

### 3.5 Authors and people

Click an author to see their papers in your library. Right-click to **Pin**
them or **Set Aside**. **People**, under Views, holds people you add
yourself, with their profiles; Settings ▸ Author can draw portraits for
them.

### 3.6 To Acquire

A work you ask to get — from a citation card's **Acquire** — waits here, with
buttons to look for it: **DOI**, **Open Copy**, **Scholar**, **Books** and
**Open Library**. Dismiss a wish once you have it.

---

## 4. Reading

### 4.1 Opening a book

Select a book and it opens in the reading pane, at its beginning. (Settings ▸
Reading ▸ **Reopen books where I left off** opens it where you stopped
instead.)

**A book you only want to glance at:** double-click an EPUB in the Finder.
It opens in its own window and is not added to your library; **Import to
Library**, at the foot of that window, adds it if you change your mind.

### 4.2 The foot bar

The words along the bottom of the reading pane choose how you read. From
left to right:

| Word | What it does |
|---|---|
| **AI** | This Mac's model reads the book: the **AI** summary, and **Issues** beside it (section 8) |
| **Scroll** | The book's own pages, in a column you scroll through |
| **Outline** | Folds the book: **Outline** (headings alone), **Overview**, **Citations** |
| **Horizontal** | Pages side by side, like a printed spread — two, or more on a wide window |
| **Focus** | One section at a time: **Focus**, **Sentence**, **Paragraph**, **Word** |
| **References** | Every work the paper cites (section 6) |
| **Transcript** | For meeting transcripts only: turns grouped by speaker |

The word in bold is the one you are in. Choose a word again, or another
word, to leave a fold or a page such as References.

At the left of the foot bar: **pin** and **set aside** for the open book. At
the right: **Contents** (every section, one click away; in Scroll also **Go
to page**), and the type controls (section 4.8).

### 4.3 Scroll

The book's own pages, as published, in a comfortable column. In Scroll:

- the **←** and **→** keys move to the previous and next paper in the list;
  **↑** and **↓** step through the headings;
- the progress readout shows how far you are and how many minutes are left;
- **Bookmarks** keep places: **Add Bookmark Here**, then choose one to
  return;
- the **margins** can hold the document's **Outline** or your
  **Annotation** for the whole document (Settings ▸ Reading ▸ Margins). The
  Outline margin shows where you are and jumps where you click; margins hide
  themselves after a few seconds unless you turn that off.

### 4.4 Outline, Overview and Citations

**Outline** folds the paper to its headings — its skeleton. Click a heading
to open that section in place. **Fold** (⌘−) and **Unfold** (⌘=) go level
by level.

**Overview** shows each section's heading with what it holds: pictures of
the people, places and organisations it mentions, its names, its Marked and
bold lines, your highlights and comments, and its citations. Choose what
appears in Settings ▸ Overview.

**Citations** shows each heading with the works its section cites.

### 4.5 Horizontal

Pages side by side, like a book. Use the arrow keys or the trackpad to turn
pages. In Horizontal the paper's title shows at the left of the foot bar.

### 4.6 Focus

One section alone, to settle into; the arrow keys move through. Its
companions:

- **Sentence** — one sentence at a time;
- **Paragraph** — one paragraph at a time;
- **Word** — speed reading, word by word at the pace you choose.

### 4.7 Full screen

Press **Esc** or use the green window button. In full screen the sidebar
slides in when you move the pointer to the left edge, and away when you
leave.

### 4.8 Type, theme and colour

- **Theme:** the palette button at the foot, or Settings ▸ Reading ▸
  **Theme**. Choose from High Contrast, Sepia, Grey, Gentle, Low Contrast,
  Warm, Cool, Cream, Night, Solarized and more — or make your own with
  **Edit Theme Colors…**. The References page, the context panel and the
  menus follow your theme.
- **Type:** in Scroll, the type popover sets **Size**, **Spacing**, **Width**
  (Wide, Medium, Narrow), **Justify**, **Hyphenate**, and **Publisher's
  Styles** (the book's own type). In Horizontal and Focus, the **Aa** menu
  sets text size, line spacing and measure, and how **Citations** (Author
  Date, [Number], Superscript), **Notes**, **Marked Text**, the **Glossary**
  and **Stretchtext** appear.
- **View ▸ Bigger Text** (⇧⌘+), **Smaller Text** (⇧⌘−), **Looser Lines**
  (⌥⌘+), **Tighter Lines** (⌥⌘−).
- **Fonts:** Settings ▸ Reading ▸ Fonts sets the body and heading typefaces
  used everywhere.

In Horizontal and Focus, more reading aids sit at the foot: text colouring by
**Grammar**, **Meaning**, **Argument** or **Key Statement**; the **¶** popover
(paragraphs, **Flow**, colour key sentences); **Bionic Reading** and a
**Reading Ruler**.

### 4.9 Flow and paragraph numbers

**View ▸ Flow** (⇧⌘F) breaks the text into reading lines at sentence and
clause marks. **View ▸ Paragraph Numbers** shows numbers in the margin;
click one to copy a link to that paragraph.

### 4.10 Reading aloud

The speaker button at the foot reads the page aloud (Space starts it).
Choose the voice in Settings ▸ Assistive: Apple's system voices, or a
neural voice that runs on this Mac.

### 4.11 Reading two documents side by side

Right-click a book and choose **Read Beside "…"**, or use **Go ▸ Read in
Parallel**. **Exit Parallel Reading** returns to one. **Go ▸ Back** (⌘[) and
**Forward** (⌘]) move through the documents you have opened.

### 4.12 Links, figures and notes

- **In-document links** ("see Figure 2", "Section 3") jump to their place.
- **Double-click a figure** to open it in its own window.
- A **figure that links to Interatlas** (or elsewhere) shows a small badge;
  click it to open the link; right-click for **Show Image** and **Show
  Reference**.
- **Footnotes and endnotes** open where you click them, as a popup or in
  place (Settings ▸ Reading ▸ Citations & Notes).
- A paper's **authors** are shown with their affiliation, email and ORCID,
  which are live links.

---

## 5. Selecting text: the dot, its menu and Context

Select words in **Scroll** or **Horizontal** — drag across them, or
double-click a word — and a small **chrome dot** appears just below and to
the right of where you let go, where a finger curls down to it.

**Move the pointer onto the dot** and its menu appears:

| Item | What it does |
|---|---|
| **Show All** | Folds the paper to its headings and every sentence that uses the selected words, each highlighted. **⌘G** and **⇧⌘G** step through them. Choose a reading word to leave |
| **Annotate** | Highlight the words as **Important**, **Quotable**, **Great**, **Disagree**, **Language Issue**, **Problematic**, **What is this?**, **Highlight** or **Strikethrough** — or **Comment…** |
| **Copy as Citation** | Copies the words as a cited quote, with the book's citation, ready to paste into your writing |
| **Context** | Opens the context panel |

**The context panel** tells you what is known about the selected words:

- the **definition**, when the paper's glossary defines them;
- a **profile**, when the words are a person your library knows;
- **In this paper** — how often the paper uses the words, with the first and
  last sentences that do;
- **Your notes** — your highlights and comments on the same words, in any
  book;
- **In your library** — other papers that use the words, in their title or
  text. Click one to open it.

Drag the panel by its title bar to move it; close it with the round button
at its left. While it is open it follows each new selection.

**Prefer the Mac's own behaviour?** Settings ▸ Reading ▸ Selection:
**Custom** shows the dot; **System** leaves only the right-click menu.

**The right-click menu** on a selection still offers everything:
**Show Definition**, **Highlight ▸**, **Add Comment…**, **Copy to Cite**,
**Copy**, **Look Up**, **Translate**, and in Horizontal also **Lift** (float
the quote on the page as a slip) and **AI ▸** (your own prompts).

---

## 6. Citations and the References page

### 6.1 The citation card

Click a citation in the text — [3], or "(Hegland 2025)" — to see its card:
the work's title, authors, year and abstract. Where the paper did not carry
an abstract, Origami asks Crossref and Semantic Scholar (and OpenAlex, if you
have a key) and shows what they know, naming the source.

From the card:

- **Open Original** / **Open in Library** — when the work is on your shelf;
- **Open on the Web** and **Online** — find the work on the web;
- **Acquire** — put it on your To Acquire list;
- **Copy BibTeX**;
- **View as Tree** — the works it cites, and the works those cite;
- **Cites N works** — expand to see what the work itself cites. A work that
  is also one of this paper's references has an **←** arrow: click it to
  open that work's card. **Double-click** any work in the list to look it up
  in its own card, with **Acquire**.

When a work has marks (section 6.3), the card lists each with what it means
and its evidence.

### 6.2 The References page

**References**, at the right of the foot bar, shows every work the paper
cites, as a whole page in your reading theme. Choose how they are listed
with the tabs at the top:

| Tab | Shows |
|---|---|
| **As Cited** | The paper's headings, each with the works its section cites, in the order it cites them. A work cited in several sections is marked **1st**, **2nd**…; hover to see every section that cites it. Works never cited in the text gather at the end |
| **Title** | Alphabetical by title |
| **Author** | Alphabetical by first author, the names large |
| **Date** | Newest first, grouped by year |
| **Time Map** | The works on a plane, one column per year, oldest at the left |
| **Concept Map** | The works on a free plane, arranged by how they relate |

Click a work to open its card. Right-click for **Show Citation Card**, **Open
in Library**, **Open on the Web**, **Read the Free Copy**, **Show Citation
Tree** and **Copy Citation**.

### 6.3 Marks: what Origami knows about each work

Under each work, small marks tell you its standing.

**Trust — shown as pills:**

| Pill | Means |
|---|---|
| **Retracted** (red) | Formally retracted; its findings should not be relied on |
| **Withdrawn** (red) | Withdrawn by its authors or publisher |
| **Not Replicated** (red) | Later studies repeated it and did not find the same result |
| **Expression of Concern** (orange) | The publisher has warned that its reliability is in question |
| **Replication Mixed** (orange) | Later attempts to repeat it disagree |
| **Preprint** (blue) | Not yet peer reviewed; shows nothing once a published version exists |
| **Replicated** (green) | Later studies repeated it and found the same result |
| **Corrected** (grey) | The publisher has issued a correction |
| **Unverified** (grey) | The reference could not be confirmed to exist — check it |

**Importance, kind, use and access — shown as words:** **Foundational**
(cited by several of this paper's other references), **Top 1% Cited** or
**Top 10% Cited** (with an OpenAlex key), **Classic**, **Cited N×**; the kind
of work (**Data**, **Software**, **Review**, **Meta-analysis**, **Book**,
**Chapter**, **Thesis**, **Report**, **Web**); **Key** (cited three or more
times in this paper) and **Self** (shares an author with it); **In Library**
and **Open Access**.

A red line at the top of the page counts any retracted, withdrawn or
not-replicated works the paper cites.

**You may know better.** In a citation card, click any pill and choose
**Remove**. Origami remembers this on your Mac for that work, in every
document that cites it. **Restore** in the same card brings it back.

**Where the marks come from:** the Retraction Watch database and FORRT's
replication database, both kept on your Mac and checked offline; Crossref,
the DOI system, DataCite, Unpaywall and OpenCitations, asked once a month
per work. Turn any of them off in Settings ▸ Reading ▸ References
(section 16).

### 6.4 The Time Map

The works stand in columns by year, oldest at the left. A line joins two
works when one cites the other — the newer always citing the older. Origami
finds these lines by reading each cited work's own reference list: from your
shelf when the work is there, otherwise from Semantic Scholar, OpenAlex,
Crossref and OpenCitations. The status line shows progress the first time;
afterwards the answers are kept.

- **Drag** a card up or down to arrange its column; it cannot leave its year.
- **Click** a card to lift it: its lines brighten and unconnected works step
  back. **Double-click** to open its card.
- **⌘A** selects every card.
- **View**, beside the tabs, orders each year's column: **As Arranged**,
  **Title**, **First Author**, **Most Cited**, **Cited by These References**,
  **Cited Most in This Paper**, **Venue**, or **Trust (warnings first)**.
  Dragging a card while a sort is shown makes the arrangement yours again.

### 6.5 The Concept Map

The same works on a free plane: drag them anywhere. **View** arranges them:

| View | Arranges the works |
|---|---|
| **As Arranged** | Where you put them |
| **Citation Network** | Works that cite each other drawn together |
| **Shared References** | Works that cite the same earlier works drawn together (bibliographic coupling) |
| **Cited Together** | Works this paper cites in the same paragraph drawn together |
| **By Section** | Under the section of this paper that first cites them |
| **By Author** | Under the authors who recur in the list |
| **By Venue** | By journal or conference |
| **Core & Periphery** | The most connected works at the centre, the rest in rings outward |

---

## 7. Highlights, comments and notes

- **Highlight** selected words from the dot's **Annotate**, or right-click ▸
  **Highlight ▸**. Each kind has its own colour; rename the kinds and change
  their colours in Settings ▸ Annotations.
- **Comment** on selected words with **Comment…** or **Add Comment…**.
- **A note on the whole document:** right-click the page's background ▸
  **Add Note…**, or set a margin to **Annotation** (Settings ▸ Reading ▸
  Margins) and write in it.
- **A note anywhere on the page** (Horizontal): right-click ▸ **Note Here…**.
- **Lift** a quote: it floats on the page as a slip you can move.

Your annotations are yours: they are kept beside the book, never written
into it, and every one of them is listed under **Views ▸ Annotations**.
Click a painted highlight to see its comment or remove it.

---

## 8. AI

### 8.1 Which model

Settings ▸ AI ▸ **Language Model** chooses the model every AI feature uses:
Apple's built-in model on this Mac, or a model server you add — such as
Ollama running on your own Mac (**Add a Model or Server**, **Find a model for
this Mac…**). Nothing is sent to a server unless you choose one.

### 8.2 The AI reading

**AI**, at the left of the foot bar, reads the open paper:

- **Aim** and **Conclusion** — what the paper sets out to do, and what it
  finds;
- **In the rest of the paper** — what else you will learn if you read on;
- a plain-language summary;
- **Names**, **Keywords** and a **Glossary** of terms the paper introduces or
  uses in its own way, each with its first and last use in the paper.

Names and keywords are checked against the paper's text, so only words the
paper really uses appear.

- **Click a keyword or name** and the paper folds to every sentence that
  uses it (the same as **Show All**).
- **Column View**, at the foot, opens those results in a column on the right
  instead, half the screen; click a result to read the paper there.
- **Issues**, beside the summary, notes problems of logic, factual
  correctness and structure. Click an issue to set it aside.
- **Regenerate** asks again; **Remove** discards the reading; **Edit
  Prompt** changes the instructions the model is given (also in Settings ▸
  AI ▸ AI Prompts).

### 8.3 Ask the Library

**Views ▸ Ask** answers a question from your own library: type "What does
my library say about…", and the answer cites the passages it rests on.
Click a source to open it.

### 8.4 Concepts

Concepts are gathered from what you read and appear in **Views ▸ Concept
Space** and **Tracked Concepts**. **Add Concept** tracks one of your own.
A journal's **AI Analyse** gathers its topics for the Map.

---

## 9. Views

**Views**, in the sidebar, hold whole-library ways of seeing:

- **Annotations** — everything you have highlighted or commented on;
- **People** — the people you follow, with profiles;
- **Concept Space** and **Tracked Concepts**;
- the library views you have switched on — **Ask**, **Glossary** and
  **Lineage** to begin with. **Edit Views** chooses which appear, from
  Connections, The Weave, Author's Circle, Map (places), Trails, Themes, Open
  Questions, Agreements, Disagreements, Hot Paragraphs, AI Insights,
  Citation Tree and more.

Settings ▸ **View Modules** turns views on and off, imports views made by
others, and helps you make your own.

---

## 10. Writing and exporting

- **File ▸ New Document** (⌘N), **New Note** (⇧⌘N), **New Book** (⇧⌘B) and
  **New Author** (⌥⌘N) start your own writing. **File ▸ Save** (⌘S) saves it.
- **File ▸ Export…** (⇧⌘E) publishes a document as an Origami EPUB.
- **File ▸ Export as Gemtext (.gmi)…** for the Gemini network.
- **File ▸ Export to XR (Author Map)…** takes a Map into Author's spatial
  view.
- **File ▸ Export Library Manifest…** writes a list of everything in your
  library.

---

## 11. Import to Format: a paper in a publisher's format

**File ▸ Import to Format…** takes a paper and produces it in a publisher's
format, as **LaTeX, PDF and EPUB**. Your original file is never changed.

### 11.1 What you can start from

An EPUB; Word (`.docx`, `.doc`); OpenDocument (`.odt`); RTF; LaTeX (a
`.tex`, a project zip — including Overleaf's download — or an arXiv source
`.tar.gz`); Markdown; a web page (`.html`); JATS XML; PDF; an Author
document; or a reference list on its own (`.bib` or CSL-JSON). For LaTeX,
choose the project zip rather than a single `.tex` — only the project brings
its bibliography.

### 11.2 The sheet

A sheet shows everything about the paper, filled in from the file. **Every
field can be corrected** for this conversion:

- **Format** — the publisher: **ACM** (conference proceedings, and ten other
  ACM formats), **IEEE**, **Springer LNCS**, **Elsevier**, or **Preprint**.
  Only ACM's conference format (`sigconf`) is fully verified; the others are
  marked.
- **Paper** — title, subtitle, date and abstract.
- **Language and translation.**
- **Authors** — name, affiliation (*Institution, City, Country*), email and
  ORCID for each; add, remove and reorder. A mistyped ORCID is flagged.
- **Venue and identifiers** — at the top, paste the **ACM rights code** that
  ACM's eRights form gives you, and the year, licence, conference, DOI and
  ISBN fill themselves in. Or type the venue, short name (e.g. *HT ’26*),
  dates, place, DOI and ISBN.
- **Classification** — keywords and CCS concepts. Paste the code from ACM's
  CCS tool straight in.
- **Rights and output** — the licence (Creative Commons CC BY and its
  variants, rights retained, licensed to ACM, copyright transferred to ACM, or
  none); the **ACM upload name**; **Also write an EPUB in this style**; **Keep
  the Visual-Meta colophon**; **Also compile to PDF**.

The foot of the sheet lists anything the paper lacks, so nothing surprises
you in the result. Choose **Process**.

### 11.3 What you get

A folder holding `paper.tex`, `refs.bib`, the images, a README, the EPUB if
chosen, and the PDF. For ACM, also the **upload ZIP** exactly as ACM's TAPS
system expects it (`pdf/` and `Source/`, named like `ht26-3`).

### 11.4 Making the PDF

The PDF needs TeX on your Mac (MacTeX, free). If it is missing, the sheet
offers **Get MacTeX…**; install it and choose **Check Again**. Because of the
macOS sandbox, the first time the sheet offers **Save Compile Helper…**:
click it and press **Save** without changing the folder or name. From then on
PDFs are made automatically.

**The current ACM template, always.** Origami fetches the current release of
ACM's `acmart` class from CTAN, builds it once, and sets every ACM paper with
it — whatever version your TeX installation has. The line under **Also
compile to PDF** shows the version used and **Check Now** looks for a newer
one.

If something fails, the message says which part and why; the other parts are
still written.

---

## 12. Finding things

- **Find** — the field at the foot of a list searches titles, authors and the
  full text of your library. Results that match only in the text appear under
  **In the Text**, each with the passage.
- **Find in a book** — **View ▸ Find** (⌘F) in the open book; **Find Next**
  (⌘G) and **Find Previous** (⇧⌘G); **All Chapters** searches the whole
  book.
- **Show All** — select words and choose **Show All** from the dot's menu
  (section 5).
- **Where Have I Read This?** (⌥⌘F) — copy a phrase from anywhere, such as an
  email or a web page, and choose this command: Origami shows where in your
  own reading it appears. It is also in every app's **Services** menu.
- **The Links panel** — **Window ▸ Show Links Panel** (⌥⌘L) shows everything
  the current document links to, what links to it, and where your library
  cites it.

---

## 13. Sharing between your devices, and Hypermedia

**File ▸ Choose Community Folder…** (⇧⌘O) picks a folder — usually in iCloud
Drive — that your Mac, iPad and Vision Pro all use. Books placed there appear
on every device; pins, Set Aside and Map layouts follow. **Rescan for
EPUBs** (Settings ▸ Library) reads the folder again.

**Hypermedia (Seed):** Settings ▸ Hypermedia connects Origami to the Seed
Hypermedia network: create an account or sign in, and follow spaces. The
spaces you follow appear in the sidebar's **Hypermedia** section, where you
can read and comment.

---

## 14. Settings, tab by tab

| Tab | What it holds |
|---|---|
| **Author** | Your name, title, ORCID and affiliation; contact portraits; people you have muted |
| **Editor** | Editing preferences, and checking references with Crossref |
| **Reading** | Theme and colours; **Margins**; **Citations & Notes**; reopening where you left off; **Selection** (Custom dot or System); triple-click; **Cited Works** (online lookups and your OpenAlex key); **References** (the databases and checks of section 6.3); **Fonts** |
| **Overview** | What the Overview shows under each heading, and its pictures |
| **Assistive** | Reading aloud: the voice and its speed |
| **Annotations** | The highlight kinds: their names and colours |
| **Layout** | The list's title font; what the library and venues are called |
| **Library** | The community folder; your Reader library; what **Where Have I Read This?** searches; which apps open Interatlas and Liquid links; reference datasets |
| **Hypermedia** | Your Seed account and the spaces you follow |
| **AI** | The language model; servers; the AI prompts; relevance; person profiles |
| **View Modules** | Which library views appear; importing and making your own |
| **Open Source** | The Origami document format and EPUB profile, to read or give to an AI |

---

## 15. Keyboard shortcuts

| Shortcut | Does |
|---|---|
| ⌘N | New Document |
| ⇧⌘N | New Note |
| ⇧⌘B | New Book |
| ⌘O | Open… |
| ⇧⌘I | Import… |
| ⇧⌘O | Choose Community Folder… |
| ⌘S | Save |
| ⇧⌘E | Export… |
| ⌘W | Close |
| ⌘L | Library |
| ⌥⌘L | Show Links Panel |
| ⌘F | Find |
| ⌘G / ⇧⌘G | Find Next / Find Previous |
| ⌥⌘F | Where Have I Read This? |
| ⌘− / ⌘= | Fold / Unfold |
| ⇧⌘+ / ⇧⌘− | Bigger / Smaller Text |
| ⌥⌘+ / ⌥⌘− | Looser / Tighter Lines |
| ⇧⌘F | Flow |
| ⌘[ / ⌘] | Back / Forward |
| ⌘A | Select every card (Maps) |
| ← / → | Previous / next paper (Scroll) |
| ↑ / ↓ | Previous / next heading (Scroll) |
| Esc | Full screen; or back to every place in the sidebar |

---

## 16. What goes online, and when

Origami Text works offline. It goes online only for what you ask of it, and
never asks you to sign in to anything when it starts.

| When | What is asked | Of whom |
|---|---|---|
| A citation card lacks an abstract | The work's title or DOI | Crossref, Semantic Scholar, OpenAlex (with your key) |
| The References page opens | Each cited work's DOI, once a month | Crossref, the DOI system, DataCite, Unpaywall, OpenCitations; OpenAlex with your key |
| The References page opens, once a week | The Retraction Watch and FORRT replication databases are downloaded | Crossref (GitLab), FORRT (GitHub) |
| The Maps read who cites whom | Each cited work's reference list | Semantic Scholar, OpenAlex, Crossref, OpenCitations |
| You make an ACM PDF | The current `acmart` version, at most daily | CTAN |
| You fetch a paper | The DOI or address you typed | Crossref, OpenAlex, Europe PMC, arXiv, the publisher |
| You use AI with a server you chose | The text of the passage or question | That server only |

Each of the References checks can be turned off in Settings ▸ Reading ▸
References, and all lookups of cited works with **Look up cited works
online**. Answers are kept on your Mac, so nothing is asked twice.

---

## 17. Troubleshooting and contact

- **A book opens blank or looks wrong:** try **Publisher's Styles** in the
  type popover, or another reading word.
- **No PDF from Import to Format:** check that MacTeX is installed and that
  the compile helper was saved (section 11.4). The folder's README gives the
  command that makes the PDF by hand.
- **Lines on the Time Map are missing:** the first time, Origami is still
  reading the cited works' reference lists — the status line shows progress.
  An OpenAlex key (Settings ▸ Reading ▸ Cited Works) finds more.
- **A mark is wrong:** remove it from the work's citation card (section 6.3).

**Contact**, at the foot of the sidebar, emails your feedback to the
developers. **Help ▸ Future Text Lab Website** opens our site.

*Origami Text is made by the Future Text Lab.*
