import Foundation

// Every CSV placed in Bundled/Wordlists is treated as a wordlist —
// nothing is hardcoded, drop a file in the folder and it shows up.
enum BundledWordlists {

    static let subdirectory = "Bundled/Wordlists"

    static func urls() -> [URL] {
        if let urls = Bundle.main.urls(forResourcesWithExtension: "csv", subdirectory: subdirectory),
           !urls.isEmpty {
            return urls
        }

        // Synchronized-folder resources may be flattened into the bundle root,
        // so fall back to every root CSV that isn't a dictionary file.
        guard let allCSVs = Bundle.main.urls(forResourcesWithExtension: "csv", subdirectory: nil) else {
            return []
        }

        return allCSVs.filter { !isDictionaryCSV($0) }
    }

    static func names() -> [String] {
        urls()
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    static func url(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: subdirectory) {
            return url
        }

        if let url = Bundle.main.url(forResource: name, withExtension: "csv"),
           !isDictionaryCSV(url) {
            return url
        }

        return nil
    }

    private static func isDictionaryCSV(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 32) else { return false }
        return String(decoding: head, as: UTF8.self).lowercased().hasPrefix("word,pos,definition")
    }
}
