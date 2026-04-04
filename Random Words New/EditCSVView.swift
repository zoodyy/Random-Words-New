import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let csvDeleted = Notification.Name("csvDeleted")
}

struct EditCSVView: View {

    let csvFileName: String
    let scrollToWord: String?

    @State private var originalOrder: [String] = []
    @State private var displayedIndices: [Int] = []

    @State private var newWord: String = ""
    @State private var highlightedOriginalIndex: Int?

    @State private var sortMode: SortMode = .reverseOriginal
    @State private var showingDeleteConfirmation = false
    @State private var wasDeleted = false

    @State private var visibleCount: Int = 0

    @Environment(\.dismiss) private var dismiss

    enum SortMode: String, CaseIterable {
        case original = "CSV Order"
        case reverseOriginal = "Reverse CSV Order"
        case alphabetical = "Alphabetical"
        case reverseAlphabetical = "Reverse Alphabetical"
    }

    private let pageSize = 150
    private let preloadThreshold = 20

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
                    ForEach(visibleDisplayedPositions, id: \.self) { displayedPosition in
                        editableRow(for: displayedPosition)
                            .id(displayedPosition)
                            .onAppear {
                                loadMoreIfNeeded(currentDisplayedPosition: displayedPosition)
                            }
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
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            saveCSV()
                        }
                    )

                    Button("Save") {
                        removeNewestDuplicates()
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
                scrollToRequestedWordIfNeeded(with: proxy)
            }
            .onDisappear {
                guard !wasDeleted else { return }

                let url = getDocumentsURL()
                if FileManager.default.fileExists(atPath: url.path) {
                    removeNewestDuplicates()
                    saveCSV()
                }
            }
        }
    }

    @ViewBuilder
    private func editableRow(for displayedPosition: Int) -> some View {
        if let originalIndex = originalIndex(forDisplayedPosition: displayedPosition) {
            TextField(
                "Word",
                text: Binding(
                    get: { originalOrder[safe: originalIndex] ?? "" },
                    set: { newValue in
                        guard originalOrder.indices.contains(originalIndex) else { return }
                        originalOrder[originalIndex] = newValue
                    }
                )
            )
            .listRowBackground(
                highlightedOriginalIndex == originalIndex
                ? Color.gray.opacity(0.5)
                : Color.clear
            )
        }
    }

    private var visibleDisplayedPositions: [Int] {
        Array(0..<min(visibleCount, displayedIndices.count))
    }

    private func originalIndex(forDisplayedPosition displayedPosition: Int) -> Int? {
        guard displayedIndices.indices.contains(displayedPosition) else { return nil }
        let originalIndex = displayedIndices[displayedPosition]
        guard originalOrder.indices.contains(originalIndex) else { return nil }
        return originalIndex
    }

    private func deleteCSVFile() {
        let fileURL = getDocumentsURL()

        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }

            wasDeleted = true

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
        } else {
            originalOrder = []
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

        visibleCount = min(pageSize, displayedIndices.count)
    }

    private func loadMoreIfNeeded(currentDisplayedPosition: Int) {
        guard currentDisplayedPosition >= visibleCount - preloadThreshold else { return }
        guard visibleCount < displayedIndices.count else { return }

        visibleCount = min(visibleCount + pageSize, displayedIndices.count)
    }

    private func scrollToRequestedWordIfNeeded(with proxy: ScrollViewProxy) {
        guard let word = scrollToWord else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let originalIndex = originalOrder.firstIndex(of: word),
                  let displayedPosition = displayedIndices.firstIndex(of: originalIndex) else {
                return
            }

            highlightedOriginalIndex = originalIndex

            if displayedPosition >= visibleCount {
                visibleCount = min(displayedPosition + pageSize, displayedIndices.count)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                withAnimation {
                    proxy.scrollTo(displayedPosition, anchor: .center)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    highlightedOriginalIndex = nil
                }
            }
        }
    }

    private func removeNewestDuplicates() {
        var seen = Set<String>()
        var deduplicatedReversed: [String] = []

        for word in originalOrder.reversed() {
            let trimmed = word.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                deduplicatedReversed.append(word)
                continue
            }

            if seen.contains(trimmed) {
                continue
            }

            seen.insert(trimmed)
            deduplicatedReversed.append(word)
        }

        originalOrder = deduplicatedReversed.reversed()
        applyCurrentSort()
    }

    private func getDocumentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(csvFileName).csv")
    }

    private func addWord() {
        let trimmed = newWord.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        let alreadyExists = originalOrder.contains {
            $0.trimmingCharacters(in: .whitespaces) == trimmed
        }
        guard !alreadyExists else {
            newWord = ""
            return
        }

        originalOrder.append(trimmed)
        newWord = ""
        applyCurrentSort()
        saveCSV()
    }

    private func deleteWords(at offsets: IndexSet) {
        let originalIndicesToRemove = offsets
            .compactMap { displayedPosition -> Int? in
                guard displayedIndices.indices.contains(displayedPosition) else { return nil }
                return displayedIndices[displayedPosition]
            }
            .sorted(by: >)

        for index in originalIndicesToRemove {
            if originalOrder.indices.contains(index) {
                originalOrder.remove(at: index)
            }
        }

        applyCurrentSort()
        saveCSV()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
