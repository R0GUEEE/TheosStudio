import XCTest
@testable import TheosStudioCore

final class SHA256Tests: XCTestCase {

    /// The published vectors. A hash that is wrong by one bit produces a package
    /// that downloads and then refuses to install.
    func testKnownVectors() {
        XCTAssertEqual(
            SHA256.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            SHA256.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    /// Longer than one 64-byte block, which is where padding bugs show up.
    func testMessageSpanningSeveralBlocks() {
        let million = String(repeating: "a", count: 1_000_000)
        XCTAssertEqual(
            SHA256.hex(million),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        )
    }

    func testPaddingBoundaries() {
        // 55, 56 and 64 bytes are the interesting lengths: the first needs no
        // extra block, the second needs one, the third starts the next chunk.
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 55)).count, 64)
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 56)).count, 64)
        XCTAssertEqual(SHA256.hex(String(repeating: "a", count: 64)).count, 64)
        XCTAssertEqual(
            SHA256.hex(String(repeating: "a", count: 64)),
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        )
    }

    func testHexIsLowercaseAndFixedLength() {
        let digest = SHA256.hex([0x00, 0x0f, 0xff])
        XCTAssertEqual(digest.count, 64)
        XCTAssertEqual(digest, digest.lowercased())
    }
}

final class DebianRepositoryTests: XCTestCase {

    private func control() -> ControlFile {
        var control = ControlFile()
        control["Package"] = "com.example.mytweak"
        control["Name"] = "MyTweak"
        control["Version"] = "0.0.1"
        control["Architecture"] = "iphoneos-arm64"
        control["Description"] = "A tweak that does a thing"
        control["Depends"] = "mobilesubstrate"
        control["Section"] = "Tweaks"
        return control
    }

    func testStanzaCarriesTheFieldsAnIndexNeeds() {
        let package = RepositoryPackage(
            control: control(),
            fileName: "com.example.mytweak_0.0.1_iphoneos-arm64.deb",
            relativePath: "./debs/com.example.mytweak_0.0.1_iphoneos-arm64.deb",
            size: 48216,
            sha256: String(repeating: "a", count: 64)
        )
        let stanza = DebianRepository.stanza(package)
        XCTAssertTrue(stanza.contains("Package: com.example.mytweak"))
        XCTAssertTrue(stanza.contains("Version: 0.0.1"))
        XCTAssertTrue(stanza.contains("Filename: ./debs/com.example.mytweak_0.0.1_iphoneos-arm64.deb"))
        XCTAssertTrue(stanza.contains("Size: 48216"))
        XCTAssertTrue(stanza.contains("SHA256: " + String(repeating: "a", count: 64)))
        XCTAssertTrue(stanza.contains("Depends: mobilesubstrate"))
        XCTAssertTrue(stanza.hasSuffix("\n"))
    }

    func testThePackageItselfIsNotModifiedByIndexing() {
        var package = RepositoryPackage(
            control: control(), fileName: "x.deb", relativePath: "./x.deb", size: 1, sha256: "b"
        )
        _ = DebianRepository.stanza(package)
        XCTAssertNil(package.control["Filename"], "the index fields belong to the index, not the package")
        package.control["Version"] = "0.0.2"
        XCTAssertEqual(package.control.version, "0.0.2")
    }

    func testPackagesFileSeparatesStanzasWithABlankLine() {
        let one = RepositoryPackage(control: control(), fileName: "a.deb", relativePath: "./a.deb", size: 1, sha256: "a")
        var second = control()
        second["Package"] = "com.example.other"
        let two = RepositoryPackage(control: second, fileName: "b.deb", relativePath: "./b.deb", size: 2, sha256: "b")

        let file = DebianRepository.packagesFile([one, two])
        XCTAssertEqual(file.components(separatedBy: "\n\n").count, 2)
        XCTAssertTrue(file.contains("Package: com.example.other"))
    }

    func testReleaseFile() {
        let release = DebianRepository.releaseFile(
            label: "MyTweak",
            description: "My tweaks",
            architectures: ["iphoneos-arm64", "iphoneos-arm"]
        )
        XCTAssertTrue(release.contains("Origin: TheosStudio"))
        XCTAssertTrue(release.contains("Label: MyTweak"))
        XCTAssertTrue(release.contains("Architectures: iphoneos-arm64 iphoneos-arm"))
        XCTAssertTrue(release.contains("Components: main"))
        XCTAssertTrue(release.hasSuffix("\n"))

        // A repo with no packages still has to declare an architecture.
        XCTAssertTrue(DebianRepository.releaseFile(label: "x", description: "y", architectures: [])
            .contains("Architectures: iphoneos-arm64"))
    }

    func testIndexHTMLEscapesWhatItPrints() {
        var control = control()
        control["Name"] = "My<Tweak> & Co"
        let html = DebianRepository.indexHTML(
            label: "repo",
            description: "test",
            packages: [RepositoryPackage(control: control, fileName: "x.deb", relativePath: "./x.deb", size: 1, sha256: "a")]
        )
        XCTAssertTrue(html.contains("My&lt;Tweak&gt; &amp; Co"))
        XCTAssertFalse(html.contains("My<Tweak>"))
    }

    func testPackageFileNamesRoundTrip() {
        let name = DebianRepository.fileName(packageIdentifier: "com.example.a", version: "1.2-3", architecture: "iphoneos-arm64")
        XCTAssertEqual(name, "com.example.a_1.2-3_iphoneos-arm64.deb")
        let parsed = DebianRepository.parseFileName(name)
        XCTAssertEqual(parsed?.packageIdentifier, "com.example.a")
        XCTAssertEqual(parsed?.version, "1.2-3")
        XCTAssertEqual(parsed?.architecture, "iphoneos-arm64")

        XCTAssertNil(DebianRepository.parseFileName("README.md"))
        XCTAssertNil(DebianRepository.parseFileName("nounderscores.deb"))
    }
}

final class DebianVersionTests: XCTestCase {

    func testOrderingFollowsDpkgNotTheAlphabet() {
        XCTAssertEqual(DebianVersion.compare("1.0", "1.0"), 0)
        XCTAssertLessThan(DebianVersion.compare("1.0", "1.1"), 0)
        // String comparison gets this one backwards.
        XCTAssertGreaterThan(DebianVersion.compare("1.10", "1.9"), 0)
        // A tilde sorts before everything, including before the end of a string.
        XCTAssertLessThan(DebianVersion.compare("1.0~rc1", "1.0"), 0)
        XCTAssertLessThan(DebianVersion.compare("1.0~rc1", "1.0~rc2"), 0)
        // An epoch beats the upstream version outright.
        XCTAssertGreaterThan(DebianVersion.compare("1:1.0", "2.0"), 0)
        XCTAssertGreaterThan(DebianVersion.compare("1.0-1", "1.0"), 0)
        XCTAssertLessThan(DebianVersion.compare("1.0-1", "1.0-2"), 0)
        XCTAssertLessThan(DebianVersion.compare("1.0a", "1.0b"), 0)
        XCTAssertLessThan(DebianVersion.compare("1.0", "1.0.1"), 0)
    }

    func testBumping() {
        XCTAssertEqual(DebianVersion.bumped("0.0.1"), "0.0.2")
        XCTAssertEqual(DebianVersion.bumped("0.0.1", .minor), "0.1.0")
        XCTAssertEqual(DebianVersion.bumped("0.0.1", .major), "1.0.0")
        XCTAssertEqual(DebianVersion.bumped("1.9.3", .major), "2.0.0")
        XCTAssertEqual(DebianVersion.bumped("1.0"), "1.0.1")
        XCTAssertEqual(DebianVersion.bumped("2", .patch), "2.0.1")
    }

    func testBumpingKeepsEpochsAndRevisions() {
        XCTAssertEqual(DebianVersion.bumped("1:2.3.4", .patch), "1:2.3.5")
        XCTAssertEqual(DebianVersion.bumped("1.0-3", .revision), "1.0-4")
        XCTAssertEqual(DebianVersion.bumped("1.0", .revision), "1.0-1")
        XCTAssertEqual(DebianVersion.bumped("1.0-3", .patch), "1.0.1-3")
    }

    func testBumpingSomethingThatIsNotANumber() {
        XCTAssertEqual(DebianVersion.bumpLastNumber(in: "beta"), "beta.1")
        XCTAssertEqual(DebianVersion.bumpLastNumber(in: "1.2rc3"), "1.2rc4")
    }
}

final class DependencyCheckTests: XCTestCase {

    func testParsingDependencies() {
        let groups = DependencyCheck.parse("mobilesubstrate, firmware (>= 15.0), ellekit | libhooker")
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups[0].alternatives.map(\.name), ["mobilesubstrate"])
        XCTAssertNil(groups[0].alternatives[0].constraint)
        XCTAssertEqual(groups[1].alternatives[0].name, "firmware")
        XCTAssertEqual(groups[1].alternatives[0].constraint, ">= 15.0")
        XCTAssertEqual(groups[2].alternatives.map(\.name), ["ellekit", "libhooker"])
        XCTAssertEqual(groups[2].display, "ellekit | libhooker")
    }

    func testArchitectureRestrictionsAndProfilesAreIgnored() {
        let groups = DependencyCheck.parse("clang [iphoneos-arm64] <!nocheck>, make")
        XCTAssertEqual(groups.map { $0.alternatives[0].name }, ["clang", "make"])
        XCTAssertNil(groups[0].alternatives[0].constraint)
    }

    func testVirtualPackageArchitectureSuffix() {
        let groups = DependencyCheck.parse("mobilesubstrate:any")
        XCTAssertEqual(groups[0].alternatives[0].name, "mobilesubstrate")
    }

    func testVersionConstraints() {
        XCTAssertTrue(DependencyCheck.satisfies("1.2.3", constraint: ">= 1.0"))
        XCTAssertFalse(DependencyCheck.satisfies("0.9", constraint: ">= 1.0"))
        XCTAssertTrue(DependencyCheck.satisfies("1.0", constraint: "<= 1.0"))
        XCTAssertTrue(DependencyCheck.satisfies("2.0", constraint: ">> 1.0"))
        XCTAssertTrue(DependencyCheck.satisfies("0.5", constraint: "<< 1.0"))
        XCTAssertTrue(DependencyCheck.satisfies("1.0-3", constraint: "= 1.0"), "= compares the upstream version")
        XCTAssertTrue(DependencyCheck.satisfies("1.0", constraint: nil))
        // Something malformed is not a reason to call a package missing.
        XCTAssertTrue(DependencyCheck.satisfies("1.0", constraint: "garbage"))
    }

    /// The failure this exists for: a tweak installed without its hooking library
    /// does nothing at all, and nothing says why.
    func testMissingDependencies() {
        let installed = ["firmware": "16.5", "ellekit": "1.0"]
        let missing = DependencyCheck.missing(
            depends: "mobilesubstrate, firmware (>= 15.0), ldid",
            installed: installed,
            provides: ["mobilesubstrate": ["ellekit"]]
        )
        XCTAssertEqual(missing.map(\.display), ["ldid"])
    }

    func testAVersionConstraintThatIsNotMetCountsAsMissing() {
        let missing = DependencyCheck.missing(
            depends: "firmware (>= 17.0)",
            installed: ["firmware": "16.5"]
        )
        XCTAssertEqual(missing.count, 1)
    }

    func testAnyAlternativeSatisfiesTheGroup() {
        let installed = ["ellekit": "1.0"]
        XCTAssertTrue(DependencyCheck.satisfies(
            DependencyGroup(alternatives: [
                DependencyAlternative(name: "mobilesubstrate"),
                DependencyAlternative(name: "ellekit"),
            ]),
            installed: installed
        ))
    }

    func testPreDependsIsIncluded() {
        let control = """
        Package: com.example.a
        Version: 1.0
        Pre-Depends: firmware (>= 15.0)
        Depends: mobilesubstrate
        """
        let dependencies = DependencyCheck.dependencies(inControl: control)
        XCTAssertTrue(dependencies.contains("firmware (>= 15.0)"))
        XCTAssertTrue(dependencies.contains("mobilesubstrate"))
    }
}

final class BuildArtifactTests: XCTestCase {

    func testParsingATheosPackageName() {
        let artifact = ArtifactHistory.artifact(
            path: "/p/packages/com.example.mytweak_0.0.1_iphoneos-arm64.deb",
            size: 505_070,
            date: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(artifact?.packageIdentifier, "com.example.mytweak")
        XCTAssertEqual(artifact?.version, "0.0.1")
        XCTAssertEqual(artifact?.architecture, "iphoneos-arm64")
        XCTAssertEqual(artifact?.displayVersion, "0.0.1 · iphoneos-arm64")
        XCTAssertEqual(artifact?.fileName, "com.example.mytweak_0.0.1_iphoneos-arm64.deb")
    }

    func testSomethingThatIsNotAPackageIsIgnored() {
        XCTAssertNil(ArtifactHistory.artifact(path: "/p/notes.txt", size: 1, date: nil))
        XCTAssertNil(ArtifactHistory.artifact(path: "/p/weird.deb", size: 1, date: nil))
    }

    func testNewestFirstByDateNotVersion() {
        let artifacts = ArtifactHistory.list([
            (path: "/p/packages/a_0.0.9_iphoneos-arm64.deb", size: 1, date: Date(timeIntervalSince1970: 50)),
            (path: "/p/packages/a_0.0.2_iphoneos-arm64.deb", size: 1, date: Date(timeIntervalSince1970: 900)),
            (path: "/p/packages/a_0.0.3_iphoneos-arm64.deb", size: 1, date: nil),
        ])
        XCTAssertEqual(artifacts.map(\.version), ["0.0.2", "0.0.9", "0.0.3"])
        XCTAssertEqual(ArtifactHistory.latestVersion(artifacts), "0.0.2")
    }
}

final class ProjectSearchTests: XCTestCase {

    private let files = [
        ProjectFile(path: "Tweak.x", contents: "%hook SBIconView\n- (void)didMoveToWindow {\n    %orig;\n}\n%end\n"),
        ProjectFile(path: "Makefile", contents: "TWEAK_NAME = MyTweak\nMyTweak_FILES = Tweak.x\n"),
        ProjectFile(path: "README.md", contents: "Hooks SBIconView.\n"),
    ]

    func testMatchingEveryOccurrenceOnEveryLine() {
        let matches = ProjectSearch.matches(in: files, query: "SBIconView")
        XCTAssertEqual(matches.count, 2, "one in Tweak.x and one in README.md")
        let first = matches.first { $0.path == "Tweak.x" }
        XCTAssertEqual(first?.line, 1)
        XCTAssertEqual(first?.column, 7)
    }

    func testCaseSensitivity() {
        XCTAssertEqual(ProjectSearch.matches(in: files, query: "sbiconview").count, 2)
        XCTAssertTrue(ProjectSearch.matches(in: files, query: "sbiconview", caseSensitive: true).isEmpty)
        // "MyTweak" appears twice in the Makefile, and nowhere with different case.
        XCTAssertEqual(ProjectSearch.matches(in: files, query: "MyTweak", caseSensitive: true).count, 2)
        XCTAssertTrue(ProjectSearch.matches(in: files, query: "MYTWEAK", caseSensitive: true).isEmpty)
        XCTAssertEqual(ProjectSearch.matches(in: files, query: "mytweak").count, 2)
    }

    func testTwoOccurrencesOnOneLineAreTwoMatches() {
        let matches = ProjectSearch.matches(
            in: [ProjectFile(path: "a.txt", contents: "x x x\n")],
            query: "x"
        )
        XCTAssertEqual(matches.map(\.column), [1, 3, 5])
    }

    func testEmptyQueryAndLimit() {
        XCTAssertTrue(ProjectSearch.matches(in: files, query: "   ").isEmpty)
        XCTAssertEqual(ProjectSearch.matches(in: files, query: "e", limit: 2).count, 2)
    }

    func testGroupingPutsTheLogosSourceFirst() {
        let matches = ProjectSearch.matches(in: files, query: "e")
        let grouped = ProjectSearch.grouped(matches)
        XCTAssertEqual(grouped.first?.path, "Tweak.x", "the source matters more than the README")
        XCTAssertTrue(grouped.allSatisfy { !$0.matches.isEmpty })
        let total = grouped.reduce(0) { $0 + $1.matches.count }
        XCTAssertEqual(total, matches.count)
    }
}
