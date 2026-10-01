import XCTest
@testable import TheosStudioCore

final class PluginTests: XCTestCase {
    func testMinimalManifestDecodesWithDefaults() throws {
        let json = """
        {
          "id": "example.tools",
          "name": "Example",
          "actions": [
            {
              "id": "device",
              "title": "Device",
              "command": ["uname", "-a"]
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(StudioPluginManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, "1.0.0")
        XCTAssertEqual(manifest.scopes, [.global])
        XCTAssertEqual(manifest.actions.first?.systemImage, "terminal")
        XCTAssertFalse(manifest.actions.first?.requiresProject ?? true)
        XCTAssertTrue(manifest.snippets.isEmpty)
    }

    func testSnippetContributionDecodesAndGetsNamespaced() throws {
        let json = """
        {
          "id": "example.snippets",
          "name": "Snippets",
          "snippets": [
            {
              "id": "guard",
              "title": "Guard",
              "language": "code",
              "suggestedFileName": "Guard.x",
              "body": "NSLog(@\\\"hello\\\");"
            }
          ]
        }
        """
        let manifest = try JSONDecoder().decode(StudioPluginManifest.self, from: Data(json.utf8))
        let contribution = try XCTUnwrap(manifest.snippets.first)
        XCTAssertEqual(contribution.language, .code)
        XCTAssertEqual(contribution.snippet(pluginID: manifest.id).id, "plugin.example.snippets.guard")
        XCTAssertTrue(contribution.body.hasSuffix("\n"))
    }

    func testValidatorRejectsBadIDsAndPackageWithoutProject() {
        let manifest = StudioPluginManifest(
            id: "Bad ID",
            name: "Broken",
            actions: [
                PluginAction(
                    id: "Bad Action",
                    title: "Inspect",
                    command: ["dpkg-deb", "--info", "{{package}}"],
                    requiresPackage: true
                )
            ]
        )
        let issues = PluginManifestValidator.issues(in: manifest)
        XCTAssertGreaterThanOrEqual(issues.count, 3)
    }

    func testTokenExpansionUsesInvocationContext() {
        let context = PluginInvocationContext(
            projectPath: "/var/mobile/Projects/Demo",
            packagePath: "/var/mobile/Projects/Demo/packages/demo.deb",
            theosPath: "/var/jb/var/theos",
            homePath: "/var/mobile",
            pluginPath: "/var/mobile/Documents/Plugins/example"
        )
        let command = PluginTokenExpander.expand(
            ["tool", "{{project}}", "{{package}}", "{{theos}}", "{{home}}", "{{plugin}}"],
            context: context
        )
        XCTAssertEqual(command, [
            "tool",
            "/var/mobile/Projects/Demo",
            "/var/mobile/Projects/Demo/packages/demo.deb",
            "/var/jb/var/theos",
            "/var/mobile",
            "/var/mobile/Documents/Plugins/example",
        ])
    }

    func testMissingRequiredTokenFailsExpansion() {
        let context = PluginInvocationContext(homePath: "/var/mobile")
        XCTAssertNil(PluginTokenExpander.expand(["tool", "{{project}}"], context: context))
    }
}
