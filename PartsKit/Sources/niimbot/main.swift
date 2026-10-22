// Find NIIMBOT printers nearby and read one — read-only, it never prints.
//   swift run niimbot             list printers seen in 8 seconds
//   swift run niimbot --info [name]   connect to the first (or the named) printer and show what it reports

import CoreBluetooth
import Foundation
import PartsKit

let args = Array(CommandLine.arguments.dropFirst())
let info = args.contains("--info")
let wanted = args.first { !$0.hasPrefix("-") }

let transport = NiimbotTransport()
let state = await transport.ready()
guard state == .poweredOn else {
    let why = [CBManagerState.unauthorized: "not allowed to use Bluetooth (System Settings › Privacy & Security › Bluetooth)",
               .poweredOff: "Bluetooth is off", .unsupported: "no Bluetooth"][state] ?? "Bluetooth isn’t ready (\(state.rawValue))"
    print("Can’t scan: \(why).")
    exit(1)
}

final class Seen: @unchecked Sendable {
    let lock = NSLock()
    var devices: [NiimbotDevice] = []
}
let seen = Seen()
transport.onDevices = { d in seen.lock.withLock { seen.devices = d } }
print("Looking for NIIMBOT printers…")
transport.startScan()
try await Task.sleep(for: .seconds(8))
transport.stopScan()
let devices = seen.lock.withLock { seen.devices }
if devices.isEmpty { print("None found. Is the printer on, and not connected to the NIIMBOT app or a phone?"); exit(0) }
for d in devices { print("  \(d.name)  \(d.modelName ?? "unknown model")  signal \(d.rssi) dBm  \(d.id)") }

guard info else { exit(0) }
guard let d = devices.first(where: { wanted == nil || $0.name.localizedCaseInsensitiveContains(wanted!) }) else { print("No printer named \(wanted!)."); exit(1) }
print("\nConnecting to \(d.name)…")
let session = NiimbotSession(transport: transport)
do {
    let i = try await session.connect(d.id, name: d.name)
    let m = i.effectiveModel
    print("  Model:        \(i.model?.displayName ?? "unknown") (id \(i.modelId.map(String.init) ?? "?"))")
    print("  Protocol:     \(i.protocolVersion)   print task: \(i.printTask.rawValue)")
    print("  Print head:   \(m.printheadPixels) dots at \(m.dpi) dpi = \(String(format: "%.1f", m.headMM)) mm, feeds \(m.direction == .left ? "sideways" : "top first")")
    if let h = i.head { print("  Reported:     head \(h.printheadWidth) dots, hardware \(h.hardware), firmware \(h.software)") }
    print("  Darkness:     \(m.densityMin)–\(m.densityMax), normally \(m.densityDefault)")
    if let b = i.battery { print("  Battery:      \(b)%") }
    if let t = i.labelType { print("  Label type:   \(t.name)") }
    if let r = i.rfid { print("  Roll tag:     \(r.barCode), \(r.type.name), \(r.remaining.map { "\($0) of \(r.total) left" } ?? "count unknown")") }
    else { print("  Roll tag:     none read") }
    if let s = i.rollSize { print("  Roll size:    \(s.name)") } else { print("  Roll size:    not reported (choose it in the app)") }
    transport.disconnect()
    try await Task.sleep(for: .milliseconds(300))
} catch {
    print("  Failed: \(error.localizedDescription)")
    exit(1)
}
