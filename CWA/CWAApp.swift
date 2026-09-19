import SwiftUI
import UIKit

@main
struct CWAApp: App {
    @State private var account = Vault.load()
    @AppStorage("appearance") private var appearance = "Automatic"
    @AppStorage("accent") private var accent = "Default"
    var body: some Scene {
        WindowGroup {
            Group {
                if let account {
                    MainView(account: account) { Vault.clear(); self.account = nil }
                } else { LoginView { self.account = $0 } }
            }
            .tint(AccentChoice.color(accent))
            .preferredColorScheme(appearance == "Dark" ? .dark : appearance == "Light" ? .light : nil)
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
                        Image(systemName: "books.vertical.fill").font(.system(size: 48)).foregroundStyle(Color.accentColor)
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
                        DisplaySection()
                        KoboSyncSection(client: client)
                        Section {
                            Button("Disconnect", role: .destructive, action: disconnect)
                        } footer: { Text("Removes the saved login from this iPhone. Books already exported to Files or another app remain there.") }
                        Section { LabeledContent("Version", value: "0.4.0") }
                    }.navigationTitle("Settings")
                }
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
                VStack(spacing: 20) {
                    Image(systemName: "magnifyingglass").font(.system(size: 58, weight: .regular)).accessibilityHidden(true)
                    Text("Search by title or author, then tap Search on the keyboard.")
                        .font(.body).multilineTextAlignment(.center).frame(maxWidth: 320)
                }.foregroundStyle(.secondary).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @State private var scrollID: String?
    init(client: Catalog, url: URL, title: String) {
        self.client = client; self.url = url; self.title = title
        let cached = client.browsing.pages[url]
        _entries = State(initialValue: cached?.entries ?? [])
        _next = State(initialValue: cached?.next)
        _loaded = State(initialValue: cached != nil)
        _scrollID = State(initialValue: cached?.scroll)
    }
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
                                    Image(systemName: "square.stack.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
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
                }.scrollTargetLayout()
                if busy { ProgressView().padding() }
                if next != nil && !busy {
                    Button("Load more") { Task { await load(reset: false) } }.buttonStyle(.bordered).padding()
                }
            }.padding(20)
        }
        .scrollPosition(id: $scrollID)
        .onChange(of: scrollID) { _, id in client.browsing.pages[url]?.scroll = id }
        .navigationTitle(title)
        .task { if !loaded || client.browsing.pages[url] == nil { await load(reset: true) } }
        .refreshable { client.invalidateBrowsing(); await load(reset: true) }
        .onReceive(NotificationCenter.default.publisher(for: .cwaBookChanged)) { _ in
            Task { await load(reset: true) }
        }
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
            client.browsing.pages[url] = BrowseMemory.Page(entries: result, next: nextURL, scroll: scrollID)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { self.error = error.localizedDescription; loaded = true } }
    }
}

struct CoverView: View {
    let client: Catalog
    let book: Entry
    let page: URL
    @State private var image: UIImage?
    @State private var revision = UUID()
    init(client: Catalog, book: Entry, page: URL) {
        self.client = client; self.book = book; self.page = page
        if let link = book.cover, let url = try? client.resolve(link.href, relativeTo: page) {
            _image = State(initialValue: client.browsing.covers.object(forKey: url as NSURL))
        }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.10))
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "book.closed.fill").font(.system(size: 42)).foregroundStyle(.teal.opacity(0.55)) }
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .cwaBookChanged)) { _ in revision = UUID() }
        .task(id: revision) {
            guard let link = book.cover,
                  let url = try? client.resolve(link.href, relativeTo: page) else { return }
            if let cached = client.browsing.covers.object(forKey: url as NSURL) { image = cached; return }
            let expected = client.cacheEpoch
            guard let data = try? await client.data(url), !Task.isCancelled, expected == client.cacheEpoch, let decoded = UIImage(data: data) else { return }
            client.browsing.covers.setObject(decoded, forKey: url as NSURL, cost: Int(decoded.size.width * decoded.size.height * 4))
            image = decoded
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
    @State var book: Entry
    let page: URL
    @State private var busy = false
    @State private var error: String?
    @State private var shared: SharedBook?
    @State private var temporaryFolder: URL?
    @State private var chooseDownload = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var notice: String?
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
                    Button { chooseDownload = true } label: {
                        Label(busy ? "Downloading…" : "Download book", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 24)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
        .confirmationDialog("Download format", isPresented: $chooseDownload, titleVisibility: .visible) {
            ForEach(book.downloads) { link in
                Button("Download \(link.format)") { Task { await download(link) } }
            }
        }

                }
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !book.summary.isEmpty { Text(book.summary).font(.body).textSelection(.enabled) }
                if !book.publisher.isEmpty { LabeledContent("Publisher", value: book.publisher) }
                if !book.published.isEmpty { LabeledContent("Published", value: book.published) }
                if !book.tags.isEmpty { Text(book.tags.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary) }
            }.padding(24)
        }
        .navigationTitle("Book details").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit", systemImage: "pencil") { editing = true }.disabled(busy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete book", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(busy || book.bookID == nil)
            }
        }
        .alert("Delete this book?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete book", role: .destructive) { Task { await deleteBook() } }
        } message: { Text("“\(book.title)” and all its formats will be permanently deleted from your CWA library on the server.") }
        .sheet(isPresented: $editing) {
            MetadataEditor(client: client, book: book, page: page) { metadata in
                book.title = metadata["title"]
                book.authors = metadata["authors"].components(separatedBy: " & ")
                book.summary = BookDescription.plainText(metadata["comments"])
                book.publisher = metadata["publisher"]
                book.published = metadata["pubdate"]
                book.tags = metadata["tags"].components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                notice = "Saved to CWA."
                client.invalidateBrowsing()
                NotificationCenter.default.post(name: .cwaBookChanged, object: nil)
            }
        }
        .sheet(item: $shared, onDismiss: {
            if let folder = temporaryFolder { try? FileManager.default.removeItem(at: folder) }
            temporaryFolder = nil
        }) { item in ShareSheet(url: item.url) }
    }
    @MainActor private func deleteBook() async {
        guard !busy, let id = book.bookID else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await client.deleteBook(id: id)
            client.invalidateBrowsing()
                NotificationCenter.default.post(name: .cwaBookChanged, object: nil)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func download(_ link: FeedLink) async {
        guard !busy else { return }
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

extension Notification.Name { static let cwaBookChanged = Notification.Name("CWABookChanged") }
