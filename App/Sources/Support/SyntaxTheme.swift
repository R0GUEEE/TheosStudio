import UIKit
import TheosStudioCore

/// Colours for the editor.
///
/// The token *ranges* come from the engine (and are tested there); this only maps
/// a kind to a colour, which is the part that cannot be tested without a device.
enum SyntaxTheme {

    static func color(for kind: SyntaxToken.Kind) -> UIColor {
        switch kind {
        case .keyword: return .systemPink
        case .type: return .systemTeal
        case .string: return .systemRed
        case .comment: return .secondaryLabel
        case .number: return .systemOrange
        case .preprocessor: return .systemPurple
        case .directive: return .systemIndigo
        case .variable: return .systemBlue
        case .field: return .systemBlue
        }
    }

    /// The editor's default attributes plus one colour per token.
    ///
    /// Colour is the only attribute set, so the text storage keeps the font and
    /// the paragraph style the text view already has.
    static func apply(
        to text: String,
        language: SyntaxLanguage,
        in storage: NSTextStorage,
        font: UIFont,
        textColor: UIColor
    ) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: textColor], range: full)
        for token in SyntaxHighlighter.tokens(in: text, language: language) {
            let range = token.range
            guard range.location >= 0, range.location + range.length <= storage.length else { continue }
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: range)
        }
        storage.endEditing()
    }
}
