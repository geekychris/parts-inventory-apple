import Foundation
import FoundationModels
import PartsKit

/// Whether the on-device Apple Intelligence model can be used, in words.
nonisolated enum AppleIntelligence {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var status: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Ready"
        case .unavailable(.deviceNotEligible): "This device doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled): "Turn on Apple Intelligence in Settings to use it here"
        case .unavailable(.modelNotReady): "Apple Intelligence is still downloading"
        case .unavailable: "Apple Intelligence isn't available"
        }
    }
}

/// What Apple Intelligence makes of a part's markings.
@Generable(description: "An electronic component identified from the text printed on it")
nonisolated struct MarkingReading {
    @Guide(description: "The manufacturer part number as printed, with obvious OCR errors fixed (O↔0, I↔1, S↔5, B↔8). Empty if no part number is printed. Never a date code, lot code or a 4-digit number alone.")
    var partNumber: String
    @Guide(description: "The manufacturer, if printed or certain from a logo word (e.g. TI, ST, Microchip). Empty if unsure.")
    var manufacturer: String
    @Guide(description: "A short plain description of what the part is, e.g. 'Dual operational amplifier' or '3.3 V LDO regulator'. Empty if unknown.")
    var description: String
    @Guide(description: "The category of the part", .anyOf(PartReader.categories))
    var category: String
    @Guide(description: "The package if it can be told from the markings or the description (DIP-8, SOIC-8, TO-220…). Empty if unknown.")
    var package: String
    @Guide(description: "How sure the identification is, from 0 (a guess) to 1 (certain)", .range(0...1))
    var confidence: Double
}

/// Reads the OCR text of a part's markings with the on-device language model and returns a
/// candidate. The model can't see the photo — it reasons about the text Vision read, plus Vision's
/// general labels. Its reading is only trusted (scored higher) when the part number it gives is
/// actually in the text.
nonisolated enum PartReader {
    static let categories = ["ICs", "ICs/Microcontrollers", "ICs/Power", "ICs/Analog", "ICs/Logic", "ICs/Memory", "ICs/Interface", "ICs/Sensors",
                             "Passives/Resistors", "Passives/Capacitors", "Passives/Inductors", "Passives/Crystals", "Passives/Potentiometers",
                             "Semiconductors/Diodes", "Semiconductors/Transistors", "Optoelectronics/LEDs", "Optoelectronics/Displays",
                             "Electromechanical/Connectors", "Electromechanical/Switches", "Electromechanical/Relays", "Electromechanical/Motors",
                             "Modules", "Modules/Wireless", "Modules/Sensors", "Boards", "Other"]

    static let instructions = """
    You identify electronic components from the text printed on them, as read by OCR from a photo. \
    The text may contain OCR errors, the manufacturer's logo name, date codes (like 2209 or 1932) and lot codes. \
    Use only what is printed and well-known marking conventions. If the part number is not readable, leave it empty \
    rather than guessing one. Keep descriptions short and factual.
    """

    static func read(ocrText: String, imageLabels: [String]) async throws -> Candidate? {
        let text = ocrText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppleIntelligence.isAvailable, !text.isEmpty else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        var prompt = "Text read from the component:\n\(text)"
        if !imageLabels.isEmpty { prompt += "\n\nThe photo looks like: \(imageLabels.joined(separator: ", "))." }
        let r = try await session.respond(to: prompt, generating: MarkingReading.self, options: GenerationOptions(temperature: 0))
        let g = r.content
        guard !g.partNumber.isEmpty || !g.description.isEmpty else { return nil }
        // The part number must be in what was read (allowing for OCR look-alikes) to be trusted.
        let toks = Identify.tokens(Identify.words(text))
        let printed = !g.partNumber.isEmpty && toks.contains { (Identify.markScore($0.text, g.partNumber)?.score ?? 0) >= 0.6 }
        let score = printed ? min(0.8, 0.5 + 0.3 * g.confidence) : min(0.4, 0.2 + 0.2 * g.confidence)
        let reading = PartReading(mpn: g.partNumber, manufacturer: g.manufacturer, description: g.description, category: g.category == "Other" ? "" : g.category, package: g.package)
        let what = [g.partNumber, g.description].filter { !$0.isEmpty }.joined(separator: " — ")
        let reason = printed ? "Apple Intelligence read the markings as \(what)" : "Apple Intelligence suggests \(what) (the number isn't in the text read, so check it)"
        return Candidate(id: "a:" + Identify.squash(g.partNumber + g.description), source: .reading(reading), score: score, reasons: [reason])
    }
}

// ---------------------------------------------------------------- asking about the inventory

/// A part, as the assistant sees it.
nonisolated struct PartSnapshot: Sendable {
    var mpn, manufacturer, description, category, location, params: String
    var qty: Int
    var line: String {
        [mpn.isEmpty ? description : "\(mpn) — \(description)", manufacturer, params, category, "qty \(qty)", location.isEmpty ? "" : "in \(location)"]
            .filter { !$0.isEmpty }.joined(separator: "; ")
    }
}

/// Lets the model search the inventory with the same parametric search as the app ("10k 0603").
nonisolated struct SearchInventoryTool: Tool {
    let name = "searchInventory"
    let description = "Search the user's electronic parts inventory. Supports part numbers, words, values with units (10k, 100nF, 3.3V), packages (0603, SOIC-8), and filters cat:<category>, loc:<location>, low (low stock). Returns matching parts with quantity and location."

    @Generable
    struct Arguments {
        @Guide(description: "A search, e.g. '10k 0603', 'lm358', 'cat:capacitors 16V', 'esp32', or '' for everything")
        var query: String
    }

    let parts: [PartSnapshot]
    let index: [@Sendable (PartQuery) -> Bool]

    func call(arguments: Arguments) async throws -> String {
        let q = PartQuery(arguments.query)
        let hits = zip(parts, index).filter { $0.1(q) }.map(\.0)
        if hits.isEmpty { return "No parts match “\(arguments.query)”." }
        let shown = hits.prefix(25).map(\.line).joined(separator: "\n")
        return hits.count > 25 ? shown + "\n…and \(hits.count - 25) more." : shown
    }
}

/// A conversation about the inventory: "Do I have a 3.3 V regulator?", "What's in drawer 3?".
@MainActor
final class InventoryAssistant {
    private var session: LanguageModelSession

    init(parts: [Part]) {
        let snaps = parts.map { p in
            PartSnapshot(mpn: p.mpn, manufacturer: p.manufacturer, description: p.partDescription, category: p.categoryLabel,
                         location: p.location?.path ?? "", params: p.paramsSummary, qty: p.qty)
        }
        let matchers: [@Sendable (PartQuery) -> Bool] = parts.map { p in
            let params = p.params.withPackage(p.package), hay = p.searchText, cat = p.category.lowercased(), loc = (p.location?.path ?? "").lowercased()
            let low = p.isLow(defaultLimit: 0)
            return { q in
                (!q.hasParams || q.matches(params)) && q.text.allSatisfy(hay.contains)
                    && (q.category.map(cat.contains) ?? true) && (q.location.map(loc.contains) ?? true) && (!q.lowOnly || low)
            }
        }
        let tool = SearchInventoryTool(parts: snaps, index: matchers)
        session = LanguageModelSession(tools: [tool], instructions: """
        You help someone find electronic parts in their own inventory. Always use the searchInventory tool to look things up — \
        try a few searches (part number, value with unit, a category) before saying something isn't there. \
        Answer briefly with part numbers, quantities and where they are stored. Never invent parts.
        """)
    }

    func ask(_ question: String) async throws -> String {
        try await session.respond(to: question).content
    }
}
