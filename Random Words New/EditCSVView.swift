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
    @State private var filteredDisplayedIndices: [Int] = []

    @State private var newWord: String = ""
    @State private var searchText: String = ""
    @State private var isSearchVisible = false
    @State private var highlightedOriginalIndex: Int?

    @State private var sortMode: SortMode = .reverseOriginal
    @State private var showingDeleteConfirmation = false
    @State private var wasDeleted = false

    // Only a window of rows is handed to the List. Rendering every row up to
    // the jump target made opening a big list take seconds (see focusRequestedWord).
    @State private var windowStart: Int = 0
    @State private var windowEnd: Int = 0

    @State private var hasLoaded = false
    @State private var pendingScrollPosition: Int?
    @State private var isJumpingToWord = false
    @State private var isExtendingWindowUpwards = false

    @State private var toastMessage: String?
    @State private var toastID = 0

    @State private var pendingUndo: [(index: Int, word: String)]?
    @State private var undoToastID = 0

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
                    VStack(spacing: 8) {
                        HStack {
                            TextField("New word", text: $newWord)
                                .textInputAutocapitalization(.never)

                            Button("Add") {
                                addWord()
                            }
                            .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                        }

                        if isSearchVisible {
                            TextField("Search words", text: $searchText)
                                .textInputAutocapitalization(.never)
                                .onChange(of: searchText) { _ in
                                    applySearchAndPagination()
                                }
                        }
                    }
                }

                Section {
                    ForEach(visibleDisplayedPositions, id: \.self) { displayedPosition in
                        editableRow(for: displayedPosition)
                            .id(displayedPosition)
                            .onAppear {
                                extendWindowIfNeeded(around: displayedPosition, with: proxy)
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
            .overlay(alignment: .top) {
                if pendingUndo != nil {
                    HStack(spacing: 6) {
                        Text("Word deleted")
                            .font(.footnote)
                            .foregroundColor(.gray)
                        Button("Undo") {
                            undoDelete()
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                    .padding(.top, 8)
                    .transition(.opacity)
                } else if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .padding(.top, 8)
                        .transition(.opacity)
                        .allowsHitTesting(false)
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

                    Button {
                        toggleSearch()
                    } label: {
                        Image(systemName: isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
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
                guard !hasLoaded else { return }
                hasLoaded = true

                ensureFileExistsInDocuments()
                loadCSV()
                focusRequestedWord()
                scrollToPendingPosition(with: proxy)
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
                        applySearchAndPagination(keepWindow: true)
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

    private var currentDisplayedIndices: [Int] {
        filteredDisplayedIndices
    }

    private var visibleDisplayedPositions: [Int] {
        let count = currentDisplayedIndices.count
        let start = min(windowStart, count)
        let end = min(max(windowEnd, start), count)
        return Array(start..<end)
    }

    private func originalIndex(forDisplayedPosition displayedPosition: Int) -> Int? {
        guard currentDisplayedIndices.indices.contains(displayedPosition) else { return nil }
        let originalIndex = currentDisplayedIndices[displayedPosition]
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
            if let bundleURL = BundledWordlists.url(named: csvFileName) {
                try? FileManager.default.copyItem(at: bundleURL, to: docURL)
            }
        }
    }

    private func loadCSV() {
        originalOrder = WordlistFile.words(named: csvFileName)
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

    private func applyCurrentSort(keepWindow: Bool = false) {
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

        applySearchAndPagination(keepWindow: keepWindow)
    }

    private func applySearchAndPagination(keepWindow: Bool = false) {
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedSearch.isEmpty {
            filteredDisplayedIndices = displayedIndices
        } else {
            filteredDisplayedIndices = displayedIndices.filter { index in
                guard originalOrder.indices.contains(index) else { return false }
                return originalOrder[index].localizedCaseInsensitiveContains(trimmedSearch)
            }
        }

        if keepWindow {
            setWindow(start: windowStart, end: max(windowEnd, windowStart + pageSize))
        } else {
            setWindow(start: 0, end: pageSize)
        }
    }

    private func setWindow(start: Int, end: Int) {
        let count = currentDisplayedIndices.count
        let clampedStart = max(0, min(start, max(count - 1, 0)))
        windowStart = count == 0 ? 0 : clampedStart
        windowEnd = min(max(end, windowStart), count)
    }

    private func extendWindowIfNeeded(around displayedPosition: Int, with proxy: ScrollViewProxy) {
        // Rows sliding past during the jump to a swiped-up word are not the user
        // scrolling, and treating them as such would page the window straight
        // back to the top of the list.
        guard !isJumpingToWord else { return }

        let count = currentDisplayedIndices.count

        if displayedPosition >= windowEnd - preloadThreshold, windowEnd < count {
            windowEnd = min(windowEnd + pageSize, count)
        }

        guard displayedPosition <= windowStart + preloadThreshold,
              windowStart > 0,
              !isExtendingWindowUpwards else {
            return
        }

        isExtendingWindowUpwards = true
        windowStart = max(0, windowStart - pageSize)

        // The rows just added sit above what the user is reading. Re-anchoring in
        // the same update keeps that row put — otherwise the list shoves it down
        // the screen and the rows now on top ask to page up again.
        proxy.scrollTo(displayedPosition, anchor: .top)

        DispatchQueue.main.async {
            isExtendingWindowUpwards = false
        }
    }

    /// Puts the swiped-up word on screen.
    ///
    /// The list only renders a window around the target rather than every row
    /// leading up to it: a word two thirds of the way into the 84k-line list
    /// used to hand the List ~58k rows to build, which alone took seconds.
    private func focusRequestedWord() {
        guard let word = scrollToWord,
              let originalIndex = originalOrder.firstIndex(of: word),
              let displayedPosition = displayedPosition(forOriginalIndex: originalIndex) else {
            return
        }

        highlightedOriginalIndex = originalIndex
        isJumpingToWord = true
        setWindow(start: displayedPosition - pageSize, end: displayedPosition + pageSize)
        pendingScrollPosition = displayedPosition

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            highlightedOriginalIndex = nil
        }
    }

    private func scrollToPendingPosition(with proxy: ScrollViewProxy) {
        guard let displayedPosition = pendingScrollPosition else { return }
        pendingScrollPosition = nil

        // The window was widened a moment ago; let SwiftUI put those rows in the
        // list before asking it to scroll to one of them.
        DispatchQueue.main.async {
            proxy.scrollTo(displayedPosition, anchor: .center)
            DispatchQueue.main.async {
                isJumpingToWord = false
            }
        }
    }

    /// Where a word sits in the list. In CSV order — the only orders a swipe-up
    /// can land in, since the sort menu resets the window anyway — this is
    /// arithmetic instead of a scan over every index.
    private func displayedPosition(forOriginalIndex originalIndex: Int) -> Int? {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch sortMode {
            case .original:
                return currentDisplayedIndices.indices.contains(originalIndex) ? originalIndex : nil

            case .reverseOriginal:
                let position = originalOrder.count - 1 - originalIndex
                return currentDisplayedIndices.indices.contains(position) ? position : nil

            default:
                break
            }
        }

        return currentDisplayedIndices.firstIndex(of: originalIndex)
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
            showToast("Already in list")
            return
        }

        // Adding a word invalidates the stale delete positions.
        undoToastID += 1
        pendingUndo = nil

        originalOrder.append(trimmed)
        newWord = ""
        applyCurrentSort()
        saveCSV()
    }

    private func showToast(_ message: String) {
        // A regular toast supersedes any pending undo.
        undoToastID += 1
        pendingUndo = nil

        toastID += 1
        let currentID = toastID

        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Only hide if no newer toast has replaced this one.
            guard toastID == currentID else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                toastMessage = nil
            }
        }
    }

    private func deleteWords(at offsets: IndexSet) {
        // The offsets index the rows the ForEach was handed, which start at
        // windowStart rather than at 0.
        let renderedPositions = visibleDisplayedPositions

        let originalIndicesToRemove = offsets
            .compactMap { offset -> Int? in
                guard renderedPositions.indices.contains(offset) else { return nil }
                let displayedPosition = renderedPositions[offset]
                guard currentDisplayedIndices.indices.contains(displayedPosition) else { return nil }
                return currentDisplayedIndices[displayedPosition]
            }
            .sorted(by: >)

        var removed: [(index: Int, word: String)] = []
        for index in originalIndicesToRemove {
            if originalOrder.indices.contains(index) {
                let word = originalOrder.remove(at: index)
                removed.append((index, word))
            }
        }

        applyCurrentSort(keepWindow: true)
        saveCSV()

        showUndoToast(removed)
    }

    private func showUndoToast(_ removed: [(index: Int, word: String)]) {
        guard !removed.isEmpty else { return }

        undoToastID += 1
        let currentID = undoToastID

        withAnimation(.easeInOut(duration: 0.2)) {
            pendingUndo = removed
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            // Only hide if no newer undo toast has replaced this one.
            guard undoToastID == currentID else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                pendingUndo = nil
            }
        }
    }

    private func undoDelete() {
        guard let removed = pendingUndo else { return }

        // Reinsert in ascending index order so each word lands back
        // at the exact position it was removed from.
        for (index, word) in removed.sorted(by: { $0.index < $1.index }) {
            let insertIndex = min(index, originalOrder.count)
            originalOrder.insert(word, at: insertIndex)
        }

        undoToastID += 1
        withAnimation(.easeInOut(duration: 0.2)) {
            pendingUndo = nil
        }

        applyCurrentSort(keepWindow: true)
        saveCSV()
    }

    private func toggleSearch() {
        isSearchVisible.toggle()

        if !isSearchVisible {
            searchText = ""
        }

        applySearchAndPagination()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
