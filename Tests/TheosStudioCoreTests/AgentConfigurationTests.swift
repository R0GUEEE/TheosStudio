import XCTest
@testable import TheosStudioCore

final class AgentApprovalPolicyTests: XCTestCase {

    func testEachPolicyApprovesWhatItSaysItDoes() {
        let accesses: [AgentAccess] = [.read, .write, .build, .install]

        XCTAssertFalse(AgentApprovalPolicy.askForChanges.needsApproval(for: .read))
        XCTAssertTrue(AgentApprovalPolicy.askForChanges.needsApproval(for: .write))
        XCTAssertTrue(AgentApprovalPolicy.askForChanges.needsApproval(for: .build))
        XCTAssertTrue(AgentApprovalPolicy.askForChanges.needsApproval(for: .install))

        XCTAssertFalse(AgentApprovalPolicy.askForBuildsAndInstalls.needsApproval(for: .write))
        XCTAssertTrue(AgentApprovalPolicy.askForBuildsAndInstalls.needsApproval(for: .build))
        XCTAssertTrue(AgentApprovalPolicy.askForBuildsAndInstalls.needsApproval(for: .install))

        XCTAssertFalse(AgentApprovalPolicy.askForInstallsOnly.needsApproval(for: .write))
        XCTAssertFalse(AgentApprovalPolicy.askForInstallsOnly.needsApproval(for: .build))
        XCTAssertTrue(AgentApprovalPolicy.askForInstallsOnly.needsApproval(for: .install))

        for access in accesses {
            XCTAssertFalse(AgentApprovalPolicy.fullAuto.needsApproval(for: access))
        }
    }

    func testEveryPolicyIsDescribedEnoughToChooseIt() {
        for policy in AgentApprovalPolicy.allCases {
            XCTAssertFalse(policy.displayName.isEmpty)
            XCTAssertFalse(policy.summary.isEmpty)
        }
    }
}

final class AgentPolicyConfigurationTests: XCTestCase {

    private func decide(
        _ action: AgentAction,
        approvals: AgentApprovalPolicy = .askForChanges,
        tools: Set<String>? = nil
    ) -> AgentDecision {
        AgentPolicy.decide(action, approvals: approvals, enabledTools: tools, privilegesCanEscalate: true)
    }

    func testTheDefaultAsksForAnythingThatChangesSomething() {
        XCTAssertEqual(decide(.readFile(path: "Tweak.x")), .allowed)
        XCTAssertEqual(decide(.writeFile(path: "Tweak.x", contents: "x")), .needsApproval(reason: "Write Tweak.x"))
        XCTAssertTrue(decide(.build(clean: false, final: true)).isApproval)
        XCTAssertTrue(decide(.install).isApproval)
    }

    func testALooserPolicyLetsEditsThroughButKeepsTheReasonWording() {
        XCTAssertEqual(
            decide(.writeFile(path: "Tweak.x", contents: "x"), approvals: .askForBuildsAndInstalls),
            .allowed
        )
        XCTAssertTrue(decide(.build(clean: false, final: true), approvals: .askForBuildsAndInstalls).isApproval)
        XCTAssertEqual(decide(.install, approvals: .askForInstallsOnly), .needsApproval(reason: "Install the built package and respring"))
    }

    /// The important one: a setting loosens the asking, never the rules.
    func testNoPolicyCanLoosenTheSandbox() {
        for policy in AgentApprovalPolicy.allCases {
            guard case .refused(let reason) = decide(.writeFile(path: "../../etc/passwd", contents: "x"), approvals: policy) else {
                return XCTFail("\(policy) allowed a path outside the project")
            }
            XCTAssertTrue(reason.contains("inside the project"), reason)

            guard case .refused = decide(.writeFile(path: "packages/x.deb", contents: "x"), approvals: policy) else {
                return XCTFail("\(policy) allowed a write into build output")
            }

            guard case .refused = decide(.readFile(path: "/var/jb/etc/passwd"), approvals: policy) else {
                return XCTFail("\(policy) allowed a read outside the project")
            }
        }
    }

    func testTurningAToolOffRefusesItByName() {
        let tools: Set<String> = ["list_files", "read_file", "write_file"]
        XCTAssertEqual(decide(.readFile(path: "Tweak.x"), tools: tools), .allowed)

        guard case .refused(let reason) = decide(.install, tools: tools) else {
            return XCTFail("expected the disabled tool to be refused")
        }
        XCTAssertTrue(reason.contains("install"), reason)
        XCTAssertTrue(reason.contains("turned off"), reason)

        // A disabled tool is refused whatever the approval policy says.
        guard case .refused = decide(.install, approvals: .fullAuto, tools: tools) else {
            return XCTFail("full auto should not re-enable a disabled tool")
        }
    }

    func testNoToolListMeansEveryToolIsAvailable() {
        XCTAssertTrue(decide(.install, tools: nil).isApproval)
        XCTAssertTrue(decide(.install, tools: AgentToolCatalog.names).isApproval)
    }

    func testAccessClassification() {
        XCTAssertEqual(AgentPolicy.access(for: .listFiles), .read)
        XCTAssertEqual(AgentPolicy.access(for: .readCrashes(limit: 3)), .read)
        XCTAssertEqual(AgentPolicy.access(for: .searchHeaders(query: "x")), .read)
        XCTAssertEqual(AgentPolicy.access(for: .gitDiff(path: nil)), .read)
        XCTAssertEqual(AgentPolicy.access(for: .writeFile(path: "a", contents: "b")), .write)
        XCTAssertEqual(AgentPolicy.access(for: .updateControl(key: "Version", value: "1")), .write)
        XCTAssertEqual(AgentPolicy.access(for: .build(clean: false, final: false)), .build)
        XCTAssertEqual(AgentPolicy.access(for: .install), .install)
        // An unparseable action is treated as the cautious answer.
        XCTAssertEqual(AgentPolicy.access(for: .unknown(name: "x", reason: "y")), .write)
    }
}

extension AgentDecision {
    var isApproval: Bool {
        if case .needsApproval = self { return true }
        return false
    }
}

final class AgentPreferenceTests: XCTestCase {

    private func snapshot(briefing: String? = nil) -> AgentProjectSnapshot {
        AgentProjectSnapshot(
            name: "MyTweak",
            path: "/var/mobile/Documents/Projects/MyTweak",
            kind: .tweak,
            scheme: .rootless,
            packageIdentifier: "com.example.mytweak",
            files: [ProjectFile(path: "Tweak.x", contents: "%hook Foo\n%end\n")],
            briefing: briefing
        )
    }

    func testPreferencesBecomePromptLinesInAStableOrder() {
        let lines = AgentPreference.promptLines(for: [.addLogging, .minimalDiffs])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("smallest possible change"), lines[0])
        XCTAssertTrue(lines[1].contains("NSLog"), lines[1])
        XCTAssertTrue(AgentPreference.promptLines(for: []).isEmpty)
    }

    func testTheSystemPromptCarriesTheChosenPreferences() {
        let plain = AgentContext.systemPrompt(snapshot())
        XCTAssertFalse(plain.contains("Standing instructions"))

        let instructed = AgentContext.systemPrompt(snapshot(), preferences: [.confirmPrivateAPIs, .sayHowToVerify])
        XCTAssertTrue(instructed.contains("# Standing instructions"))
        XCTAssertTrue(instructed.contains("search_headers"))
        XCTAssertTrue(instructed.contains("take effect"))
    }

    /// The briefing is the user's own words about their project, and a project
    /// without one must not carry an empty heading.
    func testTheProjectBriefingIsIncludedWhenItExists() {
        let without = AgentContext.systemPrompt(snapshot())
        XCTAssertFalse(without.contains("briefing for this project"))
        XCTAssertFalse(without.contains("__BRIEFING__"))

        let with = AgentContext.systemPrompt(snapshot(briefing: "Targets SpringBoard on iOS 16 only. Keep the filter narrow."))
        XCTAssertTrue(with.contains("# The user's briefing for this project"))
        XCTAssertTrue(with.contains("Targets SpringBoard on iOS 16 only."))
        XCTAssertFalse(with.contains("__BRIEFING__"))
        // The rest of the prompt survives the substitution.
        XCTAssertTrue(with.contains("# How to work"))
        XCTAssertTrue(with.contains("TWEAK_NAME"))
    }

    func testABlankBriefingIsIgnored() {
        let prompt = AgentContext.systemPrompt(snapshot(briefing: "   \n  "))
        XCTAssertFalse(prompt.contains("briefing for this project"))
    }

    func testNamesOnlyContextSendsTheListNotTheContents() {
        let full = AgentContext.contextMessage(snapshot())
        XCTAssertTrue(full.contains("%hook Foo"))

        let names = AgentContext.contextMessage(snapshot(), mode: .namesOnly)
        XCTAssertFalse(names.contains("%hook Foo"))
        XCTAssertTrue(names.contains("- Tweak.x"))
        XCTAssertTrue(names.contains("Use read_file"))
    }

    func testMaxTokensIsOnlySentWhenSet() throws {
        let without = AgentRequest(model: "m", messages: [.user("hi")])
        let data = try JSONEncoder().encode(without)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["max_tokens"])

        let with = AgentRequest(model: "m", messages: [.user("hi")], maxTokens: 4096)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(with)) as? [String: Any])
        XCTAssertEqual(object["max_tokens"] as? Int, 4096)

        // Zero means "let the provider decide", not "send zero".
        let zero = AgentRequest(model: "m", messages: [.user("hi")], maxTokens: 0)
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(zero)) as? [String: Any])
        XCTAssertNil(object["max_tokens"])
    }
}
