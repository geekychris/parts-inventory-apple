#if os(macOS)
import AppKit
import SwiftUI

/// Continuity Camera's Take Photo: the iPhone (or iPad) opens its own camera — zoom, macro, tap to focus —
/// and the photo comes straight back to the Mac. The live picture from an iPhone can't be zoomed from a Mac
/// app, so this is the way to get a sharp close-up of small markings.
struct DeviceImportButton: NSViewRepresentable {
    var title = "From iPhone"
    var onImage: (Data) -> Void

    func makeNSView(context: Context) -> DeviceImportView {
        let v = DeviceImportView(title: title)
        v.onImage = onImage
        return v
    }
    func updateNSView(_ v: DeviceImportView, context: Context) { v.onImage = onImage }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: DeviceImportView, context: Context) -> CGSize? { v.intrinsicContentSize }
}

/// A button that opens the system's "Import from iPhone or iPad" menu (Take Photo, Scan Documents, Add Sketch
/// for each nearby device) and takes the image that comes back.
final class DeviceImportView: NSButton, NSServicesMenuRequestor {
    var onImage: ((Data) -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .push
        controlSize = .large
        target = self
        action = #selector(showMenu)
        setAccessibilityLabel("Take a photo with your iPhone")
        toolTip = "Take a photo with your iPhone or iPad — its camera opens on the phone, zoom and all"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    @objc private func showMenu() {
        // The menu lists devices only for the responder that will take the image, so become it first.
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let types: [NSPasteboard.PasteboardType] = [.init("public.heic"), .init("public.jpeg"), .png, .tiff]
        for t in types { if let d = pasteboard.data(forType: t) { onImage?(d); return true } }
        if let img = NSImage(pasteboard: pasteboard), let d = img.tiffRepresentation { onImage?(d); return true }
        return false
    }
}
#endif
