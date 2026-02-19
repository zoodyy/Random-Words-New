import SwiftUI

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
    
    // Swipe animation state
    @State private var swipeOffset: CGFloat = 0
    
    // Long press timer
    @State private var longPressTimer: Timer?
    
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
    
    // MARK: - Body
    
    var body: some View {
        NavigationStack {
            mainContent()
                .toolbar { toolbarMenu() }
                .onAppear {
                    loadPersistedData()
                    loadCSVs()
                }
                .onChange(of: selectedCSVs) { _ in saveCSVs() }
                .onChange(of: csvRanges) { _ in saveRanges() }
                .onChange(of: switchInterval) { _ in updateTimer() }
                .onChange(of: numberOfWordsToShow) { _ in selectRandomWords() }
                .onChange(of: fairWordDistribution) { _ in selectRandomWords() }
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
                                let calculatedSize = min(geo.size.width, maxFontSize)
                                
                                Text(word)
                                    .font(.system(size: calculatedSize))
                                    .bold()
                                    .minimumScaleFactor(0.1)
                                    .lineLimit(1)
                                    .multilineTextAlignment(.center)
                                    .frame(
                                        width: geo.size.width,
                                        height: geo.size.height / CGFloat(selectedWords.count)
                                    )
                                    // Swipe left gesture
                                    .gesture(
                                        DragGesture()
                                            .onEnded { value in
                                                if value.translation.width < -100 {
                                                    handleLeftSwipe()
                                                }
                                            }
                                    )
                                    // Long press copy + vibrate after 0.4s hold
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.4)
                                            .onEnded { _ in
                                                // Vibrate and copy immediately after 0.4s hold
                                                UIPasteboard.general.string = word
                                                let generator = UIImpactFeedbackGenerator(style: .medium)
                                                generator.impactOccurred()
                                            }
                                    )
                            }
                        }
                        .offset(x: swipeOffset)
                        .animation(.easeInOut(duration: 0.25), value: swipeOffset)
                    }
                }
                
                Spacer()
                
                Text(filteredWords.isEmpty ? "No words available" : "")
                    .foregroundColor(.gray)
                    .padding(.bottom, 40)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !filteredWords.isEmpty else { return }
            selectRandomWords()
        }
    }
    
    // MARK: - Swipe Handling
    
    private func handleLeftSwipe() {
        guard !selectedWords.isEmpty else { return }
        
        withAnimation {
            swipeOffset = -500
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            addToOwnVocab(selectedWords)
            selectRandomWords()
            swipeOffset = 0
        }
    }
    
    // MARK: - addToOwnVocab (FIXED)
    // Preserve insertion order and avoid alphabetizing the file.
    private func addToOwnVocab(_ wordsToAdd: [String]) {
        let fileURL = getOwnVocabURL()
        
        // Read existing content into ordered array
        var existingOrdered: [String] = []
        if FileManager.default.fileExists(atPath: fileURL.path),
           let content = try? String(contentsOf: fileURL) {
            existingOrdered = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        
        // Append new words preserving order and avoiding duplicates
        for word in wordsToAdd {
            if !existingOrdered.contains(word) {
                existingOrdered.append(word)
            }
        }
        
        // Write back in insertion order (no sorting)
        let newContent = existingOrdered.joined(separator: "\n")
        try? newContent.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    private func getOwnVocabURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ownVocab.csv")
    }
    
    // MARK: - Toolbar
    
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
    
    // MARK: - Filtering
    
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
    
    // MARK: - Random
    
    private func selectRandomWords() {
        if fairWordDistribution {
            selectedWords = generateFairWords()
        } else {
            selectedWords = Array(filteredWords.shuffled()
                .prefix(min(numberOfWordsToShow, filteredWords.count)))
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
    
    // MARK: - CSV Loading
    
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
        
        selectRandomWords()
        updateTimer()
    }
    
    // MARK: - Timer
    
    private func updateTimer() {
        timer?.invalidate()
        guard switchInterval > 0 else { return }
        
        timer = Timer.scheduledTimer(withTimeInterval: switchInterval, repeats: true) { _ in
            selectRandomWords()
        }
    }
    
    // MARK: - Persistence
    
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
}
