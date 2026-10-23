import Testing
@testable import PartsKit

@Test func rowsResolveLocationsAndCategories() {
    var b = Backup()
    b.locations = [Backup.Location(id: "a", name: "Cabinet A"), Backup.Location(id: "b", parentId: "a", name: "Drawer 1")]
    var p = Backup.Part(id: "p1")
    p.mpn = "RC0603FR-0710KL"; p.category = "Passives / Resistors"; p.qty = 480; p.locationId = "b"
    p.params = PartParams(kind: "R", value: 10_000, tol: 0.01, pkg: "0603")
    b.parts = [p]
    let r = b.rows(source: "Sam", defaultLowStock: 500)[0]
    #expect(r.categoryPath == ["Passives", "Resistors"])
    #expect(r.locationPath == ["Cabinet A", "Drawer 1"])
    #expect(r.location == "Cabinet A › Drawer 1")
    #expect(r.source == "Sam" && r.qty == 480 && r.isLow)
    #expect(r.value.contains("10"))
}
