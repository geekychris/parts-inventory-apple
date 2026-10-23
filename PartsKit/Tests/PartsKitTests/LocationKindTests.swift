import Foundation
import Testing
@testable import PartsKit

@Test func locationKindsAreGuessedFromNames() {
    #expect(LocationKind.guess(name: "Cabinet A") == .cabinet)
    #expect(LocationKind.guess(name: "Top shelf") == .shelf)
    #expect(LocationKind.guess(name: "Drawer 3") == .drawer)
    #expect(LocationKind.guess(name: "Bin 12") == .bin)
    #expect(LocationKind.guess(name: "Dev boards") == nil)
    #expect(LocationKind.resolve(stored: "box", name: "Drawer 3", hasChildren: false) == .box)
    #expect(LocationKind.resolve(stored: "", name: "Dev boards", hasChildren: true) == .drawer)
    #expect(LocationKind.resolve(stored: "", name: "Dev boards", hasChildren: false) == .bin)
}

@Test func newLocationNamesSkipTakenOnes() {
    #expect(LocationKind.shelf.nextName(among: []) == "Shelf 1")
    #expect(LocationKind.shelf.nextName(among: ["Shelf 1", "shelf 2", "Drawer 3"]) == "Shelf 3")
    #expect(LocationKind.cabinet.nextName(among: ["Cabinet A", "Cabinet B", "Shelf"]) == "Cabinet C")
}

@Test func locationKindRoundTripsInBackups() throws {
    let json = #"{"id":"l1","name":"Cabinet A","kind":"cabinet"}"#
    let l = try JSONDecoder().decode(Backup.Location.self, from: Data(json.utf8))
    #expect(l.kind == "cabinet")
    // An unset kind stays out of the file, so the web tool's backups don't change.
    let plain = try JSONDecoder().decode(Backup.Location.self, from: Data(#"{"id":"l2","name":"Bin"}"#.utf8))
    let out = String(data: try JSONEncoder().encode(plain), encoding: .utf8)!
    #expect(!out.contains("kind"))
    #expect(!out.contains("parentId"))
}
