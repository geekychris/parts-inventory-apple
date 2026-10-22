import Foundation
import Testing
@testable import PartsKit

/// Hex string → bytes ("55 55 40 01 08 49 aa aa").
private func hex(_ s: String) -> [UInt8] {
    s.split(separator: " ").compactMap { UInt8($0, radix: 16) }
}

private func packet(_ s: String) throws -> NiimbotPacket { try NiimbotPacket.parse(hex(s)) }

// Fixtures: niimbluelib's test/dumps.ts (a B1 on firmware 5.22 and a B21 Pro on 3.09).
@Suite struct NiimbotPacketTests {
    @Test func requestsMatchTheDumps() {
        #expect(NiimbotPackets.connect().bytes == hex("03 55 55 c1 01 01 c1 aa aa"))
        #expect(NiimbotPackets.printerStatusData().bytes == hex("55 55 a5 01 01 a5 aa aa"))
        #expect(NiimbotPackets.info(.modelId).bytes == hex("55 55 40 01 08 49 aa aa"))
        #expect(NiimbotPackets.info(.serialNumber).bytes == hex("55 55 40 01 0b 4a aa aa"))
        #expect(NiimbotPackets.heartbeat(3).bytes == hex("55 55 dc 01 03 de aa aa"))
        #expect(NiimbotPackets.heartbeat(4).bytes == hex("55 55 dc 01 04 d9 aa aa"))
        #expect(NiimbotPackets.rfidInfo().bytes == hex("55 55 1a 01 01 1a aa aa"))
        #expect(NiimbotPackets.paperInfo().bytes == hex("55 55 59 01 01 59 aa aa"))
    }

    @Test func replyIdsAndOneWay() {
        #expect(NiimbotPackets.connect().replies == [0xC2])
        #expect(NiimbotPackets.printStatus(oneWay: true).oneWay)
        #expect(NiimbotPackets.emptyRows(at: 0, repeat: 3).oneWay)
        #expect(!NiimbotPackets.pageEnd().oneWay)
    }

    @Test func parsesAndChecks() throws {
        let p = try packet("55 55 4a 01 04 4f aa aa")
        #expect(p.command == 0x4A && p.data == [4])
        #expect(NiimbotReplies.battery(p) == 100)
        #expect(throws: NiimbotPacket.ParseError.badChecksum) { try packet("55 55 4a 01 04 4e aa aa") }
        #expect(throws: NiimbotPacket.ParseError.badTail) { try packet("55 55 4a 01 04 4f aa ab") }
    }

    @Test func splitsBundlesAndKeepsPartialPackets() {
        let (ps, rest) = NiimbotPacket.split(hex("55 55 4a 01 04 4f aa aa 55 55 f6 01 01 f6 aa aa 55 55 4a"))
        #expect(ps.map(\.command) == [0x4A, 0xF6])
        #expect(rest == hex("55 55 4a"))
        let (more, left) = NiimbotPacket.split(rest + hex("01 04 4f aa aa"))
        #expect(more.count == 1 && left.isEmpty)
        #expect(NiimbotPacket.split(hex("12 34 55 55")).packets.isEmpty)
        #expect(NiimbotPacket.split(hex("12 34 55 55")).rest.isEmpty)
    }

    @Test func modelsFromTheirIds() throws {
        let b1 = try packet("55 55 48 02 10 00 5a aa aa")
        #expect(NiimbotReplies.modelId(b1) == 4096)
        #expect(NiimbotModel.byId(4096)?.name == "B1")
        let pro = try packet("55 55 48 02 03 11 58 aa aa")
        #expect(NiimbotReplies.modelId(pro) == 785)
        #expect(NiimbotModel.byId(785)?.name == "B21_PRO")
        #expect(NiimbotModel.byId(2304)?.name == "D110")
        #expect(NiimbotModel.fromDeviceName("B1-G327071185")?.name == "B1")
        #expect(NiimbotModel.fromDeviceName("D110-A0123456")?.name == "D110")
        #expect(NiimbotModel.fromDeviceName("B21_PRO-H613")?.name == "B21_PRO")
        #expect(NiimbotModel.fromDeviceName("AirPods") == nil)
    }

    @Test func protocolVersions() throws {
        let b1 = try packet("55 55 b5 10 30 30 03 20 00 c8 00 00 00 0f 01 02 04 01 98 00 df aa aa")
        #expect(NiimbotReplies.protocolVersion(b1) == 3)
        let pro = try packet("55 55 b5 10 30 30 07 d0 00 64 00 00 00 0f 01 03 02 03 f5 00 ef aa aa")
        #expect(NiimbotReplies.protocolVersion(pro) == 5)
    }

    @Test func headInfo() throws {
        let h = try #require(NiimbotReplies.headInfo(try packet("55 55 de 0a 05 0a 05 16 01 80 02 02 01 00 48 aa aa")))
        #expect(h.printheadWidth == 384)
        #expect(h.hardware == "5.10" && h.software == "5.22")
        #expect(h.resolutionClass == 2 && h.supportsRFID)
    }

    @Test func rollRfid() throws {
        let r = try #require(NiimbotReplies.rfid(try packet(
            "55 55 1b 27 88 1d 7e 4f d9 97 00 00 08 31 30 32 36 32 32 36 30 10 50 5a 31 47 32 32 31 33 32 32 30 30 34 32 30 35 01 14 00 99 01 3d aa aa")))
        #expect(r.barCode == "10262260")
        #expect(r.serial == "PZ1G221322004205")
        #expect(r.total == 276 && r.used == 153 && r.remaining == 123)
        #expect(r.type == .withGaps)
        // B21 Pro adds a capacity field.
        let pro = try #require(NiimbotReplies.rfid(try packet(
            "55 55 1b 29 88 1d 7e 4f d9 97 00 00 08 31 30 32 36 32 32 36 30 10 50 5a 31 47 32 32 31 33 32 32 30 30 34 32 30 35 01 14 00 99 01 00 e6 d5 aa aa")))
        #expect(pro.total == 276)
        // No tag: a single byte.
        #expect(NiimbotReplies.rfid(NiimbotPacket(0x1B, [0], replies: [])) == nil)
    }

    @Test func paperInfo() throws {
        // 4 bytes (as the B21 Pro dump): not a size.
        #expect(NiimbotReplies.paper(try packet("55 55 69 04 00 23 00 23 6d aa aa")) == nil)
        // 18 bytes: gap 3 mm, 30.0 mm long, 50.0 mm wide, labels with gaps.
        let d: [UInt8] = [0, 24, 0, 240, 1, 0, 30, 1, 44, 1, 144, 1, 244, 0, 0, 0, 0, 0]
        let p = try #require(NiimbotReplies.paper(NiimbotPacket(0x69, d, replies: [])))
        #expect(p.widthMM == 50 && p.heightMM == 30 && p.gapMM == 3 && p.type == .withGaps)
        let b1 = NiimbotModel.named("B1")!, d110 = NiimbotModel.named("D110")!
        #expect(LabelSize.fromPaper(p, model: b1).map { [$0.w, $0.h] } == [50, 30])
        // Sideways printers report the side across the head as the width.
        let small = NiimbotReplies.Paper(widthMM: 12, heightMM: 30, gapMM: 2, type: .withGaps)
        #expect(LabelSize.fromPaper(small, model: d110).map { [$0.w, $0.h] } == [30, 12])
    }

    @Test func printStatusAndErrors() throws {
        let s = try #require(NiimbotReplies.printStatus(NiimbotPacket(0xB3, [0, 2, 100, 100], replies: [])))
        #expect(s.page == 2 && s.error == 0)
        let e = try #require(NiimbotReplies.printStatus(NiimbotPacket(0xB3, [0, 0, 0, 0, 0, 0, 2, 0, 0, 0], replies: [])))
        #expect(e.error == 2)
        #expect(NiimbotReplies.error(in: NiimbotPacket(0xDB, [1], replies: []))?.message == "The printer reported: the cover is open.")
    }

    @Test func heartbeats() {
        let a2 = NiimbotReplies.heartbeat(NiimbotPacket(0xD9, hex("20 41 04 4d 00 00 01 00 00"), replies: []))
        #expect(a2?.battery == 100 && a2?.paperInserted == true && a2?.lidClosed == true)
        let d110 = NiimbotReplies.heartbeat(NiimbotPacket(0xDD, [0, 0, 0, 0, 0, 0, 0, 0, 0, 3], replies: []))
        #expect(d110?.battery == 75)
    }
}

@Suite struct NiimbotImageTests {
    @Test func rowsRepeatsAndVoids() {
        var b = Bitmap1(width: 16, height: 5)
        b.fill(x: 0, y: 1, w: 8, h: 2)   // two identical rows
        b[15, 4] = true
        let img = NiimbotImage(b, direction: .top)
        #expect(img.cols == 16 && img.rows == 5)
        #expect(img.data.map(\.kind) == [.void, .pixels, .void, .pixels])
        #expect(img.data[1].repeats == 2 && img.data[1].data == [0xFF, 0x00])
        #expect(img.data[3].data == [0x00, 0x01] && img.data[3].black == 1)
    }

    @Test func sidewaysTurnsAQuarterClockwise() {
        // Read as a 3-wide, 2-high label; one dot at the top-left.
        var b = Bitmap1(width: 3, height: 2)
        b[0, 0] = true
        let img = NiimbotImage(b, direction: .left)
        #expect(img.rows == 3 && img.cols == 8)
        // Top-left of the label → first row, the far side of the head (column height-1).
        #expect(img.data.first?.kind == .pixels)
        #expect(img.data.first?.data == [0b0100_0000])
    }

    @Test func checkRowsEvery200() {
        var b = Bitmap1(width: 8, height: 420)
        b.fill(x: 0, y: 0, w: 8, h: 420)
        let img = NiimbotImage(b, direction: .top)
        #expect(img.data.filter { $0.kind == .check }.map(\.row) == [199, 399])
        #expect(img.data.filter { $0.kind == .pixels }.reduce(0) { $0 + $1.repeats } == 420)
        #expect(img.packets(printhead: 96).count == 3)
        #expect(img.packets(printhead: 96, checkLines: true).count == 5)
    }

    @Test func pixelCounts() {
        // 96-dot head: chunks of 4 bytes.
        let buf: [UInt8] = [0xFF, 0, 0, 0, 0x0F, 0, 0, 0, 0x01, 0, 0, 0]
        let split = NiimbotImage.countPixels(buf, printhead: 96)
        #expect(split.total == 13 && split.parts == [8, 4, 1])
        let total = NiimbotImage.countPixels(buf, printhead: 96, mode: .total)
        #expect(total.parts == [0, 13, 0])
        // Wider than the head: total, little-endian.
        let wide = NiimbotImage.countPixels([UInt8](repeating: 0xFF, count: 48), printhead: 96)
        #expect(wide.total == 384 && wide.parts == [0, 0x80, 0x01])
    }

    @Test func indexedRowsForFewDots() {
        var b = Bitmap1(width: 16, height: 1)
        b[1, 0] = true; b[9, 0] = true
        let r = NiimbotImage(b, direction: .top).data[0]
        let p = NiimbotPackets.row(r, printhead: 96)
        #expect(p.command == 0x83)
        // row 0, counts by 4-byte chunk of a 96-dot head [2,0,0], repeat 1, then positions 1 and 9
        #expect(p.data == [0, 0, 2, 0, 0, 1, 0, 1, 0, 9])
        var dense = Bitmap1(width: 16, height: 1)
        dense.fill(x: 0, y: 0, w: 16, h: 1)
        let q = NiimbotPackets.row(NiimbotImage(dense, direction: .top).data[0], printhead: 96)
        #expect(q.command == 0x85 && q.data == [0, 0, 16, 0, 0, 1, 0xFF, 0xFF])
    }

    @Test func grayThreshold() {
        let b = Bitmap1(width: 2, height: 1, gray: [10, 250])
        #expect(b[0, 0] && !b[1, 0])
    }
}

@Suite struct NiimbotJobTests {
    func page(_ copies: Int = 1) -> NiimbotPage {
        var b = Bitmap1(width: 16, height: 4)
        b.fill(x: 0, y: 0, w: 16, h: 1)
        return NiimbotPage(image: NiimbotImage(b, direction: .top), copies: copies)
    }

    @Test func printTasksByModel() {
        #expect(NiimbotModel.named("B1")!.printTask(protocolVersion: 3) == .b1)
        #expect(NiimbotModel.named("D110")!.printTask(protocolVersion: 0) == .d110)
        #expect(NiimbotModel.named("D11")!.printTask(protocolVersion: 0) == .d11V1)
        #expect(NiimbotModel.named("D11")!.printTask(protocolVersion: 1) == .d110)
        #expect(NiimbotModel.named("D110_M")!.printTask(protocolVersion: 4) == .d110mV4)
        #expect(NiimbotModel.named("D110_M")!.printTask(protocolVersion: 3) == .b1)
        #expect(NiimbotModel.named("B21_PRO")!.printTask(protocolVersion: 5) == .d110mV4)
        #expect(NiimbotModel.named("B21")!.printTask(protocolVersion: 1) == .b21V1)
        #expect(NiimbotModel.named("H1S")!.printTask(protocolVersion: 3) == .h1s)
        #expect(NiimbotModel.named("B3S")!.printTask(protocolVersion: 5) == .d110mV4)
        #expect(NiimbotModel.named("B3S")!.printTask(protocolVersion: 1) == .b1)
    }

    @Test func b1Job() {
        let s = NiimbotJob.steps(task: .b1, pages: [page(2), page()], density: 3, labelType: .withGaps, printhead: 384)
        #expect(s.prefix(3) == [.send(NiimbotPackets.setDensity(3)), .send(NiimbotPackets.setLabelType(.withGaps)), .send(NiimbotPackets.printStart7b(3))])
        #expect(s.contains(.send(NiimbotPackets.pageSize6b(rows: 4, cols: 16, copies: 2))))
        #expect(s.suffix(2) == [.waitStatus(pages: 3), .end])
    }

    @Test func d110WaitsAfterEachPage() {
        let s = NiimbotJob.steps(task: .d110, pages: [page(), page(2)], density: 2, labelType: .withGaps, printhead: 96)
        #expect(s.filter { if case .waitStatus = $0 { true } else { false } } == [.waitStatus(pages: 1), .waitStatus(pages: 3)])
        #expect(s.last == .end)
        #expect(s.contains(.send(NiimbotPackets.printQuantity(2))))
    }

    @Test func b21v1RepeatsPagesAndPollsPrintEnd() {
        let s = NiimbotJob.steps(task: .b21V1, pages: [page(2)], density: 3, labelType: .withGaps, printhead: 384)
        #expect(s.filter { $0 == .send(NiimbotPackets.pageStart()) }.count == 2)
        #expect(s.last == .waitPrintEnd)
    }

    @Test func v4SendsStatusOneWayFirst() {
        let s = NiimbotJob.steps(task: .d110mV4, pages: [page()], density: 3, labelType: .withGaps, printhead: 591)
        #expect(s[2] == .send(NiimbotPackets.printStart9b(1)))
        #expect(s[3] == .send(NiimbotPackets.printStatus(oneWay: true)))
        #expect(s.last == .send(NiimbotPackets.heartbeat(1).oneWayCopy))
    }
}

@Suite struct LabelLayoutTests {
    // A rough font: 0.55 of the size per character (0.6 bold).
    let measure: LabelLayout.Measure = { t, px, bold in Double(t.count) * Double(px) * (bold ? 0.6 : 0.55) }
    let content = LabelContent(title: "LM358DR", subtitle: "Dual op-amp, general purpose, SOIC-8", lines: ["Cabinet A › Drawer 2"],
                               icon: "cpu", link: "https://www.ti.com/lit/ds/symlink/lm358.pdf")

    @Test func labelSizesInDots() {
        let d110 = NiimbotModel.named("D110")!, b1 = NiimbotModel.named("B1")!
        let small = LabelSize.named("30x12")!.canvas(d110)
        #expect(small.w == 240 && small.h == 96 && !small.clipped)
        #expect(LabelSize.named("30x15")!.canvas(d110).clipped)  // 15 mm is wider than a 12 mm head
        #expect(LabelSize.named("50x30")!.canvas(b1).w == 384)   // 50 mm on a 48 mm head
        #expect(LabelSize.named("40x30")!.fits(b1) && !LabelSize.named("50x40")!.fits(d110))
        #expect(LabelSize.usual(for: d110).id == "30x12" && LabelSize.usual(for: NiimbotModel.named("B21")!).id == "40x30")
    }

    @Test func smallLabelDropsTheIconAndKeepsAShortQR() {
        let p = LabelLayout.plan(w: 240, h: 96, dpi: 203, template: .iconTextQR, content: content, qrModules: 25, measure: measure)
        #expect(p.qr != nil && (p.qr?.module ?? 0) >= 2)
        #expect(p.icon == nil)
        #expect(p.texts.count <= 3 && p.texts.first?.text == "LM358DR" && p.texts.first?.bold == true)
        #expect(p.texts.allSatisfy { $0.x + Int(measure($0.text, $0.px, $0.bold)) <= 240 - 5 - (p.qr?.size ?? 0) })
    }

    @Test func smallLabelDropsADenseQR() {
        let p = LabelLayout.plan(w: 240, h: 96, dpi: 203, template: .iconTextQR, content: content, qrModules: 45, measure: measure)
        #expect(p.qr == nil && !p.warnings.isEmpty)
    }

    @Test func bigLabelGetsIconQRAndSeveralLines() {
        let p = LabelLayout.plan(w: 400, h: 240, dpi: 203, template: .iconTextQR, content: content, qrModules: 33, measure: measure)
        #expect(p.icon != nil && p.qr != nil)
        #expect((3...5).contains(p.texts.count))
        // nothing overlaps: text between the icon and the QR code
        let textLeft = p.texts.map(\.x).min() ?? 0
        #expect(textLeft >= (p.icon!.x + p.icon!.w))
        #expect(p.texts.allSatisfy { $0.x + Int(measure($0.text, $0.px, $0.bold)) <= p.qr!.x })
    }

    @Test func descriptionOnlyIsBig() {
        let p = LabelLayout.plan(w: 240, h: 96, dpi: 203, template: .text, content: content, qrModules: 25, measure: measure)
        #expect(p.icon == nil && p.qr == nil)
        #expect(p.texts.first?.text.hasPrefix("Dual") == true)
        let one = LabelLayout.plan(w: 240, h: 96, dpi: 203, template: .text, content: LabelContent(title: "", subtitle: "10k"), qrModules: 0, measure: measure)
        #expect(one.texts.count == 1 && one.texts[0].px > 40)
    }

    @Test func iconTextWithoutQR() {
        let p = LabelLayout.plan(w: 320, h: 96, dpi: 203, template: .iconText, content: content, qrModules: 25, measure: measure)
        #expect(p.qr == nil && p.icon != nil)  // 40 × 12 mm: wide enough for the icon
    }
}

@Suite struct LabelLinkTests {
    let part = LabelLinkContext(uid: "p1a2", mpn: "LM358DR", manufacturer: "Texas Instruments", category: "ICs/Analog",
                                datasheet: "https://www.ti.com/lit/ds/symlink/lm358.pdf", supplierPages: ["https://www.digikey.com/x"])

    @Test func datasheetThenSupplierPage() {
        let ds = LabelLinks.provider("datasheet")
        #expect(ds.url(for: part, settings: .init()) == "https://www.ti.com/lit/ds/symlink/lm358.pdf")
        var none = part
        none.datasheet = "lm358.pdf"
        #expect(ds.url(for: none, settings: .init()) == "https://www.digikey.com/x")
        none.supplierPages = []
        #expect(ds.url(for: none, settings: .init()) == nil)
    }

    @Test func publicPageTemplate() {
        let pub = LabelLinks.provider("public")
        #expect(pub.url(for: part, settings: .init()) == nil)
        let s = LabelLinkSettings(publicURLTemplate: "https://example.com/parts/{uid}/?m={mpn}&by={manufacturer}")
        #expect(pub.url(for: part, settings: s) == "https://example.com/parts/p1a2/?m=LM358DR&by=Texas%20Instruments")
        #expect(LabelLinks.provider("none").url(for: part, settings: s) == nil)
        #expect(LabelLinks.provider("nonsense").id == "datasheet")
    }
}
