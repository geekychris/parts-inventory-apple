import Foundation
import SwiftData
import Testing
import PartsKit
@testable import Parts_Inventory

// The inventory table's data: parts kept live as they change, and friends' inventories read from a folder.

@MainActor
@Test func tableFollowsEditsAndFacets() async throws {
    let schema = Schema(Schema1.models)
    let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
    let ctx = container.mainContext
    let drawer = StorageLocation(name: "Drawer 1", parent: StorageLocation(name: "Cabinet A"))
    ctx.insert(drawer)
    let r = Part(); r.mpn = "RC0603FR-0710KL"; r.category = "Passives/Resistors"; r.qty = 480; r.location = drawer
    r.params = PartParams(kind: "R", value: 10_000, tol: 0.01, pkg: "0603")
    let u = Part(); u.mpn = "LM358DR"; u.category = "ICs/Analog"; u.qty = 4; u.lowStock = 5
    ctx.insert(r); ctx.insert(u)

    let m = InventoryTableModel()
    m.showFriends = false
    m.setParts([r, u], defaultLow: 0)
    #expect(m.total == 2 && m.shown.map(\.row.mpn) == ["LM358DR", "RC0603FR-0710KL"])
    #expect(m.shown.last?.row.location == "Cabinet A › Drawer 1")
    #expect(m.facets[.stock]?.first { $0.key == "low" }?.count == 1)

    m.search = "10k 0603"
    #expect(m.shown.map(\.row.mpn) == ["RC0603FR-0710KL"])
    m.search = ""
    m.filter.toggle(.category, "ICs")
    #expect(m.shown.map(\.row.mpn) == ["LM358DR"])
    m.filter.clear()

    // An edit (stock, a location's name) shows a moment later, without the list itself changing.
    u.qty = 40
    drawer.name = "Drawer 9"
    try await Task.sleep(for: .milliseconds(600))
    #expect(m.shown.first { $0.row.mpn == "LM358DR" }?.row.qty == 40)
    #expect(m.facets[.stock]?.contains { $0.key == "low" } == false)
    #expect(m.shown.first { $0.row.mpn == "RC0603FR-0710KL" }?.row.location == "Cabinet A › Drawer 9")
}

@MainActor
@Test func friendFromAFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("friend-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = FriendsStore()
    let f = try store.add(name: "Sam", folder: dir)
    #expect(throws: (any Error).self) { try store.add(name: "sam", address: "https://github.com/sam/parts") }   // same name
    #expect(throws: (any Error).self) { try store.add(name: "Kim", address: "ftp://example.com") }

    await store.refresh(f)
    #expect(store.status[f.id]?.error?.contains("no inventory") == true)

    let fixture = #"{"schema":"gw-parts-inventory","version":1,"parts":[{"id":"p1","mpn":"NE555P","qty":12,"locationId":"l1"}],"locations":[{"id":"l1","name":"Garage"}]}"#
    try Data(fixture.utf8).write(to: dir.appendingPathComponent("inventory.json"))
    await store.refresh(f)
    #expect(store.status[f.id]?.error == nil && store.status[f.id]?.parts == 1)
    #expect(store.allRows.map(\.source) == ["Sam"] && store.allRows.first?.location == "Garage")

    // A failed fetch keeps the last good copy.
    try Data("<html>gone</html>".utf8).write(to: dir.appendingPathComponent("inventory.json"))
    await store.refresh(f)
    #expect(store.status[f.id]?.error != nil && store.allRows.count == 1)

    var renamed = f; renamed.name = "Samantha"
    store.update(renamed)
    #expect(store.allRows.first?.source == "Samantha")
    store.remove(renamed)
    #expect(store.allRows.isEmpty && !store.hasFriends)
}
