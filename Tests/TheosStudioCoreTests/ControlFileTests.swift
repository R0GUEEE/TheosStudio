import XCTest
@testable import TheosStudioCore

final class ControlFileTests: XCTestCase {

    private let sample = """
    Package: com.example.mytweak
    Name: MyTweak
    Version: 0.0.1
    Architecture: iphoneos-arm64
    Description: A tweak that does a thing
     and keeps explaining it on a second line.
    Maintainer: Someone <someone@example.com>
    Section: Tweaks
    Depends: mobilesubstrate, firmware (>= 15.0)
    Custom-Field: kept
    """

    func testParsesEveryField() {
        let control = ControlFile.parse(sample)
        XCTAssertEqual(control.packageIdentifier, "com.example.mytweak")
        XCTAssertEqual(control.name, "MyTweak")
        XCTAssertEqual(control.version, "0.0.1")
        XCTAssertEqual(control.architecture, "iphoneos-arm64")
        XCTAssertEqual(control["Depends"], "mobilesubstrate, firmware (>= 15.0)")
        XCTAssertEqual(control["Custom-Field"], "kept")
    }

    func testContinuationLinesBecomeOneValue() {
        let control = ControlFile.parse(sample)
        XCTAssertEqual(control["Description"], "A tweak that does a thing\nand keeps explaining it on a second line.")
    }

    /// Serialising is what normalises field order, so the property to hold is
    /// idempotency: writing a parsed file twice produces the same bytes.
    func testSerialisingIsIdempotent() {
        let once = ControlFile.parse(sample).serialized()
        let twice = ControlFile.parse(once).serialized()
        XCTAssertEqual(once, twice)
    }

    func testRoundTripPreservesEveryFieldValue() {
        let control = ControlFile.parse(sample)
        let reparsed = ControlFile.parse(control.serialized())
        XCTAssertEqual(reparsed.fields.map(\.key), control.orderedFields().map(\.key))
        for field in control.fields {
            XCTAssertEqual(reparsed[field.key], field.value, "value of \(field.key) changed")
        }
    }

    func testSerialisingWritesContinuationsWithALeadingSpace() {
        var control = ControlFile()
        control["Package"] = "com.example.a"
        control["Description"] = "First line\nsecond line"
        let text = control.serialized()
        XCTAssertTrue(text.contains("Description: First line\n second line\n"), text)
    }

    func testFieldLookupIsCaseInsensitiveAndReCaseIsCanonical() {
        let control = ControlFile.parse("package: com.example.a\nVERSION: 1.0\n")
        XCTAssertEqual(control.packageIdentifier, "com.example.a")
        XCTAssertEqual(control.version, "1.0")
        let keys = control.fields.map(\.key)
        XCTAssertEqual(keys, ["Package", "Version"])
    }

    func testKnownFieldsAreWrittenInCanonicalOrder() {
        var control = ControlFile()
        control["Description"] = "d"
        control["Package"] = "com.example.a"
        control["Section"] = "Tweaks"
        control["Name"] = "A"
        let keys = control.serialized()
            .split(separator: "\n")
            .compactMap { $0.split(separator: ":").first.map(String.init) }
        XCTAssertEqual(Array(keys.prefix(4)), ["Package", "Name", "Section", "Description"])
    }

    func testUnknownFieldsSurviveAtTheEnd() {
        var control = ControlFile()
        control["Package"] = "com.example.a"
        control["Zebra-Field"] = "x"
        control["Name"] = "A"
        let ordered = control.orderedFields().map(\.key)
        XCTAssertEqual(ordered, ["Package", "Name", "Zebra-Field"])
    }

    func testSettingNilRemovesAField() {
        var control = ControlFile.parse(sample)
        control["Custom-Field"] = nil
        XCTAssertNil(control["Custom-Field"])
    }

    func testCommentsAndBlankLinesAreIgnored() {
        let control = ControlFile.parse("# a comment\nPackage: com.example.a\n\n\n# another\nVersion: 1.0\n")
        XCTAssertEqual(control.fields.count, 2)
    }

    func testCRLFLineEndingsAreHandled() {
        let control = ControlFile.parse("Package: com.example.a\r\nVersion: 1.0\r\n")
        XCTAssertEqual(control.version, "1.0")
        XCTAssertEqual(control.packageIdentifier, "com.example.a")
    }

    // MARK: - Validation

    func testValidIdentifierAcceptsDebianRules() {
        XCTAssertTrue(ControlValidator.isValidPackageIdentifier("com.example.my-tweak"))
        XCTAssertTrue(ControlValidator.isValidPackageIdentifier("a1+2.3"))
        XCTAssertFalse(ControlValidator.isValidPackageIdentifier("Com.Example"))
        XCTAssertFalse(ControlValidator.isValidPackageIdentifier("-leading"))
        XCTAssertFalse(ControlValidator.isValidPackageIdentifier("com..example"))
        XCTAssertFalse(ControlValidator.isValidPackageIdentifier(""))
        XCTAssertFalse(ControlValidator.isValidPackageIdentifier("com/example"))
    }

    func testMissingVersionIsAnError() {
        var control = ControlFile()
        control["Package"] = "com.example.a"
        let issues = ControlValidator.issues(for: control, kind: .tweak, projectName: "A")
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("Version:") })
    }

    func testTweakWithoutAHookingLibraryWarns() {
        var control = ControlFile()
        control["Package"] = "com.example.a"
        control["Version"] = "1.0"
        control["Description"] = "d"
        control["Maintainer"] = "Someone <a@b.c>"
        let issues = ControlValidator.issues(for: control, kind: .tweak, projectName: "A")
        XCTAssertTrue(issues.contains { $0.message.contains("hooking library") })

        control["Depends"] = "ellekit"
        let fixed = ControlValidator.issues(for: control, kind: .tweak, projectName: "A")
        XCTAssertFalse(fixed.contains { $0.message.contains("hooking library") })
    }

    func testToolDoesNotNeedAHookingLibrary() {
        var control = ControlFile()
        control["Package"] = "com.example.a"
        control["Version"] = "1.0"
        control["Architecture"] = "iphoneos-arm64"
        control["Description"] = "d"
        control["Maintainer"] = "Someone <a@b.c>"
        let issues = ControlValidator.issues(for: control, kind: .tool, projectName: "A")
        XCTAssertFalse(issues.contains { $0.message.contains("hooking library") })
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    func testNameMismatchWarnsBecauseTheFilterFileFollowsTheProjectName() {
        var control = ControlFile()
        control["Package"] = "com.example.a"
        control["Version"] = "1.0"
        control["Description"] = "d"
        control["Maintainer"] = "Someone <a@b.c>"
        control["Name"] = "SomethingElse"
        let issues = ControlValidator.issues(for: control, kind: .tool, projectName: "A")
        XCTAssertTrue(issues.contains { $0.message.contains("filter file") })
    }

    func testMaintainerNeedsAnAddress() {
        var control = ControlFile()
        control["Package"] = "com.example.a"
        control["Version"] = "1.0"
        control["Description"] = "d"
        control["Maintainer"] = "Someone"
        let issues = ControlValidator.issues(for: control, kind: .tool, projectName: "A")
        XCTAssertTrue(issues.contains { $0.message.contains("Name <email>") })
    }
}
