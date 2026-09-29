import Foundation

enum OutputNamer {
    static func proposedURL(source: URL, folder: URL, settings: ProcessingSettings) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let name = (settings.prefix + stem + settings.suffix)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "_")
        return folder.appendingPathComponent(name.isEmpty ? "image" : name).appendingPathExtension(settings.format.fileExtension)
    }

    static func availableURL(_ proposed: URL, source: URL, reserved: Set<URL>, exists: (URL) -> Bool) -> URL {
        if proposed.standardizedFileURL != source.standardizedFileURL && !reserved.contains(proposed.standardizedFileURL) && !exists(proposed) { return proposed }
        let stem = proposed.deletingPathExtension().lastPathComponent
        let ext = proposed.pathExtension
        var index = 2
        while true {
            let candidate = proposed.deletingLastPathComponent().appendingPathComponent("\(stem)-\(index)").appendingPathExtension(ext)
            if candidate.standardizedFileURL != source.standardizedFileURL && !reserved.contains(candidate.standardizedFileURL) && !exists(candidate) { return candidate }
            index += 1
        }
    }
}
