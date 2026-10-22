import Foundation

/// Text embeddings for recognising a part by look (MobileCLIP, computed ahead of time by
/// tools/make-clip-embeddings.py), and zero-shot scoring of an image embedding against them.
public struct LookLabels: Sendable {
    public struct Label: Codable, Sendable { public var ref: String; public var label: String; public var vec: [Float] }
    public var model: String
    public var dim: Int
    public var logitScale: Float
    public var kinds: [Label]
    public var boards: [Label]

    public init(model: String, dim: Int, logitScale: Float, kinds: [Label], boards: [Label]) {
        self.model = model; self.dim = dim; self.logitScale = logitScale; self.kinds = kinds; self.boards = boards
    }

    /// The bundled embeddings, or nil when the app was built without them.
    public static let shared: LookLabels? = {
        struct File: Decodable { var model: String; var dim: Int; var logitScale: Float; var kinds: [Label]; var boards: [Label] }
        guard let url = Bundle.module.url(forResource: "clip-text-embeddings", withExtension: "json"),
              let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        return LookLabels(model: f.model, dim: f.dim, logitScale: f.logitScale, kinds: f.kinds, boards: f.boards)
    }()

    public static func normalised(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    /// softmax(logitScale × cosine) over the labels, best first.
    public func scores(_ image: [Float], _ labels: [Label]) -> [LookScore] {
        guard image.count == dim, !labels.isEmpty else { return [] }
        let img = Self.normalised(image)
        let logits = labels.map { l in logitScale * zip(img, l.vec).reduce(0) { $0 + $1.0 * $1.1 } }
        let m = logits.max()!
        let ex = logits.map { exp($0 - m) }
        let sum = ex.reduce(0, +)
        return zip(labels, ex).map { LookScore(ref: $0.ref, score: Double($1 / sum)) }.sorted { $0.score > $1.score }
    }

    /// Both steps: the kind of part, then — as far as it looks like a board — which board.
    public func classify(_ image: [Float], catalog: Catalog = .shared) -> [LookScore] {
        let kinds = scores(image, self.kinds)
        let boards = Identify.boardShare(kinds, catalog: catalog) >= 0.15 ? scores(image, self.boards) : []
        return Identify.combine(kinds: kinds, boards: boards, catalog: catalog)
    }
}
