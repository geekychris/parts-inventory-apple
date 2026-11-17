import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads a part's markings using any server that speaks the OpenAI chat completions API — OpenAI
/// itself, or a compatible local/self-hosted one (Ollama, LM Studio, vLLM…). The cross-platform
/// counterpart to Apple Intelligence's PartReader (App/Intelligence/AppleIntelligence.swift), which
/// stays exclusive to macOS/iOS. Trusts its reading the same way PartReader does: only when the part
/// number it returns is actually found in the text that was read.
public struct OpenAICompatibleModel: PartIdentificationModel, Sendable {
    public var endpoint: URL
    public var apiKey: String
    public var model: String
    let session: URLSession

    public init(endpoint: URL, apiKey: String = "", model: String, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.session = session
    }

    static let instructions = """
    You identify electronic components from the text printed on them, as read by OCR from a photo. \
    The text may contain OCR errors, the manufacturer's logo name, date codes (like 2209 or 1932) and lot codes. \
    Use only what is printed and well-known marking conventions. If the part number is not readable, leave it empty \
    rather than guessing one. Keep descriptions short and factual. Reply with only a JSON object with these keys: \
    partNumber, manufacturer, description, category, package (all strings, empty if unknown), and confidence \
    (0 to 1, how sure the identification is).
    """

    public func read(ocrText: String, imageLabels: [String]) async throws -> Candidate? {
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let req = Self.makeRequest(endpoint: endpoint, apiKey: apiKey, model: model, ocrText: text, imageLabels: imageLabels)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return Self.parse(data, status: status, ocrText: text, model: model)
    }

    // MARK: Request

    struct ChatRequest: Encodable {
        var model: String
        var messages: [Message]
        var temperature: Double = 0
        var response_format = ResponseFormat()
        struct Message: Encodable { var role: String; var content: String }
        struct ResponseFormat: Encodable { var type = "json_object" }
    }

    static func makeRequest(endpoint: URL, apiKey: String, model: String, ocrText: String, imageLabels: [String]) -> URLRequest {
        var prompt = "Text read from the component:\n\(ocrText)"
        if !imageLabels.isEmpty { prompt += "\n\nThe photo looks like: \(imageLabels.joined(separator: ", "))." }
        let body = ChatRequest(model: model, messages: [.init(role: "system", content: instructions), .init(role: "user", content: prompt)])
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONEncoder().encode(body)
        return req
    }

    // MARK: Response

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { struct Msg: Decodable { var content: String }; var message: Msg }
        var choices: [Choice]
    }

    /// What the model made of the markings — the same shape Apple Intelligence's MarkingReading asks for.
    struct Reading: Decodable {
        var partNumber = "", manufacturer = "", description = "", category = "", package = ""
        var confidence = 0.0
        private enum Keys: String, CodingKey { case partNumber, manufacturer, description, category, package, confidence }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            partNumber = try c.decodeIfPresent(String.self, forKey: .partNumber) ?? ""
            manufacturer = try c.decodeIfPresent(String.self, forKey: .manufacturer) ?? ""
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
            package = try c.decodeIfPresent(String.self, forKey: .package) ?? ""
            confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        }
    }

    /// Turn the HTTP response into a candidate, or nil when the server failed or said nothing useful.
    /// The part number is only trusted (scored higher) when it's actually in the text that was read —
    /// the same rule PartReader uses, via the same `Identify` primitives.
    static func parse(_ data: Data, status: Int, ocrText: String, model: String) -> Candidate? {
        guard (200..<300).contains(status),
              let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
              let content = chat.choices.first?.message.content,
              let g = try? JSONDecoder().decode(Reading.self, from: Data(content.utf8))
        else { return nil }
        guard !g.partNumber.isEmpty || !g.description.isEmpty else { return nil }
        let toks = Identify.tokens(Identify.words(ocrText))
        let printed = !g.partNumber.isEmpty && toks.contains { (Identify.markScore($0.text, g.partNumber)?.score ?? 0) >= 0.6 }
        let score = printed ? min(0.8, 0.5 + 0.3 * g.confidence) : min(0.4, 0.2 + 0.2 * g.confidence)
        let reading = PartReading(mpn: g.partNumber, manufacturer: g.manufacturer, description: g.description, category: g.category == "Other" ? "" : g.category, package: g.package)
        let what = [g.partNumber, g.description].filter { !$0.isEmpty }.joined(separator: " — ")
        let reason = printed ? "\(model) read the markings as \(what)" : "\(model) suggests \(what) (the number isn't in the text read, so check it)"
        return Candidate(id: "a:" + Identify.squash(g.partNumber + g.description), source: .reading(reading), score: score, reasons: [reason])
    }
}
