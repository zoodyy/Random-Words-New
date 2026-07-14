import SwiftUI
import Network

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
    let word: String
    var id: String { word }
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
        } else if downloaded.contains(where: { $0.entry.id == id }) {
            downloaded.removeAll { $0.entry.id == id }
            downloadedDefinitions = downloaded
            Self.saveDefinitionsFile(downloaded, at: Self.downloadedDefinitionsURL, includeExampleAndPhonetic: true)
        }

        return definitions(for: word)
    }

    // MARK: - Downloading definitions

    private struct APIEntry: Decodable {
        struct Phonetic: Decodable {
            let text: String?
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
    }

    func downloadDefinitions(for word: String) async throws -> [DictionaryEntry] {
        guard let encodedWord = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encodedWord)") else {
            throw DefinitionDownloadError.notFound
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DefinitionDownloadError.badResponse
        }
        if httpResponse.statusCode == 404 {
            throw DefinitionDownloadError.notFound
        }
        guard httpResponse.statusCode == 200 else {
            throw DefinitionDownloadError.badResponse
        }

        let apiEntries = try JSONDecoder().decode([APIEntry].self, from: data)

        var newDefinitions: [(word: String, entry: DictionaryEntry)] = []
        for apiEntry in apiEntries {
            let phonetic = apiEntry.resolvedPhonetic
            for meaning in apiEntry.meanings {
                let wordType = Self.abbreviatedWordType(meaning.partOfSpeech ?? "")
                for apiDefinition in meaning.definitions {
                    let text = apiDefinition.definition.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let example = apiDefinition.example?.trimmingCharacters(in: .whitespacesAndNewlines)
                    newDefinitions.append((word, DictionaryEntry(
                        wordType: wordType,
                        definition: text,
                        example: (example?.isEmpty == false) ? example : nil,
                        phonetic: phonetic,
                        source: .downloaded
                    )))
                }
            }
        }

        guard !newDefinitions.isEmpty else {
            throw DefinitionDownloadError.notFound
        }

        var downloaded = downloadedDefinitions ?? Self.loadDefinitionsFile(at: Self.downloadedDefinitionsURL, source: .downloaded)
        downloaded.removeAll { $0.word.lowercased() == word.lowercased() }
        downloaded.append(contentsOf: newDefinitions)
        downloadedDefinitions = downloaded
        Self.saveDefinitionsFile(downloaded, at: Self.downloadedDefinitionsURL, includeExampleAndPhonetic: true)

        return definitions(for: word)
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
        default: return partOfSpeech
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

struct WordDefinitionView: View {
    let word: String

    @State private var entries: [DictionaryEntry]?
    @State private var currentIndex = 0
    @State private var showingAddSheet = false
    @State private var showingDeleteAlert = false
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var autoDownloadFailed = false

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(word)
                        .font(.largeTitle)
                        .bold()
                        .multilineTextAlignment(.center)

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
            .padding(.top, 16)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        // Only react to mostly-horizontal swipes so vertical
                        // scrolling and sheet dismissal keep working.
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        if value.translation.width < 0 {
                            showNextDefinition()
                        } else {
                            showPreviousDefinition()
                        }
                    }
            )
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
        .sheet(isPresented: $showingAddSheet) {
            AddDefinitionView(word: word) { wordType, definition, example, phonetic in
                addDefinition(wordType: wordType, definition: definition, example: example, phonetic: phonetic)
            }
        }
        .alert("Delete Definition", isPresented: $showingDeleteAlert) {
            Button("Delete", role: .destructive) {
                deleteCurrentDefinition()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this definition of \"\(word)\"?")
        }
        .task {
            let loaded = await EnglishDictionaryStore.shared.definitions(for: word)
            entries = loaded
            await autoDownloadIfNeeded(existingEntries: loaded)
        }
    }

    /// Automatically fetches online definitions when the setting is enabled,
    /// the word hasn't been downloaded before, and the device is online.
    private func autoDownloadIfNeeded(existingEntries: [DictionaryEntry]) async {
        guard autoDownloadDefinitions, !isDownloading else { return }
        guard !existingEntries.contains(where: { $0.source == .downloaded }) else { return }
        guard await NetworkReachability.hasConnection() else { return }
        downloadDefinitions(automatically: true)
    }

    private func addDefinition(wordType: String, definition: String, example: String, phonetic: String) {
        Task {
            let result = await EnglishDictionaryStore.shared.addUserDefinition(
                word: word,
                wordType: wordType,
                definition: definition,
                example: example,
                phonetic: phonetic
            )
            entries = result.entries
            currentIndex = result.newIndex
        }
    }

    private func deleteCurrentDefinition() {
        guard let entry = currentEntry, entry.isDeletable else { return }

        Task {
            let updated = await EnglishDictionaryStore.shared.deleteDefinition(id: entry.id, word: word)
            entries = updated
            currentIndex = min(currentIndex, max(updated.count - 1, 0))
        }
    }

    private func downloadDefinitions(automatically: Bool = false) {
        isDownloading = true
        downloadError = nil

        Task {
            do {
                let updated = try await EnglishDictionaryStore.shared.downloadDefinitions(for: word)
                entries = updated
                if !automatically {
                    currentIndex = updated.firstIndex { $0.source == .downloaded } ?? 0
                }
                autoDownloadFailed = false
            } catch DefinitionDownloadError.notFound {
                if automatically {
                    autoDownloadFailed = true
                } else {
                    downloadError = "No definitions found online for \"\(word)\"."
                }
            } catch {
                if automatically {
                    autoDownloadFailed = true
                } else {
                    downloadError = "Download failed. Check your internet connection."
                }
            }
            isDownloading = false
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
