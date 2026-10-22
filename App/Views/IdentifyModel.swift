import CoreGraphics
import Foundation
import Observation
import PartsKit

/// Identifying a part from one photo: barcodes (a bag label goes to receiving), then the markings
/// (Vision OCR, matched against the built-in list and your inventory), then — when the markings
/// aren't enough — how it looks (MobileCLIP) and what Apple Intelligence makes of the text.
@Observable
final class IdentifyModel {
    enum LookWhen: String, CaseIterable, Identifiable { case auto, always, never; var id: String { rawValue } }

    var photo: Data?
    var image: CGImage?
    var status = ""
    var busy = false
    var reading = PhotoReading()
    /// The markings as read (editable: correcting them ranks again).
    var markings = ""
    var look: [LookScore] = []
    var aiCandidate: Candidate?
    var candidates: [Candidate] = []
    var label: BagLabel?
    var error: String?
    var mode: Identify.Mode = .auto
    private var run = 0

    func set(_ data: Data) {
        guard let jpeg = Images.jpeg(data, maxSide: 2048), let img = Images.cgImage(jpeg, maxSide: 2048) else { error = "That file isn't an image this app can read."; return }
        photo = jpeg; image = img
        reading = PhotoReading(); markings = ""; look = []; aiCandidate = nil; candidates = []; label = nil; error = nil
    }

    func identify(inventory: [InventoryRef], lookWhen: LookWhen, useAI: Bool) async {
        guard let image else { return }
        run += 1
        let me = run
        busy = true; error = nil
        defer { if me == run { busy = false; status = "" } }

        status = "Reading the markings…"
        let r = await PhotoReader.read(image, inventory: inventory)
        guard me == run else { return }
        reading = r; markings = r.text
        label = r.barcodes.map(BagLabels.parse).first { $0.kind != .plain && $0.hasPart } ?? r.barcodes.map(BagLabels.parse).first { $0.hasPart && $0.supplier != nil }
        rerank(inventory: inventory)

        let sure = Identify.sure(candidates)
        if lookWhen == .always || (lookWhen == .auto && !sure), LookModel.isAvailable {
            status = "Recognising it by how it looks…"
            do { look = try await LookModel.shared.classify(image) } catch { self.error = "Recognising by look failed: \(error.localizedDescription)" }
            guard me == run else { return }
            rerank(inventory: inventory)
        }
        if useAI && !Identify.sure(candidates) && !markings.isEmpty && AppleIntelligence.isAvailable {
            status = "Asking Apple Intelligence about the markings…"
            aiCandidate = try? await PartReader.read(ocrText: markings, imageLabels: r.labels)
            guard me == run else { return }
            rerank(inventory: inventory)
        }
    }

    /// Rank again (after the markings were corrected, or a new look or reading came in).
    func rerank(inventory: [InventoryRef]) {
        var list = Identify.rank(tokens: Identify.tokens(Identify.words(markings).isEmpty ? [] : wordsForRanking), look: look, inventory: inventory, mode: mode)
        if let ai = aiCandidate, !list.contains(where: { same($0, ai) }) { list.append(ai) }
        candidates = list.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.map(\.element)
    }

    /// The OCR words with their confidence, unless the markings were edited by hand.
    private var wordsForRanking: [OCRWord] { markings == reading.text ? reading.words : Identify.words(markings) }

    /// Apple Intelligence agreeing with a catalog or inventory match isn't a separate answer.
    private func same(_ a: Candidate, _ ai: Candidate) -> Bool {
        guard case .reading(let r) = ai.source, !r.mpn.isEmpty else { return false }
        switch a.source {
        case .catalog(let e): return (e.marks ?? []).contains { (Identify.markScore(r.mpn, $0)?.score ?? 0) >= 0.85 }
        case .inventory(let p): return (Identify.markScore(r.mpn, p.mpn)?.score ?? 0) >= 0.85
        case .unknown(let t): return Identify.squash(t) == Identify.squash(r.mpn)
        default: return false
        }
    }
}
