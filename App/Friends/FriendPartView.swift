import PartsKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A part in a friend's inventory: read-only, with a request to borrow some to copy into a message.
struct FriendPartView: View {
    let row: InventoryRow
    @State private var qty = 1
    @State private var copied = false
    private let friends = FriendsStore.shared

    var fetched: Date? { friends.friends.first { $0.name == row.source }.flatMap { friends.status[$0.id]?.fetched } }

    var body: some View {
        Form {
            Section {
                LabeledContent("In stock") {
                    Text("\(row.qty)").monospacedDigit().foregroundStyle(row.qty == 0 ? .secondary : row.isLow ? Color.red : .primary)
                }
                if !row.location.isEmpty { LabeledContent("Location", value: row.location) }
            } footer: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From \(row.source)’s inventory.")
                    if let fetched { Text("Fetched \(fetched, format: .relative(presentation: .named)); part updated \(row.updated, format: .dateTime.day().month().year()).") }
                }
            }
            Section("Part") {
                if !row.mpn.isEmpty { LabeledContent("Part number", value: row.mpn) }
                if !row.manufacturer.isEmpty { LabeledContent("Manufacturer", value: row.manufacturer) }
                if !row.description.isEmpty { LabeledContent("Description") { Text(row.description).multilineTextAlignment(.trailing) } }
                if !row.categoryPath.isEmpty { LabeledContent("Category", value: row.categoryPath.joined(separator: " › ")) }
                if !row.value.isEmpty { LabeledContent("Value", value: row.value) }
                if !row.package.isEmpty { LabeledContent("Package", value: row.package) }
                if !row.tags.isEmpty { LabeledContent("Tags", value: row.tags.joined(separator: ", ")) }
                if !row.notes.isEmpty { LabeledContent("Notes") { Text(row.notes).multilineTextAlignment(.trailing) } }
            }
            if datasheet != nil || !row.suppliers.isEmpty {
                Section("Datasheet and suppliers") {
                    if let datasheet { Link(destination: datasheet) { Label("Open the datasheet", systemImage: "doc.richtext") } }
                    ForEach(Array(row.suppliers.enumerated()), id: \.offset) { _, s in
                        LabeledContent(Supplier.named(s.supplier)?.name ?? s.supplier) {
                            if let u = URL(string: s.url), !s.url.isEmpty { Link(s.pn, destination: u) }
                            else if let u = Supplier.named(s.supplier)?.search(s.pn) { Link(s.pn, destination: u) } else { Text(s.pn) }
                        }
                    }
                }
            }
            Section {
                Stepper("Borrow \(qty)", value: $qty, in: 1...max(1, row.qty))
                Text(row.borrowRequest(qty)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Button { copy(row.borrowRequest(qty)) } label: {
                    Label(copied ? "Copied" : "Copy request", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
            } header: { Text("Ask to borrow") } footer: {
                Text("Copies a short message to paste into a text or email to \(row.source).")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(row.title)
    }

    var datasheet: URL? { URL(string: row.datasheet).flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil } }

    func copy(_ s: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = s
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #endif
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }
}
