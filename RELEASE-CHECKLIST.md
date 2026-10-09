# Release checklist — every App Store build

Do these before archiving a build for App Store submission.

## Bundled documents (macOS)

- [ ] **Update the user guide** — `Origami Text macOS/OrigamiTextUserGuide.md`.
  Walk through every feature added or changed since the last submitted
  build and describe it; remove anything that has gone. Bump the `date:`
  in the front matter. The app re-converts the guide whenever the bundled
  file's date changes, so users get the new text on update.
  - Keep the document id: the EPUB is shelved as `origami-text-user-guide`,
    which the citation in Introduction.epub points at (`vm-id` /
    `origamitext://open/origami-text-user-guide`). Do not rename the file
    (`OrigamiTextUserGuide.md`) — `AppModel.ensureUserGuide()` looks it up
    by name.
- [ ] **Update Introduction.epub** (Frode) — `Origami Text macOS/Introduction.epub`.
  It opens at first launch and from the Intro button. Replacing the file
  is enough; the app re-imports it when its date changes.
- [ ] In a fresh install (or after removing the shelf copies), click the
  guide citation in the Introduction — Open Original should open the guide.

## Bundled documents (iPad and iPhone)

- [ ] **Update both iOS guides** — `Origami Text/OrigamiTextUserGuide-iPad.md`
  and `Origami Text/OrigamiTextUserGuide-iPhone.md` (written separately;
  the iPhone has no left column and no Horizontal view). Bump each `date:`.
- [ ] **Re-convert them to EPUB** — the iOS app cannot convert Markdown, so
  the `.epub` beside each `.md` is what ships. Convert with the Mac's
  `MarkdownImporter.importFile` + `OrigamiEPUBExporter.write`, document id
  `origami-text-user-guide` (RunCodeSnippet on the macOS scheme in the
  context of `MarkdownImporter.swift`; the snippet host is sandboxed, so
  serve the `.md` from `python3 -m http.server` on 127.0.0.1 and return
  the EPUB as base64). Keep the file names — `PhoneModel` looks them up.
- [ ] **Introduction.epub** ships to iOS through its target membership
  (Origami Text iOS ticked on the macOS folder's file) — nothing to copy.
- [ ] On an iPad and an iPhone: Intro opens the Introduction; its guide
  citation's card shows **Open**, which opens that device's guide.

## Rebuild guide

- [ ] **Bring `rebuild/` up to date** — for every feature added or changed
  since the last build, update the matching chapter (feature section,
  data-on-disk table, acceptance checks). See `rebuild/README.md`,
  "Keeping this guide current".

## Build

- [ ] Version and build number bumped on all three schemes (macOS, iOS, visionOS).
- [ ] All three schemes build.
