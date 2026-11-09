import Foundation
import PartsKit

/// The inventory on disk for `partsd`: the web tool's backup file (`inventory.json`, without photos) and the
/// photos beside it as files (`photos/<id>`, indexed by `photos.json`). The same format the app imports and
/// exports, so moving an inventory between the app and a server is an export and an import.
struct InventoryStore {
    struct PhotoRecord: Codable, Sendable {
        var id: String
        var partId: String?
        var locationId: String?
        var type: String
        var name: String
        var created: Double
    }

    let dir: URL
    var inventory: URL { dir.appendingPathComponent("inventory.json") }
    var photoIndex: URL { dir.appendingPathComponent("photos.json") }
    var photoDir: URL { dir.appendingPathComponent("photos", isDirectory: true) }

    init(dir: URL) throws {
        self.dir = dir
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("photos", isDirectory: true), withIntermediateDirectories: true)
    }

    /// The saved inventory, or an empty one the first time.
    func load() throws -> (Backup, [PhotoRecord]) {
        var b = Backup()
        if FileManager.default.fileExists(atPath: inventory.path) {
            b = try Backup.read(try Data(contentsOf: inventory)).backup
        }
        let photos = (try? JSONDecoder().decode([PhotoRecord].self, from: Data(contentsOf: photoIndex))) ?? []
        return (b, photos)
    }

    func save(_ b: Backup, photos: [PhotoRecord]) throws {
        var b = b
        b.photos = nil
        b.exportedAt = ISO8601DateFormatter().string(from: .now)
        b.app = "partsd"
        try b.encoded().write(to: inventory, options: .atomic)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        try e.encode(photos).write(to: photoIndex, options: .atomic)
    }

    func photoURL(_ id: String) -> URL {
        // Ids come from backups too: keep them to one plain file name.
        photoDir.appendingPathComponent(String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" }))
    }
    func readPhoto(_ id: String) -> Data? { try? Data(contentsOf: photoURL(id)) }
    func writePhoto(_ id: String, _ data: Data) throws { try data.write(to: photoURL(id), options: .atomic) }
    func deletePhoto(_ id: String) { try? FileManager.default.removeItem(at: photoURL(id)) }
}
