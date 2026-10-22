import PartsKit
import SwiftUI

/// Look a part number up at Digi-Key and Mouser, and use what they list.
struct SupplierLookupView: View {
    var query: String
    var applyTitle = "Fill in from this"
    var onApply: ((SupplierProduct) -> Void)?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: SupplierLookup.Result?
    @State private var busy = false
    private var keys: SupplierKeys { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if !keys.isConfigured {
                    noKeys
                } else {
                    List {
                        Section {
                            HStack {
                                TextField("Part number", text: $text).onSubmit { Task { await run() } }
                                    .autocorrectionDisabled()
                                Button("Look up") { Task { await run() } }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                            }
                        }
                        if busy { HStack { ProgressView(); Text("Asking \(suppliers)…").foregroundStyle(.secondary) } }
                        if let r = result {
                            ForEach(r.errors.sorted { $0.key < $1.key }, id: \.key) { id, e in
                                Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
                                    .accessibilityLabel("\(Supplier.named(id)?.name ?? id): \(e)")
                            }
                            if r.products.isEmpty && r.errors.isEmpty {
                                Text("Nothing found for “\(text)”.").foregroundStyle(.secondary)
                            }
                            ForEach(r.products) { p in
                                ProductRow(product: p, applyTitle: onApply == nil ? nil : applyTitle) {
                                    onApply?(p); dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Look up online")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .frame(minWidth: 560, minHeight: 560)
        .task {
            text = query
            if keys.isConfigured, !query.trimmingCharacters(in: .whitespaces).isEmpty { await run() }
        }
    }

    var suppliers: String {
        [keys.lookup.digikey != nil ? "Digi-Key" : nil, keys.lookup.mouser != nil ? "Mouser" : nil].compactMap { $0 }.joined(separator: " and ")
    }

    func run() async {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        busy = true
        result = await keys.lookup.lookup(q)
        busy = false
    }

    var noKeys: some View {
        ContentUnavailableView {
            Label("Add supplier keys", systemImage: "key")
        } description: {
            Text("Looking parts up needs a free Digi-Key API client ID and secret, or a Mouser Search API key. Add them in Settings › Supplier lookups.")
        } actions: {
            #if os(macOS)
            SettingsLink { Text("Open Settings") }
            #else
            Button("Open Settings") { dismiss(); app.tab = .settings }
            #endif
        }
    }
}

/// One supplier listing: number, maker, stock, prices, links and parameters.
struct ProductRow: View {
    let product: SupplierProduct
    var applyTitle: String?
    var apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                if let u = URL(string: product.image), !product.image.isEmpty {
                    AsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.1) }
                        .frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(product.supplierName).font(.caption.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(tint.opacity(0.18), in: .capsule).foregroundStyle(tint)
                        Text(product.mpn.isEmpty ? product.spn : product.mpn).font(.headline).textSelection(.enabled)
                    }
                    Text([product.manufacturer, product.description].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !product.spn.isEmpty {
                        Text("\(product.supplierName) \(product.spn)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(stockText).font(.callout.monospacedDigit()).foregroundStyle((product.stock ?? 0) > 0 ? .green : .secondary)
                    if !product.status.isEmpty && product.status != "Active" { Text(product.status).font(.caption).foregroundStyle(.orange) }
                }
            }
            if !product.prices.isEmpty {
                Text(product.prices.prefix(5).map { "\($0.qty)+: \($0.unit.formatted(.currency(code: $0.currency).precision(.significantDigits(1...4))))" }.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
            }
            HStack(spacing: 14) {
                if let applyTitle { Button(applyTitle, action: apply).buttonStyle(.borderedProminent) }
                if let u = URL(string: product.datasheet), !product.datasheet.isEmpty { Link("Datasheet", destination: u) }
                if let u = URL(string: product.url), !product.url.isEmpty { Link("On \(product.supplierName)", destination: u) }
            }
            .font(.callout)
            if !product.parameters.isEmpty {
                DisclosureGroup("Parameters") {
                    ForEach(product.parameters, id: \.self) { p in LabeledContent(p.name, value: p.value).font(.caption) }
                }
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }

    var stockText: String {
        guard let s = product.stock else { return "Stock unknown" }
        return s > 0 ? "\(s.formatted()) in stock" : "None in stock"
    }
    var tint: Color { product.supplier == "digikey" ? .red : .blue }
}
