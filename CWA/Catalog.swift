import Foundation
import Security

struct Account: Codable {
    var server: String
    var username: String
    var password: String
    var base: URL { URL(string: server)! }
}

enum Vault {
    static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "CWA.Account", kSecAttrAccount as String: "primary"]
    static func load() -> Account? {
        var q = query
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Account.self, from: data)
    }
    static func save(_ account: Account) throws {
        let data = try JSONEncoder().encode(account)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw CatalogError.message("Unable to save the login securely.") }
        } else if update != errSecSuccess { throw CatalogError.message("Unable to update the saved login.") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}

enum CatalogError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

struct FeedLink: Identifiable, Hashable {
    var id: String { rel + href }
    let rel: String
    let href: String
    let type: String
    var format: String {
        let path = URLComponents(string: href)?.path ?? href
        let parts = path.split(separator: "/").map(String.init)
        if let index = parts.lastIndex(of: "download"), parts.count > index + 2 {
            return parts[index + 2].uppercased()
        }
        if path.lowercased().contains(".kepub") { return "KEPUB" }
        if type.contains("epub") { return "EPUB" }
        if type.contains("pdf") { return "PDF" }
        return href.split(separator: "/").last.map { String($0).uppercased() } ?? "BOOK"
    }
}
struct Entry: Identifiable, Hashable {
    var id = ""
    var title = ""
    var authors: [String] = []
    var summary = ""
    var publisher = ""
    var published = ""
    var tags: [String] = []
    var links: [FeedLink] = []
    var downloads: [FeedLink] {
        var seen = Set<String>()
        return links.filter { $0.rel.contains("/acquisition") && seen.insert($0.href).inserted }
    }
    var bookID: Int? {
        for link in links {
            let parts = (URLComponents(string: link.href)?.path ?? "").split(separator: "/")
            for marker in ["download", "cover"] {
                if let i = parts.firstIndex(of: Substring(marker)), parts.count > i + 1,
                   let id = Int(parts[i + 1]) { return id }
            }
        }
        return nil
    }
    var cover: FeedLink? { links.first { $0.rel == "http://opds-spec.org/image" } ?? links.first { $0.rel.contains("/image/") } }
    var subsection: FeedLink? { links.first { $0.rel == "subsection" } }
    var isBook: Bool { subsection == nil }
}
struct Feed {
    var entries: [Entry] = []
    var next: String?
}
final class FeedParser: NSObject, XMLParserDelegate {
    private var feed = Feed()
    private var entry: Entry?
    private var stack: [String] = []
    private var texts: [String] = []
    private var sawFeed = false
    func parse(_ data: Data) throws -> Feed {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), sawFeed else { throw CatalogError.message("The server did not return a valid OPDS catalog. Check the CWA address and OPDS settings.") }
        return feed
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String]) {
        stack.append(elementName); texts.append("")
        if elementName == "feed" { sawFeed = true }
        if elementName == "entry" { entry = Entry() }
        if elementName == "category", entry != nil { entry?.tags.append(a["label"] ?? a["term"] ?? "") }
        if elementName == "link", let href = a["href"] {
            let link = FeedLink(rel: a["rel"] ?? "", href: href, type: a["type"] ?? "")
            if entry != nil { entry?.links.append(link) }
            else if link.rel == "next" { feed.next = href }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if !texts.isEmpty { texts[texts.count - 1] += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = (texts.popLast() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = stack.popLast()
        guard entry != nil else { return }
        switch elementName {
        case "id": entry?.id = value
        case "title": entry?.title = value
        case "name":
            if stack.last == "author" { entry?.authors.append(value) }
            if stack.last == "publisher" { entry?.publisher = value }
        case "summary", "content": entry?.summary = value
        case "published": entry?.published = String(value.prefix(10))
        case "entry":
            if var item = entry {
                if item.id.isEmpty { item.id = item.links.first?.href ?? item.title }
                feed.entries.append(item)
            }
            entry = nil
        default: break
        }
    }
}

// Never follow a redirect to another origin with a user's Authorization header.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              Catalog.sameOrigin(original, destination) else { completionHandler(nil); return }
        var next = request
        next.setValue(task.originalRequest?.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        completionHandler(next)
    }
}
final class Catalog {
    let account: Account
    let session: URLSession
    private let feeds = NSCache<NSURL, FeedBox>()
    private let cacheLock = NSLock()
    private var epoch = UUID()
    var cacheEpoch: UUID { cacheLock.lock(); defer { cacheLock.unlock() }; return epoch }
    private func clearFeeds() { cacheLock.lock(); defer { cacheLock.unlock() }; epoch = UUID(); feeds.removeAllObjects() }
    private func storeFeed(_ value: Feed, url: URL, epoch expected: UUID) throws {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard epoch == expected else { throw CancellationError() }
        feeds.setObject(FeedBox(value), forKey: url as NSURL)
    }
    #if canImport(UIKit)
    let browsing = BrowseMemory()
    #endif
    func invalidateBrowsing() {
        clearFeeds()
        #if canImport(UIKit)
        browsing.clear()
        #endif
    }
    init(_ account: Account, configuration: URLSessionConfiguration = .ephemeral) {
        self.account = account
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && (a.port ?? 443) == (b.port ?? 443)
    }
    func endpoint(_ path: String) -> URL { account.base.appendingPathComponent(path) }
    func resolve(_ href: String, relativeTo page: URL) throws -> URL {
        guard let url = URL(string: href, relativeTo: page)?.absoluteURL,
              Self.sameOrigin(account.base, url) else { throw CatalogError.message("CWA returned a link outside your HTTPS server. Check its reverse-proxy URL settings.") }
        return url
    }
    func request(_ url: URL) throws -> URLRequest {
        guard Self.sameOrigin(account.base, url) else { throw CatalogError.message("Blocked a request outside your CWA server.") }
        var request = URLRequest(url: url)
        let token = Data("\(account.username):\(account.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw CatalogError.message("No HTTP response received.") }
        switch http.statusCode {
        case 200...299: return
        case 401: throw CatalogError.message("Login rejected. Use your CWA username and password, not your Apple Account.")
        case 403: throw CatalogError.message("CWA denied access. Check this user's permissions.")
        default: throw CatalogError.message("CWA returned HTTP \(http.statusCode). Check the address and server availability.")
        }
    }
    func data(_ url: URL) async throws -> Data {
        var req = try request(url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: req)
        try check(response)
        return data
    }
    func feed(_ url: URL) async throws -> Feed {
        if let cached = feeds.object(forKey: url as NSURL) { return cached.value }
        let expected = cacheEpoch
        let value = try FeedParser().parse(try await data(url))
        try Task.checkCancellation()
        try storeFeed(value, url: url, epoch: expected)
        return value
    }
    func download(_ url: URL, title: String, format: String) async throws -> URL {
        let (temporary, response) = try await session.download(for: request(url))
        try check(response)
        if response.mimeType?.contains("text/html") == true { throw CatalogError.message("CWA returned a web page instead of a book.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeTitle = String(title.map { "/\\:?%*|\"<>".contains($0) ? "_" : $0 }.prefix(100))
        let destination = folder.appendingPathComponent(safeTitle.isEmpty ? "Book" : safeTitle).appendingPathExtension(format.uppercased() == "KEPUB" ? "kepub.epub" : format.lowercased())
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}

private final class FeedBox { let value: Feed; init(_ value: Feed) { self.value = value } }
