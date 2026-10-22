// Part labels: roll sizes, where things go on a label, and what the QR code opens.

import Foundation

// MARK: - Label sizes

/// A label roll as printed on the box: width × height in mm, the way the label is read.
public struct LabelSize: Identifiable, Hashable, Codable, Sendable {
    public enum Group: String, Codable, Sendable { case small, wide, roll }
    public var id: String
    public var w: Double
    public var h: Double
    public var group: Group

    public init(id: String, w: Double, h: Double, group: Group) { self.id = id; self.w = w; self.h = h; self.group = group }

    public var name: String { "\(Self.mm(w)) × \(Self.mm(h)) mm" }
    static func mm(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    /// The small printers (D11, D110, D101, H1…) feed sideways, so their 12–15 mm side runs across the head;
    /// the wide ones (B1, B21, B3S…) feed top first, so the width does.
    public static let all: [LabelSize] = [
        .init(id: "22x12", w: 22, h: 12, group: .small), .init(id: "26x15", w: 26, h: 15, group: .small),
        .init(id: "30x12", w: 30, h: 12, group: .small), .init(id: "30x14", w: 30, h: 14, group: .small),
        .init(id: "30x15", w: 30, h: 15, group: .small), .init(id: "40x12", w: 40, h: 12, group: .small),
        .init(id: "40x14", w: 40, h: 14, group: .small), .init(id: "50x14", w: 50, h: 14, group: .small),
        .init(id: "50x15", w: 50, h: 15, group: .small),
        .init(id: "25x25", w: 25, h: 25, group: .wide), .init(id: "30x20", w: 30, h: 20, group: .wide),
        .init(id: "40x20", w: 40, h: 20, group: .wide), .init(id: "40x30", w: 40, h: 30, group: .wide),
        .init(id: "50x15w", w: 50, h: 15, group: .wide), .init(id: "50x20", w: 50, h: 20, group: .wide),
        .init(id: "50x25", w: 50, h: 25, group: .wide), .init(id: "50x30", w: 50, h: 30, group: .wide),
        .init(id: "50x40", w: 50, h: 40, group: .wide),
    ]

    public static func named(_ id: String) -> LabelSize? { all.first { $0.id == id } }

    /// The label in dots, as read: `clipped` when it's wider than the head (only the head's width prints).
    public func canvas(_ m: NiimbotModel) -> (w: Int, h: Int, clipped: Bool) {
        func px(_ mm: Double) -> Int { max(8, Int((mm * Double(m.dpi) / 25.4).rounded())) }
        var w = px(self.w), h = px(self.h), clipped = false
        if m.direction == .left { if h > m.printheadPixels { h = m.printheadPixels; clipped = true } }
        else if w > m.printheadPixels { w = m.printheadPixels; clipped = true }
        return (w, h, clipped)
    }

    /// Whether the side that runs across the head fits it.
    public func fits(_ m: NiimbotModel) -> Bool {
        let across = m.direction == .left ? h : w
        return across * Double(m.dpi) / 25.4 <= Double(m.printheadPixels) * 1.05
    }

    /// The loaded roll from the printer's paper info (mm across the head and along the feed).
    public static func fromPaper(_ p: NiimbotReplies.Paper, model m: NiimbotModel) -> LabelSize? {
        let a = p.widthMM, b = p.heightMM
        guard (5...120).contains(a), (5...200).contains(b) else { return nil }
        let (w, h) = m.direction == .left ? (b, a) : (a, b)
        return LabelSize(id: "roll", w: w, h: h, group: .roll)
    }

    /// A sensible size for a printer that hasn't said what's loaded.
    public static func usual(for m: NiimbotModel) -> LabelSize {
        m.direction == .left ? named("30x12")! : (m.headMM >= 49 ? named("50x30")! : named("40x30")!)
    }
}

// MARK: - Layout

public enum LabelTemplate: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Just the description, as big as it fits.
    case text
    /// The part's icon, its number and a short description.
    case iconText
    /// The same with a QR code.
    case iconTextQR

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .text: "Description only"
        case .iconText: "Icon, number and description"
        case .iconTextQR: "Icon, number, description and QR code"
        }
    }
}

/// What goes on a label.
public struct LabelContent: Equatable, Sendable {
    /// Bold first line: the part number.
    public var title: String
    /// The description.
    public var subtitle: String
    /// More lines if there's room (parameters, location).
    public var lines: [String]
    /// An SF Symbol for the kind of part.
    public var icon: String?
    /// The QR code's address.
    public var link: String?

    public init(title: String, subtitle: String = "", lines: [String] = [], icon: String? = nil, link: String? = nil) {
        self.title = title; self.subtitle = subtitle; self.lines = lines; self.icon = icon; self.link = link
    }
}

/// Where everything goes, in whole dots so it prints crisp on a 1-bit head.
public struct LabelPlan: Equatable, Sendable {
    public struct Box: Equatable, Sendable { public var x, y, w, h: Int }
    public struct TextRow: Equatable, Sendable { public var text: String; public var x, y, px: Int; public var bold: Bool }
    public struct QR: Equatable, Sendable { public var x, y, module, size: Int }
    public var width: Int
    public var height: Int
    public var icon: Box?
    public var qr: QR?
    public var texts: [TextRow]
    public var warnings: [String]
}

public enum LabelLayout {
    /// Text width in dots for a string at a font size in dots.
    public typealias Measure = (_ text: String, _ px: Int, _ bold: Bool) -> Double

    /// Lay out a label `w`×`h` dots. Small labels (≤ 15 mm high) get one or two lines and lose the icon or QR
    /// code when they won't fit legibly; bigger ones get an icon, a QR code and three or four lines.
    public static func plan(w: Int, h: Int, dpi: Int, template: LabelTemplate, content c: LabelContent, qrModules: Int,
                            measure: Measure) -> LabelPlan {
        var warn: [String] = []
        let m = max(2, Int((Double(min(w, h)) * 0.05).rounded()))
        let small = Double(h) * 25.4 / Double(dpi) <= 15.5
        let minPx = max(9, Int((1.1 * Double(dpi) / 25.4).rounded()))
        let minModule = max(2, Int((0.24 * Double(dpi) / 25.4).rounded(.up)))
        var right = w - m, left = m

        // The QR code on the right, if it can be scanned and leaves room for words.
        var qr: LabelPlan.QR?
        if template == .iconTextQR {
            if let link = c.link, !link.isEmpty, qrModules > 0 {
                let room = min(h - 2 * m, Int(Double(w) * (small ? 0.45 : 0.36)))
                var mod = room / (qrModules + 2)          // a module of quiet zone each side…
                if mod < minModule { mod = room / qrModules } // …or let the label's margin be the quiet zone
                if mod < minModule {
                    warn.append(small ? "The QR code won’t fit legibly on a label this small, so it’s left off." :
                                        "The QR code is too dense for this label, so it’s left off — a shorter link would fit.")
                } else {
                    let size = mod * qrModules
                    if Double(w - size - 3 * m) < Double(w) * 0.3 {
                        warn.append("There’s no room for the QR code beside the text, so it’s left off.")
                    } else {
                        qr = .init(x: w - m - size, y: (h - size) / 2, module: mod, size: size)
                        right = w - m - size - m
                    }
                }
            } else {
                warn.append("No QR code: there’s no link for it.")
            }
        }

        // The icon on the left, when it leaves the text enough room.
        var icon: LabelPlan.Box?
        if template != .text, c.icon != nil {
            let size = small ? h - 2 * m : min(h - 2 * m, Int(Double(w) * 0.18), Int(Double(h) * 0.5))
            let textAfter = right - (left + size + m)
            if size >= 24 && Double(textAfter) >= max(Double(w) * 0.35, 60) {
                icon = .init(x: left, y: (h - size) / 2, w: size, h: size)
                left += size + m
            }
        }

        let tw = right - left, th = h - 2 * m
        var texts: [LabelPlan.TextRow] = []
        guard tw >= 12 else { return LabelPlan(width: w, height: h, icon: icon, qr: qr, texts: [], warnings: warn + ["There’s no room for text."]) }

        func lh(_ px: Int) -> Int { Int((Double(px) * 1.12).rounded()) }
        func clip(_ t: String, _ px: Int, _ bold: Bool) -> String {
            if measure(t, px, bold) <= Double(tw) { return t }
            var s = t
            while s.count > 1 && measure(s + "…", px, bold) > Double(tw) { s.removeLast() }
            return s.trimmingCharacters(in: .whitespaces) + "…"
        }
        func wrap(_ t: String, _ px: Int, _ bold: Bool = false) -> [String] {
            var out: [String] = [], cur = ""
            for word in t.split(whereSeparator: \.isWhitespace).map(String.init) {
                let next = cur.isEmpty ? word : cur + " " + word
                if measure(next, px, bold) <= Double(tw) || cur.isEmpty { cur = next } else { out.append(cur); cur = word }
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }

        var rows: [(text: String, px: Int, bold: Bool)] = []
        if template == .text {
            // Description only: the biggest size at which it wraps into the height.
            let body = [c.subtitle, c.title].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            var px = min(th, Int(Double(h) * 0.6))
            while px > minPx {
                let ws = wrap(body, px, true)
                if ws.count * lh(px) <= th && ws.allSatisfy({ measure($0, px, true) <= Double(tw) }) { break }
                px -= 1
            }
            let ws = wrap(body, px, true)
            let fit = max(1, th / lh(px))
            for (i, s) in ws.prefix(fit).enumerated() {
                let last = i == fit - 1 && ws.count > fit
                rows.append((clip(last ? s + "…" : s, px, true), px, true))
            }
        } else {
            let subs = ([c.subtitle] + c.lines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let title = c.title
            // Sizes from the height first: a title and room for up to two lines under it (three on big labels)…
            var base = max(minPx, Int(min(Double(th) * (subs.isEmpty ? 0.6 : 0.4), Double(h) * 0.36).rounded()))
            func subPx(_ t: Int) -> Int { max(minPx, min(Int((Double(t) * 0.72).rounded()), Int((Double(th) * 0.26).rounded()))) }
            let want = min(small ? 2 : 3, subs.count)
            while base > minPx + 3 && (title.isEmpty ? 0 : lh(base)) + want * lh(subPx(base)) > th { base -= 1 }
            // …then the title shrinks to fit its width; a long part number doesn't shrink the description below it.
            var tpx = base
            while tpx > minPx && measure(title, tpx, true) > Double(tw) { tpx -= 1 }
            if !title.isEmpty { rows.append((clip(title, tpx, true), tpx, true)) }
            let spx = title.isEmpty ? subPx(base) : min(subPx(base), max(tpx, minPx))
            var used = title.isEmpty ? 0 : lh(tpx)
            let maxRows = small ? 3 : 5
            outer: for s in subs {
                for line in wrap(s, spx) {
                    if used + lh(spx) > th || rows.count >= maxRows {
                        if let last = rows.last, !last.bold, !last.text.hasSuffix("…") {
                            rows[rows.count - 1].text = clip(last.text + "…", spx, false)
                        }
                        break outer
                    }
                    rows.append((clip(line, spx, false), spx, false))
                    used += lh(spx)
                }
            }
        }

        let used = rows.reduce(0) { $0 + lh($1.px) }
        var y = m + max(0, (th - used) / 2)
        for r in rows {
            texts.append(.init(text: r.text, x: left, y: y, px: r.px, bold: r.bold))
            y += lh(r.px)
        }
        if rows.first.map({ $0.px <= minPx }) == true && small { warn.append("The text is at its smallest — a bigger label would be easier to read.") }
        return LabelPlan(width: w, height: h, icon: icon, qr: qr, texts: texts, warnings: warn)
    }
}

// MARK: - What the QR code opens

/// What a label's QR code can point at. New targets (a public inventory, a wiki…) are one more provider.
public protocol LabelLinkProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var detail: String { get }
    func url(for part: LabelLinkContext, settings: LabelLinkSettings) -> String?
}

/// The part as far as links go.
public struct LabelLinkContext: Sendable {
    public var uid: String
    public var mpn: String
    public var manufacturer: String
    public var category: String
    public var datasheet: String
    public var supplierPages: [String]
    public init(uid: String, mpn: String, manufacturer: String = "", category: String = "", datasheet: String = "", supplierPages: [String] = []) {
        self.uid = uid; self.mpn = mpn; self.manufacturer = manufacturer; self.category = category
        self.datasheet = datasheet; self.supplierPages = supplierPages
    }
}

public struct LabelLinkSettings: Sendable {
    /// For the public inventory page, e.g. `https://example.com/parts/{uid}/` — {uid}, {mpn}, {manufacturer}, {category}.
    public var publicURLTemplate: String
    public init(publicURLTemplate: String = "") { self.publicURLTemplate = publicURLTemplate }
}

public enum LabelLinks {
    public static let all: [any LabelLinkProvider] = [Datasheet(), PublicPage(), None()]
    public static func provider(_ id: String) -> any LabelLinkProvider { all.first { $0.id == id } ?? Datasheet() }

    static func web(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: t), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https", u.host != nil else { return nil }
        return t
    }

    /// The datasheet, else a supplier's page for the part, else nothing.
    public struct Datasheet: LabelLinkProvider {
        public var id: String { "datasheet" }
        public var name: String { "Datasheet" }
        public var detail: String { "The part’s datasheet, or a supplier’s page for it when there’s no datasheet." }
        public func url(for p: LabelLinkContext, settings: LabelLinkSettings) -> String? {
            web(p.datasheet) ?? p.supplierPages.lazy.compactMap(web).first
        }
    }

    /// The part's page in a published inventory, from a URL template.
    public struct PublicPage: LabelLinkProvider {
        public var id: String { "public" }
        public var name: String { "Public inventory page" }
        public var detail: String { "The part’s page where the inventory is published, from the address template: {uid}, {mpn}, {manufacturer}, {category}." }
        public func url(for p: LabelLinkContext, settings: LabelLinkSettings) -> String? {
            let t = settings.publicURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/?#&=+")
            func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
            let filled = t.replacingOccurrences(of: "{uid}", with: enc(p.uid))
                .replacingOccurrences(of: "{mpn}", with: enc(p.mpn))
                .replacingOccurrences(of: "{manufacturer}", with: enc(p.manufacturer))
                .replacingOccurrences(of: "{category}", with: enc(p.category))
            return web(filled)
        }
    }

    public struct None: LabelLinkProvider {
        public var id: String { "none" }
        public var name: String { "No QR code" }
        public var detail: String { "Labels without a QR code." }
        public func url(for p: LabelLinkContext, settings: LabelLinkSettings) -> String? { nil }
    }
}
