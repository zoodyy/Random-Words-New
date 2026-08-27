import SwiftUI

/// The four cardinal swipe actions of the random-word screen.
///
/// The word follows the finger while it is dragged; on release the drag is
/// resolved to one of these (or to nothing, and the word springs back).
enum WordSwipeDirection {
    case up, down, left, right

    /// Shortest wording that still says what the swipe does. Shown next to the
    /// matching arrow while the word is held.
    var label: String {
        switch self {
        case .up:    return "Wordlist"
        case .down:  return "Definition"
        case .left:  return "ownVocab"
        case .right: return "Back"
        }
    }

    var arrowSymbol: String {
        switch self {
        case .up:    return "arrow.up"
        case .down:  return "arrow.down"
        case .left:  return "arrow.left"
        case .right: return "arrow.right"
        }
    }

    var isHorizontal: Bool {
        self == .left || self == .right
    }
}

/// Legend shown in the empty space above the word while the word is being
/// dragged: one arrow per cardinal direction with the action it triggers.
///
/// The direction the drag would currently commit to is highlighted, and
/// directions that can't do anything right now (nothing to go back to, unknown
/// source wordlist) are dimmed, so the hint doubles as live feedback.
struct WordSwipeCompass: View {

    /// The direction the drag is currently armed for, if any.
    let activeDirection: WordSwipeDirection?
    /// Directions that would do nothing if swiped right now.
    let unavailable: Set<WordSwipeDirection>
    let color: Color
    let background: Color

    var body: some View {
        VStack(spacing: 2) {
            item(.up)

            HStack(spacing: 12) {
                item(.left)
                Spacer(minLength: 16)
                item(.right)
            }
            .padding(.vertical, 2)

            item(.down)
        }
        .font(.footnote.weight(.semibold))
        .frame(maxWidth: 240)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(background.opacity(0.9))
        )
    }

    /// Arrows point outwards, labels sit on the inside, so the whole thing reads
    /// as a compass around the word's resting place.
    @ViewBuilder
    private func item(_ direction: WordSwipeDirection) -> some View {
        let arrow = Image(systemName: direction.arrowSymbol)
        let label = Text(direction.label)

        Group {
            switch direction {
            case .up:
                VStack(spacing: 1) { arrow; label }
            case .down:
                VStack(spacing: 1) { label; arrow }
            case .left:
                HStack(spacing: 4) { arrow; label }
            case .right:
                HStack(spacing: 4) { label; arrow }
            }
        }
        .foregroundColor(color)
        .opacity(opacity(for: direction))
        .scaleEffect(activeDirection == direction ? 1.18 : 1)
        .animation(.easeOut(duration: 0.12), value: activeDirection)
    }

    private func opacity(for direction: WordSwipeDirection) -> Double {
        if unavailable.contains(direction) { return 0.2 }
        return activeDirection == direction ? 1 : 0.45
    }
}
