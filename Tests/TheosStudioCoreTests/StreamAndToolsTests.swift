import XCTest
@testable import TheosStudioCore

final class AgentStreamDecoderTests: XCTestCase {

    /// The shape OpenAI and DeepSeek both send: content deltas, then a tool call
    /// whose arguments arrive in pieces, then the finish and the sentinel.
    private let transcript = """
    data: {"choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"choices":[{"index":0,"delta":{"content":"Reading "},"finish_reason":null}]}
    data: {"choices":[{"index":0,"delta":{"content":"the file."},"finish_reason":null}]}
    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"read_file","arguments":""}}]},"finish_reason":null}]}
    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"path\\":"}}]},"finish_reason":null}]}
    data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"Tweak.x\\"}"}}]},"finish_reason":null}]}
    data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
    data: [DONE]
    """

    func testReassemblingTextAndToolCalls() {
        var decoder = AgentStreamDecoder()
        var events: [AgentStreamEvent] = []
        for line in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            events.append(contentsOf: decoder.consume(line: String(line)))
        }

        XCTAssertTrue(decoder.isStreaming)
        XCTAssertEqual(decoder.text, "Reading the file.")

        let message = decoder.message()
        XCTAssertEqual(message.content, "Reading the file.")
        XCTAssertEqual(message.toolCalls.count, 1)
        XCTAssertEqual(message.toolCalls[0].id, "call_1")
        XCTAssertEqual(message.toolCalls[0].name, "read_file")
        XCTAssertEqual(message.toolCalls[0].arguments, #"{"path":"Tweak.x"}"#)

        // The assembled arguments are what the parser needs, so they are checked
        // by parsing them rather than by comparing strings.
        XCTAssertEqual(AgentActionParser.parse(message.toolCalls[0]), .readFile(path: "Tweak.x"))
        XCTAssertTrue(events.contains { $0 == .finished(reason: "tool_calls") })
    }

    func testTextEventsArriveInOrder() {
        var decoder = AgentStreamDecoder()
        var pieces: [String] = []
        for line in transcript.split(separator: "\n") {
            for event in decoder.consume(line: String(line)) {
                if case .text(let text) = event { pieces.append(text) }
            }
        }
        XCTAssertEqual(pieces, ["Reading ", "the file."])
    }

    func testSeveralToolCallsAreKeptApartByIndex() {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","function":{"name":"build","arguments":"{}"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"list_files","arguments":"{"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}"#,
        ]
        var decoder = AgentStreamDecoder()
        for line in lines { _ = decoder.consume(line: line) }

        let calls = decoder.message().toolCalls
        XCTAssertEqual(calls.map(\.name), ["list_files", "build"], "sorted by index, not arrival")
        XCTAssertEqual(calls[0].arguments, "{}")
        XCTAssertEqual(calls[1].arguments, "{}")
    }

    /// A repeated name must not be concatenated: some gateways repeat the name in
    /// every fragment, and `read_fileread_file` is not a tool.
    func testARepeatedNameIsNotConcatenated() {
        let lines = [
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"read_file","arguments":"a"}}]},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"read_file","arguments":"b"}}]},"finish_reason":null}]}"#,
        ]
        var decoder = AgentStreamDecoder()
        for line in lines { _ = decoder.consume(line: line) }
        XCTAssertEqual(decoder.message().toolCalls[0].name, "read_file")
        XCTAssertEqual(decoder.message().toolCalls[0].arguments, "ab")
    }

    func testEmptyArgumentsBecomeAnEmptyObject() {
        var decoder = AgentStreamDecoder()
        _ = decoder.consume(line: #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c","function":{"name":"list_files","arguments":""}}]},"finish_reason":null}]}"#)
        XCTAssertEqual(decoder.message().toolCalls[0].arguments, "{}")
    }

    func testReasoningContentIsShownButIsNotTheReply() {
        var decoder = AgentStreamDecoder()
        let events = decoder.consume(line: #"data: {"choices":[{"delta":{"reasoning_content":"thinking…"},"finish_reason":null}]}"#)
        XCTAssertEqual(events, [.text("thinking…")])
        XCTAssertEqual(decoder.text, "", "the reply is what comes after the thinking")
    }

    func testCommentsAndNoiseAreIgnored() {
        var decoder = AgentStreamDecoder()
        XCTAssertTrue(decoder.consume(line: ": keep-alive").isEmpty)
        XCTAssertTrue(decoder.consume(line: "event: message").isEmpty)
        XCTAssertTrue(decoder.consume(line: "").isEmpty)
        XCTAssertTrue(decoder.consume(line: "data: not json").isEmpty)
        XCTAssertFalse(decoder.isStreaming)
    }

    func testTheSentinelEndsTheStream() {
        var decoder = AgentStreamDecoder()
        XCTAssertEqual(decoder.consume(line: "data: [DONE]"), [.finished(reason: nil)])
    }

    /// A gateway that ignores `stream: true` answers with a plain completion; it
    /// must not be mistaken for an empty turn.
    func testANonStreamingResponseIsReadAsOneChunk() {
        let body = #"""
        {"choices":[{"message":{"role":"assistant","content":"Done.","tool_calls":[{"id":"call_9","type":"function","function":{"name":"build","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}
        """#
        var decoder = AgentStreamDecoder()
        let events = decoder.consume(body: body)
        XCTAssertEqual(decoder.text, "Done.")
        XCTAssertEqual(decoder.message().toolCalls.first?.name, "build")
        XCTAssertTrue(events.contains { $0 == .finished(reason: "tool_calls") })
    }

    func testAnErrorChunkBecomesAFailure() {
        var decoder = AgentStreamDecoder()
        let events = decoder.consume(line: #"data: {"error":{"message":"insufficient balance"}}"#)
        XCTAssertEqual(events, [.failed("insufficient balance")])
    }

    func testAnEmptyStreamProducesAnEmptyMessage() {
        var decoder = AgentStreamDecoder()
        _ = decoder.consume(line: "data: [DONE]")
        XCTAssertNil(decoder.message().content)
        XCTAssertTrue(decoder.message().toolCalls.isEmpty)
    }
}

final class MakefileSettingsTests: XCTestCase {

    private let makefile = """
    export THEOS_PACKAGE_SCHEME = rootless
    TARGET := iphone:clang:latest:15.0
    ARCHS = arm64 arm64e
    INSTALL_TARGET_PROCESSES = SpringBoard

    include $(THEOS)/makefiles/common.mk

    TWEAK_NAME = MyTweak
    MyTweak_FILES = Tweak.x
    """

    func testReadingTheSettings() {
        let settings = MakefileEditor.settings(in: makefile)
        XCTAssertEqual(settings.target, "iphone:clang:latest:15.0")
        XCTAssertEqual(settings.architectures, "arm64 arm64e")
        XCTAssertEqual(settings.installTargetProcesses, "SpringBoard")
    }

    func testWritingThemBack() {
        var settings = MakefileEditor.settings(in: makefile)
        settings.architectures = "arm64"
        settings.installTargetProcesses = "SpringBoard backboardd"
        let result = MakefileEditor.applying(settings, to: makefile)

        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.text.contains("ARCHS = arm64\n"))
        XCTAssertTrue(result.text.contains("INSTALL_TARGET_PROCESSES = SpringBoard backboardd"))
        XCTAssertFalse(result.text.contains("arm64e"))
        // Nothing else moved.
        XCTAssertTrue(result.text.contains("TWEAK_NAME = MyTweak"))
        XCTAssertTrue(result.text.contains("export THEOS_PACKAGE_SCHEME = rootless"))
    }

    func testNothingToChangeSaysSo() {
        let result = MakefileEditor.applying(MakefileEditor.settings(in: makefile), to: makefile)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.reason, "Nothing to change.")
        XCTAssertEqual(result.text, makefile)
    }

    func testExtraVariablesAreAddedAndUpdated() {
        var settings = MakefileEditor.settings(in: makefile)
        settings.extraVariables = ["DEBUG": "0", "FINALPACKAGE": "1"]
        let result = MakefileEditor.applying(settings, to: makefile)
        XCTAssertTrue(result.text.contains("DEBUG = 0"))
        XCTAssertTrue(result.text.contains("FINALPACKAGE = 1"))

        var second = MakefileEditor.settings(in: result.text)
        second.extraVariables = ["DEBUG": "1"]
        let updated = MakefileEditor.applying(second, to: result.text)
        XCTAssertTrue(updated.text.contains("DEBUG = 1"))
        XCTAssertFalse(updated.text.contains("DEBUG = 0"))
    }

    /// An empty field means "leave it alone", not "delete the line": a form that
    /// blanks a value the user did not touch is worse than no form.
    func testEmptyFieldsAreLeftAlone() {
        var settings = MakefileEditor.settings(in: makefile)
        settings.architectures = ""
        settings.target = ""
        let result = MakefileEditor.applying(settings, to: makefile)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.text.contains("ARCHS = arm64 arm64e"))
    }

    func testListingTheVariables() {
        let variables = MakefileEditor.variables(in: makefile)
        let names = variables.map(\.name)
        XCTAssertTrue(names.contains("TWEAK_NAME"))
        XCTAssertTrue(names.contains("MyTweak_FILES"))
        XCTAssertTrue(names.contains("TARGET"))
        // Each name once, even when it is mentioned twice.
        XCTAssertEqual(Set(names).count, names.count)
    }
}

final class InjectionFilterTests: XCTestCase {

    private let generated = """
    {
        Filter = {
            Bundles = ( "com.apple.springboard" );
        };
    }
    """

    func testParsingTheGeneratedFilter() {
        let filter = InjectionFilter.parse(generated)
        XCTAssertEqual(filter.bundles, ["com.apple.springboard"])
        XCTAssertTrue(filter.executables.isEmpty)
        XCTAssertTrue(filter.warnings.isEmpty)
    }

    func testParsingSeveralEntriesAndExecutables() {
        let text = """
        {
            Filter = {
                Bundles = ( "com.apple.springboard", "com.apple.Preferences" );
                Executables = ( "backboardd" );
            };
        }
        """
        let filter = InjectionFilter.parse(text)
        XCTAssertEqual(filter.bundles, ["com.apple.springboard", "com.apple.Preferences"])
        XCTAssertEqual(filter.executables, ["backboardd"])
        XCTAssertFalse(filter.warnings.isEmpty, "both lists at once is worth a warning")
    }

    func testAddingAndRemovingBundles() {
        var filter = InjectionFilter.parse(generated)
        XCTAssertTrue(filter.add(bundle: "com.apple.Preferences"))
        XCTAssertFalse(filter.add(bundle: "com.apple.Preferences"), "no duplicates")
        XCTAssertTrue(filter.remove(bundle: "com.apple.springboard"))
        XCTAssertFalse(filter.remove(bundle: "nonesuch"))

        let text = filter.serialized()
        XCTAssertEqual(InjectionFilter.parse(text).bundles, ["com.apple.Preferences"])
        // The file stays a filter.
        XCTAssertTrue(text.contains("Filter"))
        XCTAssertTrue(text.contains("Bundles"))
    }

    /// Writing only the list means the comments someone left in the file, and
    /// anything else they added, survive the form.
    func testTheRestOfTheFileSurvives() {
        let annotated = """
        // this tweak only matters in SpringBoard
        {
            Filter = {
                Bundles = ( "com.apple.springboard" );
                Mode = "Any";
            };
        }
        """
        var filter = InjectionFilter.parse(annotated)
        filter.add(bundle: "com.apple.Preferences")
        let text = filter.serialized()
        XCTAssertTrue(text.contains("// this tweak only matters in SpringBoard"))
        XCTAssertTrue(text.contains("Mode = \"Any\""))
        XCTAssertEqual(InjectionFilter.parse(text).bundles, ["com.apple.springboard", "com.apple.Preferences"])
    }

    func testAddingExecutablesWhenThereAreNone() {
        var filter = InjectionFilter.parse(generated)
        filter.add(executable: "backboardd")
        let text = filter.serialized()
        XCTAssertEqual(InjectionFilter.parse(text).executables, ["backboardd"])
        XCTAssertEqual(InjectionFilter.parse(text).bundles, ["com.apple.springboard"])
    }

    /// The warning that matters: a filter naming nothing loads the dylib
    /// everywhere, which is how a tweak becomes a bootloop.
    func testEmptyFilterWarns() {
        let filter = InjectionFilter(bundles: [], executables: [], raw: "{\n    Filter = { };\n}\n")
        XCTAssertFalse(filter.isPlausible)
        XCTAssertTrue(filter.warnings.contains { $0.contains("every") })
    }

    func testSomethingThatIsNotABundleIdentifierWarns() {
        let filter = InjectionFilter(bundles: ["SpringBoard"], executables: [], raw: generated)
        XCTAssertTrue(filter.warnings.contains { $0.contains("does not look like a bundle identifier") })
    }

    func testAnEmptyFilterFallsBackToTheDefault() {
        var filter = InjectionFilter(bundles: [], executables: [], raw: "")
        filter.add(bundle: "com.apple.Preferences")
        XCTAssertTrue(filter.serialized().contains("com.apple.Preferences"))
        XCTAssertTrue(filter.serialized().contains("Filter"))
    }
}

final class AgentExtraBodyTests: XCTestCase {

    func testExtraBodyIsMergedIntoTheRequest() throws {
        let request = AgentRequest(
            model: "m",
            messages: [.user("hi")],
            tools: nil,
            temperature: 0.2,
            maxTokens: 100,
            extraBody: ["reasoning_effort": .string("low"), "provider_order": .array([.string("a")])]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["reasoning_effort"] as? String, "low")
        XCTAssertEqual(object["provider_order"] as? [String], ["a"])
        XCTAssertEqual(object["model"] as? String, "m")
        XCTAssertEqual(object["max_tokens"] as? Int, 100)
    }

    /// The typed fields are written after the extras, so a typo in the extras
    /// cannot silently change the model or drop the conversation.
    func testTypedFieldsWinOverTheExtras() throws {
        let request = AgentRequest(
            model: "the-real-model",
            messages: [.user("hi")],
            extraBody: ["model": .string("not-the-model"), "messages": .array([])]
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "the-real-model")
        XCTAssertEqual((object["messages"] as? [[String: Any]])?.count, 1)
    }

    func testTheStreamFlagIsOnlySentWhenAskedFor() throws {
        let request = AgentRequest(model: "m", messages: [.user("hi")], stream: true)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["stream"] as? Bool, true)

        request.stream = nil
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertNil(object["stream"], "the default is whatever the provider does")
    }

    func testNoExtrasMeansNoExtraKeys() throws {
        let request = AgentRequest(model: "m", messages: [.user("hi")])
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys).subtracting(["model", "messages"]).count, 0)
    }
}
