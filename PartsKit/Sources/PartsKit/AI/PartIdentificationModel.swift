import Foundation

/// Something that can look at a part's markings — the OCR text read from a photo, plus Vision's
/// general image labels — and guess what the part is. The model never sees the photo itself.
///
/// Apple Intelligence (the App target's `PartReader`) is one implementation, kept exclusive to
/// macOS/iOS as on-device intelligence; `OpenAICompatibleModel` is another, for every other
/// platform. See PORTABILITY.md.
public protocol PartIdentificationModel: Sendable {
    /// A candidate reading of the markings, or nil when the model has nothing to say (no text, the
    /// model is unavailable, or it couldn't make anything of it).
    func read(ocrText: String, imageLabels: [String]) async throws -> Candidate?
}
