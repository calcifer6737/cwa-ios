import Foundation

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

func checkLibraryOperations() async throws {
    let original = "<p>A &amp; B</p><p>Second paragraph</p>"
    let plain = BookDescription.plainText(original)
    precondition(plain.contains("A & B") && plain.contains("Second paragraph"))
    precondition(BookDescription.html("<script>&\nnext") == "<p>&lt;script&gt;&amp;<br>next</p>")
    var header = Data(repeating: 0, count: 30)
    header.replaceSubrange(0..<4, with: [0x50, 0x4b, 0x03, 0x04]); header[26] = 8
    header.append(Data("mimetypeapplication/epub+zip".utf8))
    try EPUBImport.validateHeader(header)
    for invalid in [Data("<html>verification</html>".utf8), Data(repeating: 0, count: 128)] {
        do { try EPUBImport.validateHeader(invalid); fatalError("Accepted a non-EPUB download") } catch is CatalogError { }
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    let client = Catalog(Account(server: "https://library.example", username: "tester", password: "test"), configuration: configuration)
    var requests = 0
    StubProtocol.handler = { req in
        requests += 1
        if req.url!.query == nil {
            return (200, "<feed><link rel='next' href='/books?offset=2'/><entry><id>a</id><title>A</title></entry><entry><id>b</id><title>B</title></entry></feed>")
        }
        return (200, "<feed><entry><id>b</id><title>B</title></entry><entry><id>c</id><title>C</title></entry></feed>")
    }
    let books = try await client.allEntries(at: client.endpoint("books"))
    precondition(books.map(\.id) == ["a", "b", "c"])
    let again = try await client.allEntries(at: client.endpoint("books"))
    precondition(again.count == 3 && requests == 2, "Cached browsing repeated network requests")
    client.invalidateBrowsing()
    _ = try await client.allEntries(at: client.endpoint("books"))
    precondition(requests == 4, "Refresh failed to fetch new pages")
    client.invalidateBrowsing()
    StubProtocol.handler = { _ in (200, "<feed><link rel='next' href='/books'/></feed>") }
    do { _ = try await client.allEntries(at: client.endpoint("books")); fatalError("Accepted pagination loop") } catch is CatalogError { }

    let profile = "<html><input name='csrf_token' value='token'><input name='btn-upload' accept='.epub,.pdf'></html>"
    for response in ["[{}, {\"type\":\"success\"}]", "[{\"type\":\"danger\",\"message\":\"Denied\"}]", "{\"type\":\"danger\",\"message\":\"Denied\"}", "[]"] {
        StubProtocol.handler = { req in
            if req.url!.path == "/me" { return (200, profile) }
            precondition(req.url!.path == "/ajax/delete/42" && req.httpMethod == "POST")
            precondition(req.value(forHTTPHeaderField: "X-CSRFToken") == "token")
            return (200, response)
        }
        do {
            try await client.deleteBook(id: 42)
            precondition(response.contains("success"), "Reported failed deletion as success")
        } catch is CatalogError { precondition(!response.contains("success")) }
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
    try Data("test book".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    for failure in [false, true] {
        StubProtocol.handler = { req in
            switch req.url!.path {
            case "/me": return (200, profile)
            case "/upload":
                precondition(req.httpMethod == "POST")
                precondition(req.value(forHTTPHeaderField: "X-CSRFToken") == "token")
                return (200, "{\"location\":\"/tasks\"}")
            case "/tasks": return (200, failure ? "<div class='alert-error'>Ingest is not writable</div>" : "<html>Tasks</html>")
            default: fatalError("Unexpected request")
            }
        }
        do { try await client.uploadBook(file: file); precondition(!failure, "Reported upload error as success") }
        catch is CatalogError { precondition(failure) }
    }
}
