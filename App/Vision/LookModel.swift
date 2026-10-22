import CoreGraphics
import CoreML
import Foundation
import Vision
import PartsKit

/// Recognising a part by how it looks: Apple's MobileCLIP image encoder (Core ML, on the Neural
/// Engine) turns the photo into an embedding, which is compared with text embeddings of ~45 kinds of
/// part and ~45 boards computed ahead of time. Two steps, as in the web tool: the kind of part
/// first, then — only as far as it looks like a board — which board.
actor LookModel {
    static let shared = LookModel()

    enum Failure: LocalizedError {
        case missing, noImageInput, noOutput
        var errorDescription: String? {
            switch self {
            case .missing: "The recognition model isn't in this build."
            case .noImageInput: "The recognition model has no image input."
            case .noOutput: "The recognition model gave no embedding."
            }
        }
    }

    private var model: MLModel?

    nonisolated static var isAvailable: Bool { modelURL != nil && LookLabels.shared != nil }
    nonisolated static var modelURL: URL? { Bundle.main.url(forResource: "MobileCLIPImage", withExtension: "mlmodelc") }

    private func loaded() async throws -> MLModel {
        if let model { return model }
        guard let url = Self.modelURL else { throw Failure.missing }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let m = try await MLModel.load(contentsOf: url, configuration: config)
        model = m
        return m
    }

    /// Load the model ahead of time, so the first photo isn't slow.
    func warmUp() async { _ = try? await loaded() }

    /// The image embedding.
    func embed(_ image: CGImage) async throws -> [Float] {
        // MLModel isn't Sendable; this actor is the only user of it.
        nonisolated(unsafe) let m = try await loaded()
        let desc = m.modelDescription
        guard let (name, input) = desc.inputDescriptionsByName.first(where: { $0.value.type == .image || $0.value.type == .multiArray }) else { throw Failure.noImageInput }
        let value: MLFeatureValue
        if input.type == .image, let c = input.imageConstraint {
            value = try MLFeatureValue(cgImage: image, constraint: c, options: [.cropAndScale: VNImageCropAndScaleOption.centerCrop.rawValue])
        } else if let c = input.multiArrayConstraint {
            value = MLFeatureValue(multiArray: try Self.pixels(image, shape: c.shape.map(\.intValue)))
        } else { throw Failure.noImageInput }
        let out = try await m.prediction(from: MLDictionaryFeatureProvider(dictionary: [name: value]))
        guard let arr = out.featureNames.compactMap({ out.featureValue(for: $0)?.multiArrayValue }).first else { throw Failure.noOutput }
        return (0..<arr.count).map { arr[$0].floatValue }
    }

    /// What it looks like: scores for kinds and boards, best first.
    func classify(_ image: CGImage) async throws -> [LookScore] {
        guard let labels = LookLabels.shared else { throw Failure.missing }
        return labels.classify(try await embed(image))
    }

    /// An image as a [1, 3, H, W] array of 0–1 values, centre-cropped (for models without an image input).
    static func pixels(_ image: CGImage, shape: [Int]) throws -> MLMultiArray {
        let h = shape.count >= 2 ? shape[shape.count - 2] : 256, w = shape.last ?? 256
        let side = min(image.width, image.height)
        let crop = image.cropping(to: CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)) ?? image
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * w * h)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { p[c * w * h + y * w + x] = Float(buf[(y * w + x) * 4 + c]) / 255 } } }
        return arr
    }
}
