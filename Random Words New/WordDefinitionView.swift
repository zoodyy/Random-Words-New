import SwiftUI
import Network
import AVFoundation
import Combine

/// One-shot connectivity check used before attempting automatic downloads.
nonisolated enum NetworkReachability {
    static func hasConnection() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            nonisolated(unsafe) var hasResumed = false
            monitor.pathUpdateHandler = { path in
                // The handler runs serially on the monitor queue, and may still
                // fire once more after cancel(), so guard against double resume.
                guard !hasResumed else { return }
                hasResumed = true
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: DispatchQueue(label: "NetworkReachabilityCheck"))
        }
    }
}

nonisolated enum DefinitionSource: Sendable {
    case user
    case downloaded
    case bundled
}

nonisolated struct DictionaryEntry: Identifiable, Sendable {
    let id = UUID()
    let wordType: String
    let definition: String
    let example: String?
    let phonetic: String?
    let source: DefinitionSource

    init(wordType: String, definition: String, example: String? = nil, phonetic: String? = nil, source: DefinitionSource) {
        self.wordType = wordType
        self.definition = definition
        self.example = example
        self.phonetic = phonetic
        self.source = source
    }

    var isDeletable: Bool {
        source != .bundled
    }
}

struct DefinitionTarget: Identifiable {
    let words: [String]
    var id: String { words.joined(separator: "\u{1}") }
}

nonisolated enum DefinitionDownloadError: Error {
    case notFound
    case badResponse
}

actor EnglishDictionaryStore {
    static let shared = EnglishDictionaryStore()

    private var bundledIndex: [String: [DictionaryEntry]]?
    private var userDefinitions: [(word: String, entry: DictionaryEntry)]?
    private var downloadedDefinitions: [(word: String, entry: DictionaryEntry)]?

    // Pronunciation audio URLs are kept in memory only (never written to the
    // definitions CSV) so a word isn't refetched from the API on every tap.
    // The optional value distinguishes "known to have no audio" from "unknown".
    private var pronunciationURLCache: [String: URL?] = [:]

    func definitions(for word: String) -> [DictionaryEntry] {
        let key = word.lowercased()

        if userDefinitions == nil {
            userDefinitions = Self.loadDefinitionsFile(at: Self.userDefinitionsURL, source: .user)
        }
        if downloadedDefinitions == nil {
            downloadedDefinitions = Self.loadDefinitionsFile(at: Self.downloadedDefinitionsURL, source: .downloaded)
        }
        if bundledIndex == nil {
            bundledIndex = Self.buildBundledIndex()
        }

        let userEntries = (userDefinitions ?? [])
            .filter { $0.word.lowercased() == key }
            .map { $0.entry }

        let downloadedEntries = (downloadedDefinitions ?? [])
            .filter { $0.word.lowercased() == key }
            .map { $0.entry }

        // Within the downloaded group, surface the richest entries first:
        // ones with examples, then ones with only a phonetic, then the rest.
        let withExample = downloadedEntries.filter { $0.example != nil }
        let withPhoneticOnly = downloadedEntries.filter { $0.example == nil && $0.phonetic != nil }
        let plain = downloadedEntries.filter { $0.example == nil && $0.phonetic == nil }

        return userEntries + withExample + withPhoneticOnly + plain + (bundledIndex?[key] ?? [])
    }

    func addUserDefinition(word: String, wordType: String, definition: String, example: String = "", phonetic: String = "") -> (entries: [DictionaryEntry], newIndex: Int) {
        var definitions = userDefinitions ?? Self.loadDefinitionsFile(at: Self.userDefinitionsURL, source: .user)

        let trimmedExample = example.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhonetic = phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = DictionaryEntry(
            wordType: wordType.trimmingCharacters(in: .whitespacesAndNewlines),
            definition: definition.trimmingCharacters(in: .whitespacesAndNewlines),
            example: trimmedExample.isEmpty ? nil : trimmedExample,
            phonetic: trimmedPhonetic.isEmpty ? nil : trimmedPhonetic,
            source: .user
        )
        definitions.append((word, entry))
        userDefinitions = definitions
        Self.saveDefinitionsFile(definitions, at: Self.userDefinitionsURL, includeExampleAndPhonetic: true)

        let entries = self.definitions(for: word)
        let newIndex = entries.firstIndex { $0.id == entry.id } ?? 0
        return (entries, newIndex)
    }

    func deleteDefinition(id: UUID, word: String) -> [DictionaryEntry] {
        var user = userDefinitions ?? Self.loadDefinitionsFile(at: Self.userDefinitionsURL, source: .user)
        var downloaded = downloadedDefinitions ?? Self.loadDefinitionsFile(at: Self.downloadedDefinitionsURL, source: .downloaded)

        if user.contains(where: { $0.entry.id == id }) {
            user.removeAll { $0.entry.id == id }
            userDefinitions = user
            Self.saveDefinitionsFile(user, at: Self.userDefinitionsURL, includeExampleAndPhonetic: true)
        } else if let index = downloaded.firstIndex(where: { $0.entry.id == id }) {
            // The in-memory list can hold session-only downloads that were
            // never saved (see "Save Downloaded Definitions Locally"), so
            // remove just this record from the file instead of rewriting it
            // from memory.
            let removed = downloaded.remove(at: index)
            downloadedDefinitions = downloaded
            Self.removeDownloadedRecord(word: removed.word, entry: removed.entry)
        }

        return definitions(for: word)
    }

    private nonisolated static func removeDownloadedRecord(word: String, entry: DictionaryEntry) {
        var persisted = loadDefinitionsFile(at: downloadedDefinitionsURL, source: .downloaded)
        guard let index = persisted.firstIndex(where: {
            $0.word.lowercased() == word.lowercased() &&
            $0.entry.wordType == entry.wordType &&
            $0.entry.definition == entry.definition &&
            $0.entry.example == entry.example &&
            $0.entry.phonetic == entry.phonetic
        }) else { return }

        persisted.remove(at: index)
        saveDefinitionsFile(persisted, at: downloadedDefinitionsURL, includeExampleAndPhonetic: true)
    }

    // MARK: - Downloading definitions

    /// The online dictionaries definitions can come from, in the order they're
    /// tried. The first two are both derived from Wiktionary but served by
    /// unrelated hosts, so one going down doesn't take the other with it;
    /// `dictionaryAPIDev` is the original source and stays as a last resort.
    private enum DefinitionProvider: CaseIterable {
        case freeDictionary
        case wiktionary
        case dictionaryAPIDev

        /// Only one provider serves pronunciation recordings, so the others
        /// must not be allowed to cache "this word has no audio".
        var servesPronunciationAudio: Bool { self == .dictionaryAPIDev }

        func endpoint(for encodedWord: String) -> URL? {
            switch self {
            case .freeDictionary:
                return URL(string: "https://freedictionaryapi.com/api/v1/entries/en/\(encodedWord)")
            case .wiktionary:
                return URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(encodedWord)")
            case .dictionaryAPIDev:
                return URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encodedWord)")
            }
        }
    }

    /// A definition normalised out of whichever provider answered, ready to be
    /// turned into a `DictionaryEntry`.
    private struct FetchedDefinition {
        let wordType: String
        let definition: String
        let example: String?
        let phonetic: String?
    }

    private struct FetchedWord {
        let definitions: [FetchedDefinition]
        let audioURL: URL?
    }

    private enum ProviderOutcome {
        case success(FetchedWord)
        /// The provider answered, but its dictionary has no such word.
        case noEntry
        /// The provider couldn't be reached, or sent back something unusable.
        case unreachable
    }

    /// How long a single provider gets to answer. Without a bound, one
    /// unresponsive host stalls the whole chain — the outage this fallback
    /// chain was built for hung for roughly twenty seconds per request.
    private static let requestTimeout: TimeInterval = 10

    /// Wikimedia asks API clients to identify themselves, and
    /// freedictionaryapi.com turns away some generic library user agents.
    private static let userAgent = "RandomWords/1.0 (iOS dictionary lookup)"

    /// Runs a GET and maps the status onto `DefinitionDownloadError`: 404 is
    /// the dictionary saying it has no such word, a permanent answer, while
    /// any other non-200 is treated as a transient server problem.
    private nonisolated static func fetchJSON(from url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DefinitionDownloadError.badResponse
        }
        if httpResponse.statusCode == 404 {
            throw DefinitionDownloadError.notFound
        }
        guard httpResponse.statusCode == 200 else {
            throw DefinitionDownloadError.badResponse
        }

        return data
    }

    private nonisolated static func trimmedOrNil(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Squeezes newlines, runs of spaces and the wide spaces Wiktionary pads
    /// glosses with down to single spaces, so a definition or example reads as
    /// one line the way the rest of the app's entries do.
    private nonisolated static func singleLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    // MARK: Provider responses

    /// `freedictionaryapi.com` — Wiktionary's data already parsed into parts of
    /// speech, senses, examples and IPA, which is the shape this app wants.
    private struct FreeDictionaryResponse: Decodable {
        struct Entry: Decodable {
            struct Pronunciation: Decodable {
                let type: String?
                let text: String?
            }
            struct Sense: Decodable {
                let definition: String?
                let examples: [String]?
            }
            let partOfSpeech: String?
            let pronunciations: [Pronunciation]?
            let senses: [Sense]?
        }
        let entries: [Entry]?
    }

    /// Wikimedia's own definition endpoint, keyed by language code. Definitions
    /// arrive as HTML rather than plain text.
    private struct WiktionaryGroup: Decodable {
        struct Definition: Decodable {
            let definition: String?
            let examples: [String]?
        }
        let partOfSpeech: String?
        let language: String?
        let definitions: [Definition]?
    }

    private struct APIEntry: Decodable {
        struct Phonetic: Decodable {
            let text: String?
            let audio: String?
        }
        struct Meaning: Decodable {
            struct APIDefinition: Decodable {
                let definition: String
                let example: String?
            }
            let partOfSpeech: String?
            let definitions: [APIDefinition]
        }
        let phonetic: String?
        let phonetics: [Phonetic]?
        let meanings: [Meaning]

        // Homographs ("record" the noun vs. the verb) arrive as separate
        // entries with their own pronunciations.
        var resolvedPhonetic: String? {
            let candidates = [phonetic] + (phonetics ?? []).map { $0.text }
            return candidates
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }

        var resolvedAudioURL: URL? {
            (phonetics ?? [])
                .compactMap { $0.audio?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
                .flatMap { raw in
                    // The API occasionally returns protocol-relative URLs.
                    URL(string: raw.hasPrefix("//") ? "https:\(raw)" : raw)
                }
        }
    }

    // MARK: Provider parsing

    private nonisolated static func parseFreeDictionary(_ data: Data) throws -> FetchedWord {
        let response = try JSONDecoder().decode(FreeDictionaryResponse.self, from: data)

        var definitions: [FetchedDefinition] = []
        for entry in response.entries ?? [] {
            let wordType = abbreviatedWordType(entry.partOfSpeech ?? "")
            let phonetic = trimmedOrNil(
                (entry.pronunciations ?? [])
                    .first { $0.type?.lowercased() == "ipa" }?
                    .text
            )

            // Only the top-level senses are kept. Their subsenses are narrower
            // restatements of the same meaning, and a word like "run" has well
            // over a hundred of them to page through.
            for sense in entry.senses ?? [] {
                guard let text = trimmedOrNil(sense.definition) else { continue }
                definitions.append(FetchedDefinition(
                    wordType: wordType,
                    definition: text,
                    example: singleLine(sense.examples?.first),
                    phonetic: phonetic
                ))
            }
        }

        return FetchedWord(definitions: definitions, audioURL: nil)
    }

    private nonisolated static func parseWiktionary(_ data: Data) throws -> FetchedWord {
        let response = try JSONDecoder().decode([String: [WiktionaryGroup]].self, from: data)

        // The "en" bucket also carries Translingual sections — ISO codes and
        // symbols that happen to be spelled the same — which aren't English
        // definitions at all.
        let groups = (response["en"] ?? []).filter { $0.language == "English" }

        var definitions: [FetchedDefinition] = []
        for group in groups {
            let wordType = abbreviatedWordType(group.partOfSpeech ?? "")
            for definition in group.definitions ?? [] {
                guard let text = plainText(fromHTML: definition.definition) else { continue }
                definitions.append(FetchedDefinition(
                    wordType: wordType,
                    definition: text,
                    example: plainText(fromHTML: definition.examples?.first),
                    phonetic: nil
                ))
            }
        }

        return FetchedWord(definitions: definitions, audioURL: nil)
    }

    private nonisolated static func parseDictionaryAPIDev(_ data: Data) throws -> FetchedWord {
        let apiEntries = try JSONDecoder().decode([APIEntry].self, from: data)

        var definitions: [FetchedDefinition] = []
        for apiEntry in apiEntries {
            let phonetic = apiEntry.resolvedPhonetic
            for meaning in apiEntry.meanings {
                let wordType = abbreviatedWordType(meaning.partOfSpeech ?? "")
                for apiDefinition in meaning.definitions {
                    guard let text = trimmedOrNil(apiDefinition.definition) else { continue }
                    definitions.append(FetchedDefinition(
                        wordType: wordType,
                        definition: text,
                        example: trimmedOrNil(apiDefinition.example),
                        phonetic: phonetic
                    ))
                }
            }
        }

        return FetchedWord(
            definitions: definitions,
            audioURL: apiEntries.compactMap(\.resolvedAudioURL).first
        )
    }

    /// Turns a Wiktionary definition into displayable text. A sense's subsenses
    /// are nested inside its HTML as an `<ol>` list *and* repeated as their own
    /// entries in `definitions`, so the list is cut off rather than flattened
    /// into the parent's text.
    private nonisolated static func plainText(fromHTML html: String?) -> String? {
        guard var markup = html else { return nil }

        if let listStart = markup.range(of: "<ol") {
            markup = String(markup[markup.startIndex..<listStart.lowerBound])
        }

        var stripped = ""
        var insideTag = false
        for character in markup {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { stripped.append(character) }
            }
        }

        // "&amp;" is unescaped last so that an already-escaped entity such as
        // "&amp;lt;" isn't decoded a second time into a stray "<".
        let entities = [
            ("&nbsp;", "\u{00A0}"), ("&quot;", "\""), ("&apos;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "…"), ("&amp;", "&")
        ]
        var text = singleLine(stripped) ?? ""
        for (entity, replacement) in entities where text.contains(entity) {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        return trimmedOrNil(text)
    }

    // MARK: Provider chain

    private nonisolated static func fetch(word: String, from provider: DefinitionProvider) async throws -> FetchedWord {
        guard let encodedWord = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = provider.endpoint(for: encodedWord) else {
            throw DefinitionDownloadError.notFound
        }

        let data = try await fetchJSON(from: url)

        let fetched: FetchedWord
        switch provider {
        case .freeDictionary: fetched = try parseFreeDictionary(data)
        case .wiktionary: fetched = try parseWiktionary(data)
        case .dictionaryAPIDev: fetched = try parseDictionaryAPIDev(data)
        }

        // Some providers answer 200 with an empty body for an unknown word
        // instead of 404; either way it's a definitive "no", not a retry.
        guard !fetched.definitions.isEmpty else {
            throw DefinitionDownloadError.notFound
        }
        return fetched
    }

    private nonisolated static func attempt(word: String, from provider: DefinitionProvider) async throws -> ProviderOutcome {
        do {
            return .success(try await fetch(word: word, from: provider))
        } catch DefinitionDownloadError.notFound {
            return .noEntry
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            return .unreachable
        }
    }

    /// Asks each dictionary in turn and returns the first real answer.
    ///
    /// A provider that replies "no such word" is out of the running for good —
    /// it won't have the word a second time either. One that can't be reached
    /// (offline, server error, timeout, unparseable response) is remembered and
    /// given exactly one more turn, in the same order, once the others have had
    /// theirs. The retries are invisible to the caller, which keeps showing its
    /// loading indicator until the chain is exhausted.
    private nonisolated static func fetchFromProviders(word: String) async throws -> (provider: DefinitionProvider, result: FetchedWord) {
        var unreachable: [DefinitionProvider] = []

        for provider in DefinitionProvider.allCases {
            switch try await attempt(word: word, from: provider) {
            case .success(let result): return (provider, result)
            case .noEntry: continue
            case .unreachable: unreachable.append(provider)
            }
        }

        for provider in unreachable {
            if case .success(let result) = try await attempt(word: word, from: provider) {
                return (provider, result)
            }
        }

        // If even one dictionary was able to say it doesn't have the word,
        // that's the more useful thing to tell the user — a host being down
        // shouldn't turn every unknown word into "check your connection".
        // Only when nothing could be reached at all is this a network problem.
        if unreachable.count < DefinitionProvider.allCases.count {
            throw DefinitionDownloadError.notFound
        }
        throw DefinitionDownloadError.badResponse
    }

    func downloadDefinitions(for word: String) async throws -> [DictionaryEntry] {
        let (provider, fetched) = try await Self.fetchFromProviders(word: word)

        // Remember the pronunciation URL from this same response (in memory
        // only) so tapping the speaker button doesn't hit the API again. When
        // a provider that doesn't serve audio answered, leave the cache alone
        // rather than recording a "no audio" it can't actually vouch for.
        if provider.servesPronunciationAudio {
            pronunciationURLCache[word.lowercased()] = fetched.audioURL
        }

        let newDefinitions: [(word: String, entry: DictionaryEntry)] = fetched.definitions.map { definition in
            (word: word, entry: DictionaryEntry(
                wordType: definition.wordType,
                definition: definition.definition,
                example: definition.example,
                phonetic: definition.phonetic,
                source: .downloaded
            ))
        }

        var downloaded = downloadedDefinitions ?? Self.loadDefinitionsFile(at: Self.downloadedDefinitionsURL, source: .downloaded)
        downloaded.removeAll { $0.word.lowercased() == word.lowercased() }
        downloaded.append(contentsOf: newDefinitions)
        downloadedDefinitions = downloaded

        // With local saving off, downloads still show for this session but
        // are kept in memory only.
        let saveLocally = (UserDefaults.standard.object(forKey: "saveDownloadedDefinitionsLocally") as? Bool) ?? true
        if saveLocally {
            Self.saveDefinitionsFile(downloaded, at: Self.downloadedDefinitionsURL, includeExampleAndPhonetic: true)
        }

        return definitions(for: word)
    }

    /// Resolves the pronunciation audio URL for a word. Only `dictionaryapi.dev`
    /// serves recordings, so this asks it directly instead of walking the whole
    /// chain. The URL is cached in memory but, like all audio, never written to
    /// disk.
    func pronunciationAudioURL(for word: String) async throws -> URL? {
        let key = word.lowercased()
        if let cached = pronunciationURLCache[key] {
            return cached
        }

        do {
            let fetched = try await Self.fetch(word: word, from: .dictionaryAPIDev)
            pronunciationURLCache[key] = fetched.audioURL
            return fetched.audioURL
        } catch DefinitionDownloadError.notFound {
            // No entry at all means no recording either; remember that so the
            // speaker button stays hidden without asking again.
            pronunciationURLCache[key] = URL?.none
            return nil
        }
    }

    func deleteAllDownloadedDefinitions() {
        downloadedDefinitions = []
        try? FileManager.default.removeItem(at: Self.downloadedDefinitionsURL)
    }

    func deleteAllUserDefinitions() {
        userDefinitions = []
        try? FileManager.default.removeItem(at: Self.userDefinitionsURL)
    }

    private nonisolated static func abbreviatedWordType(_ partOfSpeech: String) -> String {
        switch partOfSpeech.lowercased() {
        case "noun": return "n."
        case "verb": return "v."
        case "adjective": return "a."
        case "adverb": return "adv."
        case "pronoun": return "pron."
        case "preposition": return "prep."
        case "conjunction": return "conj."
        case "interjection", "exclamation": return "interj."
        case "determiner": return "det."
        case "numeral", "number": return "num."
        case "article": return "art."
        case "particle": return "part."
        case "proper noun", "name": return "prop. n."
        // Wiktionary capitalises its parts of speech ("Proper noun"), so even
        // the ones without an abbreviation are lowercased to match the rest.
        default: return partOfSpeech.lowercased()
        }
    }

    // MARK: - Editable definitions persistence

    private nonisolated static var userDefinitionsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictionaries", isDirectory: true)
            .appendingPathComponent("userDefinitions.csv")
    }

    // The app bundle is read-only at runtime, so "Downloads" lives in the
    // Documents folder, mirroring the bundled Dictionaries/English layout.
    private nonisolated static var downloadedDefinitionsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Dictionaries", isDirectory: true)
            .appendingPathComponent("English", isDirectory: true)
            .appendingPathComponent("downloadedDefinitions.csv")
    }

    private nonisolated static func loadDefinitionsFile(at url: URL, source: DefinitionSource) -> [(word: String, entry: DictionaryEntry)] {
        guard let data = try? Data(contentsOf: url) else { return [] }

        var definitions: [(word: String, entry: DictionaryEntry)] = []

        for fields in parseCSVRecords(data) {
            guard fields.count >= 3 else { continue }

            let word = fields[0].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, word.lowercased() != "word" else { continue }

            let definition: String
            var example: String?
            var phonetic: String?

            if source != .bundled {
                // Downloaded and user files are only ever written by the app
                // with properly quoted fields, so extra columns are trustworthy.
                // Rows from before examples/phonetics existed have 3 fields.
                definition = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
                if fields.count > 3 {
                    let value = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
                    example = value.isEmpty ? nil : value
                }
                if fields.count > 4 {
                    let value = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
                    phonetic = value.isEmpty ? nil : value
                }
            } else {
                // Bundled files may contain unquoted commas in the
                // definition, so treat all trailing fields as part of it.
                definition = fields[2...]
                    .joined(separator: ",")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !definition.isEmpty else { continue }

            let entry = DictionaryEntry(
                wordType: fields[1].trimmingCharacters(in: .whitespaces),
                definition: definition,
                example: example,
                phonetic: phonetic,
                source: source
            )
            definitions.append((word, entry))
        }

        return definitions
    }

    private nonisolated static func saveDefinitionsFile(_ definitions: [(word: String, entry: DictionaryEntry)], at url: URL, includeExampleAndPhonetic: Bool = false) {
        var lines = [includeExampleAndPhonetic ? "word,pos,definition,example,phonetic" : "word,pos,definition"]
        for (word, entry) in definitions {
            var fields = [
                csvField(word),
                csvField(entry.wordType),
                csvField(entry.definition)
            ]
            if includeExampleAndPhonetic {
                fields.append(csvField(entry.example ?? ""))
                fields.append(csvField(entry.phonetic ?? ""))
            }
            lines.append(fields.joined(separator: ","))
        }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private nonisolated static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: - Bundled dictionary

    private nonisolated static func buildBundledIndex() -> [String: [DictionaryEntry]] {
        var index: [String: [DictionaryEntry]] = [:]

        for url in dictionaryFileURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }

            for fields in parseCSVRecords(data) {
                guard fields.count >= 3 else { continue }

                let word = fields[0].trimmingCharacters(in: .whitespaces)
                guard !word.isEmpty, word.lowercased() != "word" else { continue }

                let definition = fields[2...]
                    .joined(separator: ",")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !definition.isEmpty else { continue }

                let entry = DictionaryEntry(
                    wordType: fields[1].trimmingCharacters(in: .whitespaces),
                    definition: definition,
                    source: .bundled
                )
                index[word.lowercased(), default: []].append(entry)
            }
        }

        return index
    }

    private nonisolated static func dictionaryFileURLs() -> [URL] {
        if let urls = Bundle.main.urls(
            forResourcesWithExtension: "csv",
            subdirectory: "Bundled/Dictionaries/English"
        ), !urls.isEmpty {
            return urls
        }

        // Synchronized-folder resources may be flattened into the bundle root,
        // so identify dictionary files by their header row.
        guard let allCSVs = Bundle.main.urls(forResourcesWithExtension: "csv", subdirectory: nil) else {
            return []
        }

        return allCSVs.filter { url in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 32) else { return false }
            return String(decoding: head, as: UTF8.self).lowercased().hasPrefix("word,pos,definition")
        }
    }

    private nonisolated static func parseCSVRecords(_ data: Data) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var fieldBytes: [UInt8] = []
        var inQuotes = false

        let bytes = [UInt8](data)
        var i = 0

        func endField() {
            fields.append(String(decoding: fieldBytes, as: UTF8.self))
            fieldBytes.removeAll(keepingCapacity: true)
        }

        func endRecord() {
            endField()
            if !(fields.count == 1 && fields[0].isEmpty) {
                records.append(fields)
            }
            fields.removeAll(keepingCapacity: true)
        }

        while i < bytes.count {
            let byte = bytes[i]

            if inQuotes {
                if byte == UInt8(ascii: "\"") {
                    if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\"") {
                        fieldBytes.append(byte)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    fieldBytes.append(byte)
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inQuotes = true
                case UInt8(ascii: ","):
                    endField()
                case UInt8(ascii: "\r"):
                    if i + 1 < bytes.count, bytes[i + 1] == UInt8(ascii: "\n") {
                        i += 1
                    }
                    endRecord()
                case UInt8(ascii: "\n"):
                    endRecord()
                default:
                    fieldBytes.append(byte)
                }
            }

            i += 1
        }

        if !fieldBytes.isEmpty || !fields.isEmpty {
            endRecord()
        }

        return records
    }
}

/// Plays a word's pronunciation from the dictionary API. The audio bytes are
/// held in memory only for the duration of playback and never saved to disk.
@MainActor
final class PronunciationPlayer: ObservableObject {
    @Published private(set) var isLoading = false

    private var player: AVAudioPlayer?

    /// Returns a user-facing error message on failure, or `nil` on success.
    func play(word: String) async -> String? {
        guard !isLoading else { return nil }
        isLoading = true
        defer { isLoading = false }

        do {
            guard let audioURL = try await EnglishDictionaryStore.shared.pronunciationAudioURL(for: word) else {
                return "No pronunciation is available for \"\(word)\"."
            }

            let (data, response) = try await URLSession.shared.data(from: audioURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return "Couldn't load the pronunciation for \"\(word)\"."
            }

            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)

            let player = try AVAudioPlayer(data: data)
            self.player = player
            player.play()
            return nil
        } catch is DefinitionDownloadError {
            return "Couldn't load the pronunciation for \"\(word)\"."
        } catch {
            return "Couldn't play the pronunciation. Check your internet connection."
        }
    }
}

struct WordDefinitionView: View {
    /// The words available to inspect. When more than one is present a picker
    /// row is shown so the user can switch between them; `selectedWord` tracks
    /// which one's definitions are currently displayed.
    let words: [String]
    @State private var selectedWord: String

    init(word: String) {
        self.words = [word]
        _selectedWord = State(initialValue: word)
    }

    init(words: [String]) {
        let cleaned = words.isEmpty ? [""] : words
        self.words = cleaned
        _selectedWord = State(initialValue: cleaned[0])
    }

    @State private var entries: [DictionaryEntry]?
    @State private var currentIndex = 0
    @State private var showingAddSheet = false
    @State private var showingDeleteAlert = false
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var autoDownloadFailed = false
    @State private var pronunciationError: String?
    @State private var hasPronunciationAudio = false
    @StateObject private var pronunciationPlayer = PronunciationPlayer()

    @AppStorage("autoDownloadWordDefinitions") private var autoDownloadDefinitions = true

    private var showsDownloadButton: Bool {
        !autoDownloadDefinitions || autoDownloadFailed
    }

    private var currentEntry: DictionaryEntry? {
        guard let entries, !entries.isEmpty else { return nil }
        return entries[min(currentIndex, entries.count - 1)]
    }

    // Prefer the current entry's own pronunciation (homographs can differ),
    // falling back to any downloaded one so bundled/user entries show it too.
    private var displayedPhonetic: String? {
        currentEntry?.phonetic ?? entries?.compactMap(\.phonetic).first
    }

    private func showPreviousDefinition() {
        guard let entries, !entries.isEmpty, currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func showNextDefinition() {
        guard let entries, currentIndex < entries.count - 1 else { return }
        currentIndex += 1
    }

    private func sourceBadge(for entry: DictionaryEntry) -> String? {
        switch entry.source {
        case .user: return "Your definition"
        case .downloaded: return "Downloaded"
        case .bundled: return nil
        }
    }

    /// A horizontally-scrollable row of the currently displayed words. Tapping
    /// one shows its definitions above. Shown only when multiple words are
    /// displayed.
    private var wordPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, pickerWord in
                    let isSelected = pickerWord == selectedWord
                    Button {
                        selectedWord = pickerWord
                    } label: {
                        Text(pickerWord)
                            .font(.subheadline)
                            .fontWeight(isSelected ? .semibold : .regular)
                            .foregroundColor(isSelected ? .white : .primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(
                                    isSelected
                                        ? Color.accentColor
                                        : Color.secondary.opacity(0.15)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 12)
    }

    /// The selected word's title, pronunciation, definition and the definition
    /// navigation arrows. Kept separate from the word picker so the swipe-to-
    /// navigate gesture can be scoped to this area alone.
    private var definitionContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(selectedWord)
                        .font(.largeTitle)
                        .bold()
                        .multilineTextAlignment(.center)

                    if hasPronunciationAudio {
                        Button {
                            pronounceWord()
                        } label: {
                            // Keep the icon in the layout (just hidden) while
                            // loading so its baseline/size stay fixed and the
                            // spinner sits exactly where the icon was.
                            Image(systemName: "speaker.wave.2.circle.fill")
                                .font(.title)
                                .opacity(pronunciationPlayer.isLoading ? 0 : 1)
                                .overlay {
                                    if pronunciationPlayer.isLoading {
                                        ProgressView()
                                    }
                                }
                        }
                        .disabled(pronunciationPlayer.isLoading)
                        .accessibilityLabel("Pronounce \(selectedWord)")
                    }
                }

                if let phonetic = displayedPhonetic {
                    Text(phonetic)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)

            if let entries {
                if let entry = currentEntry {
                    if !entry.wordType.isEmpty {
                        Text(entry.wordType)
                            .font(.title3)
                            .italic()
                            .foregroundColor(.secondary)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(entry.definition)
                                .font(.body)

                            if let example = entry.example {
                                Text("“\(example)”")
                                    .font(.body)
                                    .italic()
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 16)
                    }
                    .scrollBounceBehavior(.basedOnSize)

                    if let badge = sourceBadge(for: entry) {
                        Text(badge)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .padding(.bottom, entries.count > 1 ? 0 : 24)
                    }

                    if entries.count > 1 {
                        HStack(spacing: 24) {
                            Button {
                                showPreviousDefinition()
                            } label: {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.title)
                            }
                            .disabled(currentIndex == 0)

                            Text("\(currentIndex + 1) of \(entries.count)")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .monospacedDigit()

                            Button {
                                showNextDefinition()
                            } label: {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.title)
                            }
                            .disabled(currentIndex >= entries.count - 1)
                        }
                        .padding(.bottom, 24)
                    }
                } else {
                    Spacer()

                    if isDownloading {
                        ProgressView("Downloading definitions…")
                    } else {
                        Text("No definition found")
                            .foregroundColor(.gray)

                        Button {
                            downloadDefinitions()
                        } label: {
                            Label("Download definitions", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Spacer()
                }
            } else {
                Spacer()
                ProgressView("Loading definitions…")
                Spacer()
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                definitionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { value in
                                // Only react to mostly-horizontal swipes so vertical
                                // scrolling and sheet dismissal keep working. This
                                // gesture is scoped to the definition area only, so
                                // scrolling the word picker row below doesn't change
                                // the current definition.
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                if value.translation.width < 0 {
                                    showNextDefinition()
                                } else {
                                    showPreviousDefinition()
                                }
                            }
                    )

                if words.count > 1 {
                    wordPicker
                }
            }
            .padding(.top, 16)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isDownloading {
                        ProgressView()
                    } else if showsDownloadButton {
                        Button {
                            downloadDefinitions()
                        } label: {
                            Image(systemName: "arrow.down.circle")
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if currentEntry?.isDeletable == true {
                            Button(role: .destructive) {
                                showingDeleteAlert = true
                            } label: {
                                Image(systemName: "trash")
                            }
                        }

                        Button {
                            showingAddSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
        }
        .alert("Download Failed", isPresented: Binding(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        .alert("Pronunciation Unavailable", isPresented: Binding(
            get: { pronunciationError != nil },
            set: { if !$0 { pronunciationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(pronunciationError ?? "")
        }
        .sheet(isPresented: $showingAddSheet) {
            AddDefinitionView(word: selectedWord) { wordType, definition, example, phonetic in
                addDefinition(wordType: wordType, definition: definition, example: example, phonetic: phonetic)
            }
        }
        .alert("Delete Definition", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                deleteCurrentDefinition()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this definition of \"\(selectedWord)\"?")
        }
        .task(id: selectedWord) {
            // Reset per-word state so switching words in the picker doesn't
            // briefly show the previous word's definitions or audio button.
            entries = nil
            currentIndex = 0
            hasPronunciationAudio = false
            autoDownloadFailed = false

            let loaded = await EnglishDictionaryStore.shared.definitions(for: selectedWord)
            entries = loaded
            // When an auto-download runs it primes the audio cache, so let its
            // completion refresh availability; otherwise resolve it here.
            let didStartDownload = await autoDownloadIfNeeded(existingEntries: loaded)
            if !didStartDownload {
                await refreshPronunciationAvailability()
            }
        }
    }

    /// Automatically fetches online definitions when the setting is enabled,
    /// the word hasn't been downloaded before, and the device is online.
    /// Returns `true` if a download was started.
    private func autoDownloadIfNeeded(existingEntries: [DictionaryEntry]) async -> Bool {
        guard autoDownloadDefinitions, !isDownloading else { return false }
        guard !existingEntries.contains(where: { $0.source == .downloaded }) else { return false }
        guard await NetworkReachability.hasConnection() else { return false }
        downloadDefinitions(automatically: true)
        return true
    }

    private func addDefinition(wordType: String, definition: String, example: String, phonetic: String) {
        Task {
            let result = await EnglishDictionaryStore.shared.addUserDefinition(
                word: selectedWord,
                wordType: wordType,
                definition: definition,
                example: example,
                phonetic: phonetic
            )
            entries = result.entries
            currentIndex = result.newIndex
        }
    }

    /// Determines whether the word has playable audio so the speaker button is
    /// only shown when something can actually be pronounced. Uses the in-memory
    /// cache when available, otherwise resolves the URL from the API once.
    private func refreshPronunciationAvailability() async {
        let audioURL = try? await EnglishDictionaryStore.shared.pronunciationAudioURL(for: selectedWord)
        hasPronunciationAudio = (audioURL ?? nil) != nil
    }

    private func pronounceWord() {
        Task {
            if let message = await pronunciationPlayer.play(word: selectedWord) {
                pronunciationError = message
            }
        }
    }

    private func deleteCurrentDefinition() {
        guard let entry = currentEntry, entry.isDeletable else { return }

        Task {
            let updated = await EnglishDictionaryStore.shared.deleteDefinition(id: entry.id, word: selectedWord)
            entries = updated
            currentIndex = min(currentIndex, max(updated.count - 1, 0))
        }
    }

    private func downloadDefinitions(automatically: Bool = false) {
        isDownloading = true
        downloadError = nil

        Task {
            var didDownload = false

            do {
                let updated = try await EnglishDictionaryStore.shared.downloadDefinitions(for: selectedWord)
                entries = updated
                if !automatically {
                    currentIndex = updated.firstIndex { $0.source == .downloaded } ?? 0
                }
                autoDownloadFailed = false
                didDownload = true
            } catch DefinitionDownloadError.notFound {
                if automatically {
                    autoDownloadFailed = true
                } else {
                    downloadError = "No definitions found online for \"\(selectedWord)\"."
                }
            } catch {
                if automatically {
                    autoDownloadFailed = true
                } else {
                    downloadError = "Download failed. Check your internet connection."
                }
            }
            isDownloading = false

            // Audio comes from a different provider than the definitions may
            // have, so resolving it can be a second request. It runs only once
            // the download indicator is cleared — the definitions are already
            // on screen and it's just the speaker button that's still pending.
            if didDownload {
                await refreshPronunciationAvailability()
            }
        }
    }
}

struct AddDefinitionView: View {
    let word: String
    let onSave: (_ wordType: String, _ definition: String, _ example: String, _ phonetic: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var wordType = ""
    @State private var definitionText = ""
    @State private var exampleText = ""
    @State private var phoneticText = ""

    private var trimmedDefinition: String {
        definitionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Word type (optional)") {
                    TextField("e.g. n., a., v.", text: $wordType)
                }

                Section("Definition") {
                    TextEditor(text: $definitionText)
                        .frame(minHeight: 120)
                }

                Section("Example (optional)") {
                    TextField("e.g. The word fit the sentence perfectly.", text: $exampleText, axis: .vertical)
                }

                Section("Phonetic transcription (optional)") {
                    TextField("e.g. /ˈwɜːd/", text: $phoneticText)
                }
            }
            .navigationTitle(word)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(wordType, trimmedDefinition, exampleText, phoneticText)
                        dismiss()
                    }
                    .disabled(trimmedDefinition.isEmpty)
                }
            }
        }
    }
}
