import Foundation

enum EPUBImport {
    static func validate(_ url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 200 * 1024 * 1024 else { throw CatalogError.message("Choose an EPUB smaller than 200 MB.") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 128) ?? Data()
        try validateHeader(bytes)
    }
    static func validateHeader(_ bytes: Data) throws {
        // EPUB requires its first ZIP entry to be the uncompressed mimetype file.
        func word(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        guard bytes.count >= 58, Array(bytes.prefix(4)) == [0x50, 0x4b, 0x03, 0x04], word(8) == 0,
              word(26) == 8, word(28) == 0,
              String(decoding: bytes[30..<38], as: UTF8.self) == "mimetype",
              String(decoding: bytes[38..<58], as: UTF8.self) == "application/epub+zip" else {
            throw CatalogError.message("This download is not a supported EPUB. It may be a web page or another file format. Select an EPUB download and try again.")
        }
    }
}
