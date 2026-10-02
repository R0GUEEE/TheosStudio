import XCTest
@testable import TheosStudioCore

final class DependencyAutomationTests: XCTestCase {
    func testPlansOnlyMissingDependencies() {
        let control = """
        Package: com.example.test
        Name: Test
        Version: 1.0
        Architecture: iphoneos-arm64
        Depends: firmware (>= 15.0), ellekit, preferenceloader | mobilesubstrate
        Description: Test
        """
        let plan = DependencyAutomation.plan(
            control: control,
            installed: ["firmware": "16.7", "ellekit": "1.1"]
        )
        XCTAssertEqual(plan.selectedPackages, ["preferenceloader"])
        XCTAssertEqual(plan.missing.count, 1)
    }

    func testProviderSatisfiesVirtualDependency() {
        let plan = DependencyAutomation.plan(
            control: "Depends: mobilesubstrate\n",
            installed: ["ellekit": "1.1"],
            provides: ["mobilesubstrate": ["ellekit"]]
        )
        XCTAssertTrue(plan.isSatisfied)
        XCTAssertTrue(plan.selectedPackages.isEmpty)
    }

    func testParsesDpkgQueryOutput() {
        let parsed = DependencyAutomation.parseInstalled(
            "ellekit:iphoneos-arm64\t1.1.2\tmobilesubstrate, org.coolstar.libhooker\nfirmware\t16.7\t\n"
        )
        XCTAssertEqual(parsed.versions["ellekit"], "1.1.2")
        XCTAssertEqual(parsed.versions["firmware"], "16.7")
        XCTAssertTrue(parsed.provides["mobilesubstrate"]?.contains("ellekit") == true)
    }

    func testAptArgumentsAreStructuredNotShellJoined() {
        let plan = DependencyInstallPlan(
            missing: [DependencyGroup(alternatives: [DependencyAlternative(name: "ellekit")])],
            selectedPackages: ["ellekit"]
        )
        XCTAssertEqual(plan.aptArguments(updateFirst: true), [
            ["apt-get", "update"],
            ["apt-get", "install", "-y", "ellekit"],
        ])
    }
}
