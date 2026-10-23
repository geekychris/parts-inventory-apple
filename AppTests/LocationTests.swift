import Foundation
import SwiftData
import Testing
import PartsKit
@testable import Parts_Inventory

@MainActor
struct LocationTests {
    let ctx: ModelContext
    let all: () -> [StorageLocation]
    let parts: () -> [Part]

    init() throws {
        let schema = Schema(Schema1.models)
        let c = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
        DebugLaunch.demo(c)
        try c.save()
        ctx = c
        all = { (try? c.fetch(FetchDescriptor<StorageLocation>())) ?? [] }
        parts = { (try? c.fetch(FetchDescriptor<Part>())) ?? [] }
    }

    var mover: LocationMover { LocationMover(ctx: ctx, locations: all(), parts: parts()) }
    func loc(_ path: String) -> StorageLocation { all().first { $0.path == path }! }

    @Test func partsMoveBetweenLocations() {
        let drawer = loc("Cabinet A › Drawer 1"), shelf = loc("Shelf")
        let moving = drawer.parts!.map(\.uid)
        #expect(!moving.isEmpty)
        #expect(mover.move(.parts(moving), to: shelf))
        #expect(drawer.parts!.isEmpty)
        #expect(Set(shelf.parts!.map(\.uid)).isSuperset(of: moving))
        // Dropping them where they already are does nothing; dropping on Not stored anywhere clears it.
        #expect(!mover.move(.parts(moving), to: shelf))
        #expect(mover.move(.parts([moving[0]]), to: nil))
        #expect(parts().first { $0.uid == moving[0] }!.location == nil)
    }

    @Test func aShelfMovesWithEverythingInIt() {
        let cabinet = loc("Cabinet A"), shelf = loc("Shelf")
        let before = shelf.partCount
        #expect(mover.move(.locations([shelf.uid]), to: cabinet))
        #expect(shelf.path == "Cabinet A › Shelf")
        #expect(loc("Cabinet A › Shelf › Dev boards").parts!.count == before)
        #expect(mover.move(.locations([shelf.uid]), to: nil))
        #expect(shelf.parent == nil)
    }

    @Test func aLocationCantGoInsideItself() {
        let cabinet = loc("Cabinet A"), bin = loc("Cabinet A › Drawer 2 › Bin 3")
        #expect(!mover.canMove(.locations([cabinet.uid]), to: cabinet))
        #expect(!mover.canMove(.locations([cabinet.uid]), to: bin))
        #expect(!mover.move(.locations([cabinet.uid]), to: bin))
        #expect(cabinet.parent == nil)
        #expect(mover.canMove(.locations([bin.uid]), to: cabinet))
    }

    @Test func dragsTravelAsText() {
        #expect(LocationDrag(text: LocationDrag.parts(["p1", "p2"]).text)?.text == "parts:p1,p2")
        #expect(LocationDrag(text: "locations:l1")?.text == "locations:l1")
        #expect(LocationDrag(text: "hello") == nil)
        #expect(LocationDrag(text: "parts:") == nil)
    }

    @Test func kindsGoInTheBackup() {
        let cabinet = loc("Cabinet A")
        cabinet.kind = LocationKind.cabinet.rawValue
        let b = Inventory.backup(in: ctx, photos: false)
        #expect(b.locations.first { $0.id == cabinet.uid }?.kind == "cabinet")
        let data = try! JSONEncoder().encode(b)
        let back = try! JSONDecoder().decode(Backup.self, from: data)
        #expect(back.locations.first { $0.id == cabinet.uid }?.kind == "cabinet")
    }

    @Test func locationPhotosGoInFullBackups() throws {
        let cabinet = loc("Cabinet A"), bin = loc("Cabinet A › Drawer 2 › Bin 3")
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        cabinet.setPhoto(jpeg)
        // A bin without its own photo shows its cabinet's.
        #expect(bin.nearestPhoto?.location.uid == cabinet.uid)

        let b = Inventory.backup(in: ctx, photos: true)
        let x = try #require(b.photos?.first { $0.locationId == cabinet.uid })
        #expect(x.partId == nil)
        #expect(Inventory.backup(in: ctx, photos: false).photos == nil)

        cabinet.setPhoto(nil)
        #expect(Inventory.merge(b, in: ctx).photos >= 1)
        #expect(cabinet.photo == jpeg)
    }
}
