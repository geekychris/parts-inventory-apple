import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import PartsKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Draws a label at the printer's resolution and turns it into the 1-bit dots that get printed — the
/// preview shows exactly those dots.
nonisolated enum LabelRenderer {
    struct Result {
        var bitmap: Bitmap1
        var plan: LabelPlan
    }

    static func render(_ c: LabelContent, template: LabelTemplate, w: Int, h: Int, dpi: Int) -> Result {
        let qr = template == .iconTextQR ? c.link.flatMap(qrModules) : nil
        let plan = LabelLayout.plan(w: w, h: h, dpi: dpi, template: template, content: c, qrModules: qr?.count ?? 0) { text, px, bold in
            Double(CTLineGetTypographicBounds(line(text, px, bold), nil, nil, nil))
        }
        var gray = [UInt8](repeating: 255, count: w * h)
        gray.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setShouldSmoothFonts(false)
            ctx.setFillColor(gray: 0, alpha: 1)
            // Plan coordinates run from the top; Core Graphics from the bottom.
            for t in plan.texts {
                let l = line(t.text, t.px, t.bold)
                var ascent: CGFloat = 0
                CTLineGetTypographicBounds(l, &ascent, nil, nil)
                ctx.textPosition = CGPoint(x: CGFloat(t.x), y: CGFloat(h - t.y) - ascent)
                CTLineDraw(l, ctx)
            }
            if let box = plan.icon, let name = c.icon, let img = symbol(name, size: box.h) {
                let s = min(CGFloat(box.w) / CGFloat(img.width), CGFloat(box.h) / CGFloat(img.height))
                let iw = CGFloat(img.width) * s, ih = CGFloat(img.height) * s
                ctx.draw(img, in: CGRect(x: CGFloat(box.x) + (CGFloat(box.w) - iw) / 2, y: CGFloat(h - box.y - box.h) + (CGFloat(box.h) - ih) / 2, width: iw, height: ih))
            }
            if let q = plan.qr, let modules = qr {
                for (r, row) in modules.enumerated() {
                    for (col, on) in row.enumerated() where on {
                        ctx.fill(CGRect(x: q.x + col * q.module, y: h - (q.y + (r + 1) * q.module), width: q.module, height: q.module))
                    }
                }
            }
        }
        return Result(bitmap: Bitmap1(width: w, height: h, gray: gray), plan: plan)
    }

    static func line(_ text: String, _ px: Int, _ bold: Bool) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, CGFloat(px), nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, CGFloat(px), nil)
        let black = CGColor(gray: 0, alpha: 1)
        let s = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                               NSAttributedString.Key(kCTForegroundColorAttributeName as String): black])
        return CTLineCreateWithAttributedString(s)
    }

    /// The QR code's modules (true = dark), without its quiet zone.
    static func qrModules(_ text: String) -> [[Bool]]? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage,
              let cg = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(out, from: out.extent) else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 255, count: w * h)
        px.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            ctx?.interpolationQuality = .none
            ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // The symbol is the box around the dark modules (the finder patterns sit in three corners).
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where px[y * w + x] < 128 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        guard maxX >= minX else { return nil }
        return (minY...maxY).map { y in (minX...maxX).map { x in px[y * w + x] < 128 } }
    }

    /// An SF Symbol in black, about `size` dots tall.
    static func symbol(_ name: String, size: Int) -> CGImage? {
        #if canImport(UIKit)
        let cfg = UIImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.8, weight: .semibold)
        guard let img = UIImage(systemName: name, withConfiguration: cfg)?.withTintColor(.black, renderingMode: .alwaysOriginal) else { return nil }
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        return UIGraphicsImageRenderer(size: img.size, format: fmt).image { _ in img.draw(at: .zero) }.cgImage
        #else
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(size) * 0.8, weight: .semibold)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        var r = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
        #endif
    }

    /// The dots as an image, for the preview.
    static func image(_ b: Bitmap1) -> CGImage? {
        var px = [UInt8](repeating: 255, count: b.width * b.height)
        for y in 0..<b.height { for x in 0..<b.width where b[x, y] { px[y * b.width + x] = 0 } }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: b.width, height: b.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: b.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
