import XCTest
@testable import TheosStudioCore

final class ToolchainTests: XCTestCase {

    /// A tiny in-memory filesystem: the search order is the part that breaks on
    /// devices, so it is tested without a device.
    private struct FakeFileSystem {
        var files: Set<String>
        var directories: [String: [String]]

        init(files: [String] = [], directories: [String: [String]] = [:]) {
            self.files = Set(files)
            self.directories = directories
        }

        func exists(_ path: String) -> Bool { files.contains(path) }
        func list(_ path: String) -> [String] { directories[path] ?? [] }
    }

    private func theosRootFiles(_ root: String) -> [String] {
        [root + "/makefiles/common.mk", root + "/bin/logos.pl", root + "/bin/makefiles"]
    }

    // MARK: - Layout detection

    func testRootlessPrefixIsDetectedFromVarJb() {
        let layout = JailbreakLayout.detect(exists: { $0 == "/var/jb" })
        XCTAssertEqual(layout.scheme, .rootless)
        XCTAssertEqual(layout.rootlessPrefix, "/var/jb")
        XCTAssertTrue(layout.binDirectories.first == "/var/jb/usr/bin")
    }

    func testRootfulWhenVarJbIsAbsent() {
        let layout = JailbreakLayout.detect(exists: { _ in false })
        XCTAssertEqual(layout.scheme, .rootful)
        XCTAssertNil(layout.rootlessPrefix)
        XCTAssertFalse(layout.binDirectories.contains { $0.hasPrefix("/var/jb") })
        XCTAssertTrue(layout.binDirectories.contains("/usr/bin"))
    }

    func testSchemeMetadata() {
        XCTAssertEqual(PackagingScheme.rootful.debianArchitecture, "iphoneos-arm")
        XCTAssertEqual(PackagingScheme.rootless.debianArchitecture, "iphoneos-arm64")
        XCTAssertEqual(PackagingScheme.roothide.debianArchitecture, "iphoneos-arm64e")
        XCTAssertNil(PackagingScheme.rootful.theosVariableValue)
        XCTAssertEqual(PackagingScheme.rootless.theosVariableValue, "rootless")
        XCTAssertEqual(PackagingScheme.roothide.theosVariableValue, "roothide")
        XCTAssertTrue(PackagingScheme.roothide.requiresRoothideTheos)
    }

    // MARK: - Theos discovery

    func testTheosRootSearchOrderPrefersTheJailbreakPath() {
        let layout = JailbreakLayout(rootlessPrefix: "/var/jb", scheme: .rootless)
        let roots = TheosLocator.defaultTheosRoots(home: "/var/mobile", jailbreak: layout)
        XCTAssertEqual(roots.first, "/var/jb/opt/theos")
        XCTAssertLessThan(
            roots.firstIndex(of: "/var/jb/opt/theos")!,
            roots.firstIndex(of: "/opt/theos")!
        )
        XCTAssertLessThan(
            roots.firstIndex(of: "/opt/theos")!,
            roots.firstIndex(of: "/var/mobile/theos")!
        )
    }

    func testRootIsOnlyAcceptedWithTheMakefiles() {
        let fs = FakeFileSystem(files: ["/opt/theos/makefiles/common.mk"])
        XCTAssertTrue(TheosLocator.isTheosRoot("/opt/theos", exists: fs.exists))
        XCTAssertFalse(TheosLocator.isTheosRoot("/opt/theos", exists: { _ in false }))
    }

    func testLocateTheosReturnsTheFirstUsableRoot() {
        let roots = ["/var/jb/opt/theos", "/opt/theos", "/var/theos"]
        let fs = FakeFileSystem(files: theosRootFiles("/opt/theos") + theosRootFiles("/var/theos"))
        XCTAssertEqual(TheosLocator.locateTheos(roots: roots, exists: fs.exists), "/opt/theos")
        XCTAssertNil(TheosLocator.locateTheos(roots: roots, exists: { _ in false }))
    }

    func testBundledToolchainDirectoriesAreOnThePath() {
        let layout = JailbreakLayout(rootlessPrefix: "/var/jb", scheme: .rootless)
        let directories = TheosLocator.binDirectories(jailbreak: layout, theosRoot: "/opt/theos")
        XCTAssertEqual(directories.prefix(4), ["/var/jb/usr/bin", "/var/jb/bin", "/var/jb/usr/sbin", "/var/jb/sbin"])
        XCTAssertTrue(directories.contains("/opt/theos/bin"))
        XCTAssertTrue(directories.contains("/opt/theos/toolchain/linux/iphone/bin"))
    }

    func testResolvePicksTheFirstDirectoryHoldingTheTool() {
        let directories = ["/var/jb/usr/bin", "/usr/bin"]
        let fs = FakeFileSystem(files: ["/usr/bin/make"])
        XCTAssertEqual(TheosLocator.resolve(executable: "make", in: directories, exists: fs.exists), "/usr/bin/make")
        XCTAssertNil(TheosLocator.resolve(executable: "ldid", in: directories, exists: fs.exists))
    }

    // MARK: - Environment

    func testEnvironmentExportsTheosHomeAndADeduplicatedPath() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/var/mobile"]
        let environment = TheosLocator.environment(
            theosRoot: "/opt/theos",
            binDirectories: ["/var/jb/usr/bin", "/usr/bin"],
            base: base,
            home: "/var/mobile"
        )
        XCTAssertEqual(environment["THEOS"], "/opt/theos")
        XCTAssertEqual(environment["HOME"], "/var/mobile")
        XCTAssertEqual(environment["LC_ALL"], "C")
        let components = environment["PATH"]!.split(separator: ":").map(String.init)
        XCTAssertEqual(components, ["/var/jb/usr/bin", "/usr/bin", "/opt/theos/bin", "/bin"])
    }

    // MARK: - Report

    private func report(
        files: [String],
        directories: [String: [String]] = [:],
        override: String? = nil,
        base: [String: String] = [:]
    ) -> ToolchainReport {
        let fs = FakeFileSystem(files: files, directories: directories)
        return TheosLocator.report(
            home: "/var/mobile",
            override: override,
            jailbreak: JailbreakLayout(rootlessPrefix: "/var/jb", scheme: .rootless),
            base: base,
            exists: fs.exists,
            listDirectory: fs.list
        )
    }

    private func completeToolFiles() -> [String] {
        ["make", "clang", "ldid", "dpkg-deb", "dpkg", "perl", "killall"].map { "/var/jb/usr/bin/" + $0 }
    }

    func testACompleteDeviceIsReadyToBuild() {
        let root = "/var/jb/opt/theos"
        let report = report(
            files: completeToolFiles() + theosRootFiles(root),
            directories: [root + "/sdks": ["iPhoneOS16.5.sdk", "iPhoneOS17.0.sdk", "README.md"]]
        )
        XCTAssertEqual(report.theosRoot, root)
        XCTAssertEqual(report.sdkDirectories, ["iPhoneOS16.5.sdk", "iPhoneOS17.0.sdk"])
        XCTAssertTrue(report.isReadyToBuild)
        XCTAssertTrue(report.missingRequired.isEmpty)
        XCTAssertEqual(report.installCommand, "")
    }

    func testAMissingToolNamesThePackageThatProvidesIt() {
        let root = "/var/jb/opt/theos"
        let report = report(
            files: completeToolFiles().filter { !$0.hasSuffix("/ldid") } + theosRootFiles(root),
            directories: [root + "/sdks": ["iPhoneOS16.5.sdk"]]
        )
        XCTAssertFalse(report.isReadyToBuild)
        XCTAssertEqual(report.missingRequired.map(\.tool.name), ["ldid"])
        XCTAssertEqual(report.installCommand, "apt-get update && apt-get install -y ldid")
    }

    func testMissingPackagesAreDeduplicated() {
        let report = report(files: [], directories: [:])
        // dpkg-deb and dpkg both come from `dpkg`.
        XCTAssertEqual(report.missingPackages.filter { $0 == "dpkg" }.count, 1)
        XCTAssertTrue(report.installCommand.hasPrefix("apt-get update && apt-get install -y "))
    }

    func testNoSdkIsReportedBecauseTheosCannotCompileWithoutOne() {
        let root = "/var/jb/opt/theos"
        let report = report(files: completeToolFiles() + theosRootFiles(root), directories: [:])
        XCTAssertEqual(report.theosRoot, root)
        XCTAssertTrue(report.sdkDirectories.isEmpty)
        XCTAssertFalse(report.isReadyToBuild)
        XCTAssertTrue(report.notes.contains { $0.contains("$THEOS/sdks") })
    }

    func testMissingTheosIsExplained() {
        let report = report(files: completeToolFiles())
        XCTAssertNil(report.theosRoot)
        XCTAssertFalse(report.isReadyToBuild)
        XCTAssertTrue(report.notes.contains { $0.contains("Theos was not found") })
    }

    func testAStaleOverrideFallsBackToTheSearch() {
        let root = "/var/jb/opt/theos"
        let report = report(
            files: completeToolFiles() + theosRootFiles(root),
            directories: [root + "/sdks": ["iPhoneOS16.5.sdk"]],
            override: "/nonexistent/theos"
        )
        XCTAssertEqual(report.theosRoot, root)
        XCTAssertFalse(report.theosRootWasOverridden)
        XCTAssertTrue(report.notes.contains { $0.contains("does not contain makefiles/common.mk") })
    }

    func testAGoodOverrideWinsAndIsFlagged() {
        let root = "/var/theos"
        let report = report(
            files: completeToolFiles() + theosRootFiles(root),
            directories: [root + "/sdks": ["iPhoneOS16.5.sdk"]],
            override: root
        )
        XCTAssertEqual(report.theosRoot, root)
        XCTAssertTrue(report.theosRootWasOverridden)
    }

    func testTheEnvironmentVariableIsUsedWhenThereIsNoOverride() {
        let root = "/var/theos"
        let report = report(
            files: completeToolFiles() + theosRootFiles(root),
            directories: [root + "/sdks": ["iPhoneOS16.5.sdk"]],
            base: ["THEOS": root]
        )
        XCTAssertEqual(report.theosRoot, root)
        XCTAssertTrue(report.notes.contains { $0.contains("THEOS environment variable") })
    }
}
