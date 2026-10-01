import XCTest
@testable import TheosStudioCore

final class AgentActionTests: XCTestCase {

    private func call(_ name: String, _ json: String) -> AgentToolCall {
        AgentToolCall(id: "call_1", name: name, arguments: json)
    }

    func testEveryCatalogToolIsUnderstoodByTheParser() {
        // A tool the catalog offers but the parser does not know would fail at
        // runtime with a confusing "no tool with that name" — so the names are
        // checked against each other, not just against the code.
        let expected: Set<String> = [
            "list_files", "read_file", "write_file", "replace_in_file",
            "update_control", "build", "install", "read_crashes", "git_status",
            "git_diff", "search_headers", "finish",
        ]
        XCTAssertEqual(AgentToolCatalog.names, expected)

        for name in AgentToolCatalog.names {
            let arguments: String
            switch name {
            case "read_file": arguments = #"{"path":"Tweak.x"}"#
            case "write_file": arguments = #"{"path":"a.x","contents":"x"}"#
            case "replace_in_file": arguments = #"{"path":"a.x","find":"a","replace":"b"}"#
            case "update_control": arguments = #"{"key":"Version","value":"1.0"}"#
            case "finish": arguments = #"{"summary":"done"}"#
            case "search_headers": arguments = #"{"query":"SBIconView"}"#
            default: arguments = "{}"
            }
            let action = AgentActionParser.parse(call(name, arguments))
            if case .unknown(_, let reason) = action {
                XCTFail("\(name) parsed as unknown: \(reason)")
            }
        }
    }

    func testParsingEachToolCall() {
        XCTAssertEqual(AgentActionParser.parse(call("list_files", "{}")), .listFiles)
        XCTAssertEqual(
            AgentActionParser.parse(call("read_file", #"{"path":"prefs/Makefile"}"#)),
            .readFile(path: "prefs/Makefile")
        )
        XCTAssertEqual(
            AgentActionParser.parse(call("write_file", #"{"path":"Tweak.x","contents":"hello"}"#)),
            .writeFile(path: "Tweak.x", contents: "hello")
        )
        XCTAssertEqual(
            AgentActionParser.parse(call("replace_in_file", #"{"path":"Tweak.x","find":"a","replace":"b"}"#)),
            .replaceInFile(path: "Tweak.x", find: "a", replace: "b")
        )
    }

    func testUpdateControlWithoutAValueMeansRemove() {
        XCTAssertEqual(
            AgentActionParser.parse(call("update_control", #"{"key":"Version","value":"2.0"}"#)),
            .updateControl(key: "Version", value: "2.0")
        )
        XCTAssertEqual(
            AgentActionParser.parse(call("update_control", #"{"key":"Depiction"}"#)),
            .updateControl(key: "Depiction", value: nil)
        )
    }

    func testCrashAndGitTools() {
        XCTAssertEqual(AgentActionParser.parse(call("read_crashes", "{}")), .readCrashes(limit: 5))
        XCTAssertEqual(AgentActionParser.parse(call("read_crashes", #"{"limit":10}"#)), .readCrashes(limit: 10))
        // Clamped: a model asking for a thousand logs should not be obeyed.
        XCTAssertEqual(AgentActionParser.parse(call("read_crashes", #"{"limit":1000}"#)), .readCrashes(limit: 25))
        XCTAssertEqual(AgentActionParser.parse(call("git_status", "{}")), .gitStatus)
        XCTAssertEqual(AgentActionParser.parse(call("git_diff", "{}")), .gitDiff(path: nil))
        XCTAssertEqual(AgentActionParser.parse(call("git_diff", #"{"path":"Tweak.x"}"#)), .gitDiff(path: "Tweak.x"))

        XCTAssertEqual(
            AgentActionParser.parse(call("search_headers", #"{"query":"SBIconView"}"#)),
            .searchHeaders(query: "SBIconView")
        )
        let missingQuery = AgentActionParser.parse(call("search_headers", "{}"))
        guard case .unknown(_, let reason) = missingQuery else {
            return XCTFail("expected unknown, got \(missingQuery)")
        }
        XCTAssertTrue(reason.contains("query"))
    }

    func testBuildDefaultsToAFinalPackage() {
        XCTAssertEqual(AgentActionParser.parse(call("build", "{}")), .build(clean: false, final: true))
        XCTAssertEqual(
            AgentActionParser.parse(call("build", #"{"clean":true,"final":false}"#)),
            .build(clean: true, final: false)
        )
    }

    /// A malformed call has to come back as something the app can hand to the
    /// model as a tool result, or the turn dies with the model none the wiser.
    func testBadCallsBecomeUnknownWithAReason() {
        let missingPath = AgentActionParser.parse(call("read_file", "{}"))
        guard case .unknown(let name, let reason) = missingPath else {
            return XCTFail("expected unknown, got \(missingPath)")
        }
        XCTAssertEqual(name, "read_file")
        XCTAssertTrue(reason.contains("path"))

        let badJSON = AgentActionParser.parse(call("read_file", "not json"))
        guard case .unknown(_, let jsonReason) = badJSON else {
            return XCTFail("expected unknown, got \(badJSON)")
        }
        XCTAssertTrue(jsonReason.contains("JSON object"))

        let emptyFind = AgentActionParser.parse(call("replace_in_file", #"{"path":"a.x","find":"","replace":"b"}"#))
        guard case .unknown(_, let findReason) = emptyFind else {
            return XCTFail("expected unknown, got \(emptyFind)")
        }
        XCTAssertTrue(findReason.contains("find"))

        let noSuchTool = AgentActionParser.parse(call("delete_everything", "{}"))
        guard case .unknown(_, let toolReason) = noSuchTool else {
            return XCTFail("expected unknown, got \(noSuchTool)")
        }
        XCTAssertTrue(toolReason.contains("no tool"))
    }

    func testSummariesSayWhatWillHappen() {
        XCTAssertEqual(AgentAction.readFile(path: "Tweak.x").summary, "Read Tweak.x")
        XCTAssertEqual(AgentAction.updateControl(key: "Depends", value: nil).summary, "Remove Depends from control")
        XCTAssertTrue(AgentAction.build(clean: true, final: true).summary.contains("clean"))
        XCTAssertTrue(AgentAction.install.summary.contains("Install"))
    }
}

final class AgentPolicyTests: XCTestCase {

    private func decide(_ action: AgentAction, canEscalate: Bool = true) -> AgentDecision {
        AgentPolicy.decide(action, privilegesCanEscalate: canEscalate)
    }

    func testPathsStayInsideTheProject() {
        XCTAssertEqual(AgentPolicy.relativePath("Tweak.x"), "Tweak.x")
        XCTAssertEqual(AgentPolicy.relativePath("./prefs/Makefile"), "prefs/Makefile")
        XCTAssertEqual(AgentPolicy.relativePath("prefs//Resources/Root.plist"), "prefs/Resources/Root.plist")
        XCTAssertNil(AgentPolicy.relativePath(""))
        XCTAssertNil(AgentPolicy.relativePath("/etc/passwd"))
        XCTAssertNil(AgentPolicy.relativePath("~/theos/Makefile"))
        XCTAssertNil(AgentPolicy.relativePath("../other-project/Tweak.x"))
        XCTAssertNil(AgentPolicy.relativePath("prefs/../../escape"))
    }

    func testReadingInsideTheProjectNeedsNoApproval() {
        XCTAssertEqual(decide(.readFile(path: "Tweak.x")), .allowed)
        XCTAssertEqual(decide(.listFiles), .allowed)
        XCTAssertEqual(decide(.finish(summary: "done")), .allowed)
    }

    func testReadingOutsideTheProjectIsRefusedWithAReason() {
        guard case .refused(let reason) = decide(.readFile(path: "/var/jb/etc/passwd")) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("inside the project"))
        guard case .refused(let traversal) = decide(.writeFile(path: "../evil.x", contents: "x")) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(traversal.contains("inside the project"))
    }

    func testWritingNeedsApprovalAndSaysWhatItWillDo() {
        XCTAssertEqual(
            decide(.writeFile(path: "Tweak.x", contents: "x")),
            .needsApproval(reason: "Write Tweak.x")
        )
        XCTAssertEqual(
            decide(.replaceInFile(path: "Tweak.x", find: "a", replace: "b")),
            .needsApproval(reason: "Edit Tweak.x")
        )
        XCTAssertEqual(
            decide(.updateControl(key: "Version", value: "2.0")),
            .needsApproval(reason: "Set Version in control")
        )
        XCTAssertTrue(decide(.build(clean: false, final: true)).requiresApproval)
    }

    func testBuildOutputIsNotWritable() {
        guard case .refused(let reason) = decide(.writeFile(path: "packages/com.example_1.0_iphoneos-arm64.deb", contents: "x")) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("build output"))
        guard case .refused = decide(.readFile(path: ".theos/obj/Tweak.x.o")) else {
            return XCTFail("expected a refusal")
        }
    }

    func testAnOversizedWriteIsRefused() {
        let huge = String(repeating: "a", count: AgentPolicy.maxFileBytes + 1)
        guard case .refused(let reason) = decide(.writeFile(path: "Tweak.x", contents: huge)) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertTrue(reason.contains("larger than"))
    }

    func testInstallApprovalSaysWhenItWillFail() {
        let withRoot = decide(.install, canEscalate: true)
        XCTAssertEqual(withRoot, .needsApproval(reason: "Install the built package and respring"))
        guard case .needsApproval(let note) = decide(.install, canEscalate: false) else {
            return XCTFail("expected approval")
        }
        XCTAssertTrue(note.contains("cannot become root"))
    }

    func testReadingCrashesAndGitNeedsNoApprovalButStaysInTheProject() {
        XCTAssertEqual(decide(.readCrashes(limit: 5)), .allowed)
        XCTAssertEqual(decide(.searchHeaders(query: "SBIconView")), .allowed)
        XCTAssertEqual(decide(.gitStatus), .allowed)
        XCTAssertEqual(decide(.gitDiff(path: "Tweak.x")), .allowed)
        XCTAssertEqual(decide(.gitDiff(path: nil)), .allowed)
        guard case .refused = decide(.gitDiff(path: "/etc/passwd")) else {
            return XCTFail("expected a refusal for a path outside the project")
        }
    }

    func testUnknownActionsAreRefusedWithTheParsersReason() {
        guard case .refused(let reason) = decide(.unknown(name: "read_file", reason: "read_file needs a 'path'")) else {
            return XCTFail("expected a refusal")
        }
        XCTAssertEqual(reason, "read_file needs a 'path'")
    }
}

extension AgentDecision {
    /// Named differently from the case on purpose: an enum case and a property of
    /// the same name in an extension is the kind of ambiguity that costs a CI run.
    var requiresApproval: Bool {
        if case .needsApproval = self { return true }
        return false
    }
}

final class UnifiedDiffTests: XCTestCase {

    func testIdenticalTextIsAllContext() {
        let lines = UnifiedDiff.lines(from: "a\nb\nc", to: "a\nb\nc")
        XCTAssertEqual(lines.map(\.kind), [.context, .context, .context])
        XCTAssertTrue(UnifiedDiff.hunks(from: "a\nb\nc", to: "a\nb\nc").isEmpty)
    }

    func testChangedLineReadsAsOneRemovalAndOneAddition() {
        let lines = UnifiedDiff.lines(from: "a\nb\nc", to: "a\nB\nc")
        XCTAssertEqual(lines.map(\.kind), [.context, .removed, .added, .context])
        XCTAssertEqual(lines[1].text, "b")
        XCTAssertEqual(lines[2].text, "B")
        let stats = UnifiedDiff.stats(from: "a\nb\nc", to: "a\nB\nc")
        XCTAssertEqual(stats.added, 1)
        XCTAssertEqual(stats.removed, 1)
    }

    func testInsertionAndDeletion() {
        let inserted = UnifiedDiff.lines(from: "a\nb", to: "a\nx\nb")
        XCTAssertEqual(inserted.map(\.kind), [.context, .added, .context])

        let deleted = UnifiedDiff.lines(from: "a\nx\nb", to: "a\nb")
        XCTAssertEqual(deleted.map(\.kind), [.context, .removed, .context])
    }

    /// Two changes far enough apart to be separate hunks. The second hunk's line
    /// numbers are the part that is easy to get wrong, and it was wrong once:
    /// context lines the body dropped were not counted, so the second hunk
    /// claimed to start three lines too early.
    func testSeparateHunksAreNumberedFromTheirOwnPosition() {
        let old = (1...20).map { "l\($0)" }.joined(separator: "\n")
        var newLines = (1...20).map { "l\($0)" }
        newLines[2] = "X"
        newLines[16] = "Y"
        let new = newLines.joined(separator: "\n")

        let hunks = UnifiedDiff.hunks(from: old, to: new)
        XCTAssertEqual(hunks.count, 2)
        XCTAssertEqual(hunks[0].oldStart, 1)
        XCTAssertEqual(hunks[0].newStart, 1)
        XCTAssertEqual(hunks[0].lines.map(\.text), ["l1", "l2", "l3", "X", "l4", "l5", "l6"])
        XCTAssertEqual(hunks[0].lines.map(\.kind), [.context, .context, .removed, .added, .context, .context, .context])
        XCTAssertEqual(hunks[0].header, "@@ -1,6 +1,6 @@")

        XCTAssertEqual(hunks[1].oldStart, 14)
        XCTAssertEqual(hunks[1].newStart, 14)
        XCTAssertEqual(hunks[1].lines.map(\.text), ["l14", "l15", "l16", "l17", "Y", "l18", "l19", "l20"])
        XCTAssertEqual(hunks[1].header, "@@ -14,7 +14,7 @@")
    }

    func testRenderIsAPatch() {
        let patch = UnifiedDiff.render(from: "a\nb\nc", to: "a\nB\nc", path: "Tweak.x")
        XCTAssertTrue(patch.hasPrefix("--- a/Tweak.x\n+++ b/Tweak.x\n@@"))
        XCTAssertTrue(patch.contains("-b\n"))
        XCTAssertTrue(patch.contains("+B\n"))
        XCTAssertEqual(UnifiedDiff.render(from: "a", to: "a", path: "Tweak.x"), "Tweak.x: no changes")
    }
}

final class AgentContextTests: XCTestCase {

    private func snapshot(files: [ProjectFile] = [], build: String? = nil) -> AgentProjectSnapshot {
        AgentProjectSnapshot(
            name: "MyTweak",
            path: "/var/mobile/Documents/Projects/MyTweak",
            kind: .tweak,
            scheme: .rootless,
            packageIdentifier: "com.example.mytweak",
            version: "0.0.1",
            files: files,
            buildSummary: build,
            toolchainSummary: "Theos at /var/mobile/Documents/Theos, SDKs: iPhoneOS16.5.sdk, privileges: root"
        )
    }

    func testRelevancePutsTheLogosSourceFirst() {
        XCTAssertLessThan(AgentContext.relevance(of: "Tweak.x"), AgentContext.relevance(of: "Makefile"))
        XCTAssertLessThan(AgentContext.relevance(of: "Makefile"), AgentContext.relevance(of: "README.md"))
        XCTAssertLessThan(AgentContext.relevance(of: "prefs/Resources/Root.plist"), AgentContext.relevance(of: "logo.png"))
        XCTAssertGreaterThan(AgentContext.relevance(of: "packages/x.deb"), AgentContext.relevance(of: "README.md"))
    }

    func testDigestSkipsBuildOutputAndOrder() {
        let files = [
            ProjectFile(path: "README.md", contents: "readme"),
            ProjectFile(path: "Tweak.x", contents: "%hook Foo\n%end"),
            ProjectFile(path: "Makefile", contents: "TWEAK_NAME = MyTweak"),
            ProjectFile(path: "packages/x.deb", contents: "binary"),
        ]
        let digest = AgentContext.fileDigest(files, budget: 10_000)
        XCTAssertTrue(digest.contains("### Tweak.x"))
        XCTAssertTrue(digest.contains("### Makefile"))
        XCTAssertFalse(digest.contains("binary"))
        XCTAssertLessThan(digest.range(of: "Tweak.x")!.lowerBound, digest.range(of: "Makefile")!.lowerBound)
    }

    func testDigestTruncatesToTheBudgetAndSaysWhatIsMissing() {
        let big = String(repeating: "let x = 1\n", count: 400)
        let files = [
            ProjectFile(path: "Tweak.x", contents: big),
            ProjectFile(path: "control", contents: "Package: com.example.a\n"),
            ProjectFile(path: "README.md", contents: "readme"),
        ]
        let digest = AgentContext.fileDigest(files, budget: 600)
        XCTAssertTrue(digest.contains("truncated"))
        XCTAssertTrue(digest.contains("more file") || digest.contains("### control"), digest)
        XCTAssertLessThan(digest.utf8.count, 4000)
    }

    func testSystemPromptTeachesThePackagingSchemeItWillActuallyInstallInto() {
        let prompt = AgentContext.systemPrompt(snapshot())
        XCTAssertTrue(prompt.contains("rootless"))
        XCTAssertTrue(prompt.contains("/var/jb"))
        XCTAssertTrue(prompt.contains("iphoneos-arm64"))
        XCTAssertTrue(prompt.contains("TWEAK_NAME"))
        XCTAssertTrue(prompt.contains("%orig"))
        XCTAssertTrue(prompt.contains("silently never fires"))
        XCTAssertTrue(prompt.contains("hooking library"))
    }

    func testSystemPromptTracksTheScheme() {
        var rootful = snapshot()
        rootful.scheme = .rootful
        let prompt = AgentContext.systemPrompt(rootful)
        XCTAssertTrue(prompt.contains("iphoneos-arm"))
        XCTAssertFalse(prompt.contains("/var/jb"))
    }

    func testContextMessageCarriesTheLastBuildOrSaysThereWasNone() {
        let withoutBuild = AgentContext.contextMessage(snapshot())
        XCTAssertTrue(withoutBuild.contains("No build has run"))
        XCTAssertTrue(withoutBuild.contains("## This device"))

        let withBuild = AgentContext.contextMessage(snapshot(build: "Tweak.x:12:5: error: use of undeclared identifier 'foo'"))
        XCTAssertTrue(withBuild.contains("use of undeclared identifier"))
        XCTAssertFalse(withBuild.contains("No build has run"))
    }
}

final class AgentWireFormatTests: XCTestCase {

    func testToolCallDecodingMatchesTheAPIShape() throws {
        let json = """
        {"id":"call_abc","type":"function","function":{"name":"read_file","arguments":"{\\"path\\":\\"Tweak.x\\"}"}}
        """
        let call = try JSONDecoder().decode(AgentToolCall.self, from: Data(json.utf8))
        XCTAssertEqual(call.id, "call_abc")
        XCTAssertEqual(call.name, "read_file")
        XCTAssertEqual(AgentActionParser.parse(call), .readFile(path: "Tweak.x"))
    }

    func testResponseDecodingIgnoresWhatItDoesNotKnow() throws {
        let json = """
        {
          "id": "chatcmpl-1",
          "object": "chat.completion",
          "model": "some-model",
          "choices": [
            {
              "index": 0,
              "finish_reason": "tool_calls",
              "message": {
                "role": "assistant",
                "content": null,
                "refusal": null,
                "tool_calls": [
                  {"id":"call_1","type":"function","function":{"name":"list_files","arguments":"{}"}}
                ]
              }
            }
          ],
          "usage": {"prompt_tokens": 10}
        }
        """
        let response = try JSONDecoder().decode(AgentResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.toolCalls.count, 1)
        XCTAssertEqual(response.toolCalls.first?.name, "list_files")
        XCTAssertNil(response.message?.content)
    }

    func testAssistantMessagesOmitAnEmptyContentField() throws {
        let message = AgentMessage(
            role: .assistant,
            content: nil,
            toolCalls: [AgentToolCall(id: "call_1", name: "build", arguments: "{}")]
        )
        let data = try JSONEncoder().encode(message)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["content"])
        XCTAssertEqual((object["tool_calls"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(object["role"] as? String, "assistant")
    }

    func testToolResultMessagesCarryTheCallIdentifier() throws {
        let data = try JSONEncoder().encode(AgentMessage.toolResult(id: "call_9", text: "ok"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["role"] as? String, "tool")
        XCTAssertEqual(object["tool_call_id"] as? String, "call_9")
        XCTAssertEqual(object["content"] as? String, "ok")
    }

    func testRequestEncodesToolsInTheSchemaShape() throws {
        let request = AgentRequest(
            model: "some-model",
            messages: [.system("s"), .user("u")],
            tools: AgentToolCatalog.all,
            temperature: 0.2
        )
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "some-model")
        XCTAssertEqual(object["tool_choice"] as? String, "auto")
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, AgentToolCatalog.all.count)
        guard let function = tools.first?["function"] as? [String: Any] else {
            return XCTFail("tools must be wrapped in a function object")
        }
        XCTAssertEqual(function["name"] as? String, "list_files")
        XCTAssertNotNil(function["parameters"])
    }

    func testSchemaBuilding() {
        XCTAssertEqual(
            JSONValue.property("string", "a path").rendered(),
            "{\"description\":\"a path\",\"type\":\"string\"}"
        )
        let schema = JSONValue.schema(properties: ["path": .property("string", "p")], required: ["path"])
        XCTAssertEqual(schema["type"]?.stringValue, "object")
        XCTAssertEqual(schema["required"]?.rendered(), "[\"path\"]")
    }
}
