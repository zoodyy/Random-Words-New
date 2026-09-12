import Foundation

/// Shared, fast access to the wordlist CSVs.
///
/// These files get big — the bundled 333k list is ~84k lines — and every screen
/// that opens one used to pay for `components(separatedBy: .newlines)` plus a
/// `trimmingCharacters` call per line. Both are CharacterSet-driven and cost
/// well over an order of magnitude more than scanning the raw UTF-8 bytes, so
/// the splitting happens on the bytes instead.
enum WordlistFile {

    static func documentsURL(for name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(name).csv")
    }

    /// The copy that should be read: a user-edited one in Documents if it
    /// exists, otherwise the bundled original.
    static func readableURL(for name: String) -> URL? {
        let documentsURL = documentsURL(for: name)
        if FileManager.default.fileExists(atPath: documentsURL.path) {
            return documentsURL
        }
        return BundledWordlists.url(named: name)
    }

    /// Every non-blank line of the wordlist, trimmed.
    static func words(named name: String) -> [String] {
        guard let url = readableURL(for: name) else { return [] }
        return words(at: url)
    }

    static func words(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return words(in: data)
    }

    static func words(in data: Data) -> [String] {
        var result: [String] = []
        // Wordlist lines average well under 16 bytes; over-reserving a little is
        // cheaper than repeatedly growing an 84k-element array.
        result.reserveCapacity(data.count / 8 + 1)

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count

            var lineStart = 0
            var index = 0

            while index <= count {
                guard index == count || base[index] == UInt8(ascii: "\n") else {
                    index += 1
                    continue
                }

                var start = lineStart
                var end = index

                while start < end, isTrimmable(base[end - 1]) { end -= 1 }
                while start < end, isTrimmable(base[start]) { start += 1 }

                if start < end {
                    result.append(
                        String(decoding: UnsafeBufferPointer(start: base + start, count: end - start),
                               as: UTF8.self)
                    )
                }

                lineStart = index + 1
                index += 1
            }
        }

        return result
    }

    private static func isTrimmable(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ")
            || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r")
    }
}
