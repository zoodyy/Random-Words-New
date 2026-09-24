import Foundation

/// Substring search over a wordlist, cheap enough to rerun on every keystroke.
///
/// `localizedCaseInsensitiveContains` bridges each word to NSString and costs
/// ~70 ms across the 84k-line list — a visible stall per typed letter. For an
/// ASCII query against an ASCII word it gives the same answer as comparing the
/// bytes with ASCII case folded, which takes ~1.5 ms, so that is the path
/// taken. Words or queries with anything else in them still go to Foundation,
/// which knows the case rules beyond ASCII.
enum WordSearch {

    /// The entries of `order` whose word contains `query`, kept in `order`'s
    /// order and leaving out `excludedIndex`.
    static func indices(
        of query: String,
        in words: [String],
        orderedBy order: [Int],
        excluding excludedIndex: Int? = nil
    ) -> [Int] {
        var result: [Int] = []
        let wordCount = words.count

        guard let needle = asciiFoldedBytes(of: query) else {
            for index in order where index != excludedIndex && index >= 0 && index < wordCount {
                if words[index].localizedCaseInsensitiveContains(query) {
                    result.append(index)
                }
            }
            return result
        }

        needle.withUnsafeBufferPointer { needle in
            for index in order where index != excludedIndex && index >= 0 && index < wordCount {
                let word = words[index]
                let asciiMatch = word.utf8.withContiguousStorageIfAvailable { bytes in
                    asciiContains(bytes, needle)
                } ?? nil

                if asciiMatch ?? word.localizedCaseInsensitiveContains(query) {
                    result.append(index)
                }
            }
        }

        return result
    }

    /// The query's bytes lowercased, or nil if it isn't plain ASCII.
    private static func asciiFoldedBytes(of query: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(query.utf8.count)
        for byte in query.utf8 {
            guard byte < 0x80 else { return nil }
            bytes.append(byte &- 65 < 26 ? byte | 0x20 : byte)
        }
        return bytes.isEmpty ? nil : bytes
    }

    /// Whether `haystack` contains the already-folded `needle`, ignoring ASCII
    /// case — or nil if `haystack` isn't plain ASCII and needs Foundation.
    ///
    /// Raw pointers and the inlined folding (`byte &- 65 < 26` is "A"..."Z")
    /// matter in debug builds, where every buffer subscript or helper call
    /// would be a real function call and doubled the time.
    private static func asciiContains(
        _ haystack: UnsafeBufferPointer<UInt8>,
        _ needle: UnsafeBufferPointer<UInt8>
    ) -> Bool? {
        guard let base = haystack.baseAddress, let needleBase = needle.baseAddress else {
            return needle.isEmpty
        }
        let haystackCount = haystack.count
        let needleCount = needle.count

        var index = 0
        while index < haystackCount {
            if base[index] >= 0x80 { return nil }
            index += 1
        }

        guard haystackCount >= needleCount else { return false }

        let first = needleBase[0]
        var start = 0
        while start <= haystackCount - needleCount {
            var byte = base[start]
            if byte &- 65 < 26 { byte |= 0x20 }

            if byte == first {
                var offset = 1
                while offset < needleCount {
                    var next = base[start + offset]
                    if next &- 65 < 26 { next |= 0x20 }
                    if next != needleBase[offset] { break }
                    offset += 1
                }
                if offset == needleCount { return true }
            }
            start += 1
        }
        return false
    }
}
