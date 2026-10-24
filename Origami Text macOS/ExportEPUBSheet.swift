import SwiftUI

/// Export… for a draft: Author's questions before the EPUB is written —
/// the header's style, the authors and their details, venue and journal,
/// DOI and ISBN, abstract, keywords, CCS concepts, rights. The answers
/// are saved with the draft (and into Author's `exportMeta.json` where
/// Author keeps them), then the save panel opens.
struct ExportEPUBSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editor: DraftEditor
    @State private var settings = ExportSettings()
    @State private var keywordsText = ""
    @State private var ccsText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export as Origami EPUB")
                        .font(.headline)
                    Text("What the page says about “\(editor.title)” — the same questions Author asks. Everything is kept with the draft.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)
            Divider()
            Form {
                Section("Header") {
                    Picker("Front matter", selection: $settings.frontMatter) {
                        ForEach(ExportSettings.FrontMatter.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.frontMatter.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    ForEach($settings.authors) { $author in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                TextField("Name", text: $author.name)
                                Button {
                                    settings.authors.removeAll { $0.id == author.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove this author")
                            }
                            HStack {
                                TextField("Email", text: $author.email)
                                TextField("ORCID", text: $author.orcid)
                            }
                            HStack {
                                TextField("Institution", text: $author.institution)
                                TextField("City", text: $author.city)
                                TextField("Country", text: $author.country)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    Button {
                        settings.authors.append(ExportSettings.Author())
                    } label: {
                        Label("Add Author", systemImage: "plus")
                    }
                } header: {
                    Text("Authors")
                } footer: {
                    Text("Names print under the title. Affiliation and contact lines print with the full front matter only; the record states them whichever header is chosen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Where it appears") {
                    TextField("Conference or proceedings", text: $settings.venue)
                    TextField("Journal", text: $settings.journal)
                    TextField("DOI", text: $settings.doi)
                    TextField("ISBN", text: $settings.isbn)
                }
                Section("Abstract") {
                    TextEditor(text: $settings.abstract)
                        .frame(minHeight: 90)
                }
                Section {
                    TextField("Keywords, separated by commas", text: $keywordsText)
                    TextEditor(text: $ccsText)
                        .frame(minHeight: 60)
                } header: {
                    Text("Keywords and CCS concepts")
                } footer: {
                    Text("One CCS concept per line, as printed: Human-centered computing → Hypertext / hypermedia.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $settings.license)
                        .frame(minHeight: 60)
                    TextField("Licence URI (https://creativecommons.org/licenses/by/4.0/)", text: $settings.licenseURI)
                } header: {
                    Text("Rights")
                } footer: {
                    Text("The copyright and licence statement as the page prints it, with the Creative Commons badge when it names one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(14)
        }
        .frame(width: 620, height: 720)
        .onAppear(perform: seed)
    }

    /// The draft's settings, with the document's author as the first
    /// author when none is named yet — their ORCID and affiliation from
    /// Settings.
    private func seed() {
        var current = editor.exportSettings
        if current.authors.isEmpty {
            let identity = model.authorIdentity
            current.authors = ExportSettings.defaults(author: editor.author, orcid: identity.orcid,
                                                      affiliation: identity.affiliation).authors
        }
        settings = current
        keywordsText = current.keywords.joined(separator: ", ")
        ccsText = current.ccsConcepts.joined(separator: "\n")
    }

    private func export() {
        var final = settings
        final.keywords = keywordsText.components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        final.ccsConcepts = ccsText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        final.authors.removeAll(where: \.isEmpty)
        dismiss()
        // The save panel runs modally; let the sheet leave first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            model.exportDraft(with: final)
        }
    }
}
