import PartsKit
import SwiftUI

/// Settings › Label printer.
struct LabelPrinterSection: View {
    @State private var printer = LabelPrinter.shared
    @State private var choosing = false
    @State private var testing = false
    @AppStorage(LabelPrinter.Key.size) private var size = "auto"
    @AppStorage(LabelPrinter.Key.template) private var template = LabelTemplate.iconTextQR
    @AppStorage(LabelPrinter.Key.link) private var link = "datasheet"
    @AppStorage(LabelPrinter.Key.urlTemplate) private var urlTemplate = ""
    @AppStorage(LabelPrinter.Key.showLocation) private var showLocation = true
    @AppStorage(LabelPrinter.Key.printOnAdd) private var printOnAdd = false
    @AppStorage(LabelPrinter.Key.density) private var density = 0

    var body: some View {
        Section {
            PrinterStatusRow(choosing: $choosing)
            if let i = printer.info {
                let m = i.effectiveModel
                LabeledContent("Print head", value: "\(String(format: "%.0f", m.headMM)) mm at \(m.dpi) dpi, \(m.direction == .left ? "labels feed sideways" : "labels feed top first")")
                LabeledContent("Loaded", value: rollText(i))
            }
            LabelSizePicker(selection: $size)
            Picker("Darkness", selection: $density) {
                Text("Normal (\(printer.model.densityDefault))").tag(0)
                ForEach(printer.model.densityMin...printer.model.densityMax, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Label layout", selection: $template) {
                ForEach(LabelTemplate.allCases) { Text($0.name).tag($0) }
            }
            Picker("QR code opens", selection: $link) {
                ForEach(LabelLinks.all, id: \.id) { Text($0.name).tag($0.id) }
            }
            if link == "public" {
                TextField("Address, e.g. https://example.com/parts/{uid}/", text: $urlTemplate).autocorrectionDisabled()
                #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                #endif
            }
            Toggle("Show the location on labels", isOn: $showLocation)
            Toggle("Print a label when a part is added", isOn: $printOnAdd)
            if printer.isConnected {
                Button(testing ? "Printing…" : "Print a test label") {
                    testing = true
                    Task {
                        try? await printer.print([LabelContent(title: "LM358DR", subtitle: "Dual op-amp, SOIC-8", lines: ["Test label"], icon: "cpu",
                                                               link: "https://geekychris.github.io/tools/parts-inventory/")])
                        testing = false
                    }
                }.disabled(testing || printer.isBusy)
            }
            if let m = printer.lastMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
        } header: { Text("Label printer") } footer: {
            Text(LabelLinks.provider(link).detail + " Small printers (D11, D110, D101, H1) print 12–15 mm labels; the B1, B21 and B3S print up to 50 mm wide.")
        }
        .sheet(isPresented: $choosing) { PrinterPicker() }
    }

    func rollText(_ i: NiimbotSession.Info) -> String {
        var parts: [String] = []
        if let s = i.rollSize { parts.append(s.name) }
        if let t = i.rfid?.type ?? i.labelType, t != .invalid { parts.append(t.name) }
        if let left = i.rfid?.remaining { parts.append("\(left) left") }
        return parts.isEmpty ? "Not reported — choose the label size below" : parts.joined(separator: " · ")
    }
}

/// The printer's state, with Connect / Disconnect.
struct PrinterStatusRow: View {
    @Binding var choosing: Bool
    @State private var printer = LabelPrinter.shared

    var body: some View {
        HStack {
            Image(systemName: "printer").foregroundStyle(printer.isConnected ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                if let d = detail { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if case .connecting = printer.status { ProgressView().controlSize(.small) }
            if printer.isConnected {
                Button("Disconnect") { printer.disconnect() }
            } else {
                if printer.knownPrinterName != nil {
                    Button("Connect") { Task { await printer.reconnect() } }.disabled(printer.isBusy)
                }
                Button(printer.knownPrinterName == nil ? "Connect…" : "Other…") { choosing = true }.disabled(printer.isBusy)
            }
        }
    }

    var title: String {
        switch printer.status {
        case .connected, .printing: printer.info.map { "\($0.model?.displayName ?? $0.deviceName) connected" } ?? "Connected"
        case .connecting(let n): "Connecting to \(n)…"
        case .scanning, .idle: printer.knownPrinterName.map { "\($0) — not connected" } ?? "No printer"
        case .failed: "Not connected"
        }
    }

    var detail: String? {
        switch printer.status {
        case .failed(let e): e
        case .printing(let d, let n): "Printing \(min(d + 1, n)) of \(n)…"
        default: printer.battery.map { "Battery \($0)%" }
        }
    }
}

/// Nearby NIIMBOT printers.
struct PrinterPicker: View {
    @State private var printer = LabelPrinter.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if case .failed(let e) = printer.status { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if printer.devices.isEmpty {
                    HStack { ProgressView(); Text("Looking for printers… Turn the printer on; it can’t be connected to the NIIMBOT app at the same time.") }
                        .foregroundStyle(.secondary)
                }
                ForEach(printer.devices) { d in
                    Button {
                        Task { await printer.connect(d); if printer.isConnected { dismiss() } }
                    } label: {
                        HStack {
                            Image(systemName: "printer")
                            VStack(alignment: .leading) {
                                Text(d.name)
                                Text(d.modelName.flatMap(NiimbotModel.named).map { "\($0.displayName) · \(String(format: "%.0f", $0.headMM)) mm head" } ?? "Unknown model")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if case .connecting(let n) = printer.status, n == d.name { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(printer.isBusy)
                }
            }
            .navigationTitle("Choose a printer")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { printer.startScan() }
        .onDisappear { printer.stopScan() }
    }
}

/// Label sizes: what's loaded, then the sizes that fit this printer, then the rest.
struct LabelSizePicker: View {
    @Binding var selection: String
    var title = "Label size"
    @State private var printer = LabelPrinter.shared

    var body: some View {
        let m = printer.model
        Picker(title, selection: $selection) {
            Text(printer.info?.rollSize.map { "Loaded roll (\($0.name))" } ?? "Automatic (\(LabelSize.usual(for: m).name))").tag("auto")
            Section("Fits the \(m.displayName)") {
                ForEach(LabelSize.all.filter { $0.fits(m) }) { Text($0.name).tag($0.id) }
            }
            Section("Wider than its head") {
                ForEach(LabelSize.all.filter { !$0.fits(m) }) { Text($0.name).tag($0.id) }
            }
        }
    }
}

/// Print one or more parts' labels, with a preview of exactly what prints.
struct LabelPrintSheet: View {
    let parts: [Part]
    @State private var printer = LabelPrinter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var template = LabelPrinter.shared.template
    @State private var size = UserDefaults.standard.string(forKey: LabelPrinter.Key.size) ?? "auto"
    @State private var link = UserDefaults.standard.string(forKey: LabelPrinter.Key.link) ?? "datasheet"
    @State private var copies = 1
    @State private var choosing = false
    @State private var error: String?
    @State private var printing = false

    var current: Part? { parts.indices.contains(index) ? parts[index] : parts.first }

    var body: some View {
        NavigationStack {
            Form {
                Section { PrinterStatusRow(choosing: $choosing) }
                if let p = current {
                    let size = printer.labelSize(self.size)
                    let r = printer.render(content(p), template: template, size: size)
                    Section {
                        LabelPreview(result: r, size: size, clipped: size.canvas(printer.model).clipped)
                        if parts.count > 1 {
                            HStack {
                                Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                                Spacer()
                                Text("\(index + 1) of \(parts.count): \(p.title)").font(.callout)
                                Spacer()
                                Button { index = min(parts.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }.disabled(index >= parts.count - 1)
                            }.buttonStyle(.borderless)
                        }
                        ForEach(r.plan.warnings, id: \.self) { Label($0, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary) }
                        if size.canvas(printer.model).clipped {
                            Label("This label is wider than the \(printer.model.displayName)’s print head; only \(String(format: "%.0f", printer.model.headMM)) mm of it prints.",
                                  systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                Section {
                    Picker("Layout", selection: $template) { ForEach(LabelTemplate.allCases) { Text($0.name).tag($0) } }
                    LabelSizePicker(selection: $size)
                    if template == .iconTextQR {
                        Picker("QR code opens", selection: $link) { ForEach(LabelLinks.all, id: \.id) { Text($0.name).tag($0.id) } }
                    }
                    Stepper("Copies of each: \(copies)", value: $copies, in: 1...50)
                }
                if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            .formStyle(.grouped)
            .navigationTitle(parts.count == 1 ? "Print label" : "Print \(parts.count) labels")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(printing ? "Printing…" : "Print") { Task { await go() } }
                        .disabled(!printer.isConnected || printing || parts.isEmpty)
                }
            }
            .sheet(isPresented: $choosing) { PrinterPicker() }
        }
        .frame(minWidth: 480, minHeight: 560)
        .task { await printer.reconnect() }
    }

    /// The part's label with this sheet's choice of QR target.
    func content(_ p: Part) -> LabelContent {
        var c = printer.content(for: p)
        c.link = printer.link(for: p, provider: LabelLinks.provider(link))
        return c
    }

    func go() async {
        printing = true
        error = nil
        let labels = parts.map(content)
        do {
            try await printer.print(labels, copies: copies, template: template, size: printer.labelSize(size))
            dismiss()
        } catch { self.error = error.localizedDescription }
        printing = false
    }
}

/// The label's dots, enlarged, on a label-coloured card.
struct LabelPreview: View {
    let result: LabelRenderer.Result
    let size: LabelSize
    var clipped = false

    var body: some View {
        VStack(spacing: 6) {
            if let img = LabelRenderer.image(result.bitmap) {
                Image(decorative: img, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(CGFloat(result.bitmap.width) / CGFloat(result.bitmap.height), contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: 260)
                    .padding(6)
                    .background(.white, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4)))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Label preview")
            }
            Text("\(size.name) · \(result.bitmap.width) × \(result.bitmap.height) dots").font(.caption).foregroundStyle(.secondary)
        }
    }
}
