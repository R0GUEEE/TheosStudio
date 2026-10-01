import XCTest
@testable import TheosStudioCore

final class HeaderIndexTests: XCTestCase {

    private let header = """
    //  SBIconView.h
    #import <UIKit/UIKit.h>

    @protocol SBIconViewDelegate <NSObject>
    - (void)iconViewTapped:(id)view;
    - (BOOL)iconView:(id)view canBeginDrag:(id)context;
    @end

    @interface SBIconView : UIView {
        BOOL _highlighted;
    }

    @property (nonatomic, assign, getter=isHighlighted) BOOL highlighted;
    @property (nonatomic, copy) NSString *displayName;

    - (void)didMoveToWindow;
    - (void)setFrame:(CGRect)frame;
    - (BOOL)isHighlighted;
    - (void)setValue:(id)value forKey:(NSString *)key;

    + (id)sharedInstance;
    @end

    @interface SBIconView (PrivateExtras)
    - (void)extraThing;
    @end

    extern NSString *const SBIconViewDidChangeNotification;
    int SBIconViewCount(void);
    """

    func testReadingClassesProtocolsAndMethods() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let classes = declarations.filter { $0.kind == .interface }.map(\.name)
        XCTAssertEqual(classes, ["SBIconView", "SBIconView"], "the class and its category")

        let protocols = declarations.filter { $0.kind == .protocolDeclaration }.map(\.name)
        XCTAssertEqual(protocols, ["SBIconViewDelegate"])
    }

    func testReadingSelectorsIncludingKeywords() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let methods = declarations.filter { $0.kind == .method }.map(\.name)
        XCTAssertTrue(methods.contains("didMoveToWindow"))
        XCTAssertTrue(methods.contains("isHighlighted"))
        XCTAssertTrue(methods.contains("setFrame:"))
        // A multi-part selector is what a %hook has to match exactly.
        XCTAssertTrue(methods.contains("setValue:forKey:"), "\(methods)")
        XCTAssertTrue(methods.contains("iconView:canBeginDrag:"), "\(methods)")
        XCTAssertTrue(methods.contains("sharedInstance"))
    }

    func testMethodsKnowTheirClass() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let method = declarations.first { $0.name == "didMoveToWindow" }
        XCTAssertEqual(method?.owner, "SBIconView")

        let categoryMethod = declarations.first { $0.name == "extraThing" }
        XCTAssertEqual(categoryMethod?.owner, "SBIconView", "a category is read as the class it extends")
    }

    func testPropertyNamesSkipTypeAndAttributes() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let properties = declarations.filter { $0.kind == .property }.map(\.name)
        XCTAssertEqual(properties, ["highlighted", "displayName"])
        // The getter attribute contains a paren and a comma; the name is still last.
        XCTAssertEqual(declarations.first { $0.kind == .property }?.signature.contains("getter=isHighlighted"), true)
    }

    func testCFunctionsAreFound() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let functions = declarations.filter { $0.kind == .function }.map(\.name)
        XCTAssertTrue(functions.contains("SBIconViewCount"), "\(functions)")
        // A declaration that is not a function must not be reported as one.
        XCTAssertFalse(functions.contains("if"))
    }

    func testLineNumbersPointAtTheDeclaration() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        // Computed rather than hard-coded: the fixture is meant to be editable.
        let expected = header.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.contains("didMoveToWindow") }! + 1
        let method = declarations.first { $0.name == "didMoveToWindow" }
        XCTAssertEqual(method?.line, expected)
        XCTAssertEqual(method?.location, "SBIconView.h:\(expected)")
    }

    // MARK: - Searching

    func testSearchRanksExactNamesFirstThenPrefixesThenMembers() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let results = HeaderIndex.search("SBIcon", in: declarations)
        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.first?.name, "SBIconView", "an exact class match comes first")

        let highlighted = HeaderIndex.search("highlighted", in: declarations)
        XCTAssertEqual(highlighted.first?.name, "highlighted")
        XCTAssertTrue(highlighted.contains { $0.kind == .method && $0.name == "isHighlighted" })
    }

    func testSearchingAClassAlsoFindsItsMembers() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let results = HeaderIndex.search("SBIconView", in: declarations)
        XCTAssertTrue(results.contains { $0.kind == .method && $0.name == "didMoveToWindow" }, "members are useful when you search a class")
        XCTAssertEqual(results.first?.kind, .interface)
    }

    func testEmptyQueryAndLimit() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        XCTAssertTrue(HeaderIndex.search("", in: declarations).isEmpty)
        XCTAssertLessThanOrEqual(HeaderIndex.search("e", in: declarations, limit: 3).count, 3)
        XCTAssertTrue(HeaderIndex.search("nothingNamedThis", in: declarations).isEmpty)
    }

    func testHookSkeletonForAClass() {
        let declarations = HeaderIndex.declarations(in: header, file: "/headers/SBIconView.h")
        let classDeclaration = declarations.first { $0.kind == .interface }!
        let skeleton = HeaderIndex.hookSkeleton(for: classDeclaration, projectName: "MyTweak")
        XCTAssertNotNil(skeleton)
        XCTAssertTrue(skeleton!.contains("%hook SBIconView"))
        XCTAssertTrue(skeleton!.contains("%orig"))
        XCTAssertTrue(skeleton!.contains("%end"))
        XCTAssertTrue(
            skeleton!.contains("SBIconView.h:\(classDeclaration.line)"),
            "the skeleton says where the name came from: \(skeleton!)"
        )

        // A method is not something you can %hook on its own.
        let method = declarations.first { $0.kind == .method }!
        XCTAssertNil(HeaderIndex.hookSkeleton(for: method, projectName: "MyTweak"))
    }

    func testParsingIsNotConfusedByComments() {
        let text = """
        // - (void)notARealMethod;
        /* @interface NotAClass */
        - (void)realMethod;
        """
        let declarations = HeaderIndex.declarations(in: text, file: "/tmp/x.h")
        XCTAssertEqual(declarations.map(\.name), ["realMethod"])
    }
}

final class SnippetLibraryTests: XCTestCase {

    func testEverySnippetIsUsable() {
        XCTAssertGreaterThanOrEqual(SnippetLibrary.all.count, 8)
        for snippet in SnippetLibrary.all {
            XCTAssertFalse(snippet.id.isEmpty, snippet.title)
            XCTAssertFalse(snippet.title.isEmpty, snippet.id)
            XCTAssertFalse(snippet.summary.isEmpty, snippet.id)
            XCTAssertFalse(snippet.body.isEmpty, snippet.id)
            XCTAssertFalse(snippet.suggestedFileName.isEmpty, snippet.id)
            // A snippet that does not end in a newline pastes badly.
            XCTAssertTrue(snippet.body.hasSuffix("\n"), "\(snippet.id) should end with a newline")
        }
    }

    func testIdentifiersAreUnique() {
        let ids = SnippetLibrary.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// The snippets exist because of specific mistakes; the text has to carry the
    /// reason or it is just code.
    func testTheSnippetsSayWhyTheyExist() {
        XCTAssertTrue(SnippetLibrary.snippet(id: "logos.hook")!.body.contains("silently never fires"))
        XCTAssertTrue(SnippetLibrary.snippet(id: "logos.group")!.body.contains("@available"))
        XCTAssertTrue(SnippetLibrary.snippet(id: "prefs.read")!.body.contains("CFPreferencesCopyAppValue"))
        XCTAssertTrue(SnippetLibrary.snippet(id: "prefs.read")!.body.contains("ReloadPrefs"))
        XCTAssertTrue(SnippetLibrary.snippet(id: "paths.runtime")!.body.contains("jbroot"))
        XCTAssertTrue(SnippetLibrary.snippet(id: "control.depends")!.body.contains("mobilesubstrate"))
        XCTAssertTrue(SnippetLibrary.snippet(id: "makefile.prefs")!.body.contains("SUBPROJECTS"))
    }

    func testLanguagesMatchTheSuggestedFiles() {
        for snippet in SnippetLibrary.all {
            let language = SyntaxLanguage.forFileName(snippet.suggestedFileName)
            XCTAssertEqual(language, snippet.language, "\(snippet.id) says \(snippet.language) but \(snippet.suggestedFileName) is \(language)")
        }
    }
}

final class LaunchTargetsTests: XCTestCase {

    private let makefile = """
    TWEAK_NAME = MyTweak
    INSTALL_TARGET_PROCESSES = SpringBoard backboardd
    MyTweak_FILES = Tweak.x
    """

    func testInstallTargetProcessesAreAuthoritative() {
        let targets = LaunchTargets.targets(inMakefile: makefile, filterPlist: nil)
        XCTAssertEqual(targets.map(\.name), ["SpringBoard", "backboardd"])
        XCTAssertEqual(targets.first?.source, .installTargetProcesses)
    }

    func testTheFilterAddsAProcessWhenTheMakefileIsSilentAboutIt() {
        let targets = LaunchTargets.targets(
            inMakefile: "TWEAK_NAME = MyTweak\n",
            filterPlist: "{ Filter = { Bundles = ( \"com.apple.mobilesafari\" ); }; }"
        )
        XCTAssertEqual(targets.map(\.name), ["MobileSafari"])
        XCTAssertEqual(targets.first?.source, .injectionFilter)
        XCTAssertEqual(targets.first?.bundleIdentifier, "com.apple.mobilesafari")
    }

    func testDuplicatesAreCollapsed() {
        let targets = LaunchTargets.targets(
            inMakefile: makefile,
            filterPlist: "{ Filter = { Bundles = ( \"com.apple.springboard\" ); }; }"
        )
        XCTAssertEqual(targets.map(\.name), ["SpringBoard", "backboardd"])
    }

    func testAnUnknownBundleContributesNothing() {
        let targets = LaunchTargets.targets(
            inMakefile: "TWEAK_NAME = MyTweak\n",
            filterPlist: "{ Filter = { Bundles = ( \"com.example.someapp\" ); }; }"
        )
        XCTAssertTrue(targets.isEmpty, "guessing a process name would kill the wrong thing")
        XCTAssertEqual(
            LaunchTargets.bundleIdentifiers(inFilterPlist: "{ Filter = { Bundles = ( \"com.example.someapp\" ); }; }"),
            ["com.example.someapp"]
        )
    }

    func testNilAndEmptyInputs() {
        XCTAssertTrue(LaunchTargets.targets(inMakefile: "", filterPlist: nil).isEmpty)
        XCTAssertTrue(LaunchTargets.bundleIdentifiers(inFilterPlist: nil).isEmpty)
        XCTAssertTrue(LaunchTargets.targets(inMakefile: "INSTALL_TARGET_PROCESSES =\n", filterPlist: nil).isEmpty)
    }

    func testGeneratedTweakProjectsHaveASpringBoardTarget() {
        let request = TemplateRequest(name: "MyTweak", kind: .tweak, scheme: .rootless, packageIdentifier: "com.example.mytweak")
        let files = ProjectTemplate.files(for: request)
        let makefile = files.first { $0.path == "Makefile" }!.contents
        let plist = files.first { $0.path == "MyTweak.plist" }!.contents
        let targets = LaunchTargets.targets(inMakefile: makefile, filterPlist: plist)
        XCTAssertEqual(targets.map(\.name), ["SpringBoard"])
    }
}
