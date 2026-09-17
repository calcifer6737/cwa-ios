import Foundation

@main struct CatalogChecks {
    static func main() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <link rel="next" href="/opds/search?offset=30"/>
          <entry><id>urn:uuid:book1</id><title>A &amp; B</title>
            <author><name>Author One</name></author><author><name>Author Two</name></author>
            <publisher><name>Publisher</name></publisher><summary>Some &lt;text&gt;.</summary>
            <category term="Fantasy"/><published>2024-01-02T00:00:00Z</published>
            <link rel="http://opds-spec.org/image" href="/opds/cover/1" type="image/jpeg"/>
            <link rel="http://opds-spec.org/acquisition" href="/opds/download/1/epub/" type="application/epub+zip"/>
          </entry>
          <entry><title>Kobo Sync</title><id>/opds/shelf/1</id><link rel="subsection" href="/opds/shelf/1"/></entry>
        </feed>
        """
        let feed = try FeedParser().parse(Data(xml.utf8))
        precondition(feed.entries.count == 2)
        precondition(feed.entries[0].title == "A & B")
        precondition(feed.entries[0].authors == ["Author One", "Author Two"])
        precondition(feed.entries[0].publisher == "Publisher")
        precondition(feed.entries[0].summary == "Some <text>.")
        precondition(feed.entries[0].downloads.first?.format == "EPUB")
        precondition(feed.entries[0].tags == ["Fantasy"])
        precondition(feed.entries[1].subsection?.href == "/opds/shelf/1")
        precondition(feed.next == "/opds/search?offset=30")
        do {
            _ = try FeedParser().parse(Data("<html><body>Login</body></html>".utf8))
            fatalError("Accepted HTML as an OPDS feed")
        } catch is CatalogError { }
        let client = Catalog(Account(server: "https://example.test/cwa", username: "reader", password: "test-only"))
        let page = client.endpoint("opds")
        precondition(page.absoluteString == "https://example.test/cwa/opds")
        let coverURL = try client.resolve("/cwa/opds/cover/1", relativeTo: page)
        precondition(coverURL.host == "example.test")
        for href in ["https://other.test/opds", "http://example.test/opds", "https://example.test:444/opds"] {
            do {
                _ = try client.resolve(href, relativeTo: page)
                fatalError("Accepted a cross-origin credential destination")
            } catch is CatalogError { }
        }
        print("Catalog parsing and origin checks passed.")
    }
}
