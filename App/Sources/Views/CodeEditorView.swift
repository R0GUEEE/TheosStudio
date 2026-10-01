import SwiftUI
import UIKit
import TheosStudioCore

/// A text file, editable, with the engine's syntax tokens turned into colours.
///
/// The editor saves explicitly *and* on the way out: losing a tweak because the
/// back button was tapped is the kind of bug that ends a session.
struct CodeEditorView: View {

    let path: String
    let fontSize: CGFloat
    var scrollToLine: Int?

    @State private var text = ""
    @State private var saved = ""
    @State private var loadFailure: String?

    private var language: SyntaxLanguage { SyntaxLanguage.forFileName(path) }
    private var fileName: String { (path as NSString).lastPathComponent }
    private var isModified: Bool { text != saved }

    var body: some View {
        VStack(spacing: 0) {
            if let loadFailure {
                Text(loadFailure)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }
            CodeTextView(text: $text, language: language, fontSize: fontSize, scrollToLine: scrollToLine)
            Divider()
            HStack(spacing: 12) {
                Text(languageName)
                Spacer()
                Text("\(text.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                Text("\(text.utf8.count) bytes")
                if isModified {
                    Text("modified").foregroundColor(.orange)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(.secondarySystemBackground))
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Section("Append a snippet") {
                        ForEach(SnippetLibrary.all) { snippet in
                            Button(snippet.title) { append(snippet) }
                        }
                    }
                } label: {
                    Label("Snippets", systemImage: "text.badge.plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Save", action: save).disabled(!isModified)
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    private var languageName: String {
        switch language {
        case .code: return "Objective-C / Logos"
        case .makefile: return "Makefile"
        case .controlFile: return "Debian control"
        case .plist: return "Property list"
        case .plainText: return "Text"
        }
    }

    private func load() {
        guard text.isEmpty else { return }
        if let contents = FS.read(path) {
            text = contents
            saved = contents
        } else {
            loadFailure = "Could not read \(path) as text. It may be binary, or unreadable by this app."
        }
    }

    /// Appends a snippet to the end of the file and saves. Inserting at the caret
    /// would need the text view's selection to travel through SwiftUI and back,
    /// and the end of the file is where a new hook block belongs anyway.
    private func append(_ snippet: Snippet) {
        if !text.isEmpty, !text.hasSuffix("\n") {
            text += "\n"
        }
        text += "\n" + snippet.body
        save()
    }

    private func save() {
        guard isModified else { return }
        do {
            try FS.write(text, to: path)
            saved = text
            loadFailure = nil
        } catch {
            loadFailure = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// The `UITextView` itself. SwiftUI's `TextEditor` cannot colour ranges, and
/// colouring ranges is most of what makes Logos readable.
struct CodeTextView: UIViewRepresentable {

    @Binding var text: String
    let language: SyntaxLanguage
    let fontSize: CGFloat
    let scrollToLine: Int?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language, fontSize: fontSize)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        // Every "helpful" keyboard feature is wrong for code.
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.spellCheckingType = .no
        view.keyboardType = .asciiCapable
        view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.text = text
        view.inputAccessoryView = context.coordinator.makeAccessoryView()
        context.coordinator.highlight(view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.language = language
        if view.font?.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            coordinator.highlight(view)
        }
        if !coordinator.isEditing, view.text != text {
            view.text = text
            coordinator.highlight(view)
        }
        if let line = scrollToLine, !coordinator.didScroll {
            coordinator.didScroll = true
            coordinator.scroll(toLine: line, in: view)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {

        var language: SyntaxLanguage
        var fontSize: CGFloat
        var isEditing = false
        var didScroll = false
        private var binding: Binding<String>
        /// Highlighting writes attributes into the same storage the delegate is
        /// notified about, so it has to be re-entrancy safe.
        private var isHighlighting = false

        init(text: Binding<String>, language: SyntaxLanguage, fontSize: CGFloat) {
            self.binding = text
            self.language = language
            self.fontSize = fontSize
        }

        private var font: UIFont { UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }

        func highlight(_ view: UITextView) {
            // A megabyte of source is not a tweak; skip rather than stall the
            // keyboard on a file that was opened by accident.
            guard view.text.utf16.count < 200_000, !isHighlighting else { return }
            isHighlighting = true
            SyntaxTheme.apply(
                to: view.text,
                language: language,
                in: view.textStorage,
                font: font,
                textColor: .label
            )
            isHighlighting = false
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isEditing = true
            editingView = textView
        }
        func textViewDidEndEditing(_ textView: UITextView) { isEditing = false }

        func textViewDidChange(_ textView: UITextView) {
            binding.wrappedValue = textView.text
            highlight(textView)
        }

        func scroll(toLine line: Int, in view: UITextView) {
            let text = view.text as NSString
            var current = 1
            var location = 0
            while current < line, location < text.length {
                let range = text.lineRange(for: NSRange(location: location, length: 0))
                location = range.location + range.length
                current += 1
            }
            let safe = min(location, text.length)
            view.selectedRange = NSRange(location: safe, length: 0)
            view.scrollRangeToVisible(NSRange(location: safe, length: 0))
        }

        // MARK: - Keyboard accessory

        /// The characters that are hard to reach on a phone keyboard and appear in
        /// every Logos file.
        private let symbols = ["⇥", "%", "@", "#", "{", "}", ";", "(", ")", "\""]

        func makeAccessoryView() -> UIView {
            let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
            toolbar.autoresizingMask = .flexibleWidth
            var items: [UIBarButtonItem] = []
            for symbol in symbols {
                let item = UIBarButtonItem(title: symbol, style: .plain, target: self, action: #selector(insertSymbol(_:)))
                item.accessibilityLabel = symbol == "⇥" ? "Tab" : symbol
                items.append(item)
            }
            items.append(UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil))
            items.append(UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissKeyboard)))
            toolbar.items = items
            toolbar.sizeToFit()
            return toolbar
        }

        @objc private func insertSymbol(_ sender: UIBarButtonItem) {
            guard let title = sender.title, let view = editingView else { return }
            let insertion = title == "⇥" ? "    " : title
            let range = view.selectedRange
            if let start = view.position(from: view.beginningOfDocument, offset: range.location),
               let end = view.position(from: start, offset: range.length),
               let textRange = view.textRange(from: start, to: end) {
                view.replace(textRange, withText: insertion)
            } else {
                view.insertText(insertion)
            }
            textViewDidChange(view)
        }

        @objc private func dismissKeyboard() {
            editingView?.resignFirstResponder()
        }

        /// The text view the accessory is attached to. Held weakly so a dismissed
        /// editor is not kept alive by its own keyboard toolbar.
        weak var editingView: UITextView?
    }
}
