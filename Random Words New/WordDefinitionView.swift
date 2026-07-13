import SwiftUI

nonisolated struct DictionaryEntry: Identifiable, Sendable {
    let id = UUID()
    let wordType: String
    let definition: String
    let isUserMade: Bool
}

struct DefinitionTarget: Identifiable {
    let word: String
    var id: String { word }
}

actor EnglishDictionaryStore {
    static let shared = EnglishDictionaryStore()

    private var bundledIndex: [String: [DictionaryEntry]]?
    private var userDefinitions: [(word: String, entry: DictionaryEntry)]?

    func definitions(for word: String) -> [DictionaryEntry] {
        let key = word.lowercased()

        if userDefinitions == nil {
            userDefinitions = Self.loadUserDefinitions()
        }
        if bundledIndex == nil {
            bundledIndex = Self.buildBundledIndex()
        }

        let userEntries = (userDefinitions ?? [])
            .filter { $0.word.lowercased() == key }
            .map { $0.entry }

        return userEntries + (bundledIndex?[key] ?? [])
    }

    func addUserDefinition(word: String, wordType: String, definition: String) -> (entries: [DictionaryEntry], newIndex: Int) {
        var definitions = userDefinitions ?? Self.loadUserDefinitions()

        let entry = DictionaryEntry(
            wordType: wordType.trimmingCharacters(in: .whitespacesAndNewlines),
            definition: definition.trimmingCharacters(in: .whitespacesAndNewlines),
            isUserMade: true
        )
        definitions.append((word, entry))
        userDefinitions = definitions
        saveUserDefinitions()

        let entries = self.definitions(for: word)
        let newIndex = entries.firstIndex { $0.id == entry.id } ?? 0
        return (entries, newIndex)
    }

    func deleteUserDefinition(id: UUID, word: String) -> [DictionaryEntry] {
        var definitions = userDefinitions ?? Self.loadUserDefinitions()
        definitions.removeAll { $0.entry.id == id }
        userDefinitions = definitions
        saveUserDefinitions()

        return self.definitions(for: word)
    }

    // MARK: - User definitions persistence

    private nonisolated static var userDefinitionsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictionaries", isDirectory: true)
            .appendingPathComponent("userDefinitions.csv")
    }

    private nonisolated static func loadUserDefinitions() -> [(word: String, entry: DictionaryEntry)] {
        guard let data = try? Data(contentsOf: userDefinitionsURL) else { return [] }

        var definitions: [(word: String, entry: DictionaryEntry)] = []

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
                isUserMade: true
            )
            definitions.append((word, entry))
        }

        return definitions
    }

    private func saveUserDefinitions() {
        guard let userDefinitions else { return }

        var lines = ["word,pos,definition"]
        for (word, entry) in userDefinitions {
            lines.append([
                Self.csvField(word),
                Self.csvField(entry.wordType),
                Self.csvField(entry.definition)
            ].joined(separator: ","))
        }

        let url = Self.userDefinitionsURL
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
                    isUserMade: false
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

    private var currentEntry: DictionaryEntry? {
        guard let entries, !entries.isEmpty else { return nil }
        return entries[min(currentIndex, entries.count - 1)]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(word)
                    .font(.largeTitle)
                    .bold()
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let entries {
                    if let entry = currentEntry {
                        if entry.isUserMade {
                            Text("Your definition")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }

                        if !entry.wordType.isEmpty {
                            Text(entry.wordType)
                                .font(.title3)
                                .italic()
                                .foregroundColor(.secondary)
                        }

                        ScrollView {
                            Text(entry.definition)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 24)
                                .padding(.bottom, 16)
                        }

                        if entries.count > 1 {
                            HStack(spacing: 24) {
                                Button {
                                    currentIndex -= 1
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
                                    currentIndex += 1
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
                        Text("No definition found")
                            .foregroundColor(.gray)
                        Spacer()
                    }
                } else {
                    Spacer()
                    ProgressView("Loading definitions…")
                    Spacer()
                }
            }
            .padding(.top, 16)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if currentEntry?.isUserMade == true {
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
        .sheet(isPresented: $showingAddSheet) {
            AddDefinitionView(word: word) { wordType, definition in
                addDefinition(wordType: wordType, definition: definition)
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
            entries = await EnglishDictionaryStore.shared.definitions(for: word)
        }
    }

    private func addDefinition(wordType: String, definition: String) {
        Task {
            let result = await EnglishDictionaryStore.shared.addUserDefinition(
                word: word,
                wordType: wordType,
                definition: definition
            )
            entries = result.entries
            currentIndex = result.newIndex
        }
    }

    private func deleteCurrentDefinition() {
        guard let entry = currentEntry, entry.isUserMade else { return }

        Task {
            let updated = await EnglishDictionaryStore.shared.deleteUserDefinition(id: entry.id, word: word)
            entries = updated
            currentIndex = min(currentIndex, max(updated.count - 1, 0))
        }
    }
}

struct AddDefinitionView: View {
    let word: String
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var wordType = ""
    @State private var definitionText = ""

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
                        onSave(wordType, trimmedDefinition)
                        dismiss()
                    }
                    .disabled(trimmedDefinition.isEmpty)
                }
            }
        }
    }
}
