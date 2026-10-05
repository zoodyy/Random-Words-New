import SwiftUI
import UIKit

/// Lets the screen showing selectable texts check and clear the text
/// selection, which lives in UIKit rather than in SwiftUI state. One instance
/// is shared by every selectable text on a screen.
final class DefinitionTextSelection {
    private let textViews = NSHashTable<UITextView>.weakObjects()

    var isActive: Bool {
        textViews.allObjects.contains { $0.selectedRange.length > 0 }
    }

    /// A text view keeps its selection when the user taps elsewhere on the
    /// screen, so taps outside it are passed in here to clear the selection.
    /// Taps on the text itself are left to UIKit.
    func clear(ifTappedOutsideAt globalLocation: CGPoint) {
        for textView in textViews.allObjects where textView.selectedRange.length > 0 {
            guard !textView.convert(textView.bounds, to: nil).contains(globalLocation) else { continue }
            textView.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    fileprivate func register(_ textView: UITextView) {
        textViews.add(textView)
    }

    /// Only one text holds a selection at a time, as on a web page, so
    /// selecting in one clears whatever was selected in another.
    fileprivate func selectionChanged(in textView: UITextView) {
        guard textView.selectedRange.length > 0 else { return }
        for other in textViews.allObjects where other !== textView && other.selectedRange.length > 0 {
            other.selectedRange = NSRange(location: 0, length: 0)
        }
    }
}

/// A definition and its optional example sentence as text the user can
/// long-press to select, the way text can be selected on a web page. The edit
/// menu gains a "Definition" action that looks up whatever is selected.
struct SelectableDefinitionText: UIViewRepresentable {
    let definition: String
    let example: String?
    let selection: DefinitionTextSelection
    /// Called with the selected text when "Definition" is chosen.
    let onDefine: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct Content: Hashable {
        let definition: String
        let example: String?
        let dynamicTypeSize: DynamicTypeSize
    }

    func makeCoordinator() -> SelectableTextCoordinator {
        SelectableTextCoordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        UITextView.selectableText(delegate: context.coordinator)
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(
            textView,
            content: Content(definition: definition, example: example, dynamicTypeSize: dynamicTypeSize),
            selection: selection,
            onDefine: onDefine,
            makeText: attributedText
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        let proposedWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let fitted = textView.sizeThatFits(CGSize(
            width: proposedWidth ?? .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        ))
        return CGSize(width: proposedWidth ?? ceil(fitted.width), height: ceil(fitted.height))
    }

    /// Matches the look of the SwiftUI text this replaced: the definition in
    /// body text, then the example in secondary italics 12 points below it.
    private func attributedText() -> NSAttributedString {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let bodyFont = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.paragraphSpacing = 12

        let text = NSMutableAttributedString(string: definition, attributes: [
            .font: bodyFont,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraphStyle
        ])

        if let example {
            let italicFont = bodyFont.fontDescriptor.withSymbolicTraits(.traitItalic)
                .map { UIFont(descriptor: $0, size: 0) } ?? bodyFont
            text.append(NSAttributedString(string: "\n“\(example)”", attributes: [
                .font: italicFont,
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraphStyle
            ]))
        }

        return text
    }
}

/// The word at the top of a definition screen, selectable like the definition
/// below it, so part of a long entry — one word out of an idiom or a tongue
/// twister — can be looked up on its own.
struct SelectableWordTitle: View {
    let word: String
    let selection: DefinitionTextSelection
    /// Called with the selected text when "Definition" is chosen.
    let onDefine: (String) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // The bold large title the word was shown in before it was selectable.
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        let largeTitle = UIFont.preferredFont(forTextStyle: .largeTitle, compatibleWith: traits)
        let font = largeTitle.fontDescriptor.withSymbolicTraits(.traitBold)
            .map { UIFont(descriptor: $0, size: 0) } ?? largeTitle

        WordTitleTextView(word: word, font: font, selection: selection, onDefine: onDefine)
            // SwiftUI can't see a text view's baseline, so it's given one here
            // to keep the pronunciation button beside it level with the first
            // line of the word.
            .alignmentGuide(.firstTextBaseline) { _ in font.ascender }
    }
}

private struct WordTitleTextView: UIViewRepresentable {
    let word: String
    let font: UIFont
    let selection: DefinitionTextSelection
    let onDefine: (String) -> Void

    struct Content: Hashable {
        let word: String
        let font: UIFont
    }

    func makeCoordinator() -> SelectableTextCoordinator {
        SelectableTextCoordinator()
    }

    func makeUIView(context: Context) -> UITextView {
        UITextView.selectableText(delegate: context.coordinator)
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.update(
            textView,
            content: Content(word: word, font: font),
            selection: selection,
            onDefine: onDefine
        ) {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            return NSAttributedString(string: word, attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraphStyle
            ])
        }
    }

    /// Only as wide as the word on one line, so the pronunciation button can
    /// sit right next to it; a word too long for that wraps instead.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView textView: UITextView, context: Context) -> CGSize? {
        let unbounded = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        let oneLineWidth = ceil(textView.sizeThatFits(unbounded).width)
        let width = proposal.width.map { min($0, oneLineWidth) } ?? oneLineWidth
        let fitted = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(fitted.height))
    }
}

/// Shared by the selectable texts: adds "Definition" to their edit menu and
/// keeps their selections from overlapping.
final class SelectableTextCoordinator: NSObject, UITextViewDelegate {
    private var selection: DefinitionTextSelection?
    private var onDefine: (String) -> Void = { _ in }
    private var content: AnyHashable?

    func update(
        _ textView: UITextView,
        content: AnyHashable,
        selection: DefinitionTextSelection,
        onDefine: @escaping (String) -> Void,
        makeText: () -> NSAttributedString
    ) {
        self.onDefine = onDefine
        self.selection = selection
        selection.register(textView)

        // Reassigning the text clears the selection, so only do it when what
        // is shown has actually changed.
        guard self.content != content else { return }
        self.content = content
        textView.attributedText = makeText()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        selection?.selectionChanged(in: textView)
    }

    func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
        let text = textView.attributedText.string as NSString
        let selectedText = ranges
            .map { text.substring(with: $0.rangeValue) }
            .joined(separator: " ")
        guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let define = UIAction(title: "Definition", image: UIImage(systemName: "character.book.closed")) { [weak self, weak textView] _ in
            textView?.selectedRange = NSRange(location: 0, length: 0)
            self?.onDefine(selectedText)
        }
        return UIMenu(children: [define] + suggestedActions)
    }
}

private extension UITextView {
    /// Read-only text the user can select, laid out edge to edge and sized by
    /// SwiftUI rather than scrolling itself.
    static func selectableText(delegate: UITextViewDelegate) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.delegate = delegate
        return textView
    }
}
