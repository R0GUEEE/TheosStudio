import XCTest
@testable import TheosStudioCore

final class PrivilegesTests: XCTestCase {

    func testRootRunsEverythingDirectly() {
        let context = PrivilegeResolver.resolve(isRoot: true, sudoPath: nil, sudoIsPasswordless: false)
        XCTAssertEqual(context.mode, .root)
        XCTAssertTrue(context.canEscalate)
        XCTAssertTrue(context.prefix.isEmpty)
        let wrapped = context.wrapped("/usr/bin/dpkg", ["-i", "x.deb"])
        XCTAssertEqual(wrapped.executable, "/usr/bin/dpkg")
        XCTAssertEqual(wrapped.arguments, ["-i", "x.deb"])
    }

    func testPasswordlessSudoWrapsTheTool() {
        let context = PrivilegeResolver.resolve(
            isRoot: false,
            sudoPath: "/var/jb/usr/bin/sudo",
            sudoIsPasswordless: true
        )
        XCTAssertEqual(context.mode, .sudo(path: "/var/jb/usr/bin/sudo"))
        XCTAssertTrue(context.canEscalate)
        let wrapped = context.wrapped("/var/jb/usr/bin/dpkg", ["-i", "/tmp/x.deb"])
        XCTAssertEqual(wrapped.executable, "/var/jb/usr/bin/sudo")
        XCTAssertEqual(wrapped.arguments, ["-n", "/var/jb/usr/bin/dpkg", "-i", "/tmp/x.deb"])
    }

    /// An app has no terminal. A sudo that would ask for a password is the same
    /// thing as no sudo: it would hang the build instead of failing.
    func testSudoThatWantsAPasswordIsTreatedAsNoSudo() {
        let context = PrivilegeResolver.resolve(
            isRoot: false,
            sudoPath: "/var/jb/usr/bin/sudo",
            sudoIsPasswordless: false
        )
        XCTAssertEqual(context.mode, .unprivileged)
        XCTAssertFalse(context.canEscalate)
        XCTAssertTrue(context.prefix.isEmpty)
    }

    func testNoSudoAtAllIsUnprivilegedAndExplainsItself() {
        let context = PrivilegeResolver.resolve(isRoot: false, sudoPath: nil, sudoIsPasswordless: false)
        XCTAssertFalse(context.canEscalate)
        let remedy = context.remedy(for: "apt-get install -y theos-dependencies")
        XCTAssertTrue(remedy.contains("apt-get install -y theos-dependencies"))
        XCTAssertTrue(remedy.contains("Sileo"))
        XCTAssertTrue(context.summary.contains("mobile"))
    }
}

final class TheosInstallerTests: XCTestCase {

    private func tools(including names: [String]) -> [String: String] {
        var paths: [String: String] = [:]
        for name in names { paths[name] = "/var/jb/usr/bin/" + name }
        return paths
    }

    private let allTools = ["git", "curl", "tar", "mkdir", "apt-get", "xz"]

    private func isDownload(_ step: InstallStep) -> Bool {
        if case .download = step.kind { return true }
        return false
    }

    private let sdk = SDKAsset(
        name: "iPhoneOS16.5.sdk",
        url: "https://example.invalid/iPhoneOS16.5.sdk.tar.xz",
        version: "16.5"
    )

    private func options(destination: String = "/var/mobile/Documents/Theos") -> TheosInstallOptions {
        TheosInstallOptions(destination: destination, sdkAsset: sdk, procursus: true)
    }

    func testRootPlanStartsWithTheDependencyPackages() {
        let plan = TheosInstaller.plan(
            options: options(),
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .root)
        )
        XCTAssertEqual(plan.steps.prefix(2).map(\.tool), ["apt-get", "apt-get"])
        XCTAssertEqual(plan.steps[0].arguments, ["update"])
        XCTAssertTrue(plan.steps[0].requiresRoot)
        XCTAssertEqual(plan.steps[1].arguments, ["install", "-y", "theos-dependencies"])
        XCTAssertTrue(plan.missingTools.isEmpty, "\(plan.warnings)")
    }

    func testDependencyStepUsesTheFullListOnANonProcursusBootstrap() {
        var options = options()
        options.procursus = false
        let plan = TheosInstaller.plan(
            options: options,
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .root)
        )
        let install = plan.steps.first { $0.arguments.first == "install" }
        XCTAssertEqual(install?.arguments.contains("clang"), true)
        XCTAssertEqual(install?.arguments.contains("ldid"), true)
        XCTAssertEqual(install?.arguments.contains("perl"), true)
    }

    /// The whole point: without root the plan still installs Theos and its SDK,
    /// because those are files in a folder. Only the packages are dropped.
    func testUnprivilegedPlanHasNoRootStepsButStillInstallsTheos() {
        let plan = TheosInstaller.plan(
            options: options(),
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .unprivileged)
        )
        XCTAssertFalse(plan.steps.contains { $0.requiresRoot })
        XCTAssertFalse(plan.steps.contains { $0.tool == "apt-get" })
        XCTAssertTrue(plan.steps.contains { $0.tool == "git" && $0.arguments.first == "clone" })
        // The SDK download is done by the app, so it needs no tool at all.
        XCTAssertTrue(plan.steps.contains { isDownload($0) })
        XCTAssertTrue(plan.steps.contains { $0.tool == "tar" })
        XCTAssertTrue(plan.warnings.contains { $0.contains("need root") }, "\(plan.warnings)")
        XCTAssertTrue(plan.warnings.contains { $0.contains("clang") })
    }

    func testSudoPlanKeepsTheDependencySteps() {
        let plan = TheosInstaller.plan(
            options: options(),
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .sudo(path: "/var/jb/usr/bin/sudo"))
        )
        XCTAssertTrue(plan.needsRoot)
        XCTAssertEqual(plan.steps.filter { $0.requiresRoot }.count, 2)
    }

    func testMissingGitIsReportedAndNoCloneStepIsPlanned() {
        let plan = TheosInstaller.plan(
            options: options(),
            toolPaths: tools(including: ["curl", "tar", "mkdir", "apt-get"]),
            privileges: PrivilegeContext(mode: .root)
        )
        XCTAssertEqual(plan.missingTools, ["git"])
        XCTAssertFalse(plan.steps.contains { $0.tool == "git" })
        XCTAssertTrue(plan.warnings.contains { $0.contains("git is not installed") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("fetches Theos itself") })
    }

    func testStepsKnowWhenTheyAreAlreadyDone() {
        let destination = "/var/mobile/Documents/Theos"
        let plan = TheosInstaller.plan(
            options: options(destination: destination),
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .root)
        )
        let sdk = destination + "/sdks/iPhoneOS16.5.sdk"
        XCTAssertEqual(plan.steps.first { $0.tool == "mkdir" }?.skipIfExists, destination)
        XCTAssertEqual(
            plan.steps.first { $0.tool == "git" && $0.arguments.first == "clone" }?.skipIfExists,
            destination + "/makefiles/common.mk"
        )
        XCTAssertEqual(plan.steps.first { isDownload($0) }?.skipIfExists, sdk)
        XCTAssertEqual(plan.steps.first { $0.tool == "tar" }?.skipIfExists, sdk)
        // The submodule step is a repair, not a one-off: it never claims to be done.
        XCTAssertNil(plan.steps.first { $0.tool == "git" && $0.arguments.first == "-C" }?.skipIfExists)
    }

    /// The unpack is a ladder: try tar with xz support, and if this device's tar
    /// does not have it, decompress first and unpack the result. Every rung is
    /// skipped once the SDK is on disk, so the first one that works ends it.
    func testTheUnpackLadderHasAFallbackWhenTheDeviceHasXZ() {
        let destination = "/var/mobile/Documents/Theos"
        let plan = TheosInstaller.plan(
            options: options(destination: destination),
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .root)
        )
        let sdk = destination + "/sdks/iPhoneOS16.5.sdk"
        let archive = destination + "/sdks/.iPhoneOS16.5.sdk.tar.xz"

        let unpackSteps = plan.steps.filter { $0.tool == "tar" || $0.tool == "xz" }
        XCTAssertEqual(unpackSteps.count, 3)
        XCTAssertEqual(unpackSteps[0].arguments, ["-xJf", archive, "-C", destination + "/sdks"])
        XCTAssertTrue(unpackSteps[0].tolerateFailure, "the first attempt must not end the installation")
        XCTAssertEqual(unpackSteps[1].tool, "xz")
        XCTAssertEqual(unpackSteps[1].arguments, ["-d", archive])
        XCTAssertEqual(unpackSteps[2].arguments, ["-xf", destination + "/sdks/.iPhoneOS16.5.sdk.tar", "-C", destination + "/sdks"])
        XCTAssertFalse(unpackSteps[2].tolerateFailure, "if even this fails, the installation failed")
        for step in unpackSteps {
            XCTAssertEqual(step.skipIfExists, sdk)
        }
        XCTAssertFalse(plan.warnings.contains { $0.contains("xz") }, "\(plan.warnings)")
    }

    func testWithoutXZTheFallbackIsOmittedAndReported() {
        let plan = TheosInstaller.plan(
            options: options(),
            toolPaths: tools(including: ["git", "tar", "mkdir", "apt-get"]),
            privileges: PrivilegeContext(mode: .root)
        )
        XCTAssertEqual(plan.steps.filter { $0.tool == "tar" }.count, 1)
        XCTAssertFalse(plan.steps.contains { $0.tool == "xz" })
        XCTAssertTrue(plan.warnings.contains { $0.contains("xz is not installed") }, "\(plan.warnings)")
    }

    func testDownloadStepsAreNotCommands() {
        let plan = TheosInstaller.plan(
            options: options(),
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .root)
        )
        guard let download = plan.steps.first(where: isDownload) else {
            return XCTFail("expected a download step")
        }
        XCTAssertNil(download.tool)
        if case .download(let url, let to) = download.kind {
            XCTAssertEqual(url, "https://example.invalid/iPhoneOS16.5.sdk.tar.xz")
            XCTAssertTrue(to.hasSuffix(".iPhoneOS16.5.sdk.tar.xz"))
        } else {
            XCTFail("expected .download")
        }
    }

    func testNoSDKSelectedIsWarnedAbout() {
        var options = options()
        options.sdkAsset = nil
        let plan = TheosInstaller.plan(
            options: options,
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .root)
        )
        XCTAssertFalse(plan.steps.contains { isDownload($0) })
        XCTAssertTrue(plan.warnings.contains { $0.contains("SDK") && $0.contains("cannot compile") })
    }

    func testDependenciesCanBeSkippedEntirely() {
        var options = options()
        options.installDependencies = false
        options.fetchSDK = false
        let plan = TheosInstaller.plan(
            options: options,
            toolPaths: tools(including: allTools),
            privileges: PrivilegeContext(mode: .root)
        )
        XCTAssertEqual(plan.steps.map(\.tool), ["mkdir", "git", "git"])
    }

    // MARK: - SDK discovery

    private let releaseJSON = """
    {
      "tag_name": "master-146e41f",
      "assets": [
        {"name": "AppleTVOS12.4.sdk.tar.xz", "browser_download_url": "https://example.invalid/tv12.4"},
        {"name": "iPhoneOS9.3.sdk.tar.xz", "browser_download_url": "https://example.invalid/ios9.3"},
        {"name": "iPhoneOS16.5.sdk.tar.xz", "browser_download_url": "https://example.invalid/ios16.5"},
        {"name": "iPhoneOS15.6.sdk.tar.xz", "browser_download_url": "https://example.invalid/ios15.6"},
        {"name": "README.md", "browser_download_url": "https://example.invalid/readme"}
      ]
    }
    """

    func testNewestIPhoneOSSDKIsChosenNumerically() {
        let asset = try? TheosInstaller.latestSDKAsset(fromReleaseJSON: Data(releaseJSON.utf8))
        XCTAssertEqual(asset?.name, "iPhoneOS16.5.sdk")
        XCTAssertEqual(asset?.version, "16.5")
        XCTAssertEqual(asset?.url, "https://example.invalid/ios16.5")
        // 15.6 must win over 9.3, which a string comparison gets backwards.
        XCTAssertGreaterThan(TheosInstaller.compareVersions("15.6", "9.3"), 0)
        XCTAssertGreaterThan(TheosInstaller.compareVersions("16.5", "15.6"), 0)
        XCTAssertEqual(TheosInstaller.compareVersions("16.5", "16.5"), 0)
    }

    func testReleaseWithoutAnSDKIsAnError() {
        let json = #"{"assets": [{"name": "README.md", "browser_download_url": "https://example.invalid/r"}]}"#
        XCTAssertThrowsError(try TheosInstaller.latestSDKAsset(fromReleaseJSON: Data(json.utf8)))
        XCTAssertThrowsError(try TheosInstaller.latestSDKAsset(fromReleaseJSON: Data("not json".utf8)))
    }

    func testSDKNameParsing() {
        XCTAssertEqual(TheosInstaller.version(fromSDKName: "iPhoneOS16.5.sdk"), "16.5")
        XCTAssertNil(TheosInstaller.version(fromSDKName: "AppleTVOS12.4.sdk"))
        XCTAssertNil(TheosInstaller.version(fromSDKName: "iPhoneOS.sdk"))
    }
}
