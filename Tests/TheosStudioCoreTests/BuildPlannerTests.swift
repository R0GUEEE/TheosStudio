import XCTest
@testable import TheosStudioCore

final class BuildPlannerTests: XCTestCase {

    private let path = "/var/mobile/Documents/Projects/MyTweak"

    private func request(
        scheme: PackagingScheme = .rootless,
        finalPackage: Bool = false,
        cleanFirst: Bool = false,
        verbose: Bool = true,
        jobs: Int? = nil,
        extraVariables: [String: String] = [:]
    ) -> BuildRequest {
        BuildRequest(
            projectPath: path,
            scheme: scheme,
            finalPackage: finalPackage,
            cleanFirst: cleanFirst,
            verbose: verbose,
            jobs: jobs,
            extraVariables: extraVariables
        )
    }

    func testDefaultPlanIsOneMakePackage() {
        let commands = BuildPlanner.plan(for: request(), make: "/var/jb/usr/bin/make", environment: ["THEOS": "/opt/theos"])
        XCTAssertEqual(commands.count, 1)
        let command = commands[0]
        XCTAssertEqual(command.executable, "/var/jb/usr/bin/make")
        XCTAssertEqual(command.arguments.first, "-C")
        XCTAssertEqual(command.arguments[1], path)
        XCTAssertEqual(command.arguments.last, "package")
        XCTAssertTrue(command.arguments.contains("THEOS_PACKAGE_SCHEME=rootless"))
    }

    /// `chdir` is not available on iOS, so the project directory has to travel as
    /// an argument. If this ever changes, the build silently runs in the wrong
    /// place.
    func testTheProjectDirectoryIsPassedNotInherited() {
        let commands = BuildPlanner.plan(for: request(), make: "make", environment: [:])
        XCTAssertEqual(Array(commands[0].arguments.prefix(2)), ["-C", path])
    }

    func testRootfulOmitsTheSchemeVariable() {
        let commands = BuildPlanner.plan(for: request(scheme: .rootful), make: "make", environment: [:])
        XCTAssertFalse(commands[0].arguments.contains { $0.hasPrefix("THEOS_PACKAGE_SCHEME") })
    }

    func testFinalPackageAndVerbosityBecomeMakeVariables() {
        let command = BuildPlanner.plan(for: request(finalPackage: true, verbose: true), make: "make", environment: [:])[0]
        XCTAssertTrue(command.arguments.contains("FINALPACKAGE=1"))
        XCTAssertTrue(command.arguments.contains("messages=yes"))

        let quiet = BuildPlanner.plan(for: request(verbose: false), make: "make", environment: [:])[0]
        XCTAssertFalse(quiet.arguments.contains("messages=yes"))
    }

    func testCleanFirstProducesTwoCommandsInOrder() {
        let commands = BuildPlanner.plan(for: request(cleanFirst: true), make: "make", environment: [:])
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments.last, "clean")
        XCTAssertEqual(commands[1].arguments.last, "package")
    }

    func testJobsArePassedToMake() {
        XCTAssertTrue(BuildPlanner.plan(for: request(jobs: 4), make: "make", environment: [:])[0].arguments.contains("-j4"))
        XCTAssertFalse(BuildPlanner.plan(for: request(jobs: 1), make: "make", environment: [:])[0].arguments.contains { $0.hasPrefix("-j") })
        XCTAssertFalse(BuildPlanner.plan(for: request(), make: "make", environment: [:])[0].arguments.contains { $0.hasPrefix("-j") })
    }

    func testExtraVariablesAreSortedAndAppended() {
        let command = BuildPlanner.plan(
            for: request(extraVariables: ["DEBUG": "0", "ARCHS": "arm64"]),
            make: "make",
            environment: [:]
        )[0]
        let variables = command.arguments.filter { $0.contains("=") }
        XCTAssertEqual(variables, ["ARCHS=arm64", "DEBUG=0", "THEOS_PACKAGE_SCHEME=rootless", "messages=yes"])
    }

    func testDisplayLineIsQuotableBackIntoATerminal() {
        let command = BuildPlanner.plan(for: request(), make: "/var/jb/usr/bin/make", environment: [:])[0]
        XCTAssertEqual(command.display, "/var/jb/usr/bin/make -C \(path) THEOS_PACKAGE_SCHEME=rootless messages=yes package")
    }

    func testShellQuoting() {
        XCTAssertEqual(ShellQuote.quote("simple"), "simple")
        XCTAssertEqual(ShellQuote.quote("/a/b-c.d"), "/a/b-c.d")
        XCTAssertEqual(ShellQuote.quote("with space"), "'with space'")
        XCTAssertEqual(ShellQuote.quote("it's"), "'it'\\''s'")
        XCTAssertEqual(ShellQuote.quote(""), "''")
        XCTAssertEqual(ShellQuote.join(["make", "-C", "/a b"]), "make -C '/a b'")
    }

    func testPackagesDirectoryFollowsTheosConvention() {
        XCTAssertEqual(BuildPlanner.packagesDirectory(for: path), path + "/packages")
        XCTAssertEqual(BuildPlanner.buildDirectory(for: path), path + "/.theos")
    }

    // MARK: - Artefacts

    func testNewestPackageIsChosenByDateNotName() {
        let dates: [String: Date] = [
            path + "/packages/com.example.mytweak_0.0.9_iphoneos-arm64.deb": Date(timeIntervalSince1970: 100),
            path + "/packages/com.example.mytweak_0.0.2_iphoneos-arm64.deb": Date(timeIntervalSince1970: 500),
        ]
        let newest = ArtifactLocator.newestPackage(
            in: path,
            listDirectory: { _ in ["com.example.mytweak_0.0.9_iphoneos-arm64.deb", "com.example.mytweak_0.0.2_iphoneos-arm64.deb", "notes.txt"] },
            modificationDate: { dates[$0] }
        )
        XCTAssertEqual(newest, path + "/packages/com.example.mytweak_0.0.2_iphoneos-arm64.deb")
    }

    func testNoPackagesMeansNil() {
        XCTAssertNil(ArtifactLocator.newestPackage(in: path, listDirectory: { _ in [] }, modificationDate: { _ in nil }))
        XCTAssertNil(ArtifactLocator.newestPackage(in: path, listDirectory: { _ in ["Tweak.x"] }, modificationDate: { _ in nil }))
    }
}

final class DiagnosticsTests: XCTestCase {

    func testFourPartCompilerMessage() {
        let diagnostic = DiagnosticParser.diagnostic(fromLine: "/tmp/Tweak.x:12:5: error: use of undeclared identifier 'foo'")
        XCTAssertEqual(diagnostic?.file, "/tmp/Tweak.x")
        XCTAssertEqual(diagnostic?.line, 12)
        XCTAssertEqual(diagnostic?.column, 5)
        XCTAssertEqual(diagnostic?.severity, .error)
        XCTAssertEqual(diagnostic?.message, "use of undeclared identifier 'foo'")
        XCTAssertEqual(diagnostic?.location, "/tmp/Tweak.x:12:5")
    }

    func testThreePartCompilerMessage() {
        let diagnostic = DiagnosticParser.diagnostic(fromLine: "Tweak.x:3: warning: implicit declaration of function 'NSLog'")
        XCTAssertEqual(diagnostic?.file, "Tweak.x")
        XCTAssertEqual(diagnostic?.line, 3)
        XCTAssertNil(diagnostic?.column)
        XCTAssertEqual(diagnostic?.severity, .warning)
        XCTAssertEqual(diagnostic?.location, "Tweak.x:3")
    }

    func testBareSeverityLinesFromLinkersAndScripts() {
        let diagnostic = DiagnosticParser.diagnostic(fromLine: "error: unknown target 'iPhoneOS16.5.sdk'")
        XCTAssertNil(diagnostic?.file)
        XCTAssertEqual(diagnostic?.severity, .error)
        XCTAssertEqual(diagnostic?.message, "unknown target 'iPhoneOS16.5.sdk'")
    }

    func testOrdinaryLogLinesAreNotDiagnostics() {
        XCTAssertNil(DiagnosticParser.diagnostic(fromLine: "Making all for tweak MyTweak..."))
        XCTAssertNil(DiagnosticParser.diagnostic(fromLine: "  clang -c Tweak.x -o Tweak.x.o"))
        XCTAssertNil(DiagnosticParser.diagnostic(fromLine: ""))
    }

    func testDiagnosticsAreDeduplicatedAndErrorsComeFirst() {
        let log = [
            "Tweak.x:1:1: warning: first",
            "Tweak.x:1:1: warning: first",
            "Tweak.x:9:2: error: boom",
            "error: linker failed",
        ]
        let diagnostics = DiagnosticParser.diagnostics(in: log)
        XCTAssertEqual(diagnostics.count, 3)
        XCTAssertEqual(diagnostics.map(\.severity), [.error, .error, .warning])
    }

    func testPackagedFileIsReadFromDpkgOutput() {
        let log = [
            "Making stage...",
            "dpkg-deb: building package 'com.example.mytweak' in '../packages/com.example.mytweak_0.0.1_iphoneos-arm64.deb'.",
        ]
        XCTAssertEqual(
            DiagnosticParser.packagedFile(in: log),
            "../packages/com.example.mytweak_0.0.1_iphoneos-arm64.deb"
        )
        XCTAssertNil(DiagnosticParser.packagedFile(in: ["nothing here"]))
    }

    func testFatalLineIsTheLastMakeFailure() {
        let log = [
            "make[1]: *** [obj/Tweak.x.o] Error 1",
            "make: *** [internal-library-all_] Error 2",
        ]
        XCTAssertEqual(DiagnosticParser.fatalLine(in: log), "make: *** [internal-library-all_] Error 2")
        XCTAssertNil(DiagnosticParser.fatalLine(in: ["all good"]))
    }
}
