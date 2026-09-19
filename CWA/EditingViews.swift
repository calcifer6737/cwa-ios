import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct KoboSyncSection: View {
    let client: Catalog
    @State private var confirm = false
    @State private var busy = false
    @State private var message: String?
    @State private var failed = false
    var body: some View {
        Section {
            Button { confirm = true } label: {
                HStack {
                    Label("Force full Kobo sync", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if busy { ProgressView() }
                }
            }.disabled(busy)
            if let message { Text(message).font(.callout).foregroundStyle(failed ? .red : .secondary) }
        } header: { Text("Kobo") } footer: {
            Text("Prepares a full sync for your CWA account. Then tap Sync on your Kobo while it can reach CWA.")
        }
        .alert("Prepare a full Kobo sync?", isPresented: $confirm) {
            Button("Cancel", role: .cancel) { }
            Button("Force full sync") { Task { await sync() } }
        } message: { Text("CWA will reset your account’s sync records. Your next Kobo sync may take longer.") }
    }
    @MainActor private func sync() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await client.forceKoboSync()
            failed = false; message = "Ready. Tap Sync on your Kobo to start the full sync."
        } catch { failed = true; message = error.localizedDescription }
    }
}

struct MetadataEditor: View {
    let client: Catalog
    let book: Entry
    let page: URL
    let saved: (BookMetadata) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: BookMetadata?
    @State private var error: String?
    @State private var busy = false
    @State private var loading = true
    @State private var coverData: Data?
    @State private var photo: PhotosPickerItem?
    @State private var files = false
    @State private var findCover = false
    @State private var discard = false
    @State private var releaseYear = ""
    @State private var descriptionText = ""
    @State private var originalDescription = ""
    private var dirty: Bool { metadata.map { $0.fields != $0.original || releaseYear != $0.year || descriptionText != originalDescription } == true || coverData != nil }
    private func field(_ name: String) -> Binding<String> {
        Binding(get: { metadata?[name] ?? "" }, set: { metadata?[name] = $0 })
    }
    var body: some View {
        NavigationStack {
            Form {
                if loading { Section { VStack(spacing: 12) { ProgressView(); Text("Loading book metadata…").font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 12) } }
                if metadata != nil {
                    Section("Book details") {
                        TextField("Title", text: field("title"), axis: .vertical)
                        TextField("Authors, separated by &", text: field("authors"), axis: .vertical)
                        TextField("Release year", text: $releaseYear).keyboardType(.numberPad)
                        TextField("Publisher", text: field("publisher"))
                        Picker("Rating", selection: field("rating")) {
                            Text("No rating").tag("")
                            ForEach(1...10, id: \.self) { half in
                                Text("\(Double(half) / 2, specifier: "%.1f") stars").tag(String(Double(half) / 2))
                            }
                        }
                        TextField("Tags, separated by commas", text: field("tags"), axis: .vertical)
                    }
                    Section("Series") {
                        TextField("Series name", text: field("series"))
                        TextField("Number in series", text: field("series_index")).keyboardType(.decimalPad)
                        Text("Decimals such as 0.5 and 1.5 are supported.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Description") {
                        TextEditor(text: $descriptionText).frame(minHeight: 160)
                            .accessibilityLabel("Book description")
                    }
                    Section("Cover") {
                        HStack {
                            Spacer()
                            if let data = coverData, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 10))
                            } else { CoverView(client: client, book: book, page: page).frame(width: 126) }
                            Spacer()
                        }
                        Button { findCover = true } label: { Label("Find cover options", systemImage: "magnifyingglass") }
                        PhotosPicker(selection: $photo, matching: .images) { Label("Choose from Photos", systemImage: "photo") }
                        Button { files = true } label: { Label("Choose from Files", systemImage: "folder") }
                        if coverData != nil {
                            Button("Keep current cover") { coverData = nil; photo = nil }
                            Text("The new cover will upload when you save.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                        if metadata == nil { Button("Try again") { Task { await load() } } }
                    }
                }
            }
            .disabled(busy)
            .navigationTitle("Edit metadata").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil); if dirty { discard = true } else { dismiss() } }.disabled(busy)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: { if busy { ProgressView() } else { Text("Save").bold() } }
                        .disabled(busy || metadata == nil || !dirty)
                }
            }
            .interactiveDismissDisabled(dirty || busy)
            .alert("Discard your edits?", isPresented: $discard) {
                Button("Keep editing", role: .cancel) { }
                Button("Discard edits", role: .destructive) { dismiss() }
            }
            .task { await load() }
            .onChange(of: photo) { _, item in
                Task { await loadPhoto(item) }
            }
            .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    try chooseCover(Data(contentsOf: url))
                } catch { self.error = error.localizedDescription }
            }
            .sheet(isPresented: $findCover) {
                CoverPicker(title: metadata?["title"] ?? book.title, author: metadata?["authors"] ?? book.authors.joined(separator: " ")) { data in
                    do { try chooseCover(data) } catch { self.error = error.localizedDescription }
                }
            }
        }
    }
    @MainActor private func load() async {
        loading = true; error = nil
        defer { loading = false }
        guard let id = book.bookID else { error = "This catalog entry does not include a CWA book ID."; return }
        let uuid = book.id.replacingOccurrences(of: "urn:uuid:", with: "")
        do {
            metadata = try await client.metadata(bookID: id, uuid: uuid)
            releaseYear = metadata?.year ?? ""
            descriptionText = BookDescription.plainText(metadata?["comments"] ?? "")
            originalDescription = descriptionText
        }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func loadPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            let bytes = try await item.loadTransferable(type: Data.self)
            if let bytes { try chooseCover(bytes) }
        } catch { self.error = error.localizedDescription }
    }
    private func chooseCover(_ data: Data) throws {
        guard let image = UIImage(data: data) else { throw CatalogError.message("Choose a supported image file.") }
        let scale = min(1, 2000 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.9) else { throw CatalogError.message("Unable to prepare this cover.") }
        coverData = jpeg; error = nil
    }
    @MainActor private func save() async {
        guard var metadata, !busy else { return }
        metadata.year = releaseYear.trimmingCharacters(in: .whitespacesAndNewlines)
        if descriptionText != originalDescription { metadata["comments"] = BookDescription.html(descriptionText) }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await client.saveMetadata(metadata, cover: coverData)
            saved(metadata); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct CoverPicker: View {
    @State var title: String
    @State var author: String
    let selected: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options: [CoverOption] = []
    @State private var busy = false
    @State private var searched = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                    TextField("Authors, separated by &", text: $author).textFieldStyle(.roundedBorder)
                    Button("Search covers") { Task { await search() } }.buttonStyle(.borderedProminent).disabled(busy || title.isEmpty)
                    Text("Searches Open Library using the title and author. Cover availability varies by book and edition.").font(.caption).foregroundStyle(.secondary)
                    if busy { ProgressView() }
                    if let error { Text(error).foregroundStyle(.red) }
                    if searched && options.isEmpty && !busy && error == nil {
                        Text("No covers found. Try a shorter title or choose an image from Photos or Files.").foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 18) {
                        ForEach(options) { option in
                            Button { Task { await choose(option) } } label: {
                                VStack {
                                    AsyncImage(url: option.url) { image in image.resizable().scaledToFit() } placeholder: {
                                        Image(systemName: "book.closed").font(.largeTitle).frame(maxWidth: .infinity)
                                    }.frame(height: 195)
                                    Text(option.title).font(.caption).lineLimit(2)
                                }
                            }.buttonStyle(.plain).disabled(busy)
                        }
                    }
                }.padding()
            }
            .navigationTitle("Choose a cover").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) } }
            .task { await search() }
        }
    }
    @MainActor private func search() async {
        guard !busy else { return }
        busy = true; error = nil; options = []
        defer { busy = false; searched = true }
        do { options = try await CoverSearch.search(title: title, author: author) }
        catch { self.error = error.localizedDescription }
    }
    @MainActor private func choose(_ option: CoverOption) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let data = try await CoverSearch.fetch(option.url)
            guard UIImage(data: data) != nil else { throw CatalogError.message("That cover could not be loaded. Try another option.") }
            selected(data); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
