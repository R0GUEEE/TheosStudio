import XCTest
@testable import TheosStudioCore

final class FeatureUpdateTests: XCTestCase {
    func testProjectSearchSupportsWholeWordAndExtensions() {
        let files = [
            ProjectFile(path: "Tweak.x", contents: "SpringBoard spring springboard\n"),
            ProjectFile(path: "README.md", contents: "spring\n"),
        ]
        let results = AdvancedProjectSearch.search(
            query: "spring",
            files: files,
            options: .init(caseSensitive: false, useRegex: false, wholeWord: true, fileExtensions: ["x"])
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].path, "Tweak.x")
        XCTAssertEqual(results[0].line, 1)
    }

    func testHealthFindsMissingAndUnlistedSources() {
        let files = [
            ProjectFile(path: "Makefile", contents: "TWEAK_NAME = Demo\nDemo_FILES = Tweak.x Missing.m\n"),
            ProjectFile(path: "control", contents: "Package: com.example.demo\nName: Demo\nVersion: 1.0\nArchitecture: iphoneos-arm\nMaintainer: A <a@b.com>\nDescription: Demo\nDepends: mobilesubstrate\n"),
            ProjectFile(path: "Tweak.x", contents: "%hook NSObject\n%end\n"),
            ProjectFile(path: "Extra.m", contents: "void x(void) {}\n"),
        ]
        let issues = ProjectHealth.inspect(files: files)
        XCTAssertTrue(issues.contains { $0.message.contains("Missing.m") && $0.severity == .error })
        XCTAssertTrue(issues.contains { $0.message.contains("Extra.m") && $0.severity == .warning })
    }

    func testVersionBumper() {
        XCTAssertEqual(VersionBumper.bump("1.2.3", part: .patch), "1.2.4")
        XCTAssertEqual(VersionBumper.bump("1.2.3", part: .minor), "1.3.0")
        XCTAssertEqual(VersionBumper.bump("1.2.3", part: .major), "2.0.0")
        XCTAssertEqual(VersionBumper.bump("1.2.3", part: .build), "1.2.3.1")
    }

    func testBuildProfiles() {
        let base = BuildRequest(projectPath: "/tmp/Test", scheme: .rootless)
        let release = BuildProfile.release.applying(to: base)
        XCTAssertTrue(release.finalPackage)
        XCTAssertTrue(release.cleanFirst)
        let fast = BuildProfile.fast.applying(to: base)
        XCTAssertFalse(fast.verbose)
        XCTAssertNotNil(fast.jobs)
    }
}
