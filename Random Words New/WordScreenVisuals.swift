import SwiftUI
import UIKit

// Customisable look of the random-word screen. The settings are stored in
// UserDefaults and shared between the live word screen (ContentView) and the
// preview in Settings → Appearances → Customise Random Word Screen, so the
// preview matches the real thing.

// MARK: - Color <-> hex (so colours can live in UserDefaults / @AppStorage)

extension Color {
    /// Build a colour from a "#RRGGBB" (or "RRGGBBAA") hex string. Falls back to
    /// black for an unparseable string rather than failing.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).uppercased()
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    /// "#RRGGBB" representation, used to persist a colour picked from the wheel.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}

// MARK: - Shared word font

/// The font choices offered for the random words.
let availableWordFonts: [String] = [
    "Default",
    "Slackey",
    "Avenir Next",
    "Georgia",
    "Helvetica Neue",
    "Futura",
    "Chalkboard",
    "Marker Felt",
    "Palatino",
    "Gill Sans",
    "Baskerville",
    "American Typewriter",
    "Copperplate"
]

/// Maps the stored font name to a `Font`, shared between the live word screen
/// and the settings preview so both render identically.
func wordDisplayFont(named name: String, size: CGFloat) -> Font {
    switch name {
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

// MARK: - Timer indicator choices

/// How the time remaining until the next random word is visualised.
enum TimerIndicatorStyle: String, CaseIterable, Identifiable {
    case dontShow       = "Don't show"
    case horizontalLine = "Horizontal line"
    case verticalLine   = "Vertical line"
    case circle         = "Circle"
    case seconds        = "Number in seconds"

    var id: String { rawValue }

    /// The placements that make sense for this style.
    var positions: [TimerIndicatorPosition] {
        switch self {
        case .dontShow:       return []
        case .horizontalLine: return [.top, .bottom, .underline]
        case .verticalLine:   return [.left, .right]
        case .circle, .seconds:
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        }
    }

    var defaultPosition: TimerIndicatorPosition {
        switch self {
        case .horizontalLine:   return .bottom
        case .verticalLine:     return .right
        case .circle, .seconds: return .topRight
        case .dontShow:         return .bottom
        }
    }
}

/// Where the timer indicator sits on the word screen.
enum TimerIndicatorPosition: String, CaseIterable, Identifiable {
    case top         = "Top"
    case bottom      = "Bottom"
    case left        = "Left"
    case right       = "Right"
    case topLeft     = "Top left"
    case topRight    = "Top right"
    case bottomLeft  = "Bottom left"
    case bottomRight = "Bottom right"
    case underline   = "Underlining word"

    var id: String { rawValue }

    var alignment: Alignment {
        switch self {
        case .top:         return .top
        case .bottom, .underline: return .bottom
        case .left:        return .leading
        case .right:       return .trailing
        case .topLeft:     return .topLeading
        case .topRight:    return .topTrailing
        case .bottomLeft:  return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

// MARK: - Stored keys & defaults

enum WordVisualKeys {
    static let textColor       = "word_textColor"
    static let backgroundColor = "word_backgroundColor"
    static let timerStyle      = "word_timerStyle"
    static let timerPosition   = "word_timerPosition"
    static let timerColor      = "word_timerColor"
}

/// Default values. Colours default to an empty string meaning "not picked yet":
/// text follows the app theme, the background stays the system background, and
/// the timer indicator matches whatever colour the word has.
enum WordVisualDefaults {
    static let textColor       = ""
    static let backgroundColor = ""
    static let timerStyle      = TimerIndicatorStyle.dontShow.rawValue
    static let timerPosition   = TimerIndicatorPosition.bottom.rawValue
    static let timerColor      = ""
}

enum WordScreenStyle {
    /// The word colour to draw with: the picked colour, or the theme default.
    static func resolvedTextColor(_ raw: String) -> Color {
        raw.isEmpty ? .primary : Color(hex: raw)
    }

    /// The screen background: the picked colour, or the system background.
    static func resolvedBackground(_ raw: String) -> Color {
        raw.isEmpty ? Color(.systemBackground) : Color(hex: raw)
    }

    /// The timer indicator's colour: the picked colour, or the word's colour.
    static func resolvedTimerColor(_ raw: String, textColor: String) -> Color {
        raw.isEmpty ? resolvedTextColor(textColor) : Color(hex: raw)
    }
}

// MARK: - Timer indicator

/// Draws the "time until next word" indicator. `progress` is the fraction of
/// the interval still remaining (1 → 0), so lines shrink and the circle empties
/// as the next word approaches. Shared by the live screen and the preview.
struct TimerIndicatorView: View {
    let style: TimerIndicatorStyle
    let position: TimerIndicatorPosition
    let color: Color
    let progress: Double
    let secondsRemaining: Int

    /// Shrinks the circle style (1 = full size). Used by the settings preview,
    /// which scales the circle down as the preview collapses.
    var circleScale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Group {
                switch style {
                case .dontShow:
                    EmptyView()
                case .horizontalLine:
                    // The underline placement tracks the word itself and is drawn
                    // attached to the word text via `timerUnderline`, not here.
                    if position == .underline {
                        EmptyView()
                    } else {
                        Capsule()
                            .fill(color)
                            .frame(width: max(0, geo.size.width * progress), height: 5)
                            .padding(.vertical, 6)
                    }
                case .verticalLine:
                    Capsule()
                        .fill(color)
                        .frame(width: 5, height: max(0, geo.size.height * progress))
                        .padding(.horizontal, 6)
                case .circle:
                    Circle()
                        .trim(from: 0, to: max(0, min(1, progress)))
                        .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30 * circleScale, height: 30 * circleScale)
                        .padding(10)
                case .seconds:
                    Text("\(secondsRemaining)")
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundColor(color)
                        .padding(10)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: position.alignment)
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// The "Underlining word" placement of the horizontal-line indicator: a line
    /// hugging this word text's width, drawn just beneath it, shrinking towards
    /// its centre as the next word approaches. Attached to the word rather than
    /// the screen so it exactly underlines the word wherever it sits.
    func timerUnderline(active: Bool, color: Color, nextWordDate: Date?, interval: Double) -> some View {
        overlay(alignment: .bottom) {
            if active, let nextWordDate, interval > 0 {
                TimelineView(.animation) { timeline in
                    let remaining = max(0, nextWordDate.timeIntervalSince(timeline.date))
                    Capsule()
                        .fill(color)
                        .frame(height: 5)
                        .scaleEffect(x: max(0, min(1, remaining / interval)), anchor: .center)
                        .offset(y: 10)
                }
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Presets

/// A complete, matching set of word-screen settings that can be applied in one
/// tap from the Presets section of the customise screen.
struct WordScreenPreset: Identifiable {
    let name: String
    let textColor: String
    let backgroundColor: String
    let font: String
    let timerStyle: TimerIndicatorStyle
    let timerPosition: TimerIndicatorPosition
    let timerColor: String

    var id: String { name }

    static let all: [WordScreenPreset] = [
        // The standard light/dark appearances, with and without a faint grey
        // underline as the word timer.
        WordScreenPreset(name: "Light Minimal",
                         textColor: "#000000", backgroundColor: "#FFFFFF",
                         font: "American Typewriter",
                         timerStyle: .dontShow, timerPosition: .bottom,
                         timerColor: "#D1D1D6"),
        WordScreenPreset(name: "Dark Minimal",
                         textColor: "#FFFFFF", backgroundColor: "#000000",
                         font: "American Typewriter",
                         timerStyle: .dontShow, timerPosition: .bottom,
                         timerColor: "#3A3A3C"),
        WordScreenPreset(name: "Light",
                         textColor: "#000000", backgroundColor: "#FFFFFF",
                         font: "American Typewriter",
                         timerStyle: .horizontalLine, timerPosition: .underline,
                         timerColor: "#D1D1D6"),
        WordScreenPreset(name: "Dark",
                         textColor: "#FFFFFF", backgroundColor: "#000000",
                         font: "American Typewriter",
                         timerStyle: .horizontalLine, timerPosition: .underline,
                         timerColor: "#3A3A3C"),

        // Colour themes. Each keeps its word, background and timer colours in
        // the same palette.
        WordScreenPreset(name: "Bubblegum",
                         textColor: "#D6336C", backgroundColor: "#FFD1DC",
                         font: "Marker Felt",
                         timerStyle: .circle, timerPosition: .topRight,
                         timerColor: "#FF8FAB"),
        WordScreenPreset(name: "Ocean",
                         textColor: "#7FDBFF", backgroundColor: "#0A2E4D",
                         font: "Avenir Next",
                         timerStyle: .verticalLine, timerPosition: .right,
                         timerColor: "#4FB3D9"),
        WordScreenPreset(name: "Forest",
                         textColor: "#D8F3DC", backgroundColor: "#1B3022",
                         font: "Georgia",
                         timerStyle: .horizontalLine, timerPosition: .bottom,
                         timerColor: "#588157"),
        WordScreenPreset(name: "Sunset",
                         textColor: "#FF9E64", backgroundColor: "#4A1942",
                         font: "Futura",
                         timerStyle: .circle, timerPosition: .topRight,
                         timerColor: "#E05263"),
        WordScreenPreset(name: "Midnight",
                         textColor: "#E0E1DD", backgroundColor: "#0D1B2A",
                         font: "Helvetica Neue",
                         timerStyle: .seconds, timerPosition: .topRight,
                         timerColor: "#778DA9"),
        WordScreenPreset(name: "Lemonade",
                         textColor: "#F57F17", backgroundColor: "#FFF9C4",
                         font: "Chalkboard",
                         timerStyle: .horizontalLine, timerPosition: .top,
                         timerColor: "#FBC02D"),
        WordScreenPreset(name: "Lavender",
                         textColor: "#5E4B8B", backgroundColor: "#E6E0F8",
                         font: "Baskerville",
                         timerStyle: .verticalLine, timerPosition: .left,
                         timerColor: "#9D8CD6"),
        WordScreenPreset(name: "Mint",
                         textColor: "#1B7A5A", backgroundColor: "#DFF7EC",
                         font: "Gill Sans",
                         timerStyle: .horizontalLine, timerPosition: .underline,
                         timerColor: "#7CCDB0"),
        WordScreenPreset(name: "Terracotta",
                         textColor: "#FFF3E4", backgroundColor: "#B85C38",
                         font: "Palatino",
                         timerStyle: .circle, timerPosition: .bottomRight,
                         timerColor: "#E0A458"),
        WordScreenPreset(name: "Slate",
                         textColor: "#CAD2C5", backgroundColor: "#2F3E46",
                         font: "Default",
                         timerStyle: .horizontalLine, timerPosition: .bottom,
                         timerColor: "#84A98C"),
        WordScreenPreset(name: "Coffee",
                         textColor: "#D7CCC8", backgroundColor: "#3E2723",
                         font: "American Typewriter",
                         timerStyle: .seconds, timerPosition: .bottomLeft,
                         timerColor: "#A1887F")
    ]
}

// MARK: - Settings screen

/// Customises the look of the random-word screen. A live preview at the top —
/// a small cut-out showing demo words — updates as the controls below are
/// changed, so the effect of each setting is immediately visible.
struct CustomiseWordScreenView: View {
    @AppStorage(WordVisualKeys.textColor)       private var textColor       = WordVisualDefaults.textColor
    @AppStorage(WordVisualKeys.backgroundColor) private var backgroundColor = WordVisualDefaults.backgroundColor
    @AppStorage(WordVisualKeys.timerStyle)      private var timerStyle      = WordVisualDefaults.timerStyle
    @AppStorage(WordVisualKeys.timerPosition)   private var timerPosition   = WordVisualDefaults.timerPosition
    @AppStorage(WordVisualKeys.timerColor)      private var timerColor      = WordVisualDefaults.timerColor
    @AppStorage("selectedWordFont")             private var selectedWordFontRaw = "American Typewriter"

    /// Anchors the preview's clock so the demo starts at the first word with a
    /// full interval when the screen appears.
    @State private var start = Date()

    /// Demo content cycled by the preview at a fixed rate, standing in for the
    /// real random words.
    private static let demoWords = ["Serendipity", "Wanderlust", "Ephemeral", "Luminous", "Quixotic"]
    private static let demoInterval: Double = 3

    /// Layout of the pinned preview above the form.
    private static let previewSidePadding: CGFloat = 20
    private static let previewVerticalPadding: CGFloat = 6

    /// How far the form below the preview is scrolled (0 at rest, grows downward).
    /// Drives the collapsing crop of the pinned preview.
    @State private var scrollOffset: CGFloat = 0

    private var selectedStyle: TimerIndicatorStyle {
        TimerIndicatorStyle(rawValue: timerStyle) ?? .dontShow
    }

    private var selectedPosition: TimerIndicatorPosition {
        TimerIndicatorPosition(rawValue: timerPosition) ?? selectedStyle.defaultPosition
    }

    /// The underline placement is drawn attached to the word, not via the
    /// full-screen indicator overlay.
    private var isUnderlineSelected: Bool {
        selectedStyle == .horizontalLine && selectedPosition == .underline
    }

    var body: some View {
        GeometryReader { geo in
            let previewWidth = max(0, geo.size.width - 2 * Self.previewSidePadding)
            settingsForm
                .contentMargins(.top, previewWidth + 2 * Self.previewVerticalPadding)
                .onScrollGeometryChange(for: CGFloat.self) { scroll in
                    scroll.contentOffset.y + scroll.contentInsets.top
                } action: { _, offset in
                    scrollOffset = offset
                }
                .overlay(alignment: .top) {
                    collapsiblePreview(width: previewWidth, fullHeight: previewWidth)
                }
        }
        .navigationTitle("Random Word Screen")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var settingsForm: some View {
        Form {
            Section("Words") {
                ColorPicker("Text colour", selection: textColorBinding, supportsOpacity: false)
                Picker("Word font", selection: $selectedWordFontRaw) {
                    ForEach(availableWordFonts, id: \.self) { fontName in
                        Text(fontName)
                            .font(wordDisplayFont(named: fontName, size: 17))
                            .tag(fontName)
                    }
                }
                // The default menu style ignores per-item fonts, so push a list
                // instead, where each font name renders in its own font.
                .pickerStyle(.navigationLink)
            }

            Section("Background") {
                ColorPicker("Background colour", selection: backgroundColorBinding, supportsOpacity: false)
            }

            Section {
                Picker("Timeline", selection: $timerStyle) {
                    ForEach(TimerIndicatorStyle.allCases) { style in
                        Text(style.rawValue).tag(style.rawValue)
                    }
                }
                if selectedStyle != .dontShow {
                    Picker("Position", selection: $timerPosition) {
                        ForEach(selectedStyle.positions) { position in
                            Text(position.rawValue).tag(position.rawValue)
                        }
                    }
                    ColorPicker("Colour", selection: timerColorBinding, supportsOpacity: false)
                }
            } header: {
                Text("Time until next word")
            } footer: {
                Text("Shows how long is left before the next random word appears. Hidden in manual mode.")
            }

            presetsSection
        }
        .onChange(of: timerStyle) {
            // Each style has its own sensible placements; drop invalid leftovers
            // when switching styles.
            let style = selectedStyle
            guard style != .dontShow else { return }
            if !style.positions.contains(where: { $0.rawValue == timerPosition }) {
                timerPosition = style.defaultPosition.rawValue
            }
        }
    }

    // MARK: - Presets

    private var presetsSection: some View {
        Section {
            ForEach(WordScreenPreset.all) { preset in
                Button {
                    apply(preset)
                } label: {
                    HStack {
                        presetSwatch(preset)
                        Text(preset.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if matchesCurrent(preset) {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        } header: {
            Text("Presets")
        } footer: {
            Text("Select a preset to apply its colours, font and timer style. You can still tweak everything above afterwards.")
        }
    }

    /// A small sample of the preset: its word colour on its background.
    private func presetSwatch(_ preset: WordScreenPreset) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: preset.backgroundColor))
            .frame(width: 42, height: 28)
            .overlay(
                Text("Aa")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(hex: preset.textColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.gray.opacity(0.3)))
    }

    private func apply(_ preset: WordScreenPreset) {
        textColor = preset.textColor
        backgroundColor = preset.backgroundColor
        selectedWordFontRaw = preset.font
        timerStyle = preset.timerStyle.rawValue
        timerPosition = preset.timerPosition.rawValue
        timerColor = preset.timerColor
    }

    private func matchesCurrent(_ preset: WordScreenPreset) -> Bool {
        textColor == preset.textColor
            && backgroundColor == preset.backgroundColor
            && selectedWordFontRaw == preset.font
            && timerStyle == preset.timerStyle.rawValue
            && (timerStyle == TimerIndicatorStyle.dontShow.rawValue
                || (timerPosition == preset.timerPosition.rawValue
                    && timerColor == preset.timerColor))
    }

    // MARK: - Preview

    /// How small the preview may collapse, as a fraction of its full height.
    /// Styles that sit above/below the word need a taller collapsed state so the
    /// indicator keeps a little distance from the word.
    private var collapsedMinHeightFactor: CGFloat {
        switch selectedStyle {
        case .dontShow:         return 0.38
        case .horizontalLine:   return 0.46
        case .verticalLine:     return 0.42
        case .circle, .seconds: return 0.52
        }
    }

    /// The preview, pinned above the scrolling form. While the form scrolls, the
    /// preview doesn't move away; it collapses instead, cropping the canvas from
    /// top and bottom (never rescaling the drawing) until only the central band
    /// with the demo word remains. The timer indicator isn't cropped with the
    /// canvas: it's re-overlaid on the visible part so it always stays on screen.
    private func collapsiblePreview(width: CGFloat, fullHeight: CGFloat) -> some View {
        let minHeight = max(fullHeight * collapsedMinHeightFactor, 44)
        let visibleHeight = min(fullHeight, max(minHeight, fullHeight - max(0, scrollOffset)))
        let topCrop = (fullHeight - visibleHeight) / 2
        let collapsible = fullHeight - minHeight
        let collapseFraction = collapsible > 0 ? (fullHeight - visibleHeight) / collapsible : 0

        return previewContent(height: fullHeight)
            .frame(width: width, height: fullHeight)
            .offset(y: -topCrop)
            .frame(width: width, height: visibleHeight, alignment: .top)
            .overlay {
                if selectedStyle != .dontShow, !isUnderlineSelected {
                    indicatorOverlay(circleScale: 1 - 0.35 * collapseFraction)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.3)))
            .padding(.horizontal, Self.previewSidePadding)
            .padding(.vertical, Self.previewVerticalPadding)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
    }

    /// The croppable canvas: background and cycling demo word only.
    private func previewContent(height: CGFloat) -> some View {
        TimelineView(.animation) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(start))
            let cycle = Int(elapsed / Self.demoInterval)
            let remaining = Self.demoInterval - elapsed.truncatingRemainder(dividingBy: Self.demoInterval)
            let word = Self.demoWords[cycle % Self.demoWords.count]

            ZStack {
                WordScreenStyle.resolvedBackground(backgroundColor)

                Text(word)
                    .font(wordDisplayFont(named: selectedWordFontRaw, size: height * 0.16))
                    .bold()
                    .foregroundColor(WordScreenStyle.resolvedTextColor(textColor))
                    .lineLimit(1)
                    .minimumScaleFactor(0.2)
                    .timerUnderline(
                        active: isUnderlineSelected,
                        color: WordScreenStyle.resolvedTimerColor(timerColor, textColor: textColor),
                        nextWordDate: timeline.date.addingTimeInterval(remaining),
                        interval: Self.demoInterval)
                    // Leave room next to the word when a line runs down an edge.
                    .padding(.horizontal, selectedStyle == .verticalLine ? 28 : 12)
            }
        }
    }

    /// The timer indicator, drawn over the visible (possibly collapsed) part of
    /// the preview so it never gets cropped away. Runs on the same clock as the
    /// word cycling above, so word changes and the countdown stay in sync.
    private func indicatorOverlay(circleScale: CGFloat) -> some View {
        TimelineView(.animation) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(start))
            let remaining = Self.demoInterval - elapsed.truncatingRemainder(dividingBy: Self.demoInterval)

            TimerIndicatorView(
                style: selectedStyle,
                position: TimerIndicatorPosition(rawValue: timerPosition)
                    ?? selectedStyle.defaultPosition,
                color: WordScreenStyle.resolvedTimerColor(timerColor, textColor: textColor),
                progress: remaining / Self.demoInterval,
                secondsRemaining: Int(remaining.rounded(.up)),
                circleScale: circleScale)
        }
    }

    // MARK: - Helpers

    /// Bridges the hex-string @AppStorage value to the `Color` a ColorPicker
    /// expects, showing the theme default while no colour has been picked.
    private var textColorBinding: Binding<Color> {
        Binding(get: { WordScreenStyle.resolvedTextColor(textColor) },
                set: { textColor = $0.hexString })
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(get: { WordScreenStyle.resolvedBackground(backgroundColor) },
                set: { backgroundColor = $0.hexString })
    }

    private var timerColorBinding: Binding<Color> {
        Binding(get: { WordScreenStyle.resolvedTimerColor(timerColor, textColor: textColor) },
                set: { timerColor = $0.hexString })
    }
}
