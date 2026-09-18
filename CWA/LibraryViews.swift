import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let client: Catalog
    @State private var order = "Title"
    @State private var filter = "All Books"
    @State private var importing = false
    @State private var uploading = false
    @State private var uploadMessage = ""
    @State private var showUploadMessage = false
    private var url: URL { client.endpoint(order == "Title" ? "opds/books/letter/00" : "opds/new") }
    var body: some View {
        Group {
            if filter == "All Books" {
                CatalogView(client: client, url: url, title: "Library").id(order)
            } else {
                LibraryGroups(client: client, kind: filter).id(filter)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { importing = true } label: {
                    if uploading { ProgressView() } else { Label("Add books", systemImage: "plus") }
                }.disabled(uploading)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Filter", selection: $filter) {
                        ForEach(["All Books", "Authors", "Series"], id: \.self) { Text($0).tag($0) }
                    }
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease") }
                Menu {
                    Picker("Sort books", selection: $order) {
                        Text("Title").tag("Title")
                        Text("Recently added").tag("Recent")
                    }
                } label: { Label("Sort books", systemImage: "arrow.up.arrow.down") }
                .disabled(filter != "All Books")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await upload(urls) }
            case .failure(let error): uploadMessage = error.localizedDescription; showUploadMessage = true
            }
        }
        .alert("Book uploads", isPresented: $showUploadMessage) { Button("OK", role: .cancel) {} } message: { Text(uploadMessage) }
    }
    @MainActor private func upload(_ urls: [URL]) async {
        guard !uploading, !urls.isEmpty else { return }
        uploading = true
        defer { uploading = false }
        var accepted = 0
        var errors: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            do { try await client.uploadBook(file: url); accepted += 1 }
            catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            if access { url.stopAccessingSecurityScopedResource() }
        }
        uploadMessage = accepted > 0 ? "\(accepted) book(s) queued for processing in CWA. Pull to refresh your library after processing finishes." : "No uploads were confirmed."
        if !errors.isEmpty { uploadMessage += "\n\n" + errors.joined(separator: "\n") }
        showUploadMessage = true
        if accepted > 0 { NotificationCenter.default.post(name: .cwaBookChanged, object: nil) }
    }
}

struct LibraryGroups: View {
    let client: Catalog
    let kind: String
    @State private var entries: [Entry] = []
    @State private var counts: [String: Int] = [:]
    @State private var error: String?
    @State private var loading = true
    @State private var revision = UUID()
    private var url: URL { client.endpoint(kind == "Authors" ? "opds/author/letter/00" : "opds/series/letter/00") }
    var body: some View {
        List {
            ForEach(entries) { entry in
                if let link = entry.subsection, let destination = try? client.resolve(link.href, relativeTo: url) {
                    NavigationLink {
                        CatalogView(client: client, url: destination, title: entry.title)
                    } label: {
                        HStack {
                            Text(entry.title).foregroundStyle(.primary)
                            Spacer(minLength: 16)
                            if let count = counts[entry.id] {
                                Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                                    .accessibilityLabel("\(count) books")
                            } else { Text("—").foregroundStyle(.secondary).accessibilityLabel("Count not loaded") }
                        }.padding(.vertical, 5)
                    }
                }
            }
            if loading { HStack { Spacer(); ProgressView(); Spacer() } }
            if let error {
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button("Try again") { revision = UUID() }
            }
            if !loading && entries.isEmpty && error == nil {
                ContentUnavailableView("No \(kind.lowercased()) yet", systemImage: kind == "Authors" ? "person.2" : "books.vertical")
            }
        }
        .navigationTitle(kind)
        .task(id: revision) { await load() }
        .refreshable { revision = UUID() }
        .onReceive(NotificationCenter.default.publisher(for: .cwaBookChanged)) { _ in revision = UUID() }
    }
    @MainActor private func load() async {
        loading = true; error = nil; counts = [:]
        defer { loading = false }
        do {
            let items = try await client.allEntries(at: url)
            try Task.checkCancellation()
            entries = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for entry in entries {
                try Task.checkCancellation()
                guard let link = entry.subsection else { continue }
                let books = try await client.allEntries(at: client.resolve(link.href, relativeTo: url))
                try Task.checkCancellation()
                counts[entry.id] = books.filter(\.isBook).count
            }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
}
