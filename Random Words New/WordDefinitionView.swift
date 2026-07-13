import SwiftUI

nonisolated struct DictionaryEntry: Sendable {
    let wordType: String
    let definition: String
}

struct DefinitionTarget: Identifiable {
    let word: String
    var id: String { word }
}

actor EnglishDictionaryStore {
    static let shared = EnglishDictionaryStore()

    private var index: [String: [DictionaryEntry]]?

    func definitions(for word: String) -> [DictionaryEntry] {
        if index == nil {
            index = Self.buildIndex()
        }
        return index?[word.lowercased()] ?? []
    }

    private nonisolated static func buildIndex() -> [String: [DictionaryEntry]] {
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
                    definition: definition
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

    var body: some View {
        VStack(spacing: 16) {
            Text(word)
                .font(.largeTitle)
                .bold()
                .multilineTextAlignment(.center)
                .padding(.top, 32)
                .padding(.horizontal, 24)

            if let entries {
                if entries.isEmpty {
                    Spacer()
                    Text("No definition found")
                        .foregroundColor(.gray)
                    Spacer()
                } else {
                    let entry = entries[min(currentIndex, entries.count - 1)]

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
                }
            } else {
                Spacer()
                ProgressView("Loading definitions…")
                Spacer()
            }
        }
        .task {
            entries = await EnglishDictionaryStore.shared.definitions(for: word)
        }
    }
}
