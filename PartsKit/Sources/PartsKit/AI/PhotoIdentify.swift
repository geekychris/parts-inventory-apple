import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the text printed on a part from its photo with a vision model behind the OpenAI chat completions API
/// (Ollama, vLLM, LM Studio, OpenAI…) — the OCR step for platforms without Apple's Vision framework.
public struct OpenAICompatibleMarkingReader: Sendable {
    public var endpoint: URL
    public var apiKey: String
    public var model: String
    let session: URLSession

    public init(endpoint: URL, apiKey: String = "", model: String, session: URLSession = .shared) {
        self.endpoint = endpoint; self.apiKey = apiKey; self.model = model; self.session = session
    }

    static let instructions = """
    You are an OCR engine for electronic components. Transcribe the text printed, laser-etched or silk-screened on the \
    component in the photo exactly as written, keeping each line of markings on its own line. Do not explain, correct, \
    or identify the part, and do not add anything that isn't printed. If nothing is legible, reply with an empty message.
    """

    public struct Failure: LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// The markings as text (possibly empty: nothing legible).
    public func read(image: Data, type: String) async throws -> String {
        let (data, resp) = try await session.data(for: Self.makeRequest(endpoint: endpoint, apiKey: apiKey, model: model, image: image, type: type))
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure(message: "\(model) at \(endpoint.host ?? endpoint.absoluteString) answered \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return try Self.parse(data)
    }

    static func makeRequest(endpoint: URL, apiKey: String, model: String, image: Data, type: String) -> URLRequest {
        let url = "data:\(type);base64,\(image.base64EncodedString())"
        let body: JSONValue = .object([
            "model": .string(model), "temperature": .number(0),
            "messages": .array([
                .object(["role": .string("system"), "content": .string(instructions)]),
                .object(["role": .string("user"), "content": .array([
                    .object(["type": .string("text"), "text": .string("Transcribe the markings on this component.")]),
                    .object(["type": .string("image_url"), "image_url": .object(["url": .string(url)])]),
                ])]),
            ]),
        ])
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 300  // a local model may have to load first
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = JSONValue.encode(body)
        return req
    }

    static func parse(_ data: Data) throws -> String {
        struct Chat: Decodable { struct Choice: Decodable { struct Msg: Decodable { var content: String? }; var message: Msg }; var choices: [Choice] }
        guard let chat = try? JSONDecoder().decode(Chat.self, from: data) else { throw Failure(message: "The vision model's reply wasn't a chat completion.") }
        var text = chat.choices.first?.message.content ?? ""
        // Models like to fence their output; the markings are what's inside.
        text = text.replacingOccurrences(of: "```[a-z]*", with: "", options: .regularExpression)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Identifying a part from a photo without Apple's frameworks: a vision model reads the markings, they're
/// matched against the built-in list and the inventory as the app matches Vision's OCR, and a text model's
/// reading of them is added when the matches aren't sure — the app's IdentifyModel, less barcodes and look.
public enum PhotoIdentify {
    public struct Result: Sendable {
        public var markings: String
        public var candidates: [Candidate]
        public var warning: String?
    }

    public static func identify(image: Data, type: String, inventory: [InventoryRef], reader: OpenAICompatibleMarkingReader,
                                model: (any PartIdentificationModel)?) async throws -> Result {
        let markings = try await reader.read(image: image, type: type)
        var list = Identify.rank(tokens: Identify.tokens(Identify.words(markings)), inventory: inventory)
        var warning: String?
        if markings.isEmpty { warning = "No markings could be read from the photo." }
        if let model, !markings.isEmpty, !Identify.sure(list) {
            do {
                if let ai = try await model.read(ocrText: markings, imageLabels: []), !list.contains(where: { same($0, ai) }) { list.append(ai) }
            } catch { warning = "Reading the markings with the text model failed: \(error.localizedDescription)" }
        }
        list = list.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
        return Result(markings: markings, candidates: list, warning: warning)
    }

    /// A model reading that agrees with a catalog, inventory or unknown-number match isn't a separate answer.
    static func same(_ a: Candidate, _ ai: Candidate) -> Bool {
        guard case .reading(let r) = ai.source, !r.mpn.isEmpty else { return false }
        switch a.source {
        case .catalog(let e): return (e.marks ?? []).contains { (Identify.markScore(r.mpn, $0)?.score ?? 0) >= 0.85 }
        case .inventory(let p): return (Identify.markScore(r.mpn, p.mpn)?.score ?? 0) >= 0.85
        case .unknown(let t): return Identify.squash(t) == Identify.squash(r.mpn)
        default: return false
        }
    }
}
