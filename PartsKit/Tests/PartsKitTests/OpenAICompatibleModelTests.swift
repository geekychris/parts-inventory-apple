import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import PartsKit

// OpenAICompatibleModel's request-building and response-parsing are plain functions, tested here
// without a real network call; `requestEndsUpConformingToTheProtocol` below covers the one bit of
// glue (the public `read` method) that actually touches the network.

private let endpoint = URL(string: "http://localhost:1234/v1/chat/completions")!

@Test func requestBodyMatchesTheOpenAIChatShape() throws {
    let req = OpenAICompatibleModel.makeRequest(endpoint: endpoint, apiKey: "sk-test", model: "llama3", ocrText: "LM358DR TI", imageLabels: ["a chip"])
    #expect(req.url == endpoint)
    #expect(req.httpMethod == "POST")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    let body = try #require(req.httpBody)
    let j = try JSONDecoder().decode(JSONValue.self, from: body)
    #expect(j["model"]?.string == "llama3")
    let messages = try #require(j["messages"]?.array)
    #expect(messages.count == 2)
    #expect(messages[0]["role"]?.string == "system")
    #expect(messages[1]["role"]?.string == "user")
    #expect(messages[1]["content"]?.string?.contains("LM358DR TI") == true)
    #expect(messages[1]["content"]?.string?.contains("a chip") == true)
}

@Test func requestWithoutAnAPIKeyOmitsTheHeader() {
    let req = OpenAICompatibleModel.makeRequest(endpoint: endpoint, apiKey: "", model: "llama3", ocrText: "x", imageLabels: [])
    #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
}

private func chatReply(_ json: String) -> Data {
    let escaped = json.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    return Data(#"{"choices":[{"message":{"content":"\#(escaped)"}}]}"#.utf8)
}

@Test func parsesASuccessfulReadingIntoACandidate() throws {
    let data = chatReply(#"{"partNumber":"LM358DR","manufacturer":"TI","description":"Dual op amp","category":"ICs/Analog","package":"SOIC-8","confidence":0.9}"#)
    let c = try #require(OpenAICompatibleModel.parse(data, status: 200, ocrText: "LM358DR TI 2209", model: "llama3"))
    #expect(c.score >= 0.5)
    guard case .reading(let r) = c.source else { Issue.record("expected .reading"); return }
    #expect(r.mpn == "LM358DR" && r.manufacturer == "TI" && r.package == "SOIC-8")
    #expect(c.reasons.first?.contains("llama3") == true)
}

@Test func untrustedWhenThePartNumberIsntInTheText() throws {
    let data = chatReply(#"{"partNumber":"LM358DR","description":"Dual op amp","confidence":0.9}"#)
    let c = try #require(OpenAICompatibleModel.parse(data, status: 200, ocrText: "some unrelated marking XYZ123", model: "llama3"))
    #expect(c.score <= 0.4)
    let trusted = try #require(OpenAICompatibleModel.parse(chatReply(#"{"partNumber":"LM358DR","description":"Dual op amp","confidence":0.9}"#), status: 200, ocrText: "LM358DR", model: "llama3"))
    #expect(trusted.score > c.score)
}

@Test func returnsNilOnMalformedOrUnreachableEndpoint() async {
    #expect(OpenAICompatibleModel.parse(chatReply(#"{"partNumber":"","description":""}"#), status: 200, ocrText: "x", model: "m") == nil)   // nothing useful
    #expect(OpenAICompatibleModel.parse(Data("oops".utf8), status: 500, ocrText: "x", model: "m") == nil)                                    // server error
    #expect(OpenAICompatibleModel.parse(Data("not json".utf8), status: 200, ocrText: "x", model: "m") == nil)                                // malformed body

    // Nothing listens on this port, so the request itself fails — the live `read()` path degrades
    // to a thrown error rather than crashing.
    let model = OpenAICompatibleModel(endpoint: URL(string: "http://127.0.0.1:1/v1/chat/completions")!, model: "m")
    await #expect(throws: (any Error).self) { try await model.read(ocrText: "LM358DR", imageLabels: []) }
}

@Test func emptyOCRTextNeedsNoNetworkCall() async throws {
    let model = OpenAICompatibleModel(endpoint: URL(string: "http://127.0.0.1:1/v1/chat/completions")!, model: "m")
    #expect(try await model.read(ocrText: "   ", imageLabels: []) == nil)
}
