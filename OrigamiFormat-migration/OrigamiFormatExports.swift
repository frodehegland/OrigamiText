// The format lives in its own package now — OrigamiFormat, at
// ~/Documents/OrigamiFormat — shared with Reader so the annotation model,
// the anchoring ladder, document identity and the reading palettes exist
// once rather than in two copies that had begun to disagree.
//
// Re-exported, so every file in Origami Text macOS that used `WebAnnotation`,
// `AnnotationStore`, `AnnotationAnchor` or `ReaderAnnotationKind` keeps
// working with no import to add. The names are the same names.
@_exported import OrigamiFormat
