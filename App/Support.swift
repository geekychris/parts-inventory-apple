import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

/// App-wide state: the selected tab, and a photo handed from one screen to another.
@Observable
final class AppModel {
    enum Tab: String, Hashable { case parts, scan, identify, locations, projects, ask, settings }
    var tab: Tab = .parts
    /// A photo for Identify to read (from Scan's "Identify what's in view").
    var photoForIdentify: Data?
    /// A part to show in Parts.
    var partToShow: String?
}

nonisolated enum Images {
    /// A CGImage from image data, with its EXIF orientation applied and scaled to fit `maxSide`.
    static func cgImage(_ data: Data, maxSide: CGFloat = 2048) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxSide]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// JPEG data for storing, at most `maxSide` pixels on the long side.
    static func jpeg(_ data: Data, maxSide: CGFloat = 1600, quality: CGFloat = 0.82) -> Data? {
        guard let img = cgImage(data, maxSide: maxSide) else { return nil }
        return jpeg(img, quality: quality)
    }

    static func jpeg(_ img: CGImage, quality: CGFloat = 0.82) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func rotated(_ img: CGImage, quarterTurns: Int) -> CGImage {
        let t = ((quarterTurns % 4) + 4) % 4
        guard t != 0 else { return img }
        let w = t % 2 == 0 ? img.width : img.height, h = t % 2 == 0 ? img.height : img.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -CGFloat(t) * .pi / 2)
        ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
        return ctx.makeImage() ?? img
    }
}

extension Image {
    init?(data: Data) {
        guard let cg = Images.cgImage(data, maxSide: 1200) else { return nil }
        self.init(decorative: cg, scale: 1)
    }
}

/// A JSON file for export.
struct JSONFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension View {
    /// Opens a link in the browser.
    func linkStyle() -> some View { self.foregroundStyle(.tint) }
}
