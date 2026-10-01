import XCTest
@testable import TheosStudioCore

final class DeviceLogsTests: XCTestCase {

    func testLogPathsFollowTheJailbreak() {
        let rootless = DeviceLogs.candidatePaths(
            jailbreak: JailbreakLayout(rootlessPrefix: "/var/jb", scheme: .rootless),
            home: "/var/mobile"
        )
        XCTAssertEqual(rootless.first, "/var/jb/var/log/syslog")
        XCTAssertTrue(rootless.contains("/var/log/syslog"))

        let rootful = DeviceLogs.candidatePaths(
            jailbreak: JailbreakLayout(rootlessPrefix: nil, scheme: .rootful),
            home: "/var/mobile"
        )
        XCTAssertFalse(rootful.contains { $0.hasPrefix("/var/jb") })
        XCTAssertTrue(rootful.contains("/var/log/syslog"))
    }

    func testTail() {
        XCTAssertEqual(DeviceLogs.tail("a\nb\nc", lines: 2), ["b", "c"])
        XCTAssertEqual(DeviceLogs.tail("a\nb", lines: 10), ["a", "b"])
        XCTAssertEqual(DeviceLogs.tail("", lines: 5), [""])
    }

    func testFilteringIsCaseInsensitiveAndKeepsTheNewest() {
        let log = """
        Oct  1 10:00:00 SpringBoard[123] <Notice>: boot
        Oct  1 10:00:01 SpringBoard[123] <Notice>: [MyTweak] loaded
        Oct  1 10:00:02 backboardd[99] <Notice>: something else
        Oct  1 10:00:03 SpringBoard[123] <Notice>: [mytweak] didMoveToWindow
        """
        let matches = DeviceLogs.lines(in: log, matching: "[MyTweak]")
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(matches[0].contains("loaded"))
        XCTAssertTrue(matches[1].contains("didMoveToWindow"))
    }

    func testAnEmptyQueryIsTheTailAndTheLimitIsRespected() {
        let log = (1...10).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(DeviceLogs.lines(in: log, matching: "").count, 10)
        XCTAssertEqual(DeviceLogs.lines(in: log, matching: "", limit: 3), ["line 8", "line 9", "line 10"])
        XCTAssertEqual(DeviceLogs.lines(in: log, matching: "line", limit: 2).count, 2)
    }

    func testTheTweaksOwnTagIsTheDefaultFilter() {
        let project = Project(
            path: "/p",
            name: "MyTweak",
            manifest: ProjectManifest(name: "MyTweak", kind: .tweak, packageIdentifier: "com.example.mytweak", version: "1.0"),
            builtPackage: nil,
            builtDate: nil
        )
        XCTAssertEqual(DeviceLogs.defaultQuery(for: project), "[MyTweak]")
        XCTAssertTrue(DeviceLogs.searchTerms(for: project).contains("com.example.mytweak"))
        XCTAssertEqual(DeviceLogs.defaultQuery(for: nil), "")
    }
}

final class InstallPreviewParserTests: XCTestCase {

    private let clean = """
    (Reading database ... 12345 files and directories currently installed.)
    Preparing to unpack /tmp/com.example.mytweak_0.0.1_iphoneos-arm64.deb ...
    Unpacking com.example.mytweak (0.0.1) ...
    Setting up com.example.mytweak (0.0.1) ...
    """

    func testACleanInstall() {
        let preview = InstallPreviewParser.parse(clean)
        XCTAssertEqual(preview.package, "com.example.mytweak (0.0.1)")
        XCTAssertNil(preview.replacing)
        XCTAssertTrue(preview.isClean)
        XCTAssertEqual(preview.summary, "Would install cleanly.")
    }

    func testAnUpgradeSaysWhatItReplaces() {
        let upgrade = """
        Unpacking com.example.mytweak (0.0.2) over (0.0.1) ...
        Setting up com.example.mytweak (0.0.2) ...
        """
        let preview = InstallPreviewParser.parse(upgrade)
        XCTAssertEqual(preview.replacing, "0.0.1")
        XCTAssertEqual(preview.package, "com.example.mytweak (0.0.2)")
        XCTAssertEqual(preview.summary, "Would replace 0.0.1.")
    }

    /// A conflict is the answer worth having: dpkg reports it as an error too,
    /// and the conflict is the half that says what to do about it.
    func testAConflictWinsOverTheGenericError() {
        let conflict = """
        dpkg: regarding com.example.b_1.0_iphoneos-arm64.deb containing com.example.b:
         com.example.b conflicts with com.example.a
          com.example.a is present and installed.
        dpkg: error processing archive com.example.b_1.0_iphoneos-arm64.deb (--install):
         conflicting packages - not installing com.example.b
        """
        let preview = InstallPreviewParser.parse(conflict)
        XCTAssertFalse(preview.isClean)
        XCTAssertGreaterThanOrEqual(preview.conflicts.count, 1)
        XCTAssertTrue(preview.conflicts[0].contains("conflicts with com.example.a"))
        XCTAssertTrue(preview.summary.contains("conflicts with"))
    }

    func testTryingToOverwriteIsAConflict() {
        let preview = InstallPreviewParser.parse(
            "dpkg: error processing archive x.deb (--install):\n trying to overwrite '/var/jb/usr/bin/tool', which is also in package other 1.0\n"
        )
        XCTAssertEqual(preview.conflicts.count, 1)
        XCTAssertTrue(preview.conflicts[0].contains("trying to overwrite"))
    }

    func testDependencyProblemsAreErrors() {
        let preview = InstallPreviewParser.parse("""
        dpkg: dependency problems prevent configuration of com.example.a:
         com.example.a depends on mobilesubstrate; however:
          Package mobilesubstrate is not installed.
        """)
        XCTAssertFalse(preview.isClean)
        XCTAssertTrue(preview.errors.contains { $0.contains("dependency problems") })
    }

    func testWarningsAreKeptSeparate() {
        let preview = InstallPreviewParser.parse("""
        dpkg: warning: downgrading com.example.a from 2.0 to 1.0
        Unpacking com.example.a (1.0) over (2.0) ...
        """)
        XCTAssertTrue(preview.isClean)
        XCTAssertEqual(preview.warnings.count, 1)
        XCTAssertEqual(preview.replacing, "2.0")
    }

    func testEmptyOutputIsNotAFailure() {
        let preview = InstallPreviewParser.parse("")
        XCTAssertTrue(preview.isClean)
        XCTAssertNil(preview.package)
        XCTAssertEqual(preview.summary, "Would install cleanly.")
    }
}

final class ReplaceInFileTests: XCTestCase {

    func testReplacingEveryOccurrence() {
        let (text, count) = ProjectSearch.replacingOccurrences(
            in: "%hook Foo\n%orig;\n%end\n",
            query: "%orig",
            with: "%orig()"
        )
        XCTAssertEqual(count, 1)
        XCTAssertTrue(text.contains("%orig()"))
    }

    func testCaseInsensitiveByDefault() {
        let (text, count) = ProjectSearch.replacingOccurrences(
            in: "MyTweak and mytweak\n",
            query: "mytweak",
            with: "YourTweak"
        )
        XCTAssertEqual(count, 2)
        XCTAssertEqual(text, "YourTweak and YourTweak\n")
    }

    func testCaseSensitiveWhenAsked() {
        let (text, count) = ProjectSearch.replacingOccurrences(
            in: "MyTweak and mytweak\n",
            query: "MyTweak",
            with: "YourTweak",
            caseSensitive: true
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(text, "YourTweak and mytweak\n")
    }

    /// "Replaced 0" is the answer someone needs when their text did not match;
    /// silently returning the same text is not.
    func testNoMatchSaysSo() {
        let (text, count) = ProjectSearch.replacingOccurrences(in: "abc", query: "zzz", with: "y")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(text, "abc")

        let (unchanged, emptyCount) = ProjectSearch.replacingOccurrences(in: "abc", query: "  ", with: "y")
        XCTAssertEqual(emptyCount, 0)
        XCTAssertEqual(unchanged, "abc")
    }

    func testReplacingWithNothingDeletes() {
        // The query is matched within lines, so a match is a word, not the line
        // break after it.
        let (text, count) = ProjectSearch.replacingOccurrences(
            in: "keep\ndrop\nkeep\n",
            query: "drop",
            with: ""
        )
        XCTAssertEqual(count, 1)
        XCTAssertEqual(text, "keep\n\nkeep\n")
    }
}
