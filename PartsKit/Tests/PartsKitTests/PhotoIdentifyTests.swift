import Foundation
import Testing
@testable import PartsKit

@Test func markingReaderSendsThePhotoAndCleansTheReply() throws {
    let url = URL(string: "http://127.0.0.1:11434/v1/chat/completions")!
    let req = OpenAICompatibleMarkingReader.makeRequest(endpoint: url, apiKey: "k", model: "qwen2.5vl:7b", image: Data([1, 2, 3]), type: "image/png")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    let body = try JSONDecoder().decode(JSONValue.self, from: try #require(req.httpBody))
    #expect(body["model"]?.string == "qwen2.5vl:7b")
    #expect(body["messages"]?.array?.last?["content"]?.array?.last?["image_url"]?["url"]?.string == "data:image/png;base64,AQID")

    let reply = #"{"choices":[{"message":{"content":"```text\nTI\n  LM358  \n\n2209\n```"}}]}"#
    #expect(try OpenAICompatibleMarkingReader.parse(Data(reply.utf8)) == "TI\nLM358\n2209")
    #expect(throws: OpenAICompatibleMarkingReader.Failure.self) { try OpenAICompatibleMarkingReader.parse(Data("nope".utf8)) }
}

/// A model reading that agrees with a catalog match isn't listed twice.
@Test func modelReadingThatAgreesIsNotRepeated() throws {
    let list = Identify.rank(tokens: Identify.tokens(Identify.words("LM358\n2209")))
    let top = try #require(list.first)
    let ai = Candidate(id: "a:LM358", source: .reading(PartReading(mpn: "LM358")), score: 0.7, reasons: [])
    #expect(PhotoIdentify.same(top, ai))
}
