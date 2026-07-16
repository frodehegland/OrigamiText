import SwiftUI

/// A person's contact record: name parts and affiliation, with ORCID
/// search to anchor the record to a canonical academic identity. Every
/// field ORCID returns is shown.
struct PersonFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State var person: Person
    let heading: String
    let onSave: (Person) -> Void

    @State private var isSearching = false
    @State private var results: [ORCIDResult] = []
    @State private var searchError: String?
    @State private var hasSearched = false

    private var canSearch: Bool {
        !isSearching && (!person.givenName.trimmingCharacters(in: .whitespaces).isEmpty
                         || !person.familyName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(heading)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            Form {
                Section("Name") {
                    TextField("First name", text: $person.givenName)
                    TextField("Middle name", text: $person.middleName)
                    TextField("Last name", text: $person.familyName)
                    TextField("Affiliation", text: $person.affiliation)
                }

                Section {
                    TextField("ORCID iD", text: $person.orcid,
                              prompt: Text("0000-0000-0000-0000"))
                        .font(.body.monospaced())
                    HStack {
                        Button {
                            search()
                        } label: {
                            Label(isSearching ? "Searching…" : "Search ORCID",
                                  systemImage: "magnifyingglass")
                        }
                        .disabled(!canSearch)
                        if isSearching {
                            ProgressView().controlSize(.small)
                        }
                    }
                    if let searchError {
                        Text(searchError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    if hasSearched, results.isEmpty, searchError == nil, !isSearching {
                        Text("No ORCID records found for that name.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(results) { result in
                        resultRow(result)
                    }
                } header: {
                    Text("ORCID")
                } footer: {
                    Text("The ORCID iD is the canonical identity for this person. Search fills the record from the public ORCID registry.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !person.creditName.isEmpty || !person.otherNames.isEmpty || !person.emails.isEmpty {
                    Section("From ORCID") {
                        if !person.creditName.isEmpty {
                            LabeledContent("Credit name", value: person.creditName)
                        }
                        if !person.otherNames.isEmpty {
                            LabeledContent("Other names", value: person.otherNames.joined(separator: ", "))
                        }
                        if !person.emails.isEmpty {
                            LabeledContent("Email", value: person.emails.joined(separator: ", "))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(person)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(person.displayName.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 580)
    }

    /// Every field the registry returned, visible; Use adopts the record.
    private func resultRow(_ result: ORCIDResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text([result.givenNames, result.familyNames]
                    .filter { !$0.isEmpty }.joined(separator: " "))
                    .fontWeight(.medium)
                Text(result.orcid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !result.creditName.isEmpty {
                    Text("Credit name: \(result.creditName)").font(.caption)
                }
                if !result.otherNames.isEmpty {
                    Text("Other names: \(result.otherNames.joined(separator: ", "))").font(.caption)
                }
                if !result.institutions.isEmpty {
                    Text(result.institutions.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !result.emails.isEmpty {
                    Text(result.emails.joined(separator: ", ")).font(.caption)
                }
            }
            Spacer()
            Button("Use") { adopt(result) }
        }
        .padding(.vertical, 2)
    }

    private func adopt(_ result: ORCIDResult) {
        if !result.givenNames.isEmpty { person.givenName = result.givenNames }
        if !result.familyNames.isEmpty { person.familyName = result.familyNames }
        person.orcid = result.orcid
        person.creditName = result.creditName
        person.otherNames = result.otherNames
        person.emails = result.emails
        if person.affiliation.isEmpty {
            person.affiliation = result.institutions.first ?? ""
        }
    }

    private func search() {
        isSearching = true
        searchError = nil
        results = []
        let given = person.givenName
        let family = person.familyName
        Task {
            do {
                results = try await ORCIDClient.search(givenName: given, familyName: family)
            } catch {
                searchError = "ORCID search failed: \(error.localizedDescription)"
            }
            hasSearched = true
            isSearching = false
        }
    }
}
