import Foundation
import SwiftData
import Testing
import PartsKit
@testable import Parts_Inventory

/// The repository folder written from one inventory and read back into another, as Export to folder… and
/// Import from folder… do.
@MainActor
@Test func repositoryFolderRoundTrips() async throws {
    let schema = Schema(Schema1.models)
    func store() throws -> ModelContext {
        ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
    }
    let a = try store()
    DebugLaunch.demo(a)
    try a.save()

    let dir = FileManager.default.temporaryDirectory.appending(path: "export-app-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let export = ExportController()
    export.ctx = a
    let said = await export.writeRepository(to: dir)
    #expect(said.hasPrefix("Exported 6 parts"))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "categories/passives.md").path))

    let b = try store()
    let importer = ExportController()
    importer.ctx = b
    #expect(importer.importRepository(from: dir).hasPrefix("Imported from"))
    let rowsA = InventoryRow.catalogueOrder(Inventory.backup(in: a, photos: false).rows())
    let rowsB = InventoryRow.catalogueOrder(Inventory.backup(in: b, photos: false).rows())
    #expect(rowsA == rowsB)
    // Only parts and locations by default: the stock history stays behind.
    #expect(Inventory.backup(in: b, photos: false).history.isEmpty)
    #expect(!Inventory.backup(in: a, photos: false).history.isEmpty)
}
