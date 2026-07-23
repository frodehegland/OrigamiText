import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImagePlayground
import Contacts

/// A person's contact record: name parts and affiliation, with ORCID
/// search to anchor the record to a canonical academic identity. Every
/// field ORCID returns is shown.
struct PersonFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.supportsImagePlayground) private var supportsImagePlayground
    @State var person: Person
    let heading: String
    let onSave: (Person) -> Void

    @State private var isSearching = false
    @State private var results: [ORCIDResult] = []
    @State private var searchError: String?
    @State private var hasSearched = false
    @State private var showsPhotoImporter = false
    @State private var showsPlaygroundSheet = false
    @State private var showsPhotoSearch = false
    /// Why the photograph search did not open: name and ORCID both empty.
    @State private var photoSearchNotice: String?
    /// The photograph clicked in the search sheet; adopted and processed
    /// once that sheet has closed, so the Playground sheet can present.
    @State private var pickedFoundPhoto: NSImage?
    @State private var showsContactsSearch = false
    /// The card chosen in the Contacts sheet; applied once that sheet has
    /// closed, for the same reason as the found photo above.
    @State private var pickedContact: ContactPick?
    /// Whether an added photo is processed into its cartoon immediately.
    @AppStorage(AppSettings.portraitInstantProcessingKey) private var instantProcessing = false

    private var canSearch: Bool {
        !isSearching && (!person.givenName.trimmingCharacters(in: .whitespaces).isEmpty
                         || !person.familyName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// The optional field as an editable string; emptied text clears it.
    private var publicProfileBinding: Binding<String> {
        Binding(
            get: { person.publicProfile ?? "" },
            set: { person.publicProfile = $0.isEmpty ? nil : $0 }
        )
    }

    /// The stored aliases on one line; commas separate, empties fall away.
    private var aliasesBinding: Binding<String> {
        Binding(
            get: { (person.aliases ?? []).joined(separator: ", ") },
            set: { text in
                let names = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                person.aliases = names.isEmpty ? nil : names
            }
        )
    }

    /// Every address on one line; commas separate, empties fall away.
    private var emailsBinding: Binding<String> {
        Binding(
            get: { person.emails.joined(separator: ", ") },
            set: { text in
                person.emails = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    private var letterDistributionBinding: Binding<Bool> {
        Binding(
            get: { person.letterDistribution ?? true },
            set: { person.letterDistribution = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(heading)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)

            Form {
                portraitSection
                Section("Name") {
                    TextField("First name", text: $person.givenName)
                    TextField("Middle name", text: $person.middleName)
                    TextField("Last name", text: $person.familyName)
                    TextField("Affiliation", text: $person.affiliation)
                    Button {
                        showsContactsSearch = true
                    } label: {
                        Label("Find in Contacts…", systemImage: "person.text.rectangle")
                    }
                    .help("Fill this record from your Contacts — name, email, affiliation, and photo. Contacts is only read, never changed.")
                }

                Section {
                    TextField("Aliases", text: aliasesBinding,
                              prompt: Text("Names in transcripts, comma-separated"))
                } header: {
                    Text("Also Known As")
                } footer: {
                    Text("Other spellings this person answers to — the way a transcript renders their name. Associating a transcript speaker with this record stores that spelling here, and the name resolves to this person everywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        TextField("Email", text: emailsBinding,
                                  prompt: Text("name@example.org"))
                        Toggle("Include in Letter Distribution via Mail",
                               isOn: letterDistributionBinding)
                            .toggleStyle(.checkbox)
                            .disabled(person.emails.isEmpty)
                    }
                } header: {
                    Text("Mail")
                } footer: {
                    Text("Published letters travel by mail (Settings → Sharing) to this address while the checkbox is on. Commas separate several addresses; the first receives the letters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: publicProfileBinding)
                        .font(.body)
                        .frame(minHeight: 70)
                } header: {
                    Text("Public Profile")
                } footer: {
                    Text("The person's public profile in their own words — shown on their card and their author page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        // Wide enough that the portrait row's buttons never truncate.
        .frame(width: 640, height: 660)
        .fileImporter(isPresented: $showsPhotoImporter, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if let photo = NSImage(contentsOf: url) {
                adopt(photo)
            }
        }
        .sheet(isPresented: $showsPhotoSearch, onDismiss: {
            // Adopt after the search sheet is gone: processing may need to
            // present the Image Playground sheet in its place.
            if let photo = pickedFoundPhoto {
                pickedFoundPhoto = nil
                model.portraits.adoptPhoto(photo, for: person.localID)
                processPortrait()
            }
        }) {
            PhotoSearchSheet(name: person.displayName, orcid: person.orcid) { photo in
                pickedFoundPhoto = photo
            }
        }
        .sheet(isPresented: $showsContactsSearch, onDismiss: {
            // Apply after the search sheet is gone: adopting the photo may
            // need to present the Image Playground sheet in its place.
            if let pick = pickedContact {
                pickedContact = nil
                apply(pick)
            }
        }) {
            ContactsSearchSheet(initialQuery: person.displayName) { pick in
                pickedContact = pick
            }
        }
        .imagePlaygroundSheet(isPresented: $showsPlaygroundSheet,
                              concepts: [.text(PortraitStyle.concept)],
                              sourceImage: sheetSourceImage) { url in
            model.portraits.adoptSheetPortrait(from: url, for: person.localID)
        }
        // Only the configured style is offered, so every portrait in the
        // community comes out in the same visual language.
        .imagePlaygroundGenerationStyle(PortraitStyle.current.playgroundStyle,
                                        in: [PortraitStyle.current.playgroundStyle])
    }

    /// Stores the photo; processing into a cartoon follows only when
    /// Instant Processing is on, or when the user clicks Process.
    private func adopt(_ photo: NSImage) {
        model.portraits.adoptPhoto(photo, for: person.localID)
        if instantProcessing {
            processPortrait()
        }
    }

    /// Draws the cartoon from the stored photo: silently where the Mac
    /// allows it, else through the system sheet seeded with the photo.
    private func processPortrait() {
        if model.portraits.supportsAutomaticGeneration {
            model.portraits.generatePortrait(for: person.localID)
        } else if supportsImagePlayground {
            showsPlaygroundSheet = true
        }
    }

    private var sheetSourceImage: Image? {
        // The head-framed rendition, so the cartoon inherits full-head
        // framing with margin; the raw photo only if no face was found.
        (model.portraits.framedOriginal(for: person.localID)
         ?? model.portraits.original(for: person.localID))
            .map { Image(nsImage: $0) }
    }

    /// The person's face: drop or choose a photo, and Image Playground
    /// draws the cartoon portrait used everywhere. The photo is kept
    /// untouched, so the cartoon can be re-drawn in another style.
    private var portraitSection: some View {
        Section("Portrait") {
            HStack(alignment: .center, spacing: 14) {
                portraitPreview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Choose…") { showsPhotoImporter = true }
                        Button("Find Photo…") {
                            if person.displayName.trimmingCharacters(in: .whitespaces).isEmpty,
                               person.orcid.trimmingCharacters(in: .whitespaces).isEmpty {
                                photoSearchNotice = "Fill in a name or ORCID iD first, so the search knows who to look for."
                            } else {
                                photoSearchNotice = nil
                                showsPhotoSearch = true
                            }
                        }
                        .help("Search online for a photograph of this person")
                        if model.portraits.hasOriginal(for: person.localID) {
                            Button("Process") { processPortrait() }
                                .disabled(isGeneratingPortrait || !supportsImagePlayground)
                            Button("Remove", role: .destructive) {
                                model.portraits.removeImages(for: person.localID)
                            }
                        }
                        Toggle("Instant", isOn: $instantProcessing)
                            .toggleStyle(.checkbox)
                            .help("Process a photo into its cartoon portrait the moment it is added")
                    }
                    if let photoSearchNotice {
                        Text(photoSearchNotice)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    portraitStatus
                }
                Spacer()
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let photo = NSImage(contentsOf: url) else { return false }
                adopt(photo)
                return true
            }
        }
    }

    private var isGeneratingPortrait: Bool {
        model.portraits.generatingIDs.contains(person.localID)
    }

    private var portraitPreview: some View {
        ZStack {
            if let image = model.portraits.portrait(for: person.localID)
                ?? model.portraits.original(for: person.localID) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle().fill(.quaternary)
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
            }
            if isGeneratingPortrait {
                Circle().fill(.black.opacity(0.35))
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(Circle())
    }

    @ViewBuilder private var portraitStatus: some View {
        if isGeneratingPortrait {
            Text("Drawing the cartoon portrait…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let error = model.portraits.errors[person.localID] {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        } else if !supportsImagePlayground {
            Text("Cartoon portraits need Apple Intelligence; the photo is shown as-is.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.portraits.hasOriginal(for: person.localID),
                  model.portraits.portrait(for: person.localID) == nil {
            Text("Click Process to draw the cartoon portrait from this photo.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.portraits.portrait(for: person.localID) != nil {
            Text("Drawn from your photo in the style chosen in Settings → Author.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text(instantProcessing
                 ? "Drop a photo here or choose one — it is processed into a cartoon portrait immediately."
                 : "Drop a photo here or choose one, then click Process for the cartoon portrait.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

    /// Copies a chosen Contacts card into the record: name parts, emails
    /// (merged, never dropped), affiliation where the record has none,
    /// and the card's photo into the portrait pipeline. Contacts itself
    /// is untouched.
    private func apply(_ pick: ContactPick) {
        if !pick.givenName.isEmpty { person.givenName = pick.givenName }
        if !pick.middleName.isEmpty { person.middleName = pick.middleName }
        if !pick.familyName.isEmpty { person.familyName = pick.familyName }
        if person.affiliation.isEmpty { person.affiliation = pick.organization }
        for email in pick.emails
        where !person.emails.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) {
            person.emails.append(email)
        }
        if let data = pick.imageData, let photo = NSImage(data: data) {
            adopt(photo)
        }
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

/// What a chosen Contacts card carries back into the record. Plain data,
/// so it crosses from the background fetch untangled.
private nonisolated struct ContactPick: Sendable {
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var organization = ""
    var emails: [String] = []
    var imageData: Data?
}

/// The user's Contacts, searched by name — read-only: choosing a card
/// copies its details into the record; nothing is ever written back.
/// The first use asks macOS for permission to read Contacts.
private struct ContactsSearchSheet: View {
    let initialQuery: String
    let onPick: (ContactPick) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Match: Identifiable {
        let id: String
        let displayName: String
        let detail: String
        let thumbnail: NSImage?
        let pick: ContactPick
    }

    @State private var query = ""
    @State private var matches: [Match] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find in Contacts")
                .font(.title3)
            HStack {
                TextField("Name", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                Button("Search") { search() }
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }
            Group {
                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching Contacts…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if hasSearched, matches.isEmpty {
                    Text("No contacts match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(matches) { match in
                                matchRow(match)
                            }
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                }
            }
            HStack {
                Text("Contacts is only read — choosing a card copies its details here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            query = initialQuery
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                search()
            }
        }
    }

    private func matchRow(_ match: Match) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if let thumbnail = match.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Circle().fill(.quaternary)
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(match.displayName)
                    .fontWeight(.medium)
                if !match.detail.isEmpty {
                    Text(match.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button("Use") {
                onPick(match.pick)
                dismiss()
            }
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        error = nil
        matches = []
        Task {
            do {
                matches = try await Self.findContacts(matching: trimmed).map { found in
                    Match(id: found.id,
                          displayName: [found.pick.givenName, found.pick.middleName,
                                        found.pick.familyName]
                              .filter { !$0.isEmpty }.joined(separator: " "),
                          detail: [found.pick.organization,
                                   found.pick.emails.joined(separator: ", ")]
                              .filter { !$0.isEmpty }.joined(separator: " · "),
                          thumbnail: found.thumbnailData.flatMap(NSImage.init(data:)),
                          pick: found.pick)
                }
            } catch {
                self.error = error.localizedDescription
            }
            hasSearched = true
            isSearching = false
        }
    }

    // MARK: The Contacts fetch

    private nonisolated struct FoundContact: Sendable {
        let id: String
        let pick: ContactPick
        let thumbnailData: Data?
    }

    private nonisolated struct ContactsAccessError: LocalizedError {
        var errorDescription: String? {
            "macOS declined access to Contacts. Allow Origami Text in System Settings → Privacy & Security → Contacts, then search again."
        }
    }

    /// Asks for permission on the first use, then fetches the unified
    /// cards matching the name. Off the main actor — the fetch blocks.
    private nonisolated static func findContacts(matching query: String) async throws -> [FoundContact] {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            guard (try? await store.requestAccess(for: .contacts)) == true else {
                throw ContactsAccessError()
            }
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactsAccessError()
        }
        let keys = [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey,
                    CNContactOrganizationNameKey, CNContactEmailAddressesKey,
                    CNContactImageDataKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
        let contacts = try store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: query),
            keysToFetch: keys)
        return contacts.map { contact in
            var pick = ContactPick()
            pick.givenName = contact.givenName
            pick.middleName = contact.middleName
            pick.familyName = contact.familyName
            pick.organization = contact.organizationName
            pick.emails = contact.emailAddresses.map { String($0.value) }
            pick.imageData = contact.imageData ?? contact.thumbnailImageData
            return FoundContact(id: contact.identifier,
                                pick: pick,
                                thumbnailData: contact.thumbnailImageData ?? contact.imageData)
        }
    }
}

/// Photographs found online for the person — up to five, from the lead
/// images of Wikipedia pages matching the name (resolved from the ORCID
/// registry when only the iD is filled in). Clicking one adopts it and
/// processing starts immediately; Cancel leaves the record untouched.
private struct PhotoSearchSheet: View {
    let name: String
    let orcid: String
    let onPick: (NSImage) -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Candidate: Identifiable {
        let id: String
        let title: String
        let image: NSImage
    }
    @State private var candidates: [Candidate] = []
    @State private var isSearching = true
    @State private var error: String?
    @State private var searchedName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(searchedName.isEmpty ? "Finding a Photograph" : "Photographs of \(searchedName)")
                .font(.title3)
            Group {
                if isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching online…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else if candidates.isEmpty {
                    Text("No photographs found for “\(searchedName)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Click a photograph to use it — processing starts immediately.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(candidates) { candidate in
                                VStack(spacing: 4) {
                                    Button {
                                        onPick(candidate.image)
                                        dismiss()
                                    } label: {
                                        Image(nsImage: candidate.image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 96, height: 96)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Use this photograph (from “\(candidate.title)” on Wikipedia)")
                                    Text(candidate.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 96)
                                }
                            }
                        }
                    }
                }
            }
            HStack {
                Text("Photographs are the lead images of matching Wikipedia pages.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 580)
        .task { await load() }
    }

    private func load() async {
        do {
            var query = name.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                query = try await ORCIDClient.name(forORCID: orcid) ?? ""
            }
            guard !query.isEmpty else {
                error = "The ORCID record did not give a name to search for."
                isSearching = false
                return
            }
            searchedName = query
            // Over-fetch, then keep the first five whose images download.
            var found: [Candidate] = []
            for photo in try await PhotoSearchClient.searchPhotos(name: query) {
                if found.count == 5 { break }
                if let image = await Self.download(photo.imageURL) {
                    found.append(Candidate(id: photo.id, title: photo.title, image: image))
                }
            }
            candidates = found
        } catch {
            self.error = "Photograph search failed: \(error.localizedDescription)"
        }
        isSearching = false
    }

    private static func download(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}
