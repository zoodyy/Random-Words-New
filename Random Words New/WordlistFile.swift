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
        waitForPendingSaves()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return words(in: data)
    }

    // MARK: Saving

    // Every write goes through one serial queue, so a background save can never
    // land after a newer one, and reads wait on it so nobody sees a stale file.
    private nonisolated static let saveQueue = DispatchQueue(label: "WordlistFile.save", qos: .userInitiated)

    static func save(_ words: [String], to url: URL) {
        saveQueue.sync { write(words, to: url) }
    }

    /// Joining and writing the 84k-line list takes long enough on the main
    /// thread to stutter a drag-and-drop, so edits made while the list is on
    /// screen are written from here.
    static func saveInBackground(_ words: [String], to url: URL) {
        saveQueue.async { write(words, to: url) }
    }

    static func waitForPendingSaves() {
        saveQueue.sync {}
    }

    private nonisolated static func write(_ words: [String], to url: URL) {
        try? words.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Single words

    /// Which of `candidates` are already lines of the list. Compares the raw
    /// bytes instead of building a String per line, so asking about a word or
    /// two stays quick even for the 400k-line bundled lists.
    static func lines(matching candidates: Set<String>, inListNamed name: String) -> Set<String> {
        guard !candidates.isEmpty, let url = readableURL(for: name) else { return [] }
        waitForPendingSaves()
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }

        let targets = candidates.map { (word: $0, bytes: Array($0.utf8)) }
        var found: Set<String> = []

        data.withUnsafeBytes { raw in
            guard let rawBase = raw.baseAddress else { return }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            let count = raw.count

            var lineStart = 0
            while lineStart <= count, found.count < targets.count {
                let lineEnd = memchr(rawBase + lineStart, Int32(UInt8(ascii: "\n")), count - lineStart)
                    .map { rawBase.distance(to: UnsafeRawPointer($0)) } ?? count

                var start = lineStart
                var end = lineEnd
                while start < end, isTrimmable(base[end - 1]) { end -= 1 }
                while start < end, isTrimmable(base[start]) { start += 1 }

                let length = end - start
                if length > 0 {
                    for target in targets where target.bytes.count == length && !found.contains(target.word) {
                        if memcmp(base + start, target.bytes, length) == 0 {
                            found.insert(target.word)
                        }
                    }
                }

                lineStart = lineEnd + 1
            }
        }

        return found
    }

    /// Appends whichever of `newWords` the list doesn't have yet. Appending
    /// rather than rewriting the file keeps this instant for the big lists.
    static func add(_ newWords: [String], toListNamed name: String) {
        let present = lines(matching: Set(newWords), inListNamed: name)
        var missing: [String] = []
        for word in newWords where !present.contains(word) && !missing.contains(word) {
            missing.append(word)
        }
        guard !missing.isEmpty else { return }

        let url = documentsURL(for: name)
        let bundledURL = BundledWordlists.url(named: name)
        saveQueue.sync { append(missing, to: url, seededFrom: bundledURL) }
    }

    /// Takes every line that is one of `wordsToRemove` out of the list.
    static func remove(_ wordsToRemove: Set<String>, fromListNamed name: String) {
        let words = words(named: name)
        let remaining = words.filter { !wordsToRemove.contains($0) }
        guard remaining.count < words.count else { return }
        saveInBackground(remaining, to: documentsURL(for: name))
    }

    private nonisolated static func append(_ words: [String], to url: URL, seededFrom bundledURL: URL?) {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: url.path) {
            // The first change to a bundled list starts from its contents,
            // just like opening it in the editor does.
            if let bundledURL {
                try? fileManager.copyItem(at: bundledURL, to: url)
            }
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
        }

        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return }

        // Saved lists don't end in a newline, so one usually goes in first.
        var needsSeparator = false
        if end > 0 {
            try? handle.seek(toOffset: end - 1)
            needsSeparator = (try? handle.read(upToCount: 1)) != Data([UInt8(ascii: "\n")])
            _ = try? handle.seekToEnd()
        }

        let text = (needsSeparator ? "\n" : "") + words.joined(separator: "\n")
        try? handle.write(contentsOf: Data(text.utf8))
    }

    static func words(in data: Data) -> [String] {
        var result: [String] = []
        // Wordlist lines average well under 16 bytes; over-reserving a little is
        // cheaper than repeatedly growing an 84k-element array.
        result.reserveCapacity(data.count / 8 + 1)

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            forEachLine(in: raw) { line in
                result.append(
                    String(decoding: UnsafeBufferPointer(start: base + line.lowerBound, count: line.count),
                           as: UTF8.self)
                )
            }
        }

        return result
    }

    // MARK: Lines by position

    /// Where each line of a wordlist lies in the file, so the few at some
    /// positions can be read without turning every line into a String. A
    /// range slider shows the words at its ends on every step, and reading the
    /// whole of a big list each time made it stutter.
    struct Lines: RandomAccessCollection {

        private let data: Data
        private let ranges: [Range<Int>]

        /// Every non-blank line of the wordlist, trimmed, like `words(at:)`.
        init(at url: URL) {
            WordlistFile.waitForPendingSaves()
            // Mapped, so holding on to a big list doesn't keep a copy of it in
            // memory. Wordlists are only ever replaced or appended to, never
            // rewritten in place, so the mapping stays valid.
            let data = (try? Data(contentsOf: url, options: .mappedIfSafe)) ?? Data()

            var ranges: [Range<Int>] = []
            data.withUnsafeBytes { raw in
                WordlistFile.forEachLine(in: raw) { ranges.append($0) }
            }

            self.data = data
            self.ranges = ranges
        }

        var startIndex: Int { ranges.startIndex }
        var endIndex: Int { ranges.endIndex }

        subscript(position: Int) -> String {
            String(decoding: data[ranges[position]], as: UTF8.self)
        }
    }

    /// Calls `body` with the byte range of every non-blank line, trimmed.
    private static func forEachLine(in raw: UnsafeRawBufferPointer, _ body: (Range<Int>) -> Void) {
        guard let rawBase = raw.baseAddress else { return }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        let count = raw.count

        var lineStart = 0
        while lineStart <= count {
            let lineEnd = memchr(rawBase + lineStart, Int32(UInt8(ascii: "\n")), count - lineStart)
                .map { rawBase.distance(to: UnsafeRawPointer($0)) } ?? count

            var start = lineStart
            var end = lineEnd
            while start < end, isTrimmable(base[end - 1]) { end -= 1 }
            while start < end, isTrimmable(base[start]) { start += 1 }

            if start < end {
                body(start..<end)
            }

            lineStart = lineEnd + 1
        }
    }

    private static func isTrimmable(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ")
            || byte == UInt8(ascii: "\t")
            || byte == UInt8(ascii: "\r")
    }
}
