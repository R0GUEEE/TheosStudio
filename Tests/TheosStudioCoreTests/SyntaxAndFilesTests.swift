import XCTest
@testable import TheosStudioCore

final class SyntaxHighlighterTests: XCTestCase {

    private func kinds(in text: String, language: SyntaxLanguage) -> [SyntaxToken.Kind] {
        SyntaxHighlighter.tokens(in: text, language: language).map(\.kind)
    }

    private func text(at token: SyntaxToken, in text: String) -> String {
        let units = Array(text.utf16)
        return String(decoding: units[token.location..<(token.location + token.length)], as: UTF16.self)
    }

    func testLanguageByFileName() {
        XCTAssertEqual(SyntaxLanguage.forFileName("Tweak.x"), .code)
        XCTAssertEqual(SyntaxLanguage.forFileName("Tweak.xm"), .code)
        XCTAssertEqual(SyntaxLanguage.forFileName("Foo.mm"), .code)
        XCTAssertEqual(SyntaxLanguage.forFileName("Makefile"), .makefile)
        XCTAssertEqual(SyntaxLanguage.forFileName("prefs/Makefile"), .makefile)
        XCTAssertEqual(SyntaxLanguage.forFileName("control"), .controlFile)
        XCTAssertEqual(SyntaxLanguage.forFileName("Root.plist"), .plist)
        XCTAssertEqual(SyntaxLanguage.forFileName("README.md"), .plainText)
    }

    func testLineAndBlockComments() {
        let source = "// a comment\nint x; /* block */ int y;"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .code)
        let comments = tokens.filter { $0.kind == .comment }
        XCTAssertEqual(comments.count, 2)
        XCTAssertEqual(text(at: comments[0], in: source), "// a comment")
        XCTAssertEqual(text(at: comments[1], in: source), "/* block */")
    }

    func testStringsIncludingObjectiveCStringLiterals() {
        let source = "NSLog(@\"[MyTweak] loaded\"); char c = 'x';"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .code)
        let strings = tokens.filter { $0.kind == .string }
        XCTAssertEqual(strings.map { text(at: $0, in: source) }, ["\"[MyTweak] loaded\"", "'x'"])
    }

    func testStringLiteralIsNotBrokenByAnApostropheInAComment() {
        let source = "// don't\nNSString *s = @\"fine\";"
        let kinds = kinds(in: source, language: .code)
        XCTAssertEqual(kinds.filter { $0 == .string }.count, 1)
    }

    func testLogosDirectivesAreRecognised() {
        let source = "%hook SBIconView\n- (void)didMoveToWindow { %orig; }\n%end"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .code)
        let directives = tokens.filter { $0.kind == .directive }
        XCTAssertEqual(directives.map { text(at: $0, in: source) }, ["%hook", "%orig", "%end"])
    }

    func testPercentInsideAStringIsNotADirective() {
        let source = "printf(\"%d hooks\\n\");"
        let kinds = kinds(in: source, language: .code)
        XCTAssertFalse(kinds.contains(.directive))
    }

    func testPreprocessorDirectives() {
        let source = "#import <UIKit/UIKit.h>\nint x = 1;"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .code)
        XCTAssertEqual(tokens.first?.kind, .preprocessor)
        XCTAssertEqual(text(at: tokens[0], in: source), "#import <UIKit/UIKit.h>")
    }

    func testKeywordsTypesAndNumbers() {
        let source = "static NSString *name = @\"x\"; for (NSInteger i = 0; i < 10; i++) {}"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .code)
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && self.text(at: $0, in: source) == "static" })
        XCTAssertTrue(tokens.contains { $0.kind == .type && self.text(at: $0, in: source) == "NSString" })
        XCTAssertTrue(tokens.contains { $0.kind == .type && self.text(at: $0, in: source) == "NSInteger" })
        XCTAssertTrue(tokens.contains { $0.kind == .number && self.text(at: $0, in: source) == "10" })
    }

    func testTokensNeverOverlapAndStayInsideTheText() {
        let source = "#import <UIKit/UIKit.h>\n%hook Foo\n- (void)bar { // x\n  NSString *s = @\"a\\\"b\"; }\n%end\n"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .code)
        var cursor = 0
        for token in tokens {
            XCTAssertGreaterThanOrEqual(token.location, cursor, "tokens overlap")
            XCTAssertLessThanOrEqual(token.location + token.length, source.utf16.count)
            cursor = token.location + token.length
        }
    }

    func testMakefileTargetsVariablesAndComments() {
        let source = """
        # build it
        TARGET := iphone:clang:latest:15.0
        include $(THEOS)/makefiles/common.mk

        MyTweak_FILES = Tweak.x
        all::
        \t@echo $(THEOS)
        """
        let tokens = SyntaxHighlighter.tokens(in: source, language: .makefile)
        let rendered = tokens.map { text(at: $0, in: source) }
        XCTAssertEqual(tokens.first?.kind, .comment)
        XCTAssertTrue(tokens.contains { $0.kind == .variable && self.text(at: $0, in: source) == "TARGET" })
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && self.text(at: $0, in: source) == "include" })
        XCTAssertTrue(tokens.contains { $0.kind == .variable && self.text(at: $0, in: source) == "$(THEOS)" })
        XCTAssertTrue(tokens.contains { $0.kind == .variable && self.text(at: $0, in: source) == "MyTweak_FILES" })
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && self.text(at: $0, in: source) == "all" }, "\(rendered)")
    }

    func testControlFieldsAndComments() {
        let source = "# a comment\nPackage: com.example.a\nDescription: hello\n second line\n"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .controlFile)
        let fields = tokens.filter { $0.kind == .field }.map { text(at: $0, in: source) }
        XCTAssertEqual(fields, ["Package", "Description"])
        XCTAssertEqual(tokens.first?.kind, .comment)
    }

    func testPlistTagsAndStrings() {
        let source = "<key>Name</key>\n<string>MyTweak</string>\n<!-- note -->"
        let tokens = SyntaxHighlighter.tokens(in: source, language: .plist)
        XCTAssertTrue(tokens.contains { $0.kind == .comment && self.text(at: $0, in: source) == "<!-- note -->" })
        let tags = tokens.filter { $0.kind == .keyword }.map { text(at: $0, in: source) }
        XCTAssertEqual(tags, ["<key>", "</key>", "<string>", "</string>"])
    }

    func testEmptyTextProducesNothing() {
        XCTAssertTrue(SyntaxHighlighter.tokens(in: "", language: .code).isEmpty)
        XCTAssertTrue(SyntaxHighlighter.tokens(in: "anything", language: .plainText).isEmpty)
    }
}

final class ProjectFilesTests: XCTestCase {

    func testHiddenNamesAreSkipped() {
        XCTAssertTrue(ProjectFiles.isHidden(".theos"))
        XCTAssertTrue(ProjectFiles.isHidden("obj"))
        XCTAssertTrue(ProjectFiles.isHidden(".git"))
        XCTAssertTrue(ProjectFiles.isHidden(".DS_Store"))
        XCTAssertFalse(ProjectFiles.isHidden("Tweak.x"))
        XCTAssertFalse(ProjectFiles.isHidden("packages"))
    }

    func testSortingPutsDirectoriesFirstAndOutputLast() {
        let entries = [
            ProjectEntry(relativePath: "packages/x.deb", isDirectory: false, size: 1),
            ProjectEntry(relativePath: "Tweak.x", isDirectory: false, size: 1),
            ProjectEntry(relativePath: "prefs", isDirectory: true, size: 0),
            ProjectEntry(relativePath: "Makefile", isDirectory: false, size: 1),
            ProjectEntry(relativePath: "Resources", isDirectory: true, size: 0),
        ]
        XCTAssertEqual(ProjectFiles.sort(entries).map(\.relativePath), [
            "prefs", "Resources", "Makefile", "Tweak.x", "packages/x.deb",
        ])
    }

    func testEntryLanguageFollowsTheFileName() {
        XCTAssertEqual(ProjectEntry(relativePath: "Tweak.x", isDirectory: false, size: 0).language, .code)
        XCTAssertEqual(ProjectEntry(relativePath: "Makefile", isDirectory: false, size: 0).language, .makefile)
        XCTAssertEqual(ProjectEntry(relativePath: "control", isDirectory: false, size: 0).language, .controlFile)
        XCTAssertTrue(ProjectEntry(relativePath: "Makefile", isDirectory: false, size: 0).isProbablyText)
        XCTAssertFalse(ProjectEntry(relativePath: "logo.png", isDirectory: false, size: 0).isProbablyText)
    }

    func testNameSanitising() {
        XCTAssertEqual(ProjectNaming.sanitize("My Tweak!"), "MyTweak")
        XCTAssertEqual(ProjectNaming.sanitize("my-tweak"), "mytweak")
        XCTAssertEqual(ProjectNaming.sanitize("1Bad"), "T1Bad")
        XCTAssertEqual(ProjectNaming.sanitize("!!!"), "Tweak")
        XCTAssertEqual(ProjectNaming.sanitize("AlreadyFine"), "AlreadyFine")
    }

    func testNameValidation() {
        XCTAssertTrue(ProjectNaming.isValid("MyTweak"))
        XCTAssertFalse(ProjectNaming.isValid("myTweak"))
        XCTAssertFalse(ProjectNaming.isValid("My Tweak"))
        XCTAssertFalse(ProjectNaming.isValid(""))
        XCTAssertFalse(ProjectNaming.isValid("My-Tweak"))
        XCTAssertFalse(ProjectNaming.isValid(String(repeating: "A", count: 65)))
    }

    func testDefaultIdentifier() {
        XCTAssertEqual(ProjectNaming.defaultPackageIdentifier(name: "MyTweak"), "com.example.mytweak")
        XCTAssertEqual(ProjectNaming.defaultPackageIdentifier(name: "MyTweak", namespace: "R0GUEEE"), "com.r0gueee.mytweak")
        XCTAssertEqual(ProjectNaming.defaultPackageIdentifier(name: "!!!", namespace: ""), "com.example.tweak")
    }

    func testSafeFileName() {
        XCTAssertEqual(ProjectNaming.safeFileName("com.example.my-tweak_1.0"), "com.example.my-tweak_1.0")
        XCTAssertEqual(ProjectNaming.safeFileName("weird name/with:chars"), "weird-name-with-chars")
        XCTAssertEqual(ProjectNaming.safeFileName(""), "package")
    }
}
