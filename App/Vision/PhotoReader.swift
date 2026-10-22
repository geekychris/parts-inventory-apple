import CoreGraphics
import Foundation
import ImageIO
import Vision
import PartsKit

/// Everything Vision reads from a photo: the words (with their lines and confidence), any barcodes,
/// and a few general labels for what's in it.
nonisolated struct PhotoReading: Sendable {
    var words: [OCRWord] = []
    var text = ""
    var barcodes: [String] = []
    var labels: [String] = []
    /// The rotation the text read best at, in quarter turns.
    var quarterTurns = 0
}

nonisolated enum PhotoReader {
    static let symbologies: [BarcodeSymbology] = [.dataMatrix, .qr, .code128, .code39, .code93, .ean13, .ean8, .upce, .pdf417, .aztec, .microQR]

    /// Read a photo: barcodes first; then text. Chips are often photographed sideways, so when the
    /// text matches nothing useful upright, the other three rotations are tried and the best kept.
    @concurrent static func read(_ image: CGImage, inventory: [InventoryRef] = []) async -> PhotoReading {
        var out = PhotoReading()
        out.barcodes = await barcodes(image)
        out.labels = await labels(image)
        let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
        var best: (score: Double, words: [OCRWord], turns: Int)?
        for (i, o) in orientations.enumerated() {
            let words = await text(image, orientation: o)
            let ranked = Identify.rank(tokens: Identify.tokens(words), inventory: inventory)
            let score = (ranked.first?.score ?? 0) + Double(words.count) * 0.001
            if best == nil || score > best!.score { best = (score, words, i) }
            if Identify.sure(ranked) || (i == 0 && (ranked.first?.score ?? 0) >= 0.6) { break }
        }
        if let best {
            out.words = best.words; out.quarterTurns = best.turns
            out.text = Dictionary(grouping: best.words, by: \.line).sorted { $0.key < $1.key }.map { $0.value.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        }
        return out
    }

    static func text(_ image: CGImage, orientation: CGImagePropertyOrientation) async -> [OCRWord] {
        var req = RecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false   // part numbers aren't words
        req.minimumTextHeightFraction = 0.01
        guard let obs = try? await req.perform(on: image, orientation: orientation) else { return [] }
        var words: [OCRWord] = []
        for (li, o) in obs.enumerated() {
            guard let c = o.topCandidates(1).first else { continue }
            for w in c.string.split(whereSeparator: \.isWhitespace) {
                words.append(OCRWord(text: String(w), conf: Double(c.confidence) * 100, line: li))
            }
        }
        return words
    }

    static func barcodes(_ image: CGImage) async -> [String] {
        var req = DetectBarcodesRequest()
        req.symbologies = symbologies
        guard let obs = try? await req.perform(on: image) else { return [] }
        var seen = Set<String>()
        return obs.compactMap(\.payloadString).filter { seen.insert($0).inserted }
    }

    /// Vision's general image labels ("circuit_board", "tool"), as hints for Apple Intelligence.
    static func labels(_ image: CGImage) async -> [String] {
        let req = ClassifyImageRequest()
        guard let obs = try? await req.perform(on: image) else { return [] }
        return obs.filter { $0.confidence > 0.15 }.prefix(5).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }
}
