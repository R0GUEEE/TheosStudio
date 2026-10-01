import XCTest
@testable import TheosStudioCore

final class MakefileEditorTests: XCTestCase {

    private let tweakMakefile = """
    export THEOS_PACKAGE_SCHEME = rootless
    TARGET := iphone:clang:latest:15.0
    ARCHS = arm64 arm64e

    include $(THEOS)/makefiles/common.mk

    TWEAK_NAME = MyTweak
    MyTweak_FILES = Tweak.x
    MyTweak_CFLAGS = -fobjc-arc
    MyTweak_FRAMEWORKS = UIKit

    include $(THEOS_MAKE_PATH)/tweak.mk
    """

    func testFileListVariableFollowsTheProjectKind() {
        XCTAssertEqual(MakefileEditor.fileListVariable(in: tweakMakefile), "MyTweak_FILES")
        XCTAssertEqual(
            MakefileEditor.fileListVariable(in: "APPLICATION_NAME = MyApp\nMyApp_FILES = main.m\n"),
            "MyApp_FILES"
        )
        XCTAssertEqual(
            MakefileEditor.fileListVariable(in: "TOOL_NAME = mytool\ntool_FILES = main.m\n"),
            "mytool_FILES"
        )
        XCTAssertNil(MakefileEditor.fileListVariable(in: "ARCHS = arm64\n"))
    }

    func testReadingValuesAndContinuations() {
        XCTAssertEqual(MakefileEditor.readValue("TWEAK_NAME", in: tweakMakefile), "MyTweak")
        XCTAssertEqual(MakefileEditor.readValue("ARCHS", in: tweakMakefile), "arm64 arm64e")
        XCTAssertEqual(MakefileEditor.readValue("TARGET", in: tweakMakefile), "iphone:clang:latest:15.0")
        XCTAssertEqual(MakefileEditor.readValue("NOPE", in: tweakMakefile), nil)

        let wrapped = """
        TWEAK_NAME = MyTweak
        MyTweak_FILES = Tweak.x \\
            Extra.x \\
            Third.x
        """
        XCTAssertEqual(MakefileEditor.sources(in: wrapped), ["Tweak.x", "Extra.x", "Third.x"])
    }

    func testSourcingOutComments() {
        XCTAssertEqual(
            MakefileEditor.readValue("ARCHS", in: "ARCHS = arm64  # drop arm64e if you do not hook system processes\n"),
            "arm64"
        )
    }

    /// The whole point of the file: a new source that is not in the file list is
    /// never compiled, and the build still succeeds.
    func testAddingASourceToTheFileList() {
        let result = MakefileEditor.addSource("Second.x", to: tweakMakefile)
        XCTAssertTrue(result.changed)
        XCTAssertNil(result.reason)
        XCTAssertTrue(result.text.contains("MyTweak_FILES = Tweak.x Second.x"))
        XCTAssertEqual(MakefileEditor.sources(in: result.text), ["Tweak.x", "Second.x"])
        // Nothing else moved.
        XCTAssertTrue(result.text.contains("MyTweak_FRAMEWORKS = UIKit"))
        XCTAssertEqual(result.text.split(separator: "\n").count, tweakMakefile.split(separator: "\n").count)
    }

    func testAddingToAWrappedFileListKeepsItWrapped() {
        let wrapped = """
        TWEAK_NAME = MyTweak
        MyTweak_FILES = Tweak.x \\
            Extra.x
        """
        let result = MakefileEditor.addSource("Third.x", to: wrapped)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(MakefileEditor.sources(in: result.text), ["Tweak.x", "Extra.x", "Third.x"])
        XCTAssertTrue(result.text.contains("\\"), "the continuation should survive")
    }

    func testAddingASourceThatIsAlreadyThereSaysSo() {
        let result = MakefileEditor.addSource("Tweak.x", to: tweakMakefile)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.reason, "Tweak.x is already in MyTweak_FILES.")
        XCTAssertEqual(result.text, tweakMakefile, "an unchanged edit must not rewrite the file")
    }

    func testAddingASourceWithoutAFileListIsExplained() {
        let result = MakefileEditor.addSource("Second.x", to: "ARCHS = arm64\n")
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.reason?.contains("TWEAK_NAME") == true, result.reason ?? "")
    }

    func testAddingASourceWhenTheVariableIsMissingIsExplained() {
        let makefile = "TWEAK_NAME = MyTweak\ninclude $(THEOS_MAKE_PATH)/tweak.mk\n"
        let result = MakefileEditor.addSource("Second.x", to: makefile)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.reason?.contains("MyTweak_FILES") == true, result.reason ?? "")
    }

    func testRemovingASource() {
        let makefile = "TWEAK_NAME = MyTweak\nMyTweak_FILES = Tweak.x Second.x\n"
        let result = MakefileEditor.removeSource("Second.x", from: makefile)
        XCTAssertTrue(result.changed)
        XCTAssertEqual(MakefileEditor.sources(in: result.text), ["Tweak.x"])

        let missing = MakefileEditor.removeSource("Nope.x", from: makefile)
        XCTAssertFalse(missing.changed)
        XCTAssertTrue(missing.reason?.contains("not in") == true)
    }

    func testSettingAValue() {
        let updated = MakefileEditor.setValue("ARCHS", to: "arm64", in: tweakMakefile)
        XCTAssertTrue(updated.contains("ARCHS = arm64\n"))
        XCTAssertFalse(updated.contains("arm64e"))

        let withComment = MakefileEditor.setValue("ARCHS", to: "arm64", in: "ARCHS = arm64 arm64e  # both\n")
        // The comment survives; the spacing around it is normalised.
        XCTAssertTrue(withComment.contains("ARCHS = arm64 # both"), withComment)

        let added = MakefileEditor.setValue("DEBUG", to: "0", in: "ARCHS = arm64\n")
        XCTAssertTrue(added.contains("DEBUG = 0"))
    }

    /// The generated templates are what the app actually writes, so the editor has
    /// to understand them, including the lower-cased tool name.
    func testItUnderstandsGeneratedTemplates() {
        for kind in ProjectKind.allCases {
            let request = TemplateRequest(
                name: "MyTool",
                kind: kind,
                scheme: .rootless,
                packageIdentifier: "com.example.mytool"
            )
            let makefile = ProjectTemplate.makefile(for: request)
            let result = MakefileEditor.addSource("Extra.x", to: makefile)
            XCTAssertTrue(result.changed, "\(kind.rawValue): \(result.reason ?? "no reason given")")
            XCTAssertTrue(MakefileEditor.sources(in: result.text).contains("Extra.x"), kind.rawValue)
        }
    }

    func testSourceFileDetection() {
        XCTAssertTrue(MakefileEditor.isSourceFile("Tweak.x"))
        XCTAssertTrue(MakefileEditor.isSourceFile("prefs/RootListController.m"))
        XCTAssertTrue(MakefileEditor.isSourceFile("Tweak.xm"))
        XCTAssertFalse(MakefileEditor.isSourceFile("control"))
        XCTAssertFalse(MakefileEditor.isSourceFile("README.md"))
        XCTAssertFalse(MakefileEditor.isSourceFile("MyTweak.plist"))
    }
}

final class CrashLogParserTests: XCTestCase {

    private let modern = """
    {"app_name":"SpringBoard","timestamp":"2026-10-01 12:00:00.00 -0400","bug_type":"309","os_version":"iPhone OS 16.5 (20F66)"}
    {"uptime":1200,"procName":"SpringBoard","termination":{"flags":0,"code":11,"indicator":"Segmentation fault: 11"},"faultingThread":0,
     "threads":[{"triggered":true,"frames":[{"imageIndex":12,"symbol":"MyTweak_hook + 42","imageOffset":1024},
     {"imageIndex":3,"symbol":"-[SBIconView didMoveToWindow] + 8"}]}],
     "usedImages":[{"name":"MyTweak.dylib","path":"/var/jb/Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib"}]}
    """

    func testReadingAModernIPSReport() {
        let summary = CrashLogParser.parse(
            fileName: "SpringBoard-2026-10-01-120000.ips",
            contents: modern,
            interestingNames: ["MyTweak"]
        )
        XCTAssertEqual(summary.process, "SpringBoard")
        XCTAssertEqual(summary.kind, "bug type 309")
        XCTAssertEqual(summary.reason, "Segmentation fault: 11")
        XCTAssertTrue(summary.mentionsOurs)
        XCTAssertNotNil(summary.ownFrame)
        XCTAssertNotNil(summary.date)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour], from: summary.date!)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 10)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 12)
    }

    func testACrashThatIsNotOursIsNotClaimed() {
        let summary = CrashLogParser.parse(
            fileName: "backboardd-2026-10-01-090000.ips",
            contents: modern.replacingOccurrences(of: "MyTweak", with: "SomethingElse"),
            interestingNames: ["MyTweak", "com.example.mytweak"]
        )
        XCTAssertFalse(summary.mentionsOurs)
        XCTAssertEqual(summary.process, "backboardd")
    }

    func testReadingALegacyCrashReport() {
        let legacy = """
        Incident Identifier: 1A2B3C4D
        CrashReporter Key:   0e5c...
        Process:             SpringBoard [1234]
        Path:                /System/Library/CoreServices/SpringBoard.app/SpringBoard
        Exception Type:      EXC_BAD_ACCESS (SIGSEGV)
        Termination Reason:  Namespace SIGNAL, Code 11 Segmentation fault: 11
        Crashed Thread:      0

        Thread 0 Crashed:
        0   MyTweak.dylib    0x0000000102a4c1f0 0x102a40000 + 0xc1f0
        """
        let summary = CrashLogParser.parse(
            fileName: "SpringBoard-2026-10-01-120000.crash",
            contents: legacy,
            interestingNames: ["MyTweak"]
        )
        XCTAssertEqual(summary.process, "SpringBoard")
        XCTAssertEqual(summary.kind, "EXC_BAD_ACCESS (SIGSEGV)")
        XCTAssertTrue(summary.reason?.contains("Segmentation fault") == true, summary.reason ?? "")
        XCTAssertTrue(summary.mentionsOurs)
        XCTAssertTrue(summary.ownFrame?.contains("MyTweak.dylib") == true, summary.ownFrame ?? "")
    }

    func testFileNameParsingWithoutADate() {
        let summary = CrashLogParser.parse(fileName: "weird-name.ips", contents: modern, interestingNames: [])
        XCTAssertEqual(summary.process, "weird")
        XCTAssertNil(summary.date)
    }

    func testCrashDirectoryCandidatesFollowTheJailbreak() {
        let rootless = CrashLogParser.candidateDirectories(
            jailbreak: JailbreakLayout(rootlessPrefix: "/var/jb", scheme: .rootless),
            home: "/var/mobile"
        )
        XCTAssertTrue(rootless.contains("/var/jb/var/mobile/Library/Logs/CrashReporter"))
        XCTAssertTrue(rootless.contains("/var/mobile/Library/Logs/CrashReporter"))

        let rootful = CrashLogParser.candidateDirectories(
            jailbreak: JailbreakLayout(rootlessPrefix: nil, scheme: .rootful),
            home: "/var/mobile"
        )
        XCTAssertFalse(rootful.contains { $0.hasPrefix("/var/jb") })
    }
}

final class GitPorcelainTests: XCTestCase {

    func testParsingStatusOutput() {
        let output = """
         M Tweak.x
        M  control
        ?? NewFile.x
        A  prefs/Root.plist
        R  Tweak.x -> TweakOld.x
        D  gone.m
        """
        let files = GitPorcelain.parse(output)
        XCTAssertEqual(files.count, 6)

        let tweak = files.first { $0.path == "Tweak.x" }!
        XCTAssertTrue(tweak.isModified)
        XCTAssertFalse(tweak.isStaged)
        XCTAssertEqual(tweak.label, "working tree: modified")

        let control = files.first { $0.path == "control" }!
        XCTAssertTrue(control.isStaged)

        let untracked = files.first { $0.path == "NewFile.x" }!
        XCTAssertTrue(untracked.isUntracked)
        XCTAssertEqual(untracked.label, "Untracked")

        let renamed = files.first { $0.path == "TweakOld.x" }!
        XCTAssertEqual(renamed.originalPath, "Tweak.x")

        XCTAssertEqual(files.map(\.path).first, "control", "sorted for display")
    }

    func testSummary() {
        let files = GitPorcelain.parse(" M Tweak.x\n?? New.x\nM  control\n")
        XCTAssertEqual(GitPorcelain.summary(files), "3 changed files, 1 staged, 1 untracked.")
        XCTAssertEqual(GitPorcelain.summary([]), "No changes.")
    }

    /// A file with a space in its path is quoted by git; the quoting must not end
    /// up in the path the app then opens.
    func testQuotedPaths() {
        let files = GitPorcelain.parse("?? \"weird name.x\"\n")
        XCTAssertEqual(files.first?.path, "weird name.x")
    }

    func testCommandsCarryTheProjectDirectory() {
        XCTAssertEqual(GitCommands.status(project: "/p")[0...1], ["-C", "/p"])
        XCTAssertEqual(GitCommands.diff(project: "/p", path: "Tweak.x").suffix(2), ["--", "Tweak.x"])
        XCTAssertTrue(GitCommands.diff(project: "/p", staged: true).contains("--cached"))
        XCTAssertEqual(GitCommands.commit(project: "/p", message: "work").suffix(2), ["-m", "work"])
        XCTAssertEqual(GitCommands.addAll(project: "/p").suffix(2), ["add", "-A"])
    }

    func testRepositoryDetection() {
        XCTAssertTrue(GitCommands.isRepository(project: "/p", exists: { $0 == "/p/.git" }))
        XCTAssertFalse(GitCommands.isRepository(project: "/p", exists: { _ in false }))
    }
}

final class DebListingTests: XCTestCase {

    /// The real shape of `dpkg-deb -c`, including the header directories.
    private let listing = """
    drwxr-xr-x root/wheel         0 2026-09-30 22:23 ./
    drwxr-xr-x root/wheel         0 2026-09-30 22:23 ./var/
    drwxr-xr-x root/wheel         0 2026-09-30 22:23 ./var/jb/
    drwxr-xr-x root/wheel         0 2026-09-30 22:23 ./var/jb/Library/
    drwxr-xr-x root/wheel         0 2026-09-30 22:23 ./var/jb/Library/MobileSubstrate/
    -rw-r--r-- root/wheel       812 2026-09-30 22:23 ./var/jb/Library/MobileSubstrate/DynamicLibraries/MyTweak.plist
    -rwxr-xr-x root/wheel     48216 2026-09-30 22:23 ./var/jb/Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib
    -rw-r--r-- root/wheel       640 2026-09-30 22:23 ./var/jb/Library/PreferenceLoader/Preferences/MyTweak.plist
    """

    func testParsingAListing() {
        let entries = DebListing.parse(listing)
        XCTAssertEqual(entries.count, 7, "the ./ root entry is not a file in the package")
        XCTAssertEqual(DebListing.files(entries).count, 3)
        XCTAssertTrue(entries.contains { $0.isDirectory && $0.path == "./var/" })

        let dylib = entries.first { $0.path.hasSuffix("MyTweak.dylib") }!
        XCTAssertEqual(dylib.size, 48216)
        XCTAssertEqual(dylib.installedPath, "var/jb/Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib")
    }

    /// tar prints several date formats depending on the build; the size and the
    /// path are in the same places in all of them.
    func testOtherDateFormats() {
        let other = """
        -rw-r--r-- root/wheel      1240 Sep 30 22:23 ./var/jb/thing.dylib
        -rw-r--r-- root/wheel      1240 Sep 30  2023 ./var/jb/other.dylib
        """
        let entries = DebListing.parse(other)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].size, 1240)
        XCTAssertEqual(entries[1].installedPath, "var/jb/other.dylib")
    }

    func testTotalsAndLargest() {
        let entries = DebListing.parse(listing)
        XCTAssertEqual(DebListing.totalSize(entries), 48216 + 812 + 640)
        XCTAssertEqual(DebListing.largest(entries).first?.size, 48216)
        XCTAssertEqual(DebListing.largest(entries, limit: 2).count, 2)
    }

    /// The silent, total failure: a rootful package on a rootless device installs
    /// where nothing reads.
    func testLayoutChecks() {
        let rootless = DebListing.parse(listing)
        XCTAssertTrue(DebListing.matchesScheme(rootless, scheme: .rootless))

        let rootful = DebListing.parse("""
        -rwxr-xr-x root/wheel     48216 2026-09-30 22:23 ./Library/MobileSubstrate/DynamicLibraries/MyTweak.dylib
        """)
        XCTAssertFalse(DebListing.matchesScheme(rootful, scheme: .rootless))
        XCTAssertTrue(DebListing.matchesScheme(rootful, scheme: .rootful))
        // roothide decides at runtime; nothing to check.
        XCTAssertTrue(DebListing.matchesScheme(rootful, scheme: .roothide))
    }

    func testSummaryRows() {
        var control = ControlFile()
        control["Package"] = "com.example.mytweak"
        control["Version"] = "0.0.1"
        control["Architecture"] = "iphoneos-arm64"
        control["Depends"] = "mobilesubstrate"

        let rows = DebListing.summary(entries: DebListing.parse(listing), control: control, scheme: .rootless)
        let dictionary = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertEqual(dictionary["Files"], "3")
        XCTAssertEqual(dictionary["Package"], "com.example.mytweak")
        XCTAssertEqual(dictionary["Depends"], "mobilesubstrate")
        XCTAssertEqual(dictionary["Dylibs"], "MyTweak.dylib")
        XCTAssertNil(dictionary["Layout"], "a matching layout should not be reported")
    }

    func testSummaryReportsAMismatchedLayout() {
        var control = ControlFile()
        control["Package"] = "com.example.mytweak"
        let rows = DebListing.summary(
            entries: DebListing.parse("-rwxr-xr-x root/wheel  10 2026-09-30 22:23 ./Library/Thing.dylib"),
            control: control,
            scheme: .rootless
        )
        let dictionary = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertTrue(dictionary["Layout"]?.contains("rootful package") == true, dictionary["Layout"] ?? "")
    }
}
