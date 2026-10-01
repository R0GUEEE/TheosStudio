import XCTest
@testable import TheosStudioCore

final class AgentProviderTests: XCTestCase {

    func testTheCatalogHasUniqueIdentifiers() {
        let ids = AgentProvider.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate provider id")
        XCTAssertEqual(AgentProvider.all.count, 12)
    }

    /// The two the setup screen is expected to offer first, at the addresses that
    /// actually answer.
    func testTheHeadlineProvidersPointAtTheirRealEndpoints() {
        XCTAssertEqual(AgentProvider.provider(id: "openai").baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(AgentProvider.provider(id: "deepseek").baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(AgentProvider.provider(id: "deepseek").suggestions, ["deepseek-chat", "deepseek-reasoner"])
        XCTAssertEqual(AgentProvider.all.first?.id, "openai")
    }

    func testEveryProviderIsUsable() {
        for provider in AgentProvider.all where !provider.isCustom {
            XCTAssertFalse(provider.baseURL.isEmpty, provider.id)
            let isLocal = provider.host == "localhost"
            XCTAssertTrue(
                provider.baseURL.hasPrefix("https://") || (isLocal && provider.baseURL.hasPrefix("http://")),
                "\(provider.id) should be https unless it is a local server"
            )
            XCTAssertFalse(provider.host.isEmpty, provider.id)
            XCTAssertFalse(provider.displayName.isEmpty, provider.id)
        }
    }

    func testProvidersThatDoNotNeedAKeyAreTheLocalOnes() {
        let optionalKey = AgentProvider.all.filter { !$0.requiresKey }.map(\.id)
        XCTAssertEqual(Set(optionalKey), ["ollama", "lmstudio", AgentProvider.customID])
    }

    func testUnknownOrMissingProviderIdsFallBackToCustom() {
        XCTAssertEqual(AgentProvider.provider(id: nil).id, AgentProvider.customID)
        XCTAssertEqual(AgentProvider.provider(id: "nonesuch").id, AgentProvider.customID)
        XCTAssertEqual(AgentProvider.provider(id: "deepseek").id, "deepseek")
    }

    func testSuggestionsBecomeModels() {
        let models = AgentModelList.suggestions(for: AgentProvider.provider(id: "deepseek"))
        XCTAssertEqual(models.map(\.id), ["deepseek-chat", "deepseek-reasoner"])
        XCTAssertTrue(AgentModelList.suggestions(for: AgentProvider.provider(id: "openai")).isEmpty)
    }
}

final class AgentModelListTests: XCTestCase {

    /// The OpenAI shape, with the models a provider really lists alongside the
    /// chat ones.
    private let openAIish = """
    {
      "object": "list",
      "data": [
        {"id": "gpt-4o", "object": "model", "created": 1715367049, "owned_by": "system"},
        {"id": "gpt-4o-mini", "object": "model", "created": 1721172741, "owned_by": "system"},
        {"id": "text-embedding-3-small", "object": "model", "created": 1705948997, "owned_by": "system"},
        {"id": "whisper-1", "object": "model", "created": 1677532384, "owned_by": "system"},
        {"id": "dall-e-3", "object": "model", "created": 1698785189, "owned_by": "system"},
        {"id": "tts-1", "object": "model", "created": 1704793990, "owned_by": "system"}
      ]
    }
    """

    func testDecodingAndFilteringOutNonChatModels() {
        let all = try? AgentModelList.decode(Data(openAIish.utf8))
        XCTAssertEqual(all?.count, 6)
        XCTAssertEqual(AgentModelList.chatModels(all ?? []).map(\.id), ["gpt-4o", "gpt-4o-mini"])
    }

    func testNonChatDetection() {
        XCTAssertFalse(AgentModelList.isChatModel(AgentModel(id: "text-embedding-3-large")))
        XCTAssertFalse(AgentModelList.isChatModel(AgentModel(id: "gpt-4o-realtime-preview")))
        XCTAssertFalse(AgentModelList.isChatModel(AgentModel(id: "llama-3.1-8b:batch")))
        XCTAssertTrue(AgentModelList.isChatModel(AgentModel(id: "gpt-4o")))
        XCTAssertTrue(AgentModelList.isChatModel(AgentModel(id: "deepseek-chat")))
        XCTAssertTrue(AgentModelList.isChatModel(AgentModel(id: "deepseek-reasoner")))
        XCTAssertTrue(AgentModelList.isChatModel(AgentModel(id: "openai/gpt-4o:free")))
    }

    /// OpenRouter lists a human name and a context length next to the id.
    func testDecodingTheAggregatorShape() {
        let json = """
        {"data": [
          {"id": "anthropic/claude-sonnet-5.5", "name": "Anthropic: Claude Sonnet 5.5", "context_length": 200000},
          {"id": "openai/gpt-6.1", "name": "OpenAI: GPT-6.1", "context_length": 400000}
        ]}
        """
        let models = (try? AgentModelList.decode(Data(json.utf8))) ?? []
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].displayName, "Anthropic: Claude Sonnet 5.5")
        XCTAssertEqual(models[0].contextLength, 200000)
        XCTAssertEqual(models[0].title, "Anthropic: Claude Sonnet 5.5")
        XCTAssertEqual(AgentModel(id: "x").title, "x")
    }

    func testABareArrayIsAccepted() {
        let json = #"[{"id": "llama3.2"}, {"id": "qwen2.5-coder"}]"#
        let models = (try? AgentModelList.decode(Data(json.utf8))) ?? []
        XCTAssertEqual(models.map(\.id), ["llama3.2", "qwen2.5-coder"])
    }

    func testDuplicateIdsAreCollapsedAndSorted() {
        let models = [
            AgentModel(id: "zeta"),
            AgentModel(id: "alpha"),
            AgentModel(id: "zeta"),
            AgentModel(id: "Beta"),
        ]
        XCTAssertEqual(AgentModelList.sorted(models).map(\.id), ["alpha", "Beta", "zeta"])
    }

    /// DeepSeek's list is exactly this: no name, no context length, two models.
    /// The setup screen has to turn it into a picker with both of them in it.
    func testDecodingDeepSeeksShape() {
        let json = """
        {"object":"list","data":[
          {"id":"deepseek-chat","object":"model","owned_by":"deepseek"},
          {"id":"deepseek-reasoner","object":"model","owned_by":"deepseek"}
        ]}
        """
        let models = (try? AgentModelList.decode(Data(json.utf8))) ?? []
        XCTAssertEqual(AgentModelList.chatModels(models).map(\.id), ["deepseek-chat", "deepseek-reasoner"])
        XCTAssertNil(models[0].displayName)
        XCTAssertNil(models[0].contextLength)
    }

    func testAlternativeShapesAreAccepted() {
        // The array nested under `models`, ids under `model`, a string context
        // window, and an entry with no id at all.
        let json = """
        {"models":[
          {"model":"qwen2.5-coder","context_length":"32768"},
          {"name":"No id here"},
          {"id":"llama3.2","context_length":131072}
        ]}
        """
        let models = (try? AgentModelList.decode(Data(json.utf8))) ?? []
        XCTAssertEqual(models.map(\.id), ["qwen2.5-coder", "llama3.2"])
        XCTAssertEqual(models[0].contextLength, 32768)
        XCTAssertEqual(models[1].contextLength, 131072)
    }

    func testReasoningModelsGetAToolCallingCaveat() {
        XCTAssertNotNil(AgentModelList.toolCallingCaveat(for: "deepseek-reasoner"))
        XCTAssertNotNil(AgentModelList.toolCallingCaveat(for: "deepseek-r1"))
        XCTAssertTrue(AgentModelList.toolCallingCaveat(for: "deepseek-reasoner")!.contains("deepseek-chat"))
        XCTAssertNil(AgentModelList.toolCallingCaveat(for: "deepseek-chat"))
        XCTAssertNil(AgentModelList.toolCallingCaveat(for: "gpt-4o"))
    }

    func testMalformedResponsesThrow() {
        XCTAssertThrowsError(try AgentModelList.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try AgentModelList.decode(Data(#"{"error": "unauthorized"}"#.utf8)))
    }

    func testAnEmptyListIsNotAnError() {
        XCTAssertEqual((try? AgentModelList.decode(Data(#"{"data": []}"#.utf8)))?.count, 0)
    }
}
