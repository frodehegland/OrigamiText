# Origami Text

Origami Text is a macOS app for reading, writing, and thinking in **Origami Documents** (`.origamitext`) — a plain-text document format owned by its community. It is a Future Text Lab project, initiated by Frode Hegland, who designed the format and built the first implementation.

Learn more, or join one of our open lab sessions on Mondays: https://futuretextlab.info

## Building

Open `OrigamiText.xcodeproj` and build the **Origami Text macOS** scheme — that is the macOS app. It requires macOS 26 or newer. The iOS and visionOS targets are experiments and are not currently supported; the macOS scheme is the one that builds and runs.

## Documentation

- [rebuild/](rebuild/) — **the rebuild guide**: the whole app described closely enough for a person or an LLM to build it again on any platform, chapter by chapter, tied to the source
- [ORIGAMI-TEXT-OVERVIEW.md](ORIGAMI-TEXT-OVERVIEW.md) — what the app is and how it thinks
- [ORIGAMI-DOCUMENT-FORMAT.md](ORIGAMI-DOCUMENT-FORMAT.md) — the full format specification
- [LIQUID-DOCUMENT-FORMAT.md](LIQUID-DOCUMENT-FORMAT.md) — a rename notice: Liquid is the format's earlier name
- [ORIGAMI-EPUB-PROFILE-1.0.md](ORIGAMI-EPUB-PROFILE-1.0.md) — the EPUB profile: how an Origami document travels as a conforming EPUB 3, normative
- [origami-schemas/](origami-schemas/) — the profile's JSON schemas, the reference validator and extractor, their test suites, and a conforming sample publication
- [origami-corpus/](origami-corpus/) — the conformance corpus: 25 publications with their expected extractions and verdicts, all EPUBCheck-clean
- [origami-packaging-tests/](origami-packaging-tests/) — the September packaging test that settled §4.4, superseded by the corpus's item 11

## License

The Origami Text application and the document specifications are free and open source, released under the [MIT License](LICENSE).

Copyright © 2026 Frode Hegland and Future Text Lab contributors.
