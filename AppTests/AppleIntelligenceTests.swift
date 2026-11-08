import Foundation
import Testing
import PartsKit
@testable import Parts_Inventory

/// AppleIntelligenceModel adapts PartReader to PartsKit's `PartIdentificationModel` — the same
/// contract OpenAICompatibleModel implements for non-Apple platforms (see PORTABILITY.md). This
/// checks the adapter actually satisfies the protocol (an existential assignment fails to compile
/// otherwise) and that it delegates to PartReader without changing its answer.
@MainActor @Test func partReaderSatisfiesPartIdentificationModel() async throws {
    let model: any PartIdentificationModel = AppleIntelligenceModel()
    let ocrText = "LM358DR TI 2209"
    let labels = ["an integrated circuit"]
    let viaProtocol = try await model.read(ocrText: ocrText, imageLabels: labels)
    let direct = try await PartReader.read(ocrText: ocrText, imageLabels: labels)
    #expect(viaProtocol == direct)
}
