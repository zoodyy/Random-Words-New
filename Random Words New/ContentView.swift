//

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
    @AppStorage("selectedWordFont") private var selectedWordFontRaw: String = "American Typewriter"

    @AppStorage(WordVisualKeys.textColor) private var wordTextColorRaw: String = WordVisualDefaults.textColor
    @AppStorage(WordVisualKeys.backgroundColor) private var wordBackgroundColorRaw: String = WordVisualDefaults.backgroundColor
    @AppStorage(WordVisualKeys.timerStyle) private var timerIndicatorStyleRaw: String = WordVisualDefaults.timerStyle
    @AppStorage(WordVisualKeys.timerPosition) private var timerIndicatorPositionRaw: String = WordVisualDefaults.timerPosition
    @AppStorage(WordVisualKeys.timerColor) private var timerIndicatorColorRaw: String = WordVisualDefaults.timerColor
    @AppStorage(WordVisualKeys.sideMargin) private var wordSideMargin: Double = WordVisualDefaults.sideMargin
    @AppStorage(WordVisualKeys.letterSpacing) private var wordLetterSpacing: Double = WordVisualDefaults.letterSpacing
    @AppStorage(WordVisualKeys.userCustomised) private var wordScreenCustomised: Bool = false

    /// The scheme the window is actually rendered in. With a Light/Dark theme
    /// override this reflects the override; on "System" it's the device setting.
    @Environment(\.colorScheme) private var renderedColorScheme

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
    @State private var nextWordDate: Date?
    @State private var sliderChangeTrigger = 0
    @State private var allWordsPerCSV: [String: [String]] = [:]
    @State private var minLengthExcludedCSVs: Set<String> = []
    
    @State private var wordPools: [String: CSVWordPool] = [:]
    @State private var orderedActiveCSVs: [String] = []
    @State private var totalEligibleWordCount: Int = 0
    @State private var firstSelectedWordSourceCSV: String?
    
    /// How far the word is currently displaced from its resting place: the live
    /// finger translation while dragging, then the fly-out while a swipe commits.
    @State private var dragOffset: CGSize = .zero
    @State private var isDraggingWord = false
    /// The direction the current drag would trigger if the finger lifted now.
    @State private var armedSwipeDirection: WordSwipeDirection?
    /// True from the moment a swipe is committed until the word has flown off
    /// and been replaced, so a stray touch can't fight the exit animation.
    @State private var isCommittingSwipe = false
    /// Size of the word screen, used to detect a release on a screen edge.
    @State private var wordScreenSize: CGSize = .zero
    @State private var longPressTimer: Timer?
    
    @GestureState private var isPressing = false
    
    @State private var navigateToCSV: String?
    @State private var selectedWordSource: (csv: String, word: String)?
    @State private var definitionTarget: DefinitionTarget?
    
    @State private var wordHistory: [[String]] = []
    @State private var historyIndex: Int = -1

    @State private var toastMessage: String?
    @State private var toastID = 0

    @State private var hasLoadedOnce = false
    @State private var isScreenVisible = false
    @State private var wasTimerRunningBeforeDisappear = false
    @State private var isRestoringState = false
    
    private let maxHistoryCount: Int = 100

    /// Coordinate space of the word screen, so a drag's release point can be
    /// compared against the screen edges.
    private static let wordScreenSpace = "wordScreen"
    /// How far the finger must travel, or be flung, for a release to count.
    private static let swipeThreshold: CGFloat = 100
    /// A release this close to a screen edge counts as a swipe that way no
    /// matter how far the finger actually travelled.
    private static let edgeReleaseInset: CGFloat = 32

    /// Drag the word around with the finger; on release either commit to one of
    /// the four actions or let the word spring back.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .named(Self.wordScreenSpace))
            .onChanged { value in
                guard !isCommittingSwipe else { return }

                if !isDraggingWord {
                    withAnimation(.easeOut(duration: 0.15)) { isDraggingWord = true }
                }
                // Deliberately unanimated: the word tracks the finger 1:1.
                dragOffset = value.translation
                armedSwipeDirection = releaseDirection(for: value)
            }
            .onEnded { value in
                withAnimation(.easeOut(duration: 0.15)) { isDraggingWord = false }
                armedSwipeDirection = nil
                guard !isCommittingSwipe else { return }

                switch committedDirection(for: value) {
                case .left?:  handleLeftSwipe()
                case .right?: handleRightSwipe()
                case .up?:    handleUpSwipe()
                case .down?:  handleDownSwipe()
                case nil:     releaseWord()
                }
            }
    }

    /// The direction a release right here would trigger, judged on where the
    /// finger actually is: far enough along an axis, or on a screen edge.
    private func releaseDirection(for value: DragGesture.Value) -> WordSwipeDirection? {
        if let edge = edgeReleaseDirection(for: value) { return edge }
        return dominantDirection(of: value.translation, atLeast: Self.swipeThreshold)
    }

    private func committedDirection(for value: DragGesture.Value) -> WordSwipeDirection? {
        if let direction = releaseDirection(for: value) { return direction }
        // Quick flick: `predictedEndTranslation` folds in the lift-off velocity,
        // so a short but fast swipe commits just like a long slow drag.
        return dominantDirection(of: value.predictedEndTranslation, atLeast: Self.swipeThreshold)
    }

    private func dominantDirection(of translation: CGSize, atLeast threshold: CGFloat) -> WordSwipeDirection? {
        guard max(abs(translation.width), abs(translation.height)) >= threshold else { return nil }

        if abs(translation.width) >= abs(translation.height) {
            return translation.width < 0 ? .left : .right
        }
        return translation.height < 0 ? .up : .down
    }

    /// A drag that wanders around still counts as a swipe when the finger is
    /// lifted on the edge of the screen it was heading for.
    private func edgeReleaseDirection(for value: DragGesture.Value) -> WordSwipeDirection? {
        guard wordScreenSize.width > 0, wordScreenSize.height > 0 else { return nil }

        let inset = Self.edgeReleaseInset
        let location = value.location
        let translation = value.translation

        // Only edges the finger actually moved towards, so starting a drag next
        // to an edge and barely moving doesn't trigger anything.
        var directions: [WordSwipeDirection] = []
        if location.x <= inset, translation.width < 0 { directions.append(.left) }
        if location.x >= wordScreenSize.width - inset, translation.width > 0 { directions.append(.right) }
        if location.y <= inset, translation.height < 0 { directions.append(.up) }
        if location.y >= wordScreenSize.height - inset, translation.height > 0 { directions.append(.down) }

        guard directions.count > 1 else { return directions.first }

        // Released in a corner: go with the axis the finger travelled furthest along.
        let horizontal = abs(translation.width) >= abs(translation.height)
        return directions.first { $0.isHorizontal == horizontal } ?? directions.first
    }

    /// Directions that would do nothing if swiped right now, so the hint can
    /// dim them.
    private var unavailableSwipeDirections: Set<WordSwipeDirection> {
        var unavailable: Set<WordSwipeDirection> = []
        if selectedWords.isEmpty {
            unavailable.formUnion([.left, .up, .down])
        }
        if wordHistory.isEmpty || historyIndex <= 0 {
            unavailable.insert(.right)
        }
        if firstSelectedWordSourceCSV == nil {
            unavailable.insert(.up)
        }
        return unavailable
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
        
        for name in BundledWordlists.names() {
            names.insert(name)
        }
        
        return names.sorted()
    }
    
    private func wordFont(size: CGFloat) -> Font {
        wordDisplayFont(named: selectedWordFontRaw, size: size)
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
                    WordDefinitionView(words: target.words)
                }
                .onAppear {
                    syncDefaultWordScreenStyle()
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
                .onChange(of: renderedColorScheme) { _ in
                    syncDefaultWordScreenStyle()
                }
        }
        .preferredColorScheme(colorScheme)
    }
    
    private func mainContent() -> some View {
        ZStack {
            WordScreenStyle.resolvedBackground(wordBackgroundColorRaw)
                .ignoresSafeArea()

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
                                            .tracking(wordLetterSpacing)
                                            .foregroundColor(getTextColor)
                                            .multilineTextAlignment(.center)
                                            .lineLimit(nil)
                                            .minimumScaleFactor(1.0)
                                    } else {
                                        Text(word)
                                            .font(wordFont(size: baseFontSize))
                                            .bold()
                                            .tracking(wordLetterSpacing)
                                            .foregroundColor(getTextColor)
                                            .minimumScaleFactor(minScale)
                                            .lineLimit(1)
                                            .multilineTextAlignment(.center)
                                    }
                                }
                                .timerUnderline(
                                    active: isUnderlineIndicator,
                                    color: timerIndicatorColor,
                                    nextWordDate: nextWordDate,
                                    interval: switchInterval)
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
                                            showToast("Copied")
                                            let generator = UIImpactFeedbackGenerator(style: .medium)
                                            generator.impactOccurred()
                                        }
                                )
                            }
                        }
                        .offset(x: dragOffset.width, y: dragOffset.height)
                    }
                    .padding(.horizontal, wordSideMargin)
                }
                
                Spacer()
                
                Text(hasAvailableWords ? "" : "No words available")
                    .foregroundColor(.gray)
                    .padding(.bottom, 40)
            }

            VStack {
                if let toastMessage {
                    Text(toastMessage)
                        .font(.footnote)
                        .foregroundColor(.gray)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                Spacer()
            }
            .allowsHitTesting(false)

            swipeHintOverlay

            timerIndicatorOverlay
        }
        .contentShape(Rectangle())
        .gesture(swipeGesture)
        .onTapGesture {
            guard hasAvailableWords else { return }
            selectRandomWords(recordHistory: true)
        }
        .coordinateSpace(.named(Self.wordScreenSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { wordScreenSize = $0 }
    }

    /// While the word is held, the four swipe actions are spelled out in the
    /// empty space above where the word normally sits.
    @ViewBuilder
    private var swipeHintOverlay: some View {
        if isDraggingWord {
            VStack {
                WordSwipeCompass(
                    activeDirection: armedSwipeDirection,
                    unavailable: unavailableSwipeDirections,
                    color: WordScreenStyle.resolvedTextColor(wordTextColorRaw),
                    background: WordScreenStyle.resolvedBackground(wordBackgroundColorRaw)
                )
                .padding(.top, 40)

                Spacer()
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
    
    private var hasAvailableWords: Bool {
        totalEligibleWordCount > 0
    }

    /// While the user hasn't customised the word screen, keep it on the standard
    /// Light/Dark preset matching the current appearance (theme setting, or the
    /// device's light/dark mode when following the system).
    private func syncDefaultWordScreenStyle() {
        guard !wordScreenCustomised else { return }
        let scheme = colorScheme ?? renderedColorScheme
        WordScreenPreset.standard(for: scheme).writeToDefaults()
    }

    private var timerIndicatorStyle: TimerIndicatorStyle {
        TimerIndicatorStyle(rawValue: timerIndicatorStyleRaw) ?? .dontShow
    }

    private var timerIndicatorPosition: TimerIndicatorPosition {
        TimerIndicatorPosition(rawValue: timerIndicatorPositionRaw)
            ?? timerIndicatorStyle.defaultPosition
    }

    /// The underline placement tracks the word itself, so it's drawn attached to
    /// each word rather than by the full-screen indicator overlay.
    private var isUnderlineIndicator: Bool {
        timerIndicatorStyle == .horizontalLine && timerIndicatorPosition == .underline
    }

    private var timerIndicatorColor: Color {
        WordScreenStyle.resolvedTimerColor(timerIndicatorColorRaw, textColor: wordTextColorRaw)
    }

    /// The "time until next word" indicator chosen in Appearances → Customise
    /// Random Word Screen. Only shown while the automatic timer is running.
    @ViewBuilder
    private var timerIndicatorOverlay: some View {
        if timerIndicatorStyle != .dontShow, !isUnderlineIndicator,
           switchInterval > 0, let nextWordDate {
            TimelineView(.animation) { timeline in
                let remaining = max(0, nextWordDate.timeIntervalSince(timeline.date))
                TimerIndicatorView(
                    style: timerIndicatorStyle,
                    position: timerIndicatorPosition,
                    color: timerIndicatorColor,
                    progress: remaining / switchInterval,
                    secondsRemaining: Int(remaining.rounded(.up)))
            }
            .allowsHitTesting(false)
        }
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
    
    private func showToast(_ message: String) {
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

    /// Far enough that the word is off screen before its replacement arrives.
    private var horizontalFlyOut: CGFloat {
        max(wordScreenSize.width, 500)
    }

    private var verticalFlyOut: CGFloat {
        max(wordScreenSize.height * 0.8, 400)
    }

    /// No action: let the word settle back where it came from.
    private func releaseWord() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            dragOffset = .zero
        }
    }

    /// Fling the word off screen, then perform the action and slide the new word
    /// in from the same side.
    private func commitSwipe(to offset: CGSize, then action: @escaping () -> Void) {
        isCommittingSwipe = true

        withAnimation(.easeInOut(duration: 0.25)) {
            dragOffset = offset
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            action()
            withAnimation(.easeOut(duration: 0.2)) {
                dragOffset = .zero
            }
            isCommittingSwipe = false
        }
    }

    private func handleLeftSwipe() {
        pauseTimer()
        guard !selectedWords.isEmpty else { return releaseWord() }

        commitSwipe(to: CGSize(width: -horizontalFlyOut, height: dragOffset.height)) {
            addToOwnVocab(selectedWords)
            showToast(selectedWords.count == 1 ? "Added word to ownVocab" : "Added words to ownVocab")
            selectRandomWords(recordHistory: true)
        }
    }
    
    private func handleRightSwipe() {
        pauseTimer()
        guard !wordHistory.isEmpty, historyIndex > 0 else { return releaseWord() }

        commitSwipe(to: CGSize(width: horizontalFlyOut, height: dragOffset.height)) {
            historyIndex -= 1
            selectedWords = wordHistory[historyIndex]
            saveHistoryState()
        }
    }
    
    private func handleUpSwipe() {
        guard let word = selectedWords.first,
              let csv = firstSelectedWordSourceCSV else { return releaseWord() }

        pauseTimer()

        commitSwipe(to: CGSize(width: dragOffset.width, height: -verticalFlyOut)) {
            selectedWordSource = (csv, word)
            navigateToCSV = csv
        }
    }
    
    private func handleDownSwipe() {
        guard !selectedWords.isEmpty else { return releaseWord() }

        pauseTimer()

        commitSwipe(to: CGSize(width: dragOffset.width, height: verticalFlyOut)) {
            definitionTarget = DefinitionTarget(words: selectedWords)
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
            } else if let bundleURL = BundledWordlists.url(named: csv) {
                content = try? String(contentsOf: bundleURL)
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
        nextWordDate = nil
        guard switchInterval > 0, isScreenVisible else { return }

        nextWordDate = Date().addingTimeInterval(switchInterval)
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
            nextWordDate = nil
        }
    }

    private func resumeTimer() {
        if switchInterval > 0 {
            updateTimer()
        }
    }
    
    private var getTextColor: Color {
        // No custom colour picked: keep the original grey-when-paused look.
        // With a custom colour, dim it while paused so the pause state stays visible.
        if wordTextColorRaw.isEmpty {
            return timer == nil ? Color.gray : Color.primary
        }
        let custom = Color(hex: wordTextColorRaw)
        return timer == nil ? custom.opacity(0.5) : custom
    }
}
