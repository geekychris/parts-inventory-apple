import Foundation

/// What a storage location is. Stored as its raw value; an empty or unknown value is worked out from the name.
public enum LocationKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cabinet, shelf, drawer, bin, box, other

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    /// The SF Symbol shown beside it.
    public var symbol: String {
        switch self {
        case .cabinet: "cabinet"
        case .shelf: "books.vertical"
        case .drawer: "tray"
        case .bin: "archivebox"
        case .box: "shippingbox"
        case .other: "square.dashed"
        }
    }

    /// What usually goes inside one of these, for "Add inside".
    public var usualChild: LocationKind {
        switch self {
        case .cabinet: .shelf
        case .shelf: .drawer
        case .drawer, .bin, .box, .other: .bin
        }
    }

    /// "Cabinet A" → cabinet, "Shelf 2" → shelf, "Drawer 3" → drawer; nil when the name doesn't say.
    public static func guess(name: String) -> LocationKind? {
        let words = name.lowercased().split(whereSeparator: { !$0.isLetter })
        for w in words {
            switch w {
            case "cabinet", "cupboard", "cab", "rack", "organizer", "organiser": return .cabinet
            case "shelf", "shelves", "rack shelf": return .shelf
            case "drawer", "drawers": return .drawer
            case "bin", "bins", "tray", "compartment", "slot", "cell": return .bin
            case "box", "case", "tub", "crate", "bag": return .box
            default: continue
            }
        }
        return nil
    }

    /// The kind to show: the stored one, else a guess from the name, else drawer for something that holds
    /// other locations and bin for the rest.
    public static func resolve(stored: String, name: String, hasChildren: Bool) -> LocationKind {
        LocationKind(rawValue: stored) ?? guess(name: name) ?? (hasChildren ? .drawer : .bin)
    }

    /// A name for a new one that isn't taken by its siblings: "Shelf 1", "Shelf 2", …
    public func nextName(among siblings: [String]) -> String {
        let taken = Set(siblings.map { $0.lowercased() })
        var n = 1
        while taken.contains("\(label.lowercased()) \(n)") { n += 1 }
        return "\(label) \(n)"
    }
}
