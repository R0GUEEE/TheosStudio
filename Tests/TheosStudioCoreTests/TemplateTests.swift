import XCTest
@testable import TheosStudioCore

final class TemplateTests: XCTestCase {

    private func request(
        _ kind: ProjectKind,
        scheme: PackagingScheme = .rootless,
        name: String = "MyTweak"
    ) -> TemplateRequest {
        TemplateRequest(
            name: name,
            kind: kind,
            scheme: scheme,
            packageIdentifier: "com.example.\(name.lowercased())",
            authorName: "Someone",
            authorEmail: "someone@example.com",
            summary: "A test project."
        )
    }

    private func contents(_ files: [TemplateFile], _ path: String) -> String? {
        files.first { $0.path == path }?.contents
    }

    func testEveryKindProducesTheCoreFiles() {
        for kind in ProjectKind.allCases {
            let files = ProjectTemplate.files(for: request(kind))
            for path in ["Makefile", "control", "README.md"] {
                XCTAssertNotNil(contents(files, path), "\(kind.rawValue) is missing \(path)")
            }
            XCTAssertEqual(Set(files.map(\.path)).count, files.count, "\(kind.rawValue) has duplicate paths")
        }
    }

    func testRootlessDeclaresTheSchemeAndRootfulDoesNot() {
        let rootless = ProjectTemplate.makefile(for: request(.tweak, scheme: .rootless))
        XCTAssertTrue(rootless.contains("export THEOS_PACKAGE_SCHEME = rootless"))

        let roothide = ProjectTemplate.makefile(for: request(.tweak, scheme: .roothide))
        XCTAssertTrue(roothide.contains("export THEOS_PACKAGE_SCHEME = roothide"))
        XCTAssertTrue(roothide.contains("iphoneos-arm64e"))

        let rootful = ProjectTemplate.makefile(for: request(.tweak, scheme: .rootful))
        XCTAssertFalse(rootful.contains("THEOS_PACKAGE_SCHEME"), rootful)
        XCTAssertTrue(rootful.contains("Rootful"))
    }

    func testMakefileCarriesTargetArchitecturesAndRules() {
        let makefile = ProjectTemplate.makefile(for: request(.tweak))
        XCTAssertTrue(makefile.contains("TARGET := iphone:clang:latest:15.0"), makefile)
        XCTAssertTrue(makefile.contains("ARCHS = arm64 arm64e"))
        XCTAssertTrue(makefile.contains("TWEAK_NAME = MyTweak"))
        XCTAssertTrue(makefile.contains("MyTweak_FILES = Tweak.x"))
        XCTAssertTrue(makefile.contains("include $(THEOS)/makefiles/common.mk"))
        XCTAssertTrue(makefile.contains("include $(THEOS_MAKE_PATH)/tweak.mk"))
        XCTAssertTrue(makefile.contains("INSTALL_TARGET_PROCESSES = SpringBoard"))
    }

    func testControlFileMatchesTheRequest() {
        let request = request(.tweak)
        let control = ControlFile.parse(ProjectTemplate.files(for: request).first { $0.path == "control" }!.contents)
        XCTAssertEqual(control.packageIdentifier, "com.example.mytweak")
        XCTAssertEqual(control.name, "MyTweak")
        XCTAssertEqual(control.architecture, "iphoneos-arm64")
        XCTAssertEqual(control["Maintainer"], "Someone <someone@example.com>")
        XCTAssertEqual(control["Depends"], "mobilesubstrate")
        XCTAssertEqual(control["Section"], "Tweaks")
    }

    func testTweakGetsAFilterPlistNamedAfterTheProject() {
        let files = ProjectTemplate.files(for: request(.tweak))
        let filter = contents(files, "MyTweak.plist")
        XCTAssertNotNil(filter)
        XCTAssertTrue(filter!.contains("com.apple.springboard"))
        XCTAssertFalse(filter!.contains("//"), "an old-style plist read at process start should not carry comments")
    }

    func testApplicationDoesNotGetAFilterPlist() {
        let files = ProjectTemplate.files(for: request(.application))
        XCTAssertNil(contents(files, "MyApplication.plist"))
        XCTAssertNotNil(contents(files, "main.m"))
        XCTAssertNotNil(contents(files, "MyTweakAppDelegate.m"))
    }

    func testTweakWithPreferencesWiresTheSubproject() {
        let files = ProjectTemplate.files(for: request(.tweakWithPreferences, name: "MyTweak"))
        XCTAssertNotNil(contents(files, "prefs/Makefile"))
        XCTAssertNotNil(contents(files, "prefs/MyTweakPrefsRootListController.m"))
        XCTAssertNotNil(contents(files, "prefs/Resources/Root.plist"))
        XCTAssertNotNil(contents(files, "prefs/Resources/Info.plist"))
        XCTAssertNotNil(contents(files, "layout/Library/PreferenceLoader/Preferences/MyTweak.plist"))

        let makefile = contents(files, "Makefile")!
        XCTAssertTrue(makefile.contains("SUBPROJECTS += prefs"))
        XCTAssertTrue(makefile.contains("aggregate.mk"))
        XCTAssertTrue(contents(files, "prefs/Makefile")!.contains("BUNDLE_NAME = MyTweakPrefs"))
    }

    func testStandaloneBundleUsesTheTopLevelMakefile() {
        let files = ProjectTemplate.files(for: request(.preferenceBundle, name: "MyPrefs"))
        XCTAssertNil(contents(files, "prefs/Makefile"))
        let makefile = contents(files, "Makefile")!
        XCTAssertTrue(makefile.contains("BUNDLE_NAME = MyPrefs"))
        XCTAssertTrue(makefile.contains("MyPrefs_INSTALL_PATH = /Library/PreferenceBundles"))
        XCTAssertTrue(makefile.contains("bundle.mk"))
        XCTAssertNotNil(contents(files, "MyPrefsRootListController.m"))
    }

    func testToolNameIsLowercasedEverywhere() {
        let files = ProjectTemplate.files(for: request(.tool, name: "MyTool"))
        let makefile = contents(files, "Makefile")!
        XCTAssertTrue(makefile.contains("TOOL_NAME = mytool"))
        XCTAssertTrue(makefile.contains("mytool_INSTALL_PATH = /usr/local/bin"))
        XCTAssertTrue(makefile.contains("tool.mk"))
        XCTAssertTrue(contents(files, "main.m")!.contains("Hello from mytool"))
    }

    func testApplicationInfoPlistIsComplete() {
        let files = ProjectTemplate.files(for: request(.application, name: "MyApp"))
        let plist = contents(files, "Resources/Info.plist")!
        XCTAssertTrue(plist.contains("<string>com.example.myapp</string>"))
        XCTAssertTrue(plist.contains("<key>MinimumOSVersion</key>\n\t<string>15.0</string>"))
        XCTAssertTrue(plist.contains("<key>LSRequiresIPhoneOS</key>"))
    }

    func testGeneratedTweakSourceIsHookedButHarmless() {
        let source = ProjectTemplate.tweakSource(for: request(.tweak))
        XCTAssertTrue(source.contains("%hook SBIconView"))
        XCTAssertTrue(source.contains("%orig;"))
        XCTAssertTrue(source.contains("%ctor"))
        XCTAssertTrue(source.contains("NSLog(@\"[MyTweak]"))
    }

    func testReadmeNamesTheSchemeAndInstallRoot() {
        let files = ProjectTemplate.files(for: request(.tweak, scheme: .rootless))
        let readme = contents(files, "README.md")!
        XCTAssertTrue(readme.contains("/var/jb"))
        XCTAssertTrue(readme.contains("iphoneos-arm64"))
        XCTAssertTrue(readme.contains("make package"))
    }

    /// The generated Makefile has to be readable by the app itself, because that
    /// is how a project opened from disk is labelled.
    func testGeneratedProjectParsesBackIntoTheSameManifest() {
        for kind in ProjectKind.allCases {
            for scheme in PackagingScheme.allCases {
                let request = request(kind, scheme: scheme, name: "MyTweak")
                let files = ProjectTemplate.files(for: request)
                let makefile = files.first { $0.path == "Makefile" }!.contents
                let control = files.first { $0.path == "control" }!.contents
                let manifest = ProjectManifest.parse(makefile: makefile, control: control)
                // The tool template lowercases its name, because it becomes an
                // executable; every other kind keeps the project name as written.
                XCTAssertEqual(manifest.name?.lowercased(), "mytweak", "\(kind) / \(scheme)")
                XCTAssertEqual(manifest.packageIdentifier, request.packageIdentifier)
                XCTAssertEqual(manifest.version, "0.0.1")
                if let expected = scheme.theosVariableValue {
                    XCTAssertEqual(manifest.declaredScheme?.rawValue, expected, "\(kind) / \(scheme)")
                } else {
                    XCTAssertNil(manifest.declaredScheme, "\(kind) / \(scheme)")
                }
            }
        }
    }

    func testManifestDistinguishesApplicationsAndBundles() {
        let app = ProjectManifest.parse(
            makefile: ProjectTemplate.makefile(for: request(.application, name: "MyApp")),
            control: ""
        )
        XCTAssertEqual(app.kind, .application)
        XCTAssertEqual(app.name, "MyApp")

        let bundle = ProjectManifest.parse(
            makefile: ProjectTemplate.makefile(for: request(.preferenceBundle, name: "MyPrefs")),
            control: ""
        )
        XCTAssertEqual(bundle.kind, .preferenceBundle)

        let prefs = ProjectManifest.parse(
            makefile: ProjectTemplate.makefile(for: request(.tweakWithPreferences, name: "MyTweak")),
            control: ""
        )
        XCTAssertEqual(prefs.kind, .tweakWithPreferences)

        let tool = ProjectManifest.parse(
            makefile: ProjectTemplate.makefile(for: request(.tool, name: "MyTool")),
            control: ""
        )
        XCTAssertEqual(tool.kind, .tool)
        XCTAssertEqual(tool.name, "mytool")
    }

    func testManifestReadsRealWorldMakefileShapes() {
        let makefile = """
        export THEOS_PACKAGE_SCHEME = rootless
        TARGET := iphone:clang:latest:14.0
        ARCHS = arm64
        include $(THEOS)/makefiles/common.mk

        TWEAK_NAME = Foo
        Foo_FILES = Tweak.xm
        Foo_CFLAGS = -fobjc-arc

        include $(THEOS_MAKE_PATH)/tweak.mk
        """
        let manifest = ProjectManifest.parse(makefile: makefile, control: "Package: com.example.foo\nVersion: 2.1\n")
        XCTAssertEqual(manifest.name, "Foo")
        XCTAssertEqual(manifest.kind, .tweak)
        XCTAssertEqual(manifest.declaredScheme, .rootless)
        XCTAssertEqual(manifest.version, "2.1")
        XCTAssertEqual(manifest.packageIdentifier, "com.example.foo")
    }

    func testAssignmentParsingIgnoresCommentsAndOtherNames() {
        XCTAssertEqual(ProjectManifest.assignmentValue(in: "TWEAK_NAME = Foo", name: "TWEAK_NAME"), "Foo")
        XCTAssertEqual(ProjectManifest.assignmentValue(in: "export THEOS_PACKAGE_SCHEME = rootless  # modern", name: "THEOS_PACKAGE_SCHEME"), "rootless")
        XCTAssertNil(ProjectManifest.assignmentValue(in: "TWEAK_NAME = Foo", name: "TOOL_NAME"))
        XCTAssertNil(ProjectManifest.assignmentValue(in: "include $(THEOS)/makefiles/common.mk", name: "TWEAK_NAME"))
        XCTAssertEqual(ProjectManifest.assignmentValue(in: "ARCHS += arm64", name: "ARCHS"), "arm64")
    }
}
