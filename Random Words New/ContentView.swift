import SwiftUI
import UIKit

struct ContentView: View {
    
    enum AppTheme: String, CaseIterable, Identifiable {
        case system = "System"
        case light = "Light"
        case dark = "Dark"
        var id: String { rawValue }
    }
    
    struct RangePair: Codable, Equatable {
        var lower: Double
        var upper: Double
    }
    
    private struct CSVWordPool {
        let words: [String]
        let lowerBound: Int
        let upperBound: Int
        let eligibleIndices: [Int]?
        
        var count: Int {
            if let eligibleIndices {
                return eligibleIndices.count
            }
            return max(upperBound - lowerBound, 0)
        }
        
        func word(atEligibleOffset offset: Int) -> String? {
            guard offset >= 0, offset < count else { return nil }
            
            if let eligibleIndices {
                let actualIndex = eligibleIndices[offset]
                guard words.indices.contains(actualIndex) else { return nil }
                return words[actualIndex]
            } else {
                let actualIndex = lowerBound + offset
                guard words.indices.contains(actualIndex) else { return nil }
                return words[actualIndex]
            }
        }
    }

    @AppStorage("switchInterval") private var switchInterval: Double = 3
    @AppStorage("numberOfWordsToShow") private var numberOfWordsToShow: Int = 1
    @AppStorage("fairWordDistribution") private var fairWordDistribution: Bool = false
    @AppStorage("selectedTheme") private var selectedThemeRaw: String = AppTheme.system.rawValue
    @AppStorage("minimumWordLength") private var minimumWordLength: Int = 1
    @AppStorage("selectedWordFont") private var selectedWordFontRaw: String = "Default"
    
    @AppStorage("selectedCSVsData") private var selectedCSVsData: Data = Data()
    @AppStorage("csvRangesData") private var csvRangesData: Data = Data()
    @AppStorage("minLengthExcludedCSVsData") private var minLengthExcludedCSVsData: Data = Data()
    @AppStorage("wordHistoryData") private var wordHistoryData: Data = Data()
    @AppStorage("savedHistoryIndex") private var savedHistoryIndex: Int = -1
    @AppStorage("savedWordSourceCSV") private var savedWordSourceCSV: String = ""
    
    @State private var selectedCSVs: Set<String> = []
    @State private var csvRanges: [String: RangePair] = [:]
    @State private var selectedWords: [String] = []
    @State private var timer: Timer?
    @State private var sliderChangeTrigger = 0
    @State private var allWordsPerCSV: [String: [String]] = [:]
    @State private var minLengthExcludedCSVs: Set<String> = []
    
    @State private var wordPools: [String: CSVWordPool] = [:]
    @State private var orderedActiveCSVs: [String] = []
    @State private var totalEligibleWordCount: Int = 0
    @State private var firstSelectedWordSourceCSV: String?
    
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeUpOffset: CGFloat = 0
    @State private var longPressTimer: Timer?
    
    @GestureState private var isPressing = false
    
    @State private var navigateToCSV: String?
    @State private var selectedWordSource: (csv: String, word: String)?
    @State private var definitionTarget: DefinitionTarget?
    
    @State private var wordHistory: [[String]] = []
    @State private var historyIndex: Int = -1

    @State private var hasLoadedOnce = false
    @State private var isScreenVisible = false
    @State private var wasTimerRunningBeforeDisappear = false
    @State private var isRestoringState = false
    
    private let maxHistoryCount: Int = 100
    
    private var swipeGesture: some Gesture {
        DragGesture()
            .onEnded { value in
                if value.translation.width < -100 {
                    handleLeftSwipe()
                } else if value.translation.width > 100 {
                    handleRightSwipe()
                }
                
                if value.translation.height < -100 {
                    handleUpSwipe()
                } else if value.translation.height > 100 {
                    handleDownSwipe()
                }
            }
    }
    
    private var selectedTheme: AppTheme {
        AppTheme(rawValue: selectedThemeRaw) ?? .system
    }
    
    private var colorScheme: ColorScheme? {
        switch selectedTheme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    private var availableCSVNames: [String] {
        var names = Set<String>()
        
        let fileManager = FileManager.default
        
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
           let documentFiles = try? fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: nil) {
            for file in documentFiles where file.pathExtension.lowercased() == "csv" {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        
        if let bundleFiles = Bundle.main.urls(forResourcesWithExtension: "csv", subdirectory: nil) {
            for file in bundleFiles {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        
        return names.sorted()
    }
    
    private func wordFont(size: CGFloat) -> Font {
        switch selectedWordFontRaw {
        case "Slackey":
            return .custom("Slackey", size: size)
        case "Avenir Next":
            return .custom("AvenirNext-Regular", size: size)
        case "Georgia":
            return .custom("Georgia", size: size)
        case "Helvetica Neue":
            return .custom("HelveticaNeue", size: size)
        case "Futura":
            return .custom("Futura-Medium", size: size)
        case "Chalkboard":
            return .custom("ChalkboardSE-Regular", size: size)
        case "Marker Felt":
            return .custom("MarkerFelt-Wide", size: size)
        case "Palatino":
            return .custom("Palatino-Roman", size: size)
        case "Gill Sans":
            return .custom("GillSans", size: size)
        case "Baskerville":
            return .custom("Baskerville", size: size)
        case "American Typewriter":
            return .custom("AmericanTypewriter", size: size)
        case "Copperplate":
            return .custom("Copperplate", size: size)
        default:
            return .system(size: size)
        }
    }
    
    var body: some View {
        NavigationStack {
            mainContent()
                .toolbar { toolbarMenu() }
                .navigationDestination(item: $navigateToCSV) { csv in
                    if let source = selectedWordSource {
                        EditCSVView(
                            csvFileName: csv,
                            scrollToWord: source.word
                        )
                    }
                }
                .sheet(item: $definitionTarget) { target in
                    WordDefinitionView(word: target.word)
                }
                .onAppear {
                    isScreenVisible = true
                    if hasLoadedOnce {
                        // Returning from another screen: refresh CSV contents
                        // (they may have been edited) but keep the displayed
                        // word and the swipe history intact.
                        reloadCSVContents()
                        if selectedWords.isEmpty {
                            selectRandomWords(recordHistory: true)
                        }
                        if wasTimerRunningBeforeDisappear {
                            resumeTimer()
                        }
                    } else {
                        hasLoadedOnce = true
                        isRestoringState = true
                        loadPersistedData()
                        reloadCSVContents()

                        if historyIndex >= 0, historyIndex < wordHistory.count {
                            selectedWords = wordHistory[historyIndex]
                        } else {
                            selectRandomWords(recordHistory: true)
                        }

                        updateTimer()

                        // The restore above mutates selectedCSVs/csvRanges/
                        // minLengthExcludedCSVs, whose onChange handlers would
                        // discard the restored word and history. Lift the guard
                        // once those initial updates have settled.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            isRestoringState = false
                        }
                    }
                }
                .onDisappear {
                    wasTimerRunningBeforeDisappear = timer != nil
                    isScreenVisible = false
                    pauseTimer()
                }
                .onChange(of: selectedCSVs) { _ in
                    guard !isRestoringState else { return }
                    saveCSVs()
                    loadCSVs()
                }
                .onChange(of: csvRanges) { _ in
                    guard !isRestoringState else { return }
                    saveRanges()
                    rebuildWordPools()
                    selectRandomWords(recordHistory: true)
                }
                .onChange(of: minLengthExcludedCSVs) { _ in
                    guard !isRestoringState else { return }
                    saveMinLengthExcludedCSVs()
                    rebuildWordPools()
                    selectRandomWords(recordHistory: true)
                }
                .onChange(of: switchInterval) { _ in
                    updateTimer()
                }
                .onChange(of: numberOfWordsToShow) { _ in
                    selectRandomWords(recordHistory: true)
                }
                .onChange(of: fairWordDistribution) { _ in
                    selectRandomWords(recordHistory: true)
                }
                .onChange(of: minimumWordLength) { _ in
                    rebuildWordPools()
                    selectRandomWords(recordHistory: true)
                }
        }
        .preferredColorScheme(colorScheme)
    }
    
    private func mainContent() -> some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            
            VStack {
                Spacer()
                
                if selectedWords.isEmpty {
                    Text("Select CSV(s)")
                        .font(.largeTitle)
                        .bold()
                } else {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            ForEach(selectedWords, id: \.self) { word in
                                
                                let maxFontSize = geo.size.height * 0.2
                                let baseFontSize = min(geo.size.width, maxFontSize)
                                let minScale: CGFloat = 0.2
                                
                                let shouldWrap = needsWrapping(
                                    text: word,
                                    baseFontSize: baseFontSize,
                                    availableWidth: geo.size.width,
                                    minScale: minScale
                                )
                                
                                Group {
                                    if shouldWrap {
                                        Text(makeBreakableText(word))
                                            .font(wordFont(size: baseFontSize * minScale))
                                            .bold()
                                            .foregroundColor(getTextColor)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(nil)
                                            .minimumScaleFactor(1.0)
                                    } else {
                                        Text(word)
                                            .font(wordFont(size: baseFontSize))
                                            .bold()
                                            .foregroundColor(getTextColor)
                                            .minimumScaleFactor(minScale)
                                            .lineLimit(1)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                                .frame(
                                    width: geo.size.width,
                                    height: geo.size.height / CGFloat(selectedWords.count)
                                )
                                .gesture(swipeGesture)
                                .simultaneousGesture(
                                    LongPressGesture(minimumDuration: 0.4)
                                        .updating($isPressing) { currentState, gestureState, _ in
                                            gestureState = currentState
                                        }
                                        .onChanged { _ in
                                            if timer == nil {
                                                resumeTimer()
                                            } else {
                                                pauseTimer()
                                            }
                                        }
                                        .onEnded { _ in
                                            resumeTimer()
                                            
                                            UIPasteboard.general.string = word
                                            let generator = UIImpactFeedbackGenerator(style: .medium)
                                            generator.impactOccurred()
                                        }
                                )
                            }
                        }
                        .offset(x: swipeOffset, y: swipeUpOffset)
                        .animation(.easeInOut(duration: 0.25), value: swipeOffset)
                        .animation(.easeInOut(duration: 0.25), value: swipeUpOffset)
                    }
                }
                
                Spacer()
                
                Text(hasAvailableWords ? "" : "No words available")
                    .foregroundColor(.gray)
                    .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .gesture(swipeGesture)
        .onTapGesture {
            guard hasAvailableWords else { return }
            selectRandomWords(recordHistory: true)
        }
    }
    
    private var hasAvailableWords: Bool {
        totalEligibleWordCount > 0
    }
    
    private func needsWrapping(text: String, baseFontSize: CGFloat, availableWidth: CGFloat, minScale: CGFloat) -> Bool {
        let font = UIFont.boldSystemFont(ofSize: baseFontSize)
        let singleLineWidth = (text as NSString).size(withAttributes: [.font: font]).width
        
        let usableWidth = max(availableWidth - 24, 1)
        
        if singleLineWidth <= usableWidth {
            return false
        }
        
        let requiredScale = usableWidth / singleLineWidth
        return requiredScale < minScale
    }
    
    private func makeBreakableText(_ text: String) -> String {
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return text
        }
        return text.map { String($0) }.joined(separator: "\u{200B}")
    }
    
    private func letterCount(of word: String) -> Int {
        word.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
    }
    
    private func handleLeftSwipe() {
        pauseTimer()
        guard !selectedWords.isEmpty else { return }
        
        withAnimation {
            swipeOffset = -500
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            addToOwnVocab(selectedWords)
            selectRandomWords(recordHistory: true)
            swipeOffset = 0
        }
    }
    
    private func handleRightSwipe() {
        pauseTimer()
        guard !wordHistory.isEmpty, historyIndex > 0 else { return }
        
        withAnimation {
            swipeOffset = 500
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            historyIndex -= 1
            selectedWords = wordHistory[historyIndex]
            swipeOffset = 0
            saveHistoryState()
        }
    }
    
    private func handleUpSwipe() {
        guard let word = selectedWords.first else { return }
        
        pauseTimer()
        
        withAnimation(.easeInOut(duration: 0.25)) {
            swipeUpOffset = -400
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let csv = firstSelectedWordSourceCSV {
                selectedWordSource = (csv, word)
                swipeUpOffset = 0
                navigateToCSV = csv
            } else {
                swipeUpOffset = 0
            }
        }
    }
    
    private func handleDownSwipe() {
        guard let word = selectedWords.first else { return }

        pauseTimer()

        withAnimation(.easeInOut(duration: 0.25)) {
            swipeUpOffset = 400
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            swipeUpOffset = 0
            definitionTarget = DefinitionTarget(word: word)
        }
    }

    private func addToOwnVocab(_ wordsToAdd: [String]) {
        let fileURL = getOwnVocabURL()
        
        var existingOrdered: [String] = []
        if FileManager.default.fileExists(atPath: fileURL.path),
           let content = try? String(contentsOf: fileURL) {
            existingOrdered = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        
        for word in wordsToAdd {
            if !existingOrdered.contains(word) {
                existingOrdered.append(word)
            }
        }
        
        let newContent = existingOrdered.joined(separator: "\n")
        try? newContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    private func getOwnVocabURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ownVocab.csv")
    }
    
    @ToolbarContentBuilder
    private func toolbarMenu() -> some ToolbarContent {
        
        ToolbarItem(placement: .topBarLeading) {
            NavigationLink(
                destination: SettingsView(
                    switchInterval: $switchInterval,
                    numberOfWordsToShow: $numberOfWordsToShow,
                    fairWordDistribution: $fairWordDistribution,
                    selectedThemeRaw: $selectedThemeRaw,
                    minimumWordLength: $minimumWordLength,
                    minLengthExcludedCSVs: $minLengthExcludedCSVs,
                    selectedWordFontRaw: $selectedWordFontRaw,
                    availableCSVs: availableCSVNames
                )
            ) {
                Image(systemName: "line.3.horizontal")
            }
        }
        
        ToolbarItem(placement: .topBarTrailing) {
            NavigationLink(
                destination: DictView(
                    selectedCSVs: $selectedCSVs,
                    words: .constant([]),
                    csvRanges: Binding(
                        get: { csvRanges.mapValues { ($0.lower, $0.upper) } },
                        set: { newValue in
                            csvRanges = newValue.mapValues {
                                RangePair(lower: $0.0, upper: $0.1)
                            }
                        }
                    ),
                    sliderChangeTrigger: $sliderChangeTrigger
                )
            ) {
                Image(systemName: "book")
            }
        }
    }
    
    private func selectRandomWords(recordHistory: Bool = true) {
        updateTimer()

        let selection = fairWordDistribution
            ? generateFairSelection()
            : generateCombinedPoolSelection()

        selectedWords = selection.words
        firstSelectedWordSourceCSV = selection.firstSourceCSV

        defer { saveHistoryState() }

        guard recordHistory, !selection.words.isEmpty else { return }
        
        if historyIndex >= 0, historyIndex < wordHistory.count - 1 {
            wordHistory = Array(wordHistory.prefix(historyIndex + 1))
        }
        
        if wordHistory.last != selection.words {
            wordHistory.append(selection.words)
            
            if wordHistory.count > maxHistoryCount {
                let overflow = wordHistory.count - maxHistoryCount
                wordHistory.removeFirst(overflow)
            }
        }
        
        historyIndex = wordHistory.count - 1
    }
    
    private func generateFairSelection() -> (words: [String], firstSourceCSV: String?) {
        let activeCSVNames = orderedActiveCSVs.filter { (wordPools[$0]?.count ?? 0) > 0 }
        guard !activeCSVNames.isEmpty else { return ([], nil) }
        
        var results: [String] = []
        var firstSource: String?
        
        for _ in 0..<numberOfWordsToShow {
            guard let randomCSV = activeCSVNames.randomElement(),
                  let pool = wordPools[randomCSV],
                  pool.count > 0 else {
                continue
            }
            
            let randomOffset = Int.random(in: 0..<pool.count)
            if let word = pool.word(atEligibleOffset: randomOffset) {
                if firstSource == nil {
                    firstSource = randomCSV
                }
                results.append(word)
            }
        }
        
        return (results, firstSource)
    }
    
    private func generateCombinedPoolSelection() -> (words: [String], firstSourceCSV: String?) {
        guard totalEligibleWordCount > 0 else { return ([], nil) }
        
        let desiredCount = min(numberOfWordsToShow, totalEligibleWordCount)
        var selectedGlobalOffsets = Set<Int>()
        
        while selectedGlobalOffsets.count < desiredCount {
            selectedGlobalOffsets.insert(Int.random(in: 0..<totalEligibleWordCount))
        }
        
        let sortedOffsets = selectedGlobalOffsets.sorted()
        
        var results: [String] = []
        var firstSource: String?
        
        for globalOffset in sortedOffsets {
            if let resolved = resolveGlobalEligibleOffset(globalOffset) {
                if firstSource == nil {
                    firstSource = resolved.csv
                }
                results.append(resolved.word)
            }
        }
        
        return (results, firstSource)
    }
    
    private func resolveGlobalEligibleOffset(_ globalOffset: Int) -> (csv: String, word: String)? {
        var runningTotal = 0
        
        for csv in orderedActiveCSVs {
            guard let pool = wordPools[csv], pool.count > 0 else { continue }
            let nextTotal = runningTotal + pool.count
            
            if globalOffset < nextTotal {
                let localOffset = globalOffset - runningTotal
                if let word = pool.word(atEligibleOffset: localOffset) {
                    return (csv, word)
                }
                return nil
            }
            
            runningTotal = nextTotal
        }
        
        return nil
    }
    
    private func loadCSVs() {
        reloadCSVContents()

        wordHistory.removeAll()
        historyIndex = -1

        selectRandomWords(recordHistory: true)
        updateTimer()
    }

    private func reloadCSVContents() {
        allWordsPerCSV.removeAll()
        
        for csv in selectedCSVs {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("\(csv).csv")
            
            var content: String?
            
            if FileManager.default.fileExists(atPath: documentsURL.path) {
                content = try? String(contentsOf: documentsURL)
            } else if let bundlePath = Bundle.main.path(forResource: csv, ofType: "csv") {
                content = try? String(contentsOfFile: bundlePath)
            }
            
            if let content = content {
                let lines = content
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                
                allWordsPerCSV[csv] = lines
            }
        }

        rebuildWordPools()
    }
    
    private func rebuildWordPools() {
        var newPools: [String: CSVWordPool] = [:]
        var newOrderedActiveCSVs: [String] = []
        var newTotalEligibleWordCount = 0
        
        for csv in selectedCSVs {
            guard let range = csvRanges[csv],
                  let words = allWordsPerCSV[csv] else {
                continue
            }
            
            let total = words.count
            guard total > 0 else { continue }
            
            let lower = min(max(Int(Double(total) * range.lower), 0), total)
            let upper = min(max(Int(Double(total) * range.upper), lower), total)
            guard lower < upper else { continue }
            
            let pool: CSVWordPool
            
            if minLengthExcludedCSVs.contains(csv) {
                pool = CSVWordPool(
                    words: words,
                    lowerBound: lower,
                    upperBound: upper,
                    eligibleIndices: nil
                )
            } else {
                var indices: [Int] = []
                indices.reserveCapacity(upper - lower)
                
                for index in lower..<upper {
                    if letterCount(of: words[index]) >= minimumWordLength {
                        indices.append(index)
                    }
                }
                
                pool = CSVWordPool(
                    words: words,
                    lowerBound: lower,
                    upperBound: upper,
                    eligibleIndices: indices
                )
            }
            
            if pool.count > 0 {
                newPools[csv] = pool
                newOrderedActiveCSVs.append(csv)
                newTotalEligibleWordCount += pool.count
            }
        }
        
        wordPools = newPools
        orderedActiveCSVs = newOrderedActiveCSVs
        totalEligibleWordCount = newTotalEligibleWordCount
    }
    
    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard switchInterval > 0, isScreenVisible else { return }
        
        timer = Timer.scheduledTimer(withTimeInterval: switchInterval, repeats: true) { _ in
            selectRandomWords(recordHistory: true)
        }
    }
    
    private func saveCSVs() {
        selectedCSVsData = (try? JSONEncoder().encode(selectedCSVs)) ?? Data()
    }
    
    private func saveRanges() {
        csvRangesData = (try? JSONEncoder().encode(csvRanges)) ?? Data()
    }
    
    private func saveMinLengthExcludedCSVs() {
        minLengthExcludedCSVsData = (try? JSONEncoder().encode(minLengthExcludedCSVs)) ?? Data()
    }

    private func saveHistoryState() {
        wordHistoryData = (try? JSONEncoder().encode(wordHistory)) ?? Data()
        savedHistoryIndex = historyIndex
        savedWordSourceCSV = firstSelectedWordSourceCSV ?? ""
    }

    private func loadPersistedData() {
        selectedCSVs = (try? JSONDecoder().decode(Set<String>.self, from: selectedCSVsData)) ?? []
        csvRanges = (try? JSONDecoder().decode([String: RangePair].self, from: csvRangesData)) ?? [:]
        minLengthExcludedCSVs = (try? JSONDecoder().decode(Set<String>.self, from: minLengthExcludedCSVsData)) ?? []

        wordHistory = (try? JSONDecoder().decode([[String]].self, from: wordHistoryData)) ?? []
        historyIndex = wordHistory.isEmpty
            ? -1
            : min(max(savedHistoryIndex, 0), wordHistory.count - 1)
        firstSelectedWordSourceCSV = savedWordSourceCSV.isEmpty ? nil : savedWordSourceCSV
    }
    
    private func pauseTimer() {
        if switchInterval > 0 {
            timer?.invalidate()
            timer = nil
        }
    }

    private func resumeTimer() {
        if switchInterval > 0 {
            updateTimer()
        }
    }
    
    private var getTextColor: Color {
        timer == nil ? Color.gray : Color.primary
    }
}
