import AppKit

struct ImageAsset: Identifiable, @unchecked Sendable {
    let url: URL
    let width: Int
    let height: Int
    let byteCount: Int64
    let format: String
    let thumbnail: NSImage

    var id: URL { url.standardizedFileURL }
    var name: String { url.lastPathComponent }
    var dimensions: String { "\(width) × \(height)" }
    var fileSize: String { ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file) }
}
