# Concept colours in Origami Text's XR: a plan for not clashing with them

8 Nov 2026. A plan only; no code has been changed. Revised the same day after a review: every figure re-measured, rose moved, the pill darkened, the guard widened, and Frode's decisions recorded in section 8.

Author and Knowledge Space now give each kind of concept a colour: a Person is orange wherever the writer meets one. Origami Text is to show the same colours in its XR reader (see Author's `CONCEPT_CATEGORY_COLORS_HANDOVER.md`). Origami already colours a great deal in XR, and much of it uses those same hues for other meanings. Today a Find match, a selected label, a "Highlight" annotation and an Event would all be yellow. This plan sets out how Origami should colour everything else so that a colour in the document can only mean one thing.

## 1. The palette to protect

These are the defaults. Each writer can change them, and only the changes are kept, in `categoryColors.json`. The hue and lightness figures are OKLCH. Contrast is WCAG.

| Kind | Hex | Hue | Lightness | On dark desk #1C1C1F | On light desk #FAF7F0 |
|---|---|---|---|---|---|
| person | `#FF9440` | 55° | 0.77 | 7.7 : 1 | **2.1 : 1** |
| artifact | `#C9935A` | 67° | 0.70 | 6.3 : 1 | **2.5 : 1** |
| event | `#FFD233` | 92° | 0.88 | 11.8 : 1 | **1.4 : 1** |
| location | `#4FC96A` | 148° | 0.74 | 8.0 : 1 | **2.0 : 1** |
| institution | `#5FA0FF` | 258° | 0.71 | 6.4 : 1 | **2.5 : 1** |
| concept | `#B07CFF` | 300° | 0.70 | 5.8 : 1 | **2.7 : 1** |

What this table shows:
- **Warm hues are taken.** Everything from orange to yellow (about 50°–95°) belongs to three kinds: Person, Artifact and Event. Person and Artifact are close already: their distance is 9.2 in OKLab ΔE×100. That leaves Origami no room for any orange, amber, gold or yellow of its own.
- **Blue and violet are taken too.** Concept and Institution are 12.8 apart.
- **Two gaps are free.**
  - **Cyan to teal**, about 175°–215°, between Location and Institution.
  - **Rose to red**, about 330°–30°, between Concept and Person. Author keeps red for alarm and the Issue tag, so it is already spoken for in meaning, though not as a kind of concept.
- **Neutrals are free, apart from the middle greys.** Pure white is 20.7 from the nearest concept colour and #ECECEC is 18.0. But Artifact is a low-chroma tan, so greys from about #8A8A8A to #B0B0B0 come within 10–12 of it. A grey that carries a meaning should be #7A7A7A or darker (15.8 and more), or #C8C8C8 or lighter (16.3 and more).
- **The palette is made for dark grounds.** On the light Reading Desk every concept colour fails even 3 : 1 (see section 5).

How far apart counts as distinct: below 10, two colours read as the same colour. From 10 to 15 they can be confused at a glance. From 18 up they are clearly different, and that is the target.

## 2. The rule

> In a view that shows concept colours, a hue that is one of the six means that kind of concept and nothing else.

Everything else Origami shows marks its meaning in one of three ways:
1. **Neutrals:** white, greys, and the room's glass.
2. **Form:** weight, underline, dashes, outline, glyphs and position.
3. **The two free hues.** Use as few as possible:
   - Teal `#17938B` (188°), which is at least 18.5 from every concept colour.
   - Rose `#FF47AE` (352° in OKLCH, lightness 0.70, chroma 0.24), which is at least 18.8 from every concept colour.
   - Alarm red `#D12929` stays as it is: it is 20.2 from the nearest, and it is the same red Author uses for alarm.
   - Rose and red must also stay apart from each other, because annotations use both in the same text. The first rose chosen, `#E94287` (0°), was only 12.5 from alarm red. `#FF47AE` is 19.3 from it, and that's the reason for the move. No rose gets much further from red without coming close to Concept or Person.

Retro is left as it is. It is a look chosen on purpose, with its own colours on black. Knowledge Space's Retro pills don't use concept colours either, so the two apps agree. When Retro is on, concept colours are not shown.

## 3. What clashes today, and what it should become

These are taken from a survey of the files built into the visionOS target. Each colour is shown with the nearest concept colour and the distance between them.

### Severe: reads as a kind of concept (under 10)

| Origami use | Where | Now | Nearest kind, distance | Change to |
|---|---|---|---|---|
| Find match (background) | `OrigamiVision.swift:5563` | `.yellow` #FFCC00 @0.45 | event, **1.7** | A thick white underline (3 pt) with white at 0.12 behind it. The current match gets a 1.5 pt white outline as well. This has to look clearly unlike a Highlight, which is a white fill and nothing else. A fill alone at a slightly different strength would be lost on glass. |
| Selected label or picture in the Map | `EPUBMapView.swift:3498, 3513, 4688` | gold #FFD673 | event, **4.5** | White words and a white glow, like the selected card border already is. Knowledge Space marks selection in white too. |
| "Highlight" annotation | `OrigamiVision.swift:7138–57` | #E8C51D | event, **5.0** | Neutral: white at 0.22. See the annotation table below. |
| Pin icon | `EPUBMapView.swift:3623` | #F2AD40 | person, **6.1** | White. |
| Caution warning or pill | `:3703, :10865`; `VisionMarkPill` | #E0851A / `.orange` | artifact, **5.6** | Alarm red's outline with ⚠︎. Alarm itself stays solid red (decided, section 8). |
| "Good" status | `VisionMarkPill`, stance "agree" | `.green` #34C759 | location, **2.6** | White ✓. A verdict says itself with a symbol rather than green. |
| "Info" status | `VisionMarkPill` | `.blue` #007AFF | institution, 12.0 | Grey ⓘ. |
| Author's mark, orange (the default) | `OrigamiReading.swift:286–296, 1013` | dark #FFBB5F, light #BB6A26 | event **7.3**, artifact 10.6 | In XR the default becomes weight and an underline, with no colour (decided, section 8). Every existing option stays on offer, Blue included. Blue is 15.8 from Institution, so the guard notes it next to the choice instead of hiding it. |
| Selected citation lines | `EPUBMapView.swift:11036–41` | green, blue, yellow, grey, red @0.45 | location 4.4, event 4.4 | Teal in three weights or dash patterns, plus grey. |
| Lines to deeper citations | `:11845` | #FFB84D @0.08 | event 7.1 | White @0.08. |
| Lineage "influence" | `LineageCore.swift:426–434` | #C4791C | artifact **7.1** | Rose #FF47AE. "Roots" #2743C4 can stay, as it is 25.8 from Institution. |

### Subject tags: a second set of categories in the same Map

`OrigamiTags.defaults` (`EPUBShelf.swift:5309–33`) colours works by subject. Seven of its eight colours fall within 7.7 of a concept colour. For example, Extended Reality #4A8FE7 is 5.9 from Institution, and Artificial Intelligence #9B6BE0 is 6.8 from Concept. There are eight subjects and only two free hues, so tags can't simply be given new colours. Instead, **tags and concepts keep apart by role**:
- **Concept colours are ink.** They colour words, bullets and a concept's own node.
- **Tag colours are ground.** They stay what they mostly are already: a muted mosaic behind a card, under the black wash (0.36 or 0.42). They are never used as text. A card's title and a hub's label (`EPUBMapView.swift:3515, 3801`, the first `paintColours`) become white.
- **Spheres and blobs** for a subject (`:3885`) stay tag-coloured. They are drawn at lower chroma, about 0.06 in OKLCH, so they read as a subject's colouring and not as a concept's colour. They also never stand where a concept's node does.
- **The colour key** (`OrigamiVision.swift:9104–9196`) is headed "Subjects", so its swatches aren't taken for kinds of concept.

### Annotations: nine kinds, two free hues

`VisionAnnotationInk` paints kinds as backgrounds at 0.35. Every one of them is within 18.6 of some concept colour, and six are within 15. In views with concept colours, mark kinds by **colour family and line together**:

| Kind | Now | Distance | Becomes |
|---|---|---|---|
| Important | #E4572E | 12.9 | Rose fill |
| Disagree | #C93C3C | 18.6 | Alarm red, wavy underline, no fill |
| Problematic | #D98E1B | **4.8** | Alarm red, dotted underline, no fill |
| Quotable | #2E8B8B | 18.5 | Teal fill (it is teal already) |
| Great | #3A9B35 | 13.6 | Teal, solid underline, no fill |
| What is this? | #3B6FD4 | 14.6 | Rose, dashed underline, with a ? in the margin |
| Language Issue | #8E5BC0 | 12.9 | Rose, wavy underline |
| Highlight | #E8C51D | **5.0** | White fill at 0.22 |
| Strikethrough | #8A8A8A | — | As it is: grey, struck through |

Fills sit behind the words and concept colours are the words, but both are colour to the eye. Keeping the fills to rose, teal and white means a coloured word is always a kind of concept. Rose and red appear together here, which is why rose was moved to `#FF47AE` (section 2). Within each family the line style does the rest of the work: solid, dashed, dotted and wavy must each be drawn heavily enough to tell apart at reading distance in the headset.

Readers who change kind colours in `annotationKindColors` keep their own choices. They are never swapped. The guard in section 4 only warns them (decided, section 8).

### Lines and spaces with their own colours

| Use | Where | Now | Change to |
|---|---|---|---|
| Concept space highlight and relation lines | `EPUBMapView.swift:13227, 13242` | `systemPurple` | White @0.18 / @0.28. Violet would say "Concept" about lines between every kind. |
| Orbiting document card border | `:13102` | `systemBlue` @0.5 | White @0.5 |
| Knowledge Space view lines | `KnowledgeSpaceView.swift:530–623` | `.purple` and `.blue` | White for concept lines; teal @0.45 for document lines |
| Citation line and cited dot | `:10784, :10888` | #33B8CC | Teal #17938B, the official citation colour (the current colour is 11.7 from Institution) |
| Lineage "influence" and other rose uses | see above | — | Rose #FF47AE throughout; no other rose anywhere |
| Weave threads, bot monograms | `OrigamiVision.swift:8420, 8901` | hue from the name | Keep hues out of the six bands. Draw from the two free arcs only, or use greys at different lightness. |
| Timeflows series | `EPUBMapView.swift:12756–67`, `SankeySpace.swift:244–253` | earth tones (Ochre, Sienna, Sand…) | Leave as they are. Timeflows shows no concepts. If it ever does, use greys there. |
| Reading-aloud paragraph | `OrigamiVision.swift:5961` | accent @0.14 | As it is, as long as the accent stays the system's. Don't set an accent colour in the asset catalog. |

### Already fine
- Body and link text in `.label`.
- Glass grounds, card grounds (#1A1A1A–#1F1F1F) and the warning red #D12929.
- Lineage "roots".
- The faithful-EPUB CSS greys.
- `TextColoring`'s meaning and grammar colours, which aren't in XR. If they are ever brought to XR, "meaning" should simply *become* the concept palette: person → person, place → location, organisation → institution, time → event. It shouldn't be a third set of colours.

## 4. A guard, because the colours are the writer's

The defaults above are only where things start. A writer may make Person teal. So Origami should check its own colours against the writer's colours each time it reads them, rather than trust a fixed table:

1. **Write down every role colour Origami uses in XR, in one place.** This is Origami's own role table, for example `XRColourRoles`, holding find, selection, citation, annotation kinds, tag grounds and so on. No colour stays hard-coded at the point where it is drawn.
2. **Compare each role with each concept colour** after reading `categoryColors.json`, using OKLab ΔE×100.
3. **Compare the roles with each other too.** Roles that share a view (rose, alarm red and teal in annotations; Find against Highlight) must stay at least 15 apart, or must differ in form as well.
4. **Compare solid colours, whatever a role's opacity.** A fill at 0.35 blended over the desk is much darker than a solid concept colour, so measuring the blend against the solid colour shows a large distance even when the hue is the same. Yellow at 0.45 over the dark desk measures 17.5 from Event that way, yet it plainly reads as Event. Blending both colours at the role's opacity doesn't help either. It pulls both toward the ground and shrinks the distance in step with the opacity, so at 0.08 every colour, white included, would count as a clash. What the eye names is the hue, and solid against solid measures that: Find yellow is 1.7 from Event. (Corrected 8 Nov 2026 while building the guard.)
5. **If one of Origami's own default roles comes within 15:**
   - First, swap it for the other free hue.
   - If both free hues are taken, use white or grey and rely on form.
   - Never move the concept colour: it is the writer's.
6. **Never change a colour the reader chose themselves** (annotation kinds, the Author's mark). Warn instead, beside the choice in Settings. For example: "Quotable is close to your Location colour." Every option stays on offer.
7. **Keep form even where colour passes.** OKLab distance assumes full colour vision. For red–green colour blindness Person, Artifact and Event come much closer than 9.2, and Location comes close to Event. That's down to the writer's palette, which Origami doesn't control. But it's why every meaning in section 3 also has a form (a weight, a line, a glyph) and doesn't rely on hue alone.

This is a few dozen comparisons each time the colours load, so the cost is nothing.

## 5. Concept colours on the light Reading Desk

The concept colours are mid-tones made for dark grounds. On the light desk (#FAF7F0) the best of them reaches only 2.7 : 1, and Event yellow 1.4 : 1, so it can't be read. There are two choices:
- **(a) Author's way, with a darker pill:** each concept on a dark grey pill, its name in the kind's colour on top. This is how Author's Concepts margin and Overview look. But Author's own pill, #707070 at 90%, doesn't make the colours readable: on it they reach only 1.7 : 1 (Concept), 1.8 (Artifact), 1.9 (Institution), 2.3 (Person and Location) and 3.4 (Event). A pill of **#2A2A2A** gives every kind at least 4.5 : 1: Concept 4.9, Artifact 5.3, Institution 5.4, Person 6.5, Location 6.8 and Event 9.9. The pill itself stands out well against the light desk (13.4 : 1). #303030 just reaches 4.5 for Concept, so #2A2A2A is the safer choice.
- **(b) The same hues, darkened:** keep the hue and lower the lightness to about 0.50 in OKLCH, which gives at least 4.5 : 1 on the light desk.

Decided: **(a) with the #2A2A2A pill** for nodes and labels. Use **(b)** only for colour running inside body text, where a pill would break the line. Author's pill should darken to match. That is a carry-back owed to Author, so the two apps keep the same look.

## 6. Reading the colours, and the licence

- **Read** `<iCloud.com.liquid.Author>/Concepts/categoryColors.json` when the app has that container. Otherwise use the defaults.
  - Read again each time the app becomes active.
  - Treat `"product"` as `"artifact"`.
  - **Never write the colours into an EPUB.** They are a reader's preference.
- **Write Origami's own small reader from the file format.** The format is a version number, a modification date and a map of kind to `#RRGGBB`. Don't link LiquidKit's `ConceptCategoryColorsFile`: Origami is open source and LiquidKit is commercial, so the two codebases stay apart. The defaults are six published hex values and can be written into Origami directly.
- An EPUB opened by someone else shows the reader's colours. That is correct.

## 7. Order of work

1. **Role table and guard (section 4).** Move every XR colour listed in section 3 into one table, with no change in how anything looks yet. Add a test that runs the table against the defaults and fails at any distance under 15, whether role to concept or role to role (same view and form). **Written 8 Nov 2026:** `XRColourRoles.swift` holds 37 roles. Each clash known today is tagged with the step that owns it (53 clashes, none unowned), and the test fails only on a clash no step owns. `Origami TextTests/XRColourRolesTests.swift` waits on the test host. Left out on purpose: the reader's accent, hues made from a name, subject tags and Timeflows (see the file's header). The test target hosts the iOS app and can't see most macOS-only files. So the table and the guard go in one file that every target includes, and that file must not depend on anything else. If the test still can't reach it, run the same check through RunCodeSnippet.
2. **The severe changes:** Find, selection, Highlight, pin, caution and "good", and the mark's default in XR. These are the cases where a colour reads as a kind of concept today.
3. **Tags as ground, not ink:** white titles and hub labels, lower-chroma subject spheres, and the key headed "Subjects".
4. **Annotations,** remapped to rose, teal, red and white with their lines.
5. **Lines and spaces:** citation teal, white concept-space lines, and hue-from-name confined to the free arcs.
6. **Read `categoryColors.json`** and show concept kinds in their colours, on pills on the light desk.
7. **Check in the headset:**
   - On glass and on both desks.
   - With the defaults, and with a writer's colours chosen to collide on purpose, such as Person set to teal, so the guard has to act.

The test in step 1 keeps the work honest from then on. A new colour can't be added near a concept colour without the build saying so.

## 8. Decided by Frode, 8 Nov 2026

- **Author's mark in XR:** weight and underline only, with no colour. The colour options stay in the list; any that collide get a note.
- **Annotation colours a reader has changed** that collide: warned about, never swapped.
- **The light desk:** (a) pills, darkened to #2A2A2A. Darkening Author's pill is owed back to Author.
- **Caution:** red outline plus ⚠︎. Amber is the usual colour for caution, but in this palette amber means Person.
