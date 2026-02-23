import SwiftUI
import UIKit

struct ContentView: View {
    
    // MARK: - Theme
    
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

    // MARK: - Persistent Storage
    
    @AppStorage("switchInterval") private var switchInterval: Double = 3
    @AppStorage("numberOfWordsToShow") private var numberOfWordsToShow: Int = 1
    @AppStorage("fairWordDistribution") private var fairWordDistribution: Bool = false
    @AppStorage("selectedTheme") private var selectedThemeRaw: String = AppTheme.system.rawValue
    
    @AppStorage("selectedCSVsData") private var selectedCSVsData: Data = Data()
    @AppStorage("csvRangesData") private var csvRangesData: Data = Data()
    
    // MARK: - Runtime State
    
    @State private var selectedCSVs: Set<String> = []
    @State private var csvRanges: [String: RangePair] = [:]
    @State private var selectedWords: [String] = []
    @State private var timer: Timer?
    @State private var sliderChangeTrigger = 0
    @State private var allWordsPerCSV: [String: [String]] = [:]
    
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeUpOffset: CGFloat = 0
    @State private var longPressTimer: Timer?
    
    @GestureState private var isPressing = false
    
    @State private var navigateToCSV: String?
    @State private var selectedWordSource: (csv: String, word: String)?
    
    // ✅ History for previous word(s)
    @State private var wordHistory: [[String]] = []
    @State private var historyIndex: Int = -1
    
    // MARK: - Shared Swipe Gesture
    
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
                }
            }
    }
    
    // MARK: - Theme
    
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
                .onAppear {
                    loadPersistedData()
                    loadCSVs()
                }
                .onChange(of: selectedCSVs) { _ in saveCSVs() }
                .onChange(of: csvRanges) { _ in saveRanges() }
                .onChange(of: switchInterval) { _ in updateTimer() }
                .onChange(of: numberOfWordsToShow) { _ in selectRandomWords(recordHistory: true) }
                .onChange(of: fairWordDistribution) { _ in selectRandomWords(recordHistory: true) }
        }
        .preferredColorScheme(colorScheme)
    }
    
    // MARK: - Main Content
    
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
                                
                                // ✅ FIX AREA:
                                // Still shrink down, but if shrinking would go below minScale,
                                // stop shrinking and wrap (prefer spaces; otherwise allow char wrapping).
                                let shouldWrap = needsWrapping(
                                    text: word,
                                    baseFontSize: baseFontSize,
                                    availableWidth: geo.size.width,
                                    minScale: minScale
                                )
                                
                                Group {
                                    if shouldWrap {
                                        Text(makeBreakableText(word))
                                            .font(.system(size: baseFontSize * minScale))
                                            .bold()
                                            .foregroundColor(getTextColor)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(nil)
                                            .minimumScaleFactor(1.0) // no further shrinking; wrapping instead
                                    } else {
                                        Text(word)
                                            .font(.system(size: baseFontSize))
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
                
                Text(filteredWords.isEmpty ? "No words available" : "")
                    .foregroundColor(.gray)
                    .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .gesture(swipeGesture)
        .onTapGesture {
            guard !filteredWords.isEmpty else { return }
            selectRandomWords(recordHistory: true)
        }
    }
    
    // ✅ Helpers for wrapping decision / break behavior
    
    private func needsWrapping(text: String, baseFontSize: CGFloat, availableWidth: CGFloat, minScale: CGFloat) -> Bool {
        // if it fits on one line at full size, no need to wrap
        let font = UIFont.boldSystemFont(ofSize: baseFontSize)
        let singleLineWidth = (text as NSString).size(withAttributes: [.font: font]).width
        
        // a little padding so we don't hit the edge
        let usableWidth = max(availableWidth - 24, 1)
        
        if singleLineWidth <= usableWidth {
            return false
        }
        
        let requiredScale = usableWidth / singleLineWidth
        return requiredScale < minScale
    }
    
    private func makeBreakableText(_ text: String) -> String {
        // Prefer breaking at spaces automatically.
        // If there are no spaces, inject zero-width spaces to allow wrapping between characters.
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return text
        }
        return text.map { String($0) }.joined(separator: "\u{200B}")
    }
    
    // MARK: - Swipe Handling
    
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
        }
    }
    
    private func handleUpSwipe() {
        guard let word = selectedWords.first else { return }
        
        pauseTimer()
        
        withAnimation(.easeInOut(duration: 0.25)) {
            swipeUpOffset = -400
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            for csv in selectedCSVs {
                if let words = allWordsPerCSV[csv],
                   words.contains(word) {
                    
                    selectedWordSource = (csv, word)
                    
                    swipeUpOffset = 0
                    navigateToCSV = csv
                    break
                }
            }
        }
    }
    
    // MARK: - Remaining Logic
    
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
                    selectedThemeRaw: $selectedThemeRaw
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
    
    private var filteredWords: [String] {
        var combined: [String] = []
        
        for csv in selectedCSVs {
            guard let range = csvRanges[csv],
                  let words = allWordsPerCSV[csv] else { continue }
            
            let total = words.count
            let lower = Int(Double(total) * range.lower)
            let upper = Int(Double(total) * range.upper)
            
            if lower < upper {
                combined.append(contentsOf: words[lower..<upper])
            }
        }
        
        return combined
    }
    
    private func selectRandomWords(recordHistory: Bool = true) {
        updateTimer()
        
        let newSelection: [String]
        if fairWordDistribution {
            newSelection = generateFairWords()
        } else {
            newSelection = Array(filteredWords.shuffled()
                .prefix(min(numberOfWordsToShow, filteredWords.count)))
        }
        
        selectedWords = newSelection
        
        guard recordHistory, !newSelection.isEmpty else { return }
        
        if historyIndex >= 0, historyIndex < wordHistory.count - 1 {
            wordHistory = Array(wordHistory.prefix(historyIndex + 1))
        }
        
        if wordHistory.last != newSelection {
            wordHistory.append(newSelection)
            historyIndex = wordHistory.count - 1
        } else {
            historyIndex = wordHistory.count - 1
        }
    }
    
    private func generateFairWords() -> [String] {
        var results: [String] = []
        let active = selectedCSVs.filter {
            guard let range = csvRanges[$0],
                  let words = allWordsPerCSV[$0]
            else { return false }
            return !words.isEmpty && range.lower < range.upper
        }
        
        for _ in 0..<numberOfWordsToShow {
            guard let randomCSV = active.randomElement(),
                  let range = csvRanges[randomCSV],
                  let words = allWordsPerCSV[randomCSV]
            else { continue }
            
            let total = words.count
            let lower = Int(Double(total) * range.lower)
            let upper = Int(Double(total) * range.upper)
            
            if lower < upper,
               let word = words[lower..<upper].randomElement() {
                results.append(word)
            }
        }
        return results
    }
    
    private func loadCSVs() {
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
        
        wordHistory.removeAll()
        historyIndex = -1
        
        selectRandomWords(recordHistory: true)
        updateTimer()
    }
    
    private func updateTimer() {
        timer?.invalidate()
        guard switchInterval > 0 else { return }
        
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
    
    private func loadPersistedData() {
        selectedCSVs = (try? JSONDecoder().decode(Set<String>.self, from: selectedCSVsData)) ?? []
        csvRanges = (try? JSONDecoder().decode([String: RangePair].self, from: csvRangesData)) ?? [:]
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
