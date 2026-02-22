import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let csvDeleted = Notification.Name("csvDeleted")
}

struct EditCSVView: View {

    let csvFileName: String
    let scrollToWord: String?

    @State private var words: [String] = []
    @State private var originalOrder: [String] = []
    @State private var displayedIndices: [Int] = []

    @State private var newWord: String = ""
    @State private var highlightedWord: String?

    @State private var sortMode: SortMode = .reverseOriginal
    @State private var showingDeleteConfirmation = false

    @Environment(\.dismiss) private var dismiss

    enum SortMode: String, CaseIterable {
        case original = "CSV Order"
        case reverseOriginal = "Reverse CSV Order"
        case alphabetical = "Alphabetical"
        case reverseAlphabetical = "Reverse Alphabetical"
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {

                Section(header: Text("Add New Word")) {
                    HStack {
                        TextField("New word", text: $newWord)
                            .textInputAutocapitalization(.never)

                        Button("Add") {
                            addWord()
                        }
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Section {
                    ForEach(words.indices, id: \.self) { index in
                        TextField("Word", text: $words[index])
                            .id(index)
                            .onChange(of: words[index]) { _ in
                                updateOriginalOrder(fromDisplayedIndex: index)
                            }
                            .listRowBackground(
                                highlightedWord == words[index]
                                ? Color.gray.opacity(0.5)
                                : Color.clear
                            )
                    }
                    .onDelete(perform: deleteWords)
                }

                Section {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Text("Delete CSV File")
                    }
                }
            }
            .navigationTitle("\(csvFileName).csv")
            .toolbar {

                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            Button {
                                changeSortMode(to: mode)
                            } label: {
                                if sortMode == mode {
                                    Label(mode.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(mode.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {

                    ShareLink(
                        item: getDocumentsURL(),
                        preview: SharePreview("\(csvFileName).csv")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .onTapGesture {
                        saveCSV()
                    }

                    Button("Save") {
                        saveCSV()
                        dismiss()
                    }
                }
            }
            .alert("Delete CSV File?",
                   isPresented: $showingDeleteConfirmation) {

                Button("Delete", role: .destructive) {
                    deleteCSVFile()
                }

                Button("Cancel", role: .cancel) { }

            } message: {
                Text("This will permanently delete this CSV file.")
            }
            .onAppear {
                ensureFileExistsInDocuments()
                loadCSV()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if let word = scrollToWord,
                       let index = words.firstIndex(of: word) {
                        highlightedWord = word
                        withAnimation {
                            proxy.scrollTo(index, anchor: .center)
                        }

                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            highlightedWord = nil
                        }
                    }
                }
            }
            // ✅ FIX: If you navigate back after deleting, onDisappear was re-saving and recreating the CSV.
            // Only auto-save if the file still exists.
            .onDisappear {
                let url = getDocumentsURL()
                if FileManager.default.fileExists(atPath: url.path) {
                    saveCSV()
                }
            }
        }
    }

    private func deleteCSVFile() {
        let fileURL = getDocumentsURL()

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }

            NotificationCenter.default.post(
                name: .csvDeleted,
                object: csvFileName
            )

            dismiss()

        } catch {
            print("Failed to delete CSV: \(error)")
        }
    }

    private func ensureFileExistsInDocuments() {
        let docURL = getDocumentsURL()

        if !FileManager.default.fileExists(atPath: docURL.path) {
            if let bundlePath = Bundle.main.path(forResource: csvFileName, ofType: "csv") {
                try? FileManager.default.copyItem(atPath: bundlePath, toPath: docURL.path)
            }
        }
    }

    private func loadCSV() {
        let fileURL = getDocumentsURL()

        if let content = try? String(contentsOf: fileURL) {
            originalOrder = content
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }

        applyCurrentSort()
    }

    private func saveCSV() {
        let fileURL = getDocumentsURL()
        let content = originalOrder.joined(separator: "\n")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func changeSortMode(to mode: SortMode) {
        sortMode = mode
        applyCurrentSort()
    }

    private func applyCurrentSort() {
        switch sortMode {
        case .original:
            displayedIndices = Array(originalOrder.indices)

        case .reverseOriginal:
            displayedIndices = Array(originalOrder.indices.reversed())

        case .alphabetical:
            displayedIndices = originalOrder.indices.sorted {
                originalOrder[$0].localizedCaseInsensitiveCompare(originalOrder[$1]) == .orderedAscending
            }

        case .reverseAlphabetical:
            displayedIndices = originalOrder.indices.sorted {
                originalOrder[$0].localizedCaseInsensitiveCompare(originalOrder[$1]) == .orderedDescending
            }
        }

        words = displayedIndices.map { originalOrder[$0] }
    }

    private func updateOriginalOrder(fromDisplayedIndex displayedIndex: Int) {
        guard displayedIndices.indices.contains(displayedIndex) else { return }
        let originalIndex = displayedIndices[displayedIndex]
        guard originalOrder.indices.contains(originalIndex) else { return }
        originalOrder[originalIndex] = words[displayedIndex]
    }

    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(csvFileName).csv")
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        originalOrder.append(trimmed)
        newWord = ""
        applyCurrentSort()
        saveCSV()
    }

    private func deleteWords(at offsets: IndexSet) {
        let originalIndicesToRemove = offsets
            .compactMap { displayedIndices.indices.contains($0) ? displayedIndices[$0] : nil }
            .sorted(by: >)

        for idx in originalIndicesToRemove {
            if originalOrder.indices.contains(idx) {
                originalOrder.remove(at: idx)
            }
        }

        applyCurrentSort()
        saveCSV()
    }
}
