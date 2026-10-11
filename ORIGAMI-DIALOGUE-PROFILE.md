# Origami Dialogue Publications: Meeting Transcripts and Letters

*Version 0.1, 11 October 2026. An addition to the [Origami EPUB Profile 1.0](ORIGAMI-EPUB-PROFILE-1.0.md). Written for Author, which produces these publications, and for any reader that wants to understand them.*

## 1. What this covers

A **dialogue publication** is one EPUB 3 holding one meeting's transcript, or one letter. Each one belongs to a **series**: a run of meetings, or one correspondence.

Origami Text reads the series as a timeline, the speakers as people, and every turn as an addressable moment. It analyses all of this ahead of time. The analysis is kept **beside** the EPUB, never inside it (section 7).

Three things must be written:
- the **meeting's own date**;
- the **series** the meeting belongs to;
- **who took part**, and which words each person said.

Everything uses EPUB 3's own vocabulary where it has one, so any EPUB reader understands the basics. Where EPUB has no word, a small `dialogue` block in Visual-Meta carries the rest.

The publication must still read as a plain transcript in any reader: "Frode Hegland: …" on every turn.

## 2. The package (package.opf)

### 2.1 The kind of publication

```xml
<dc:type>transcript</dc:type>      <!-- or: letter -->
```

### 2.2 The date: the meeting's, not the export's

```xml
<dc:date>2026-10-09T17:00:00+01:00</dc:date>
<meta property="dcterms:modified">2026-10-11T09:12:44Z</meta>
```

- `dc:date` is **when the meeting took place**: a full ISO 8601 date and time, with its UTC offset. For a letter it is when the letter was written.
  - The date alone (`2026-10-09`) is allowed when the time is not known.
- `dcterms:modified` stays the export time, as EPUB requires.
- **Today Author writes the export day in `dc:date`. For dialogue publications this must change: the timeline is built from `dc:date`.**

### 2.3 The series

EPUB 3's collection metadata:

```xml
<meta property="belongs-to-collection" id="series">Future Text Lab Meetings</meta>
<meta refines="#series" property="collection-type">series</meta>
<meta refines="#series" property="group-position">42</meta>
```

- **The collection's name** is the series name, exactly as it should be shown. Every meeting in the series uses the same name.
- **`collection-type`** is `series`.
- **`group-position`** is the meeting's number in the series, when meetings are numbered. Leave it out when they are not.
- **Letters:** the series is the correspondence, for example "Letters with Vint Cerf". `group-position` is left out; Origami orders letters by date.

### 2.4 The participants

One `dc:contributor` per person who took part, each with a role:

```xml
<dc:contributor id="p1">Frode Hegland</dc:contributor>
<meta refines="#p1" property="role" scheme="marc:relators">spk</meta>
<meta refines="#p1" property="file-as">Hegland, Frode</meta>

<dc:contributor id="p2">Mark Anderson</dc:contributor>
<meta refines="#p2" property="role" scheme="marc:relators">spk</meta>
```

- **`id`:** the participant's id, used by every turn (section 4). Keep each person's id the same in every meeting of the series when you can, but names decide identity, not ids (section 6).
- **Role:** a MARC relator code.
  - `spk` is a speaker.
  - `mod` is a moderator or chair.
  - `rcp` is a letter's recipient.
  - A letter's sender is its `dc:creator`.
- **`dc:creator`:** whoever made the transcript, as now.

### 2.5 The identifier

`dc:identifier` stays stable for the Author document, as it is now. For letters it is the thread, the way letters arrive today.

## 3. Visual-Meta (visual-meta.json)

The `document` object gains a `dialogue` block. Fields EPUB already states are repeated here so the record is whole on its own.

```json
"document": {
  "title": {"value": "Future Text Lab, 9 October 2026", "lang": "en"},
  "date": "2026-10-09T17:00:00+01:00",
  "dialogue": {
    "type": "transcript",
    "date": "2026-10-09T17:00:00+01:00",
    "duration": "PT1H32M",
    "place": "Zoom",
    "series": {"name": "Future Text Lab Meetings", "number": 42},
    "participants": [
      {"id": "p1", "name": "Frode Hegland", "role": "host",
       "orcid": "0000-0002-1825-0097", "aliases": ["Frode", "FH"]},
      {"id": "p2", "name": "Mark Anderson", "role": "speaker",
       "aliases": ["Mark"]}
    ]
  }
}
```

**The `dialogue` fields:**

| Field | Required | Meaning |
|---|---|---|
| `type` | yes | `transcript` or `letter` |
| `date` | yes | The meeting's (or letter's) date and time, ISO 8601 with offset — the same as `dc:date` |
| `duration` | no | ISO 8601 duration of the meeting, e.g. `PT1H32M` |
| `place` | no | Where it happened — a room, a city, "Zoom" |
| `series.name` | yes | The series name — the same as `belongs-to-collection` |
| `series.number` | no | The meeting's number in the series — the same as `group-position` |
| `participants` | yes | Everyone who took part, in order of first speaking |

**Each participant:**

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Matches the `dc:contributor` id and every turn's `data-speaker` |
| `name` | yes | Full name as shown — the name every turn's label uses |
| `role` | no | `host`, `chair`, `speaker`, `guest`, `sender`, `recipient` |
| `orcid` | no | Bare ORCID iD; the strongest identity across series |
| `aliases` | no | Other names the transcript or the speakers use for this person ("Frode", "FH") — so mentions and earlier transcripts are recognised |

## 4. The turns (the content document)

Each turn is one paragraph. It begins with the speaker's name in a `strong` of class `speaker`, followed by a colon:

```html
<p id="t17" class="turn" data-speaker="p1" data-time="PT12M31S">
  <strong class="speaker">Frode Hegland:</strong> So the question is whether the
  reader can see who disagreed.
</p>
```

- **`id`:** stable and unique in the publication. Every analysis points at turns by this id, so it must not change when the transcript is re-exported unchanged.
- **`class="turn"`:** marks the paragraph as a turn.
- **`data-speaker`:** the participant's id.
- **`data-time`** (optional): when the turn started, as an ISO 8601 duration from the start of the meeting (`PT12M31S`, meaning 12 minutes 31 seconds).
- **The label:** `<strong class="speaker">Name:</strong>` uses the participant's full `name`. It is what makes the transcript readable anywhere, and what readers without this profile go by. Origami already reads it.

**A turn longer than one paragraph** continues in paragraphs with the same `class` and `data-speaker`, and no label:

```html
<p id="t18" class="turn" data-speaker="p1">And the second point is…</p>
```

**Headings** (`h2`, `h3`) mark agenda items or sections. They are optional, and they divide the timeline within a meeting.

**A letter** needs no labels. Its paragraphs are the sender's. The sender is `dc:creator`, and the recipients are `dc:contributor`s with role `rcp`.

**Everything else is as in Profile 1.0:** citations, links, figures, references.

## 5. A minimal complete example

```xml
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
  <dc:identifier id="pub-id">urn:uuid:7c1e…</dc:identifier>
  <dc:title>Future Text Lab, 9 October 2026</dc:title>
  <dc:type>transcript</dc:type>
  <dc:date>2026-10-09T17:00:00+01:00</dc:date>
  <dc:language>en</dc:language>
  <dc:creator>Frode Hegland</dc:creator>
  <dc:contributor id="p1">Frode Hegland</dc:contributor>
  <meta refines="#p1" property="role" scheme="marc:relators">mod</meta>
  <dc:contributor id="p2">Mark Anderson</dc:contributor>
  <meta refines="#p2" property="role" scheme="marc:relators">spk</meta>
  <meta property="belongs-to-collection" id="series">Future Text Lab Meetings</meta>
  <meta refines="#series" property="collection-type">series</meta>
  <meta refines="#series" property="group-position">42</meta>
  <meta property="dcterms:modified">2026-10-11T09:12:44Z</meta>
</metadata>
```

```html
<h2 id="s1">Opening</h2>
<p id="t1" class="turn" data-speaker="p1" data-time="PT0S"><strong class="speaker">Frode Hegland:</strong> Welcome, everyone.</p>
<p id="t2" class="turn" data-speaker="p2" data-time="PT9S"><strong class="speaker">Mark Anderson:</strong> Thanks, Frode.</p>
```

## 6. Who is who across meetings

Origami matches a person across meetings and series in this order:
1. **The ORCID iD**, when given.
2. **The full name**, folded: case, accents and spacing don't count.
3. **The aliases**, recognised as the same person.

An `id` is only local to its publication. The person in Origami's People directory with the same name (or ORCID) is the same person. Names the reader merges by hand in Origami stay merged.

## 7. The analysis lives beside the EPUB

Origami for macOS analyses each dialogue publication and writes the results to the community folder, beside the EPUBs, in `Dialogue/<series>/`:
- **`<meeting>.analysis.json`:** one meeting's analysis. Every item points at turn ids as its evidence.
- **`series.json`:** the series as a whole. Meetings in date order, the people across them, and how they interact.

The headset and other devices only read these files. A meeting is analysed again only when its text, or the analysis itself, changes. Nothing is written into the EPUB.

The first analysis needs no AI model:
- how much each person spoke;
- who answers whom;
- who mentions whom;
- links and citations;
- the terms used.

Topics, themes, claims, agreements, decisions and summaries follow, made by the reader's chosen model and anchored to the same turn ids.

## 8. What Author needs to change

1. **Write the meeting's date and time as `dc:date`** for transcripts and letters. Keep the export time in `dcterms:modified`.
2. **Write `dc:type`:** `transcript` or `letter`.
3. **Write the series:** `belongs-to-collection` with `collection-type` `series`, and `group-position` for a numbered meeting.
4. **Write one `dc:contributor` per participant,** with an `id` and a MARC role.
5. **Add the `dialogue` block to Visual-Meta's `document`:**
   - type, date, series, participants;
   - name, id and role for each participant, plus aliases and ORCID where known;
   - duration and place where known.
6. **Write each turn as `<p id class="turn" data-speaker>`,** labelled `<strong class="speaker">Name:</strong>`.
   - Give it `data-time` when the transcript has timings.
   - Keep turn ids stable across re-exports.
