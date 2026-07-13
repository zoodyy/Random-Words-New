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
        case .horizontalLine: return [.top, .bottom]
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

    var id: String { rawValue }

    var alignment: Alignment {
        switch self {
        case .top:         return .top
        case .bottom:      return .bottom
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

/// Default values. Text and background colour default to an empty string,
/// meaning "follow the app theme" (primary text on the system background), so
/// nothing changes until the user actually picks a colour.
enum WordVisualDefaults {
    static let textColor       = ""
    static let backgroundColor = ""
    static let timerStyle      = TimerIndicatorStyle.dontShow.rawValue
    static let timerPosition   = TimerIndicatorPosition.bottom.rawValue
    static let timerColor      = "#34C759"
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

    var body: some View {
        GeometryReader { geo in
            Group {
                switch style {
                case .dontShow:
                    EmptyView()
                case .horizontalLine:
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, geo.size.width * progress), height: 5)
                        .padding(.vertical, 6)
                case .verticalLine:
                    Capsule()
                        .fill(color)
                        .frame(width: 5, height: max(0, geo.size.height * progress))
                        .padding(.horizontal, 6)
                case .circle:
                    ZStack {
                        Circle()
                            .stroke(color.opacity(0.25), lineWidth: 4)
                        Circle()
                            .trim(from: 0, to: max(0, min(1, progress)))
                            .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 30, height: 30)
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
            }

            Section("Background") {
                ColorPicker("Background colour", selection: backgroundColorBinding, supportsOpacity: false)
            }

            Section {
                Picker("Show time until next word", selection: $timerStyle) {
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
                    ColorPicker("Colour", selection: colorBinding($timerColor), supportsOpacity: false)
                }
            } header: {
                Text("Time until next word")
            } footer: {
                Text("Shows how long is left before the next random word appears. Hidden in manual mode.")
            }
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

    // MARK: - Preview

    /// The preview, pinned above the scrolling form. While the form scrolls, the
    /// preview doesn't move away; it collapses instead, cropping the canvas from
    /// top and bottom (never rescaling the drawing) until only the central band
    /// with the demo word remains.
    private func collapsiblePreview(width: CGFloat, fullHeight: CGFloat) -> some View {
        let minHeight = max(fullHeight * 0.38, 44)
        let visibleHeight = min(fullHeight, max(minHeight, fullHeight - max(0, scrollOffset)))
        let topCrop = (fullHeight - visibleHeight) / 2

        return previewContent(height: fullHeight)
            .frame(width: width, height: fullHeight)
            .offset(y: -topCrop)
            .frame(width: width, height: visibleHeight, alignment: .top)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.3)))
            .padding(.horizontal, Self.previewSidePadding)
            .padding(.vertical, Self.previewVerticalPadding)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
    }

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
                    .padding(.horizontal, 12)

                if selectedStyle != .dontShow {
                    TimerIndicatorView(
                        style: selectedStyle,
                        position: TimerIndicatorPosition(rawValue: timerPosition)
                            ?? selectedStyle.defaultPosition,
                        color: Color(hex: timerColor),
                        progress: remaining / Self.demoInterval,
                        secondsRemaining: Int(remaining.rounded(.up)))
                }
            }
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

    private func colorBinding(_ raw: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hex: raw.wrappedValue) },
                set: { raw.wrappedValue = $0.hexString })
    }
}
