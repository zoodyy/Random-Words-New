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

    // Typing over a row's number moves that word to the typed position.
    @State private var editingPositionIndex: Int?
    @State private var positionInput = ""
    @FocusState private var focusedPositionIndex: Int?

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
                    .onMove(perform: dragToReorderAction)
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
                            saveCSVNow()
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
            .onChange(of: focusedPositionIndex) { oldValue, newValue in
                // Tapping away from a number drops what was typed. Hopping
                // straight to another number already moved the edit there.
                if newValue == nil, editingPositionIndex == oldValue {
                    editingPositionIndex = nil
                }
            }
            .onDisappear {
                guard !wasDeleted else { return }

                let url = getDocumentsURL()
                if FileManager.default.fileExists(atPath: url.path) {
                    removeNewestDuplicates()
                    // The screen underneath reads this file as soon as it's back.
                    saveCSVNow()
                }
            }
        }
    }

    @ViewBuilder
    private func editableRow(for displayedPosition: Int) -> some View {
        if let originalIndex = originalIndex(forDisplayedPosition: displayedPosition) {
            HStack(spacing: 12) {
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

                positionLabel(for: originalIndex)
            }
            // Otherwise the separator lines up under the number, the only Text.
            .alignmentGuide(.listRowSeparatorLeading) { dimensions in
                dimensions[.leading]
            }
            .listRowBackground(
                highlightedOriginalIndex == originalIndex
                ? Color.gray.opacity(0.5)
                : Color.clear
            )
        }
    }

    /// The word's line number in the CSV, whatever the sort. Tapping it lets
    /// the user type a new one.
    @ViewBuilder
    private func positionLabel(for originalIndex: Int) -> some View {
        if editingPositionIndex == originalIndex {
            TextField(String(originalIndex + 1), text: $positionInput)
                .keyboardType(.numbersAndPunctuation)
                .submitLabel(.done)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 80)
                .focused($focusedPositionIndex, equals: originalIndex)
                .onAppear {
                    focusedPositionIndex = originalIndex
                }
                .onChange(of: positionInput) { _, newValue in
                    // Digits only, so there's no way to type a negative number.
                    let digits = newValue.filter(\.isASCIIDigit)
                    if digits != newValue {
                        positionInput = digits
                    }
                }
                .onSubmit(commitPositionEdit)
        } else {
            Button {
                beginPositionEdit(for: originalIndex)
            } label: {
                Text(verbatim: String(originalIndex + 1))
                    .monospacedDigit()
                    .foregroundStyle(Color.secondary)
                    .padding(.leading, 12)
                    // A bigger target than the digits, without making the row taller.
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Position \(originalIndex + 1)")
            .accessibilityHint("Type a new number to move this word")
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

        // A save still in flight would put the file right back.
        WordlistFile.waitForPendingSaves()

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
        WordlistFile.saveInBackground(originalOrder, to: getDocumentsURL())
    }

    /// For when something reads the file right away (sharing, leaving).
    private func saveCSVNow() {
        WordlistFile.save(originalOrder, to: getDocumentsURL())
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
            let numberedIndex = csvIndex(forNumberQuery: trimmedSearch)
            var matches = WordSearch.indices(
                of: trimmedSearch,
                in: originalOrder,
                orderedBy: displayedIndices,
                excluding: numberedIndex
            )
            if let numberedIndex {
                matches.insert(numberedIndex, at: 0)
            }
            filteredDisplayedIndices = matches
        }

        if keepWindow {
            setWindow(start: windowStart, end: max(windowEnd, windowStart + pageSize))
        } else {
            setWindow(start: 0, end: pageSize)
        }
    }

    /// A search that is only a number also finds the word with that number:
    /// "6" is the 6th line, not 60–69. Any letter in the query turns this off.
    private func csvIndex(forNumberQuery query: String) -> Int? {
        guard query.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let number = Int(query),
              originalOrder.indices.contains(number - 1) else {
            return nil
        }
        return number - 1
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

    /// This runs every time the list is closed and almost never finds
    /// anything, so it only rebuilds the list (and re-sorts, ~0.5 s when
    /// alphabetical) when it has to.
    private func removeNewestDuplicates() {
        let whitespace = CharacterSet.whitespaces
        var seen = Set<String>(minimumCapacity: originalOrder.count)
        var isDuplicate: [Bool]?

        for index in originalOrder.indices.reversed() {
            let word = originalOrder[index]
            // Words come off the file already trimmed; only the ones edited
            // here can need it, and trimming all 84k is most of the cost.
            let needsTrimming = word.unicodeScalars.first.map(whitespace.contains) == true
                || word.unicodeScalars.last.map(whitespace.contains) == true
            let trimmed = needsTrimming ? word.trimmingCharacters(in: .whitespaces) : word

            if trimmed.isEmpty { continue }

            if !seen.insert(trimmed).inserted {
                if isDuplicate == nil {
                    isDuplicate = Array(repeating: false, count: originalOrder.count)
                }
                isDuplicate?[index] = true
            }
        }

        guard let isDuplicate else { return }

        originalOrder = originalOrder.indices
            .filter { !isDuplicate[$0] }
            .map { originalOrder[$0] }
        applyCurrentSort(keepWindow: true)
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

    // MARK: Reordering

    /// Dragging only makes sense while the rows show the whole CSV in file
    /// order (or reversed): there a row's position is its line in the file.
    /// Sorted alphabetically a dropped word would just snap back, and search
    /// results skip the lines in between.
    private var canDragToReorder: Bool {
        (sortMode == .original || sortMode == .reverseOriginal)
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var dragToReorderAction: ((IndexSet, Int) -> Void)? {
        guard canDragToReorder else { return nil }
        return { offsets, destination in
            moveRows(fromOffsets: offsets, toOffset: destination)
        }
    }

    private func moveRows(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        // The offsets index the rows the ForEach was handed, which start at
        // windowStart rather than at 0.
        let count = originalOrder.count
        let sourcePositions = offsets.map { windowStart + $0 }
        let destinationPosition = windowStart + destination

        if sortMode == .reverseOriginal {
            originalOrder.move(
                fromOffsets: IndexSet(sourcePositions.map { count - 1 - $0 }),
                toOffset: count - destinationPosition
            )
        } else {
            originalOrder.move(fromOffsets: IndexSet(sourcePositions), toOffset: destinationPosition)
        }

        // Rows are laid out by CSV index in these orders, so they already
        // show the new arrangement; nothing to re-sort or re-filter.
        finishReorder()
    }

    private func beginPositionEdit(for originalIndex: Int) {
        positionInput = ""
        editingPositionIndex = originalIndex
    }

    private func commitPositionEdit() {
        guard let source = editingPositionIndex else { return }
        editingPositionIndex = nil

        // The field drops anything but digits as it's typed; this covers
        // keystrokes that land faster than it can.
        let digits = positionInput.filter(\.isASCIIDigit)
        guard !digits.isEmpty, !originalOrder.isEmpty else { return }

        // Numbering always runs 1...count with no gaps, so anything past the
        // end means the end (digits too long for an Int included).
        let requested = Int(digits) ?? .max
        let destination = min(max(requested, 1), originalOrder.count) - 1
        guard destination != source else { return }

        moveWord(from: source, to: destination)
        showToast("Moved to \(destination + 1)")
    }

    /// Puts the word at `source` on line `destination`. The word that had that
    /// line and everything between the two shifts by one to fill the gap.
    private func moveWord(from source: Int, to destination: Int) {
        guard originalOrder.indices.contains(source),
              originalOrder.indices.contains(destination) else { return }

        let word = originalOrder.remove(at: source)
        originalOrder.insert(word, at: destination)

        if sortMode == .alphabetical || sortMode == .reverseAlphabetical {
            // The words keep their alphabetical rows and only their numbers
            // change, so shifting the indices beats a full localized re-sort.
            let shift = source < destination ? -1 : 1
            let shifted = min(source, destination)...max(source, destination)
            displayedIndices = displayedIndices.map { index in
                if index == source { return destination }
                return shifted.contains(index) ? index + shift : index
            }
        }
        // In CSV order the rows are laid out by index and already match.

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            filteredDisplayedIndices = displayedIndices
        } else {
            // The results are still the same words, but a number search now
            // points at whichever word took that line.
            applySearchAndPagination(keepWindow: true)
        }

        finishReorder()
    }

    private func finishReorder() {
        // Undo remembers CSV positions, which now point at other words.
        undoToastID += 1
        pendingUndo = nil
        highlightedOriginalIndex = nil
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

private extension Character {
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
