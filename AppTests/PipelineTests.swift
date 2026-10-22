import CoreGraphics
import Foundation
import Testing
import PartsKit
@testable import Parts_Inventory

// Runs the real pipeline — Vision OCR and barcodes, MobileCLIP, ranking — on photos in the folder
// named by TEST_PHOTOS_DIR (pass TEST_RUNNER_TEST_PHOTOS_DIR to xcodebuild). Skipped without it.
// Expected: chip.jpg (an ATmega328P), pot.jpg (a trimmer pot), stepper.jpg, tact.jpg.

let photosDir = ProcessInfo.processInfo.environment["TEST_PHOTOS_DIR"].map { URL(fileURLWithPath: $0) }

@MainActor func photo(_ name: String) throws -> CGImage {
    let url = try #require(photosDir).appendingPathComponent(name)
    return try #require(Images.cgImage(try Data(contentsOf: url)))
}

func describe(_ c: Candidate) -> String {
    let what: String = switch c.source {
    case .catalog(let e): e.id
    case .generic(let g): g.id
    case .inventory(let p): "inventory:" + p.id
    case .unknown(let t): "unknown:" + t
    case .reading(let r): "ai:" + r.mpn
    }
    return "\(what) \(Int(c.score * 100))%"
}

@MainActor @Test(.enabled(if: photosDir != nil)) func chipIsReadFromItsMarkings() async throws {
    let r = await PhotoReader.read(try photo("chip.jpg"))
    print("chip text:", r.text.replacingOccurrences(of: "\n", with: " | "), "turns:", r.quarterTurns, "labels:", r.labels)
    let ranked = Identify.rank(tokens: Identify.tokens(r.words))
    print("chip ranked:", ranked.prefix(4).map(describe))
    guard case .catalog(let e)? = ranked.first?.source else { Issue.record("no catalog match"); return }
    #expect(e.id == "atmega328p")
}

@MainActor @Test(.enabled(if: photosDir != nil && LookModel.isAvailable), arguments: ["pot.jpg", "stepper.jpg", "tact.jpg", "chip.jpg"])
func looks(_ name: String) async throws {
    let img = try photo(name)
    let t0 = Date()
    let look = try await LookModel.shared.classify(img)
    let ranked = Identify.rank(tokens: [], look: look)
    print("\(name) look (\(Int(Date().timeIntervalSince(t0) * 1000)) ms):", look.prefix(3).map { "\($0.ref) \(Int($0.score * 100))%" }, "→", ranked.prefix(3).map(describe))
    #expect(!look.isEmpty)
    if name == "pot.jpg" {
        #expect(look.prefix(2).contains { $0.ref == "g-trimpot" || $0.ref == "g-pot" })
    }
}

@MainActor @Test(.enabled(if: photosDir != nil)) func appleIntelligenceReadsTheChip() async throws {
    guard AppleIntelligence.isAvailable else { print("Apple Intelligence:", AppleIntelligence.status); return }
    let r = await PhotoReader.read(try photo("chip.jpg"))
    let c = try await PartReader.read(ocrText: r.text, imageLabels: r.labels)
    print("AI reading:", c.map(describe) ?? "none", c?.reasons ?? [])
    #expect(c != nil)
}
