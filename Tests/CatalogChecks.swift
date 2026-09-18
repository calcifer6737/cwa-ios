import Foundation
import SwiftSoup

@main struct CatalogChecks {
    static func main() async throws {
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
        let kepub = FeedLink(rel: "http://opds-spec.org/acquisition", href: "/opds/download/1/kepub/", type: "application/epub+zip")
        precondition(kepub.format == "KEPUB")
        var entry = feed.entries[0]
        entry.links.append(kepub)
        entry.links.append(kepub)
        precondition(entry.downloads.map(\.format) == ["EPUB", "KEPUB"])
        precondition(entry.bookID == 1)
        let form = try SwiftSoup.parse("""
        <form id="book_edit_frm">
          <input name="title" value="A &amp; B &quot;quoted&quot;">
          <input name="authors" value="An Author">
          <input name="identifier-type-3" value="isbn"><input name="identifier-val-3" value="123">
          <input name="languages" value="English"><input name="csrf_token" value="token">
          <input name="blacklist_annotations" type="checkbox" checked>
          <input name="blacklist_reading_progress" type="checkbox">
          <textarea name="comments">&lt;p&gt;Keep &amp;amp; preserve&lt;/p&gt;</textarea>
          <select name="custom_column_1"><option value="None"></option><option value="True" selected>Yes</option></select>
          <input name="btn-upload-cover" type="file"><input name="disabled" disabled value="ignore">
        </form>
        """)
        let fields = try WebForm.fields(form.select("form").first()!)
        precondition(fields["title"] == "A & B \"quoted\"")
        precondition(fields["comments"] == "<p>Keep &amp; preserve</p>")
        precondition(fields["identifier-val-3"] == "123")
        precondition(fields["languages"] == "English")
        precondition(fields["custom_column_1"] == "True")
        precondition(fields["blacklist_annotations"] == "on")
        precondition(fields["blacklist_reading_progress"] == nil)
        precondition(fields["btn-upload-cover"] == nil && fields["disabled"] == nil)
        var metadata = BookMetadata(fields: fields, original: fields, bookID: 1, uuid: "test")
        metadata["rating"] = "4.5"; metadata["series_index"] = "0.5"
        metadata["pubdate"] = "2012-06-14"
        metadata.year = "2012"
        precondition(metadata["pubdate"] == "2012-06-14")
        metadata.year = "2020"
        precondition(metadata["pubdate"] == "2020-01-01")
        try metadata.validate()
        for invalid in ["6", "nan", "4.2"] {
            metadata["rating"] = invalid
            do { try metadata.validate(); fatalError("Accepted invalid rating") } catch is CatalogError { }
        }
        try await checkLibraryOperations()
        print("Catalog, origin safety, metadata, pagination, upload, and deletion checks passed.")
    }
}
