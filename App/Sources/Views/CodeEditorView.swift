import SwiftUI
import UIKit
import TheosStudioCore

/// A text file, editable, with the engine's syntax tokens turned into colours and
/// the line numbers in a gutter beside it.
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
    @State private var isFinding = false
    @State private var scrollRequest: Int?

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
            CodeTextView(
                text: $text,
                language: language,
                fontSize: fontSize,
                scrollToLine: scrollRequest ?? scrollToLine,
                showsLineNumbers: showsLineNumbers
            )
            Divider()
            statusBar
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isFinding = true
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
            }
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
        .sheet(isPresented: $isFinding) {
            NavigationView {
                FindReplaceView(
                    text: $text,
                    onJump: { line in
                        scrollRequest = line
                        isFinding = false
                    },
                    onReplace: { save() }
                )
            }
            .navigationViewStyle(.stack)
        }
        .onAppear(perform: load)
        .onDisappear(perform: save)
    }

    /// Kept in the app's settings so someone reading on a phone in the dark can
    /// turn it off; line numbers are useful more often than they are in the way.
    private var showsLineNumbers: Bool {
        UserDefaults.standard.object(forKey: "com.r0gueee.theosstudio.line-numbers") as? Bool ?? true
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

    private var statusBar: some View {
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
}

// MARK: - Find and replace

/// Find in one file, with replace.
///
/// Reuses the project search's matching, which is why it reports a count rather
/// than a silent `true`: "replaced 0" is the answer someone needs when their text
/// did not match.
@MainActor
struct FindReplaceView: View {

    @Binding var text: String
    var onJump: (Int) -> Void
    var onReplace: () -> Void

    @State private var query = ""
    @State private var replacement = ""
    @State private var caseSensitive = false
    @State private var outcome: String?
    @Environment(\.presentationMode) private var presentation

    private var matches: [ProjectMatch] {
        ProjectSearch.matches(
            in: [ProjectFile(path: "", contents: text)],
            query: query,
            caseSensitive: caseSensitive
        )
    }

    var body: some View {
        List {
            Section {
                TextField("Find", text: $query)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(size: 13, design: .monospaced))
                Toggle("Match case", isOn: $caseSensitive)
            }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Section {
                    ForEach(matches.prefix(50)) { match in
                        Button {
                            onJump(match.line)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(match.text.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(2)
                                Text("line \(match.line), column \(match.column)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if matches.count > 50 {
                        Text("\(matches.count - 50) more matches")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("\(matches.count) match\(matches.count == 1 ? "" : "es")")
                }

                Section {
                    TextField("Replace with", text: $replacement)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(size: 13, design: .monospaced))
                    Button {
                        replaceAll()
                    } label: {
                        Label("Replace all", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(matches.isEmpty)
                } footer: {
                    if let outcome {
                        Text(outcome).foregroundColor(outcome.hasPrefix("Replaced") ? .green : .secondary)
                    } else {
                        Text("Replacing writes the file. It is saved immediately, so there is nothing else to tap.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Find")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { presentation.wrappedValue.dismiss() }
            }
        }
    }

    private func replaceAll() {
        let result = ProjectSearch.replacingOccurrences(
            in: text,
            query: query,
            with: replacement,
            caseSensitive: caseSensitive
        )
        guard result.count > 0 else {
            outcome = "Nothing matched, so nothing was replaced."
            return
        }
        text = result.text
        outcome = "Replaced \(result.count) occurrence\(result.count == 1 ? "" : "s")."
        onReplace()
    }
}

// MARK: - The text view

/// The editor: a gutter, and the text view beside it.
///
/// SwiftUI's `TextEditor` cannot colour ranges or show line numbers, and both are
/// most of what makes Logos readable on a phone.
struct CodeTextView: UIViewRepresentable {

    @Binding var text: String
    let language: SyntaxLanguage
    let fontSize: CGFloat
    let scrollToLine: Int?
    var showsLineNumbers: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, language: language, fontSize: fontSize)
    }

    func makeUIView(context: Context) -> CodeEditorContainer {
        let container = CodeEditorContainer()
        let view = container.textView

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

        container.showsLineNumbers = showsLineNumbers
        container.gutter.textView = view
        context.coordinator.container = container
        context.coordinator.highlight(view)

        return container
    }

    func updateUIView(_ container: CodeEditorContainer, context: Context) {
        let coordinator = context.coordinator
        let view = container.textView

        coordinator.language = language
        container.showsLineNumbers = showsLineNumbers
        container.setNeedsLayout()

        if view.font?.pointSize != fontSize {
            view.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            coordinator.highlight(view)
            container.gutter.setNeedsDisplay()
        }
        if !coordinator.isEditing, view.text != text {
            view.text = text
            coordinator.highlight(view)
            container.gutter.setNeedsDisplay()
        }
        if let line = scrollToLine, coordinator.lastScrolledLine != line {
            coordinator.lastScrolledLine = line
            coordinator.scroll(toLine: line, in: view)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {

        var language: SyntaxLanguage
        var fontSize: CGFloat
        var isEditing = false
        var lastScrolledLine: Int?
        weak var container: CodeEditorContainer?
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
            container?.gutter.setNeedsDisplay()
        }

        /// The gutter draws in the text view's coordinate space, so it has to be
        /// redrawn when that space moves.
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            container?.gutter.setNeedsDisplay()
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

/// Holds the gutter and the text view, because a `UIViewRepresentable` is one
/// view and the editor is two.
final class CodeEditorContainer: UIView {

    /// Built on a TextKit 1 stack on purpose: the gutter asks the layout manager
    /// where each paragraph sits, and iOS 16's TextKit 2 text views only expose one
    /// in compatibility mode.
    let textView: UITextView
    let gutter = LineNumberGutterView()

    var showsLineNumbers: Bool = true {
        didSet {
            gutterWidth = showsLineNumbers ? 46 : 0
            setNeedsLayout()
        }
    }

    private var gutterWidth: CGFloat = 46
    private let gutterSpace: CGFloat = 4

    override init(frame: CGRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        textView = UITextView(frame: .zero, textContainer: container)

        super.init(frame: frame)
        backgroundColor = .systemBackground
        addSubview(gutter)
        addSubview(textView)
        textView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width: CGFloat = gutterWidth > 0 ? gutterWidth + gutterSpace : 0
        gutter.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        gutter.isHidden = gutterWidth == 0
        textView.frame = CGRect(x: width, y: 0, width: bounds.width - width, height: bounds.height)
        gutter.setNeedsDisplay()
    }
}

/// The line numbers, drawn where the text view puts each paragraph — which is
/// what keeps them aligned when a long line wraps, as lines do on a phone.
final class LineNumberGutterView: UIView {

    weak var textView: UITextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .secondarySystemBackground
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.secondarySystemBackground.cgColor)
        context.fill(rect)

        let fontSize = max(8, (textView.font?.pointSize ?? 12) * 0.8)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.secondaryLabel,
        ]

        let text = textView.text as NSString
        let inset = textView.textContainerInset
        let offset = textView.contentOffset.y
        let layoutManager = textView.layoutManager
        let container = textView.textContainer

        var lineNumber = 1
        let full = NSRange(location: 0, length: text.length)
        // A local: the closure below is escaping, so it cannot reach back into
        // the view for its own bounds.
        let rightEdge = bounds.width

        text.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            let y = lineRect.minY + inset.top - offset
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: rightEdge - size.width - 6, y: y), withAttributes: attributes)
            lineNumber += 1
        }

        // An empty file still has a first line.
        if text.length == 0 {
            let label = "1" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: bounds.width - size.width - 6, y: inset.top - offset), withAttributes: attributes)
        }
    }
}
