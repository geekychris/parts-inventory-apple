import PartsKit
import SwiftUI

/// The facets beside the table: each with its values and how many parts each would show. Category and
/// location are trees; long lists show the first few with "Show all".
struct FacetColumn: View {
    let model: InventoryTableModel
    var showsSource: Bool
    var manageFriends: () -> Void
    @State private var expanded: Set<String> = []
    @State private var showAll: Set<FacetKind> = []
    static let topN = 8

    var kinds: [FacetKind] {
        FacetKind.allCases.filter { f in
            if f == .source { return showsSource }
            // A facet with a single value can't narrow anything (unless it's chosen, or a tree with branches).
            let nodes = model.facets[f] ?? []
            return model.filter.selected[f] != nil || nodes.reduce(0) { $0 + $1.size } > 1
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(kinds, id: \.self) { f in section(f) }
                if !showsSource {
                    Button("Add a friend’s inventory…", action: manageFriends).buttonStyle(.borderless).font(.callout)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.automatic)
    }

    @ViewBuilder func section(_ f: FacetKind) -> some View {
        let nodes = model.facets[f] ?? []
        let all = showAll.contains(f)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(f.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if model.filter.selected[f] != nil {
                    Button("Clear") { model.filter.selected[f] = nil }.buttonStyle(.borderless).font(.caption)
                }
                if f == .source {
                    Button("Friends…", action: manageFriends).buttonStyle(.borderless).font(.caption)
                }
            }
            ForEach(all ? nodes : Array(nodes.prefix(Self.topN))) { n in tree(f, n, depth: 0) }
            if nodes.count > Self.topN {
                Button(all ? "Show fewer" : "Show all \(nodes.count)") {
                    if all { showAll.remove(f) } else { showAll.insert(f) }
                }
                .buttonStyle(.borderless).font(.caption).padding(.leading, 22)
            }
        }
    }

    func tree(_ f: FacetKind, _ n: FacetNode, depth: Int) -> AnyView {
        let key = f.rawValue + "\u{1F}" + n.key
        let open = expanded.contains(key) || containsChosen(f, n)
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            value(f, n, depth: depth, open: open, toggleOpen: n.children.isEmpty ? nil : {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            })
            if open {
                ForEach(n.children) { c in tree(f, c, depth: depth + 1) }
            }
        })
    }

    /// Keep a branch open while something under it is chosen.
    func containsChosen(_ f: FacetKind, _ n: FacetNode) -> Bool {
        guard !n.children.isEmpty, let s = model.filter.selected[f] else { return false }
        return s.contains { $0.hasPrefix(n.key + FacetKind.separator) }
    }

    func value(_ f: FacetKind, _ n: FacetNode, depth: Int, open: Bool, toggleOpen: (() -> Void)?) -> some View {
        let on = model.filter.contains(f, n.key)
        return HStack(spacing: 4) {
            Group {
                if let toggleOpen {
                    Button(action: toggleOpen) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0))
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 14, height: 14).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "Collapse \(n.label)" : "Expand \(n.label)")
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            Button { model.filter.toggle(f, n.key) } label: {
                HStack(spacing: 6) {
                    Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
                    Text(n.label).lineLimit(1).truncationMode(.middle).italic(n.key.isEmpty && f != .source)
                    Spacer(minLength: 4)
                    Text(n.count, format: .number).monospacedDigit().foregroundStyle(.secondary).font(.callout)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(n.count == 0 && !on ? 0.45 : 1)
            .help(f.isTree ? n.key : n.label)
            .accessibilityLabel("\(n.label), \(n.count) parts")
            .accessibilityAddTraits(on ? .isSelected : [])
        }
        .font(.callout)
    }
}

/// The chosen facet values as chips, each removable, with Clear all.
struct FilterChips: View {
    let model: InventoryTableModel

    var body: some View {
        if !model.filter.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.filter.chips, id: \.id) { c in
                        Button { model.filter.remove(c.facet, c.key) } label: {
                            HStack(spacing: 4) {
                                Text(c.facet.title + ":").foregroundStyle(.secondary)
                                Text(c.facet.label(c.key)).lineLimit(1)
                                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(c.facet.title) \(c.facet.label(c.key))")
                    }
                    Button("Clear all") { model.filter.clear() }.buttonStyle(.borderless).font(.callout)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .background(.bar)
        }
    }
}
