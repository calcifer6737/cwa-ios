import SwiftUI
import UIKit

@main
struct CWAApp: App {
    @State private var account = Vault.load()
    var body: some Scene {
        WindowGroup {
            Group {
                if let account {
                    MainView(account: account) { Vault.clear(); self.account = nil }
                } else { LoginView { self.account = $0 } }
            }
            .tint(.teal)
        }
    }
}

struct LoginView: View {
    var connected: (Account) -> Void
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "books.vertical.fill").font(.system(size: 48)).foregroundStyle(.teal)
                        Text("Your books. Your server.").font(.title2.bold())
                        Text("Connect to Calibre-Web Automated to bring your library to your iPhone.").foregroundStyle(.secondary)
                    }.padding(.vertical, 20)
                }
                Section("CWA server") {
                    TextField("https://dxp2800.tailXXXX.ts.net", text: $server)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("CWA username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("CWA password", text: $password).textContentType(.password)
                }
                Section {
                    Button { Task { await connect() } } label: {
                        HStack { Spacer(); if busy { ProgressView() }; Text(busy ? "Connecting…" : "Connect to library"); Spacer() }
                    }.disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
                } footer: { Text("Use your CWA login. Your credentials stay in this iPhone’s Keychain and are sent only to your HTTPS server.") }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }.navigationTitle("Welcome")
        }
    }
    @MainActor private func connect() async {
        busy = true; error = nil
        defer { busy = false }
        let raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw), components.scheme?.lowercased() == "https",
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            error = "Enter your full HTTPS CWA address without a username, password, query, or fragment in the URL."; return
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/opds") { path = String(path.dropLast(5)) }
        components.path = path
        guard let url = components.url else { error = "That server address is invalid."; return }
        let account = Account(server: url.absoluteString, username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        do {
            let client = Catalog(account)
            _ = try await client.feed(client.endpoint("opds"))
            try Vault.save(account)
            connected(account)
        } catch { self.error = error.localizedDescription }
    }
}

struct MainView: View {
    let account: Account
    let disconnect: () -> Void
    @State private var client: Catalog
    init(account: Account, disconnect: @escaping () -> Void) {
        self.account = account; self.disconnect = disconnect
        _client = State(initialValue: Catalog(account))
    }
    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack { LibraryView(client: client) }
            }
            Tab("Shelves", systemImage: "square.stack") {
                NavigationStack { ShelvesView(client: client) }
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                NavigationStack { SearchView(client: client) }
            }
            Tab("Settings", systemImage: "gearshape") {
                NavigationStack {
                    Form {
                        Section("Connected to") {
                            LabeledContent("Server", value: account.base.host ?? "CWA")
                            LabeledContent("Username", value: account.username)
                        }
                        Section("This first version") {
                            Text("Browse, search, view shelves, and download books. Shelf editing and an in-app reader are not included yet.")
                            Text("Your Kobo continues syncing directly with CWA.")
                        }
                        Section {
                            Button("Disconnect", role: .destructive, action: disconnect)
                        } footer: { Text("Removes the saved login from this iPhone. Books already exported to Files or another app remain there.") }
                        Section { LabeledContent("Version", value: "0.1.0") }
                    }.navigationTitle("Settings")
                }
            }
        }
    }
}

struct LibraryView: View {
    let client: Catalog
    @State private var order = "Title"
    private var url: URL { client.endpoint(order == "Title" ? "opds/books/letter/00" : "opds/new") }
    var body: some View {
        CatalogView(client: client, url: url, title: "Library")
            .id(order)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort books", selection: $order) {
                            Text("Title").tag("Title")
                            Text("Recently added").tag("Recent")
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel("Sort books")
                }
            }
    }
}
struct ShelvesView: View {
    let client: Catalog

    var body: some View {
        List {
            NavigationLink {
                CatalogView(
                    client: client,
                    url: client.endpoint("opds/shelfindex"),
                    title: "My shelves"
                )
            } label: {
                Label("My shelves", systemImage: "square.stack")
            }

            NavigationLink {
                CatalogView(
                    client: client,
                    url: client.endpoint("opds/magicshelfindex"),
                    title: "Magic shelves"
                )
            } label: {
                Label("Magic shelves", systemImage: "sparkles")
            }
        }
        .navigationTitle("Shelves")
    }
}
struct SearchView: View {
    let client: Catalog
    @State private var query = ""
    @State private var submitted = ""
    private var url: URL {
        var c = URLComponents(url: client.endpoint("opds/search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "query", value: submitted)]
        return c.url!
    }
    var body: some View {
        Group {
            if submitted.isEmpty {
                ContentUnavailableView("Find your next book", systemImage: "magnifyingglass", description: Text("Search by title or author, then tap Search on the keyboard."))
                    .navigationTitle("Search")
            } else { CatalogView(client: client, url: url, title: "Search").id(submitted) }
        }
        .searchable(text: $query, prompt: "Title or author")
        .onSubmit(of: .search) { submitted = query.trimmingCharacters(in: .whitespacesAndNewlines) }
        .onChange(of: query) { _, value in if value.isEmpty { submitted = "" } }
    }
}
struct CatalogView: View {
    let client: Catalog
    let url: URL
    let title: String
    @State private var entries: [Entry] = []
    @State private var next: URL?
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 18, alignment: .top)]
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let error {
                    VStack(spacing: 12) {
                        Label("Unable to load", systemImage: "wifi.exclamationmark").font(.headline)
                        Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Try again") { Task { await load(reset: entries.isEmpty) } }.buttonStyle(.bordered)
                    }.padding()
                }
                if loaded && entries.isEmpty && error == nil {
                    ContentUnavailableView("Nothing here yet", systemImage: "books.vertical", description: Text("No items were returned by CWA."))
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                    ForEach(entries) { entry in
                        if let link = entry.subsection, let destination = try? client.resolve(link.href, relativeTo: url) {
                            NavigationLink {
                                CatalogView(client: client, url: destination, title: entry.title)
                            } label: {
                                VStack(alignment: .leading, spacing: 14) {
                                    Image(systemName: "square.stack.fill").font(.largeTitle).foregroundStyle(.teal)
                                    Text(entry.title).font(.headline).foregroundStyle(.primary)
                                }.frame(maxWidth: .infinity, minHeight: 110, alignment: .leading).padding()
                                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(.plain)
                        } else {
                            NavigationLink {
                                BookView(client: client, book: entry, page: url)
                            } label: { BookTile(client: client, book: entry, page: url) }.buttonStyle(.plain)
                        }
                    }
                }
                if busy { ProgressView().padding() }
                if next != nil && !busy {
                    Button("Load more") { Task { await load(reset: false) } }.buttonStyle(.bordered).padding()
                }
            }.padding(20)
        }
        .navigationTitle(title)
        .task { if !loaded { await load(reset: true) } }
        .refreshable { await load(reset: true) }
    }
    @MainActor private func load(reset: Bool) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        let target = reset ? url : (next ?? url)
        do {
            let feed = try await client.feed(target)
            try Task.checkCancellation()
            let nextURL: URL?
            if let href = feed.next {
                var n = try client.resolve(href, relativeTo: target)
                // CWA 4.0.6 drops the search query from pagination links.
                if let original = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let search = original.queryItems?.first(where: { $0.name == "query" }),
                   var c = URLComponents(url: n, resolvingAgainstBaseURL: false) {
                    var items = c.queryItems ?? []; items.removeAll { $0.name == "query" }; items.append(search)
                    c.queryItems = items; n = c.url ?? n
                }
                nextURL = n == target ? nil : n
            } else { nextURL = nil }
            var result = reset ? [] : entries
            var ids = Set(result.map(\.id))
            for entry in feed.entries where ids.insert(entry.id).inserted { result.append(entry) }
            entries = result; next = nextURL; loaded = true
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; loaded = true } }
    }
}

struct CoverView: View {
    let client: Catalog
    let book: Entry
    let page: URL
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.teal.opacity(0.10))
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "book.closed.fill").font(.system(size: 42)).foregroundStyle(.teal.opacity(0.55)) }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: book.id) {
            guard image == nil, let link = book.cover,
                  let url = try? client.resolve(link.href, relativeTo: page),
                  let data = try? await client.data(url) else { return }
            image = UIImage(data: data)
        }
    }
}
struct BookTile: View {
    let client: Catalog
    let book: Entry
    let page: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(client: client, book: book, page: page)
            Text(book.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
            Text(book.authors.joined(separator: ", ")).font(.caption).lineLimit(2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
struct SharedBook: Identifiable { let id = UUID(); let url: URL }
struct BookView: View {
    let client: Catalog
    let book: Entry
    let page: URL
    @State private var busy = false
    @State private var error: String?
    @State private var shared: SharedBook?
    @State private var temporaryFolder: URL?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                CoverView(client: client, book: book, page: page)
                    .frame(width: 180).frame(maxWidth: .infinity).padding(.top)
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(.title.bold())
                    Text(book.authors.joined(separator: ", ")).font(.title3).foregroundStyle(.secondary)
                }
                if !book.downloads.isEmpty {
                    Menu {
                        ForEach(book.downloads) { link in
                            Button("Download \(link.format)") { Task { await download(link) } }
                        }
                    } label: {
                        HStack { if busy { ProgressView() }; Label(busy ? "Downloading…" : "Download book", systemImage: "arrow.down.circle.fill") }
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !book.summary.isEmpty { Text(book.summary).font(.body).textSelection(.enabled) }
                if !book.publisher.isEmpty { LabeledContent("Publisher", value: book.publisher) }
                if !book.published.isEmpty { LabeledContent("Published", value: book.published) }
                if !book.tags.isEmpty { Text(book.tags.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
            }.padding(24)
        }
        .navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shared, onDismiss: {
            if let folder = temporaryFolder { try? FileManager.default.removeItem(at: folder) }
            temporaryFolder = nil
        }) { item in ShareSheet(url: item.url) }
    }
    @MainActor private func download(_ link: FeedLink) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let url = try client.resolve(link.href, relativeTo: page)
            let file = try await client.download(url, title: book.title, format: link.format)
            temporaryFolder = file.deletingLastPathComponent()
            shared = SharedBook(url: file)
        } catch { self.error = error.localizedDescription }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
