import Foundation
import Observation
import PartsKit

/// The NIIMBOT label printer: finding and connecting to it, what's loaded, and printing part labels.
/// Bluetooth is only switched on when you first look for a printer, so the app doesn't ask for it at launch.
@Observable
final class LabelPrinter {
    static let shared = LabelPrinter()

    enum Status: Equatable {
        case idle, scanning, connecting(String), connected, printing(done: Int, of: Int), failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var devices: [NiimbotDevice] = []
    private(set) var info: NiimbotSession.Info?
    private(set) var battery: Int?
    private(set) var lastMessage: String?

    @ObservationIgnored private var transport: NiimbotTransport?
    @ObservationIgnored private var session: NiimbotSession?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?

    // Settings (the same keys the views use with @AppStorage).
    enum Key {
        static let device = "label.device", deviceName = "label.deviceName", size = "label.size", template = "label.template"
        static let link = "label.link", urlTemplate = "label.urlTemplate", showLocation = "label.showLocation"
        static let printOnAdd = "label.printOnAdd", density = "label.density"
    }
    private var defaults: UserDefaults { .standard }

    var isConnected: Bool { info != nil && (status == .connected || { if case .printing = status { true } else { false } }()) }
    var isBusy: Bool { if case .printing = status { true } else if case .connecting = status { true } else { false } }
    var knownPrinterName: String? { defaults.string(forKey: Key.deviceName) }

    /// The printer's model: what it reported, or the D110 until then.
    var model: NiimbotModel { info?.effectiveModel ?? .fallback }

    /// The label size: the setting, or ("auto") what the printer reports is loaded, or a usual size for it.
    func labelSize(_ id: String? = nil) -> LabelSize {
        let chosen = id ?? defaults.string(forKey: Key.size) ?? "auto"
        if chosen != "auto", let s = LabelSize.named(chosen) { return s }
        return info?.rollSize ?? LabelSize.usual(for: model)
    }

    var template: LabelTemplate { LabelTemplate(rawValue: defaults.string(forKey: Key.template) ?? "") ?? .iconTextQR }
    var linkProvider: any LabelLinkProvider { LabelLinks.provider(defaults.string(forKey: Key.link) ?? "datasheet") }
    var density: Int {
        let d = defaults.integer(forKey: Key.density)
        return d == 0 ? model.densityDefault : min(model.densityMax, max(model.densityMin, d))
    }

    // MARK: Finding and connecting

    private func makeTransport() -> NiimbotTransport {
        if let transport { return transport }
        let t = NiimbotTransport()
        t.onDevices = { d in Task { @MainActor in LabelPrinter.shared.devices = d } }
        t.onDisconnect = { why in Task { @MainActor in LabelPrinter.shared.disconnected(why) } }
        transport = t
        session = NiimbotSession(transport: t)
        return t
    }

    func startScan() {
        let t = makeTransport()
        Task {
            switch await t.ready() {
            case .poweredOn:
                if status == .idle || { if case .failed = status { true } else { false } }() { status = .scanning }
                t.startScan()
            case .unauthorized: status = .failed("Parts Inventory isn’t allowed to use Bluetooth. Allow it in Settings › Privacy › Bluetooth.")
            case .poweredOff: status = .failed("Bluetooth is off.")
            default: status = .failed("Bluetooth isn’t available.")
            }
        }
    }

    func stopScan() {
        transport?.stopScan()
        if status == .scanning { status = .idle }
    }

    func connect(_ d: NiimbotDevice) async {
        await connect(id: d.id, name: d.name)
    }

    /// Connect to the printer used last time, if there is one and it's on.
    func reconnect() async {
        guard info == nil, !isBusy, let s = defaults.string(forKey: Key.device), let id = UUID(uuidString: s) else { return }
        await connect(id: id, name: knownPrinterName ?? "printer", quiet: true)
    }

    private func connect(id: UUID, name: String, quiet: Bool = false) async {
        let t = makeTransport()
        guard await t.ready() == .poweredOn, let session else {
            if !quiet { status = .failed("Bluetooth isn’t on.") }
            return
        }
        t.stopScan()
        status = .connecting(name)
        do {
            let i = try await session.connect(id, name: name)
            info = i
            battery = i.battery
            status = .connected
            defaults.set(id.uuidString, forKey: Key.device)
            defaults.set(name, forKey: Key.deviceName)
            startHeartbeat()
        } catch {
            info = nil
            status = quiet ? .idle : .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        heartbeat?.cancel()
        transport?.disconnect()
        info = nil
        status = .idle
    }

    func forget() {
        disconnect()
        defaults.removeObject(forKey: Key.device)
        defaults.removeObject(forKey: Key.deviceName)
    }

    private func disconnected(_ why: String?) {
        heartbeat?.cancel()
        guard info != nil else { return }
        info = nil
        status = why.map { .failed("The printer disconnected: \($0)") } ?? .idle
    }

    /// Keep the battery current and notice a new roll.
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            var lastPaper: Bool?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let session = self.session, self.status == .connected else { continue }
                guard let h = await session.heartbeat() else { continue }
                if let b = h.battery { self.battery = b }
                if let p = h.paperInserted, p != lastPaper {
                    if lastPaper != nil, let i = await session.refreshRoll() { self.info = i }
                    lastPaper = p
                }
            }
        }
    }

    func refreshRoll() async {
        guard let session, let i = await session.refreshRoll() else { return }
        info = i
    }

    // MARK: Labels

    /// What goes on a part's label.
    func content(for p: Part, showLocation: Bool? = nil) -> LabelContent {
        let loc = showLocation ?? (defaults.object(forKey: Key.showLocation) as? Bool ?? true)
        let desc = p.partDescription.isEmpty ? p.paramsSummary : p.partDescription
        var lines: [String] = []
        if !p.paramsSummary.isEmpty && p.paramsSummary != desc { lines.append(p.paramsSummary) }
        if loc, let l = p.location { lines.append(l.path) }
        return LabelContent(title: p.mpn.isEmpty ? p.title : p.mpn, subtitle: desc, lines: lines,
                            icon: PartRow.symbol(for: p), link: link(for: p))
    }

    func link(for p: Part, provider: (any LabelLinkProvider)? = nil) -> String? {
        let ctx = LabelLinkContext(uid: p.uid, mpn: p.mpn, manufacturer: p.manufacturer, category: p.category,
                                   datasheet: p.datasheet, supplierPages: p.suppliers.map(\.url))
        return (provider ?? linkProvider).url(for: ctx, settings: LabelLinkSettings(publicURLTemplate: defaults.string(forKey: Key.urlTemplate) ?? ""))
    }

    /// The label as it will print: dots in reading orientation, and where things went.
    func render(_ c: LabelContent, template: LabelTemplate, size: LabelSize) -> LabelRenderer.Result {
        let m = model, canvas = size.canvas(m)
        return LabelRenderer.render(c, template: template, w: canvas.w, h: canvas.h, dpi: m.dpi)
    }

    /// The kind of stock to tell the printer: what the roll's tag says, else what the printer reports.
    private var labelType: NiimbotLabelType {
        if let t = info?.rfid?.type, t != .invalid { return t }
        if let t = info?.labelType, t != .invalid { return t }
        return .withGaps
    }

    /// Print labels: each content `copies` times.
    func print(_ labels: [LabelContent], copies: Int = 1, template: LabelTemplate? = nil, size: LabelSize? = nil) async throws {
        guard !labels.isEmpty else { return }
        if info == nil { await reconnect() }
        guard let session, let info, status == .connected else { throw NiimbotError("Connect a NIIMBOT printer first (Settings › Label printer).") }
        let m = info.effectiveModel, size = size ?? labelSize(), template = template ?? self.template
        let pages = labels.map { NiimbotPage(image: NiimbotImage(render($0, template: template, size: size).bitmap, direction: m.direction), copies: copies) }
        let total = pages.reduce(0) { $0 + $1.copies }
        let steps = NiimbotJob.steps(task: info.printTask, pages: pages, density: density, labelType: labelType, printhead: m.printheadPixels)
        status = .printing(done: 0, of: total)
        defer { if case .printing = status { status = .connected } }
        do {
            try await session.run(steps, total: total) { done, of in
                Task { @MainActor in if case .printing = LabelPrinter.shared.status { LabelPrinter.shared.status = .printing(done: done, of: of) } }
            }
            lastMessage = total == 1 ? "Printed a label." : "Printed \(total) labels."
        } catch {
            lastMessage = error.localizedDescription
            throw error
        }
        if let i = await session.refreshRoll() { self.info = i }
    }

    func print(parts: [Part], copies: Int = 1, template: LabelTemplate? = nil, size: LabelSize? = nil) async throws {
        try await print(parts.map { content(for: $0) }, copies: copies, template: template, size: size)
    }

    /// Called when a part is added (identified, scanned, batch): prints its label if that's switched on.
    func partAdded(_ p: Part) {
        guard defaults.bool(forKey: Key.printOnAdd), defaults.string(forKey: Key.device) != nil else { return }
        let c = content(for: p)
        Task { try? await print([c]) }
    }
}
