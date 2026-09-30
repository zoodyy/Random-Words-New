import SwiftUI
import UIKit

/// Lets the screen showing a `SelectableDefinitionText` check and clear the
/// text selection, which lives in UIKit rather than in SwiftUI state.
final class DefinitionTextSelection {
    fileprivate weak var textView: UITextView?

    var isActive: Bool {
        (textView?.selectedRange.length ?? 0) > 0
    }

    /// A text view keeps its selection when the user taps elsewhere on the
    /// screen, so taps outside it are passed in here to clear the selection.
    /// Taps on the text itself are left to UIKit.
    func clear(ifTappedOutsideAt globalLocation: CGPoint) {
        guard let textView, isActive else { return }
        guard !textView.convert(textView.bounds, to: nil).contains(globalLocation) else { return }
        textView.selectedRange = NSRange(location: 0, length: 0)
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

    struct Content: Equatable {
        let definition: String
        let example: String?
        let dynamicTypeSize: DynamicTypeSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.dataDetectorTypes = []
        textView.delegate = context.coordinator
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        selection.textView = textView

        // Reassigning the text clears the selection, so only do it when what
        // is shown has actually changed.
        let content = Content(definition: definition, example: example, dynamicTypeSize: dynamicTypeSize)
        guard context.coordinator.content != content else { return }
        context.coordinator.content = content
        textView.attributedText = attributedText()
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

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableDefinitionText
        var content: Content?

        init(parent: SelectableDefinitionText) {
            self.parent = parent
        }

        func textView(_ textView: UITextView, editMenuForTextInRanges ranges: [NSValue], suggestedActions: [UIMenuElement]) -> UIMenu? {
            let text = textView.attributedText.string as NSString
            let selectedText = ranges
                .map { text.substring(with: $0.rangeValue) }
                .joined(separator: " ")
            guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            let define = UIAction(title: "Definition", image: UIImage(systemName: "character.book.closed")) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.parent.onDefine(selectedText)
            }
            return UIMenu(children: [define] + suggestedActions)
        }
    }
}
