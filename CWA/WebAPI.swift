import Foundation
import SwiftSoup

struct BookMetadata {
    var fields: [String: String]
    var original: [String: String]
    var bookID: Int
    var uuid: String
    subscript(_ name: String) -> String {
        get { fields[name] ?? "" }
        set { fields[name] = newValue }
    }
    var year: String {
        get { String(self["pubdate"].prefix(4)) }
        set {
            if newValue == year { return }
            self["pubdate"] = newValue.isEmpty ? "" : newValue + "-01-01"
        }
    }
    func validate() throws {
        guard !self["title"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !self["authors"].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CatalogError.message("Enter a title and author.")
        }
        if !year.isEmpty {
            guard self["pubdate"].count == 10, year.count == 4, let y = Int(year), (1...9999).contains(y) else {
                throw CatalogError.message("Enter a four-digit release year, or leave it blank.")
            }
        }
        if !self["rating"].isEmpty {
            guard let rating = Double(self["rating"]), rating.isFinite,
                  (0.5...5).contains(rating), (rating * 2).rounded() == rating * 2 else {
                throw CatalogError.message("Choose a rating in half-star steps, or no rating.")
            }
        }
        if !self["series_index"].isEmpty {
            guard let index = Double(self["series_index"]), index.isFinite, index >= 0 else {
                throw CatalogError.message("Use a nonnegative series number, such as 1 or 0.5.")
            }
        }
    }
}

// Parse successful HTML form controls so identifiers, languages, custom columns,
// descriptions and existing flags survive a native edit unchanged.
enum WebForm {
    static func fields(_ element: Element) throws -> [String: String] {
        var result: [String: String] = [:]
        for control in try element.select("input[name], textarea[name], select[name]").array() {
            if control.hasAttr("disabled") { continue }
            let name = try control.attr("name")
            let type = try control.attr("type").lowercased()
            if ["file", "submit", "button", "reset"].contains(type) { continue }
            if ["checkbox", "radio"].contains(type) && !control.hasAttr("checked") { continue }
            if control.tagName() == "select" {
                let options = try control.select("option").array()
                if let selected = options.first(where: { $0.hasAttr("selected") }) ?? options.first {
                    result[name] = selected.hasAttr("value") ? try selected.attr("value") : try selected.text()
                }
            } else if control.tagName() == "textarea" {
                result[name] = try control.text(trimAndNormaliseWhitespace: false)
            } else {
                result[name] = control.hasAttr("value") ? try control.attr("value") : (["checkbox", "radio"].contains(type) ? "on" : "")
            }
        }
        return result
    }
    static func token(_ document: Document) throws -> String {
        if let input = try document.select("input[name=csrf_token]").first() { return try input.attr("value") }
        if let meta = try document.select("meta[name=csrf-token]").first() { return try meta.attr("content") }
        throw CatalogError.message("CWA did not provide a security token. Reload and try again.")
    }
    static func errors(_ document: Document) throws -> String? {
        let messages = try document.select(".alert-danger, .alert-error").array().map { try $0.text() }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

extension Catalog {
    private func send(_ url: URL, fields: [String: String], cover: Data? = nil) async throws -> (Data, URLResponse) {
        var req = try request(url)
        req.httpMethod = "POST"
        req.setValue(account.base.absoluteString + "/", forHTTPHeaderField: "Referer")
        if let csrf = fields["csrf_token"] { req.setValue(csrf, forHTTPHeaderField: "X-CSRFToken") }
        let boundary = "CWA-" + UUID().uuidString
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            guard !name.contains("\r"), !name.contains("\n"), !name.contains("\"") else { continue }
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        if let cover {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"btn-upload-cover\"; filename=\"cover.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
            body.append(cover); append("\r\n")
        }
        append("--\(boundary)--\r\n")
        req.httpBody = body
        let result = try await session.data(for: req)
        try check(result.1)
        return result
    }
    private func document(_ url: URL) async throws -> Document {
        try SwiftSoup.parse(String(decoding: try await data(url), as: UTF8.self))
    }
    // Only sign in when the session has expired. Cookies stay in the ephemeral
    // session and the redirect guard never forwards credentials to another origin.
    private func authenticatedPage(_ url: URL) async throws -> Document {
        let page = try await document(url)
        if try page.select("input[name=next]").isEmpty() { return page }
        let token = try WebForm.token(page)
        let (body, _) = try await send(endpoint("login"), fields: ["username": account.username,
            "password": account.password, "csrf_token": token, "next": "/"])
        let response = try SwiftSoup.parse(String(decoding: body, as: UTF8.self))
        if let error = try WebForm.errors(response) { throw CatalogError.message(error) }
        guard try response.select("input[name=next]").isEmpty() else {
            throw CatalogError.message("CWA web login failed. Check your login and standard-login settings.")
        }
        let signedIn = try await document(url)
        guard try signedIn.select("input[name=next]").isEmpty() else {
            throw CatalogError.message("CWA did not keep the signed-in session. Check its proxy and cookie settings.")
        }
        return signedIn
    }
    func metadata(bookID: Int, uuid: String) async throws -> BookMetadata {
        let page = try await authenticatedPage(endpoint("admin/book/\(bookID)"))
        guard let form = try page.select("form#book_edit_frm").first() else {
            throw CatalogError.message("Metadata editing is unavailable. Check that your CWA user has permission to edit books.")
        }
        var fields = try WebForm.fields(form)
        // CWA's HTML form truncates half-star ratings. Read the full stored value
        // from its companion endpoint before displaying or resubmitting a rating.
        let bytes = try await data(endpoint("ajax/book/\(uuid)"))
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let id = json["application_id"] as? Int, id == bookID,
              let raw = json["rating"], let rating = Double(String(describing: raw)) else {
            throw CatalogError.message("Unable to read the complete book metadata safely. No changes were made.")
        }
        fields["rating"] = rating == 0 ? "" : String(rating / 2)
        return BookMetadata(fields: fields, original: fields, bookID: bookID, uuid: uuid)
    }
    func saveMetadata(_ edited: BookMetadata, cover: Data?) async throws {
        try edited.validate()
        // Reload before writing: preserve unrelated concurrent edits and reject
        // conflicts in fields this user changed instead of silently overwriting.
        let latest = try await metadata(bookID: edited.bookID, uuid: edited.uuid)
        var fields = latest.fields
        for (name, value) in edited.fields where value != edited.original[name] {
            if latest[name] != edited.original[name] && latest[name] != value {
                throw CatalogError.message("This book was edited elsewhere. Close and reopen the editor to load the latest values.")
            }
            fields[name] = value
        }
        fields.removeValue(forKey: "detail_view")
        let (body, _) = try await send(endpoint("admin/book/\(edited.bookID)"), fields: fields, cover: cover)
        let response = try SwiftSoup.parse(String(decoding: body, as: UTF8.self))
        if let error = try WebForm.errors(response) {
            throw CatalogError.message("CWA reported: \(error) Some fields may have been saved; reopen the editor to check.")
        }
        guard try response.select("form#book_edit_frm").first() != nil,
              !(try response.select(".alert-success").isEmpty()) else {
            throw CatalogError.message("CWA did not confirm the save. Reopen the editor to check before trying again.")
        }
    }
    func forceKoboSync() async throws {
        let page = try await authenticatedPage(endpoint("me"))
        guard try page.select("#kobo_full_sync").first() != nil else {
            throw CatalogError.message("Kobo sync is unavailable for this CWA account. Check Kobo integration in CWA.")
        }
        let (body, _) = try await send(endpoint("ajax/fullsync"), fields: ["csrf_token": try WebForm.token(page)])
        guard let messages = try JSONSerialization.jsonObject(with: body) as? [[String: String]],
              !messages.isEmpty, messages.allSatisfy({ $0["type"] == "success" }) else {
            throw CatalogError.message("CWA did not confirm the sync reset. Please check the server and try again.")
        }
    }
}

struct CoverOption: Identifiable {
    let id: Int
    let title: String
    var url: URL { URL(string: "https://covers.openlibrary.org/b/id/\(id)-L.jpg?default=false")! }
}
enum CoverSearch {
    static func search(title: String, author: String) async throws -> [CoverOption] {
        var url = URLComponents(string: "https://openlibrary.org/search.json")!
        url.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "author", value: author),
                          URLQueryItem(name: "fields", value: "title,cover_i"), URLQueryItem(name: "limit", value: "24")]
        // Public requests never use the CWA session, cookies or Authorization header.
        let bytes = try await fetch(url.url!)
        guard let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let docs = json["docs"] as? [[String: Any]] else {
            throw CatalogError.message("The cover service returned an unexpected response.")
        }
        var seen = Set<Int>()
        return docs.compactMap { doc in
            guard let id = doc["cover_i"] as? Int, id > 0, seen.insert(id).inserted else { return nil }
            return CoverOption(id: id, title: (doc["title"] as? String) ?? title)
        }
    }
    static func fetch(_ url: URL) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("CWA-iOS/0.2 (personal library client)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw CatalogError.message("The cover service is unavailable. Try again later or choose a local image.")
        }
        return bytes
    }
}
