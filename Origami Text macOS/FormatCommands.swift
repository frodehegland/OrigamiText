import SwiftUI

/// The editor under the keyboard, for the Format menu.
struct RichTextControllerKey: FocusedValueKey {
    typealias Value = RichTextController
}

extension FocusedValues {
    var richTextController: RichTextController? {
        get { self[RichTextControllerKey.self] }
        set { self[RichTextControllerKey.self] = newValue }
    }
}

/// Format — Author's basic writing commands, with Author's shortcuts:
/// headings ⌘1–⌘3 and Body ⌘0, Bold ⌘B, Italic ⌘I, Bullet ⌘8 and Dash
/// ⌘9 lists, Code, Weblink ⌘K, Citation ⌘T, and the two inserts. Always
/// present; each item acts on the document being written.
struct FormatCommands: Commands {
    @FocusedValue(\.richTextController) private var controller

    var body: some Commands {
        CommandMenu("Format") {
            Menu("Heading") {
                Button("Body") { controller?.setStyle(.body) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Heading 1") { controller?.setStyle(.header1) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Heading 2") { controller?.setStyle(.header2) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Heading 3") { controller?.setStyle(.header3) }
                    .keyboardShortcut("3", modifiers: .command)
            }
            .disabled(controller == nil)
            Menu("Emphasize") {
                Button("Bold") { controller?.toggleBold() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("Italic") { controller?.toggleItalic() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            .disabled(controller == nil)
            Menu("List") {
                Button("Bullet") { controller?.setStyle(.bulletList) }
                    .keyboardShortcut("8", modifiers: .command)
                Button("Dash") { controller?.setStyle(.dashList) }
                    .keyboardShortcut("9", modifiers: .command)
            }
            .disabled(controller == nil)
            Button("Code") { controller?.setStyle(.code) }
                .disabled(controller == nil)
            Divider()
            Menu("Link") {
                Button("Citation…") { controller?.editor?.requestCitation = true }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Weblink…") { controller?.editor?.requestLink = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .disabled(controller == nil)
            Divider()
            Button("Insert Image…") { controller?.chooseAndInsertImages() }
                .disabled(controller == nil)
            Button("Insert Table…") { controller?.editor?.requestTable = true }
                .disabled(controller == nil)
        }
    }
}
