// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation
import XCTest
@testable import FM1Kit

final class SLOOPFlashTests: XCTestCase {
    func testCRCIsZlibs() {
        XCTAssertEqual(SysExCoding.crc32(Array("123456789".utf8)), 0xCBF4_3926, "storage.c st_crc32 is zlib's CRC-32")
    }

    func testWritesTheSongAsSLOOPWouldLoadIt() throws {
        var doc = try SLOOPSongDoc(sloopSong(sections: [0]))
        doc.patterns[.loop]![track: 0].place(60, at: 0, steps: 1)
        doc.order = SLOOPOrder(entries: [.init(section: 0, bars: 2)], loops: true)
        let song = doc.archive()
        var s: SLOOPFlash.Sectors = [:]
        try SLOOPFlash.put(song, into: &s)
        XCTAssertEqual(SLOOPFlash.read(s, 7).map { Data($0) }, song.part("0")?.data, "the loop in progress")
        XCTAssertEqual(SLOOPFlash.read(s, 1).map { Data($0) }, song.part("2")?.data, "section A")
        XCTAssertEqual(SLOOPFlash.read(s, 2), [], "an empty section: a record of length 0")
        XCTAssertEqual(SLOOPFlash.read(s, 0).flatMap { SLOOPOrder(settings: Data($0)) }, doc.order)
        XCTAssertNotNil(s[0x97000]); XCTAssertNotNil(s[0x9F000]); XCTAssertNotNil(s[0xFC000])
        XCTAssertEqual(SLOOPFlash.header(s, 7, 0)?.seq, 1)
        // a header with a wrong CRC isn't a copy
        var bad = s; bad[0x97000]![20] ^= 1
        XCTAssertNil(SLOOPFlash.read(bad, 1))
    }

    func testWritesTheOtherCopyAndKeepsTheEmulatorsSettings() throws {
        // the emulator's own settings: the PER3 object followed by its drum kits, with a side record (a theme)
        var base: SLOOPFlash.Sectors = [:]
        var mine = [UInt8](sloopSettings(order: [(3, 1)])) + [UInt8](repeating: 0x5A, count: 500)
        mine[10] = 0x42
        try SLOOPFlash.write(&base, 0, mine)
        base[0xFC000]!.replaceSubrange(64..<80, with: [UInt8](repeating: 0x77, count: 16))
        try SLOOPFlash.write(&base, 1, [UInt8](sloopProject(fill: 9)))       // an older section A
        let text = try SLOOPFlash.save(package: Data([1, 2, 3]), sha256: String(repeating: "a", count: 64), name: "SLOOP", sectors: base)

        let song = sloopSong(sections: [0, 1])
        let out = try SLOOPFlash.emulatorSave(song: song, package: Data([1, 2, 3]), sha256: String(repeating: "a", count: 64), name: "SLOOP", base: text)
        let s = try SLOOPFlash.sectors(ofSave: out)
        let settings = try XCTUnwrap(SLOOPFlash.read(s, 0))
        XCTAssertEqual(settings.count, mine.count, "the drum kits after the settings stay")
        XCTAssertEqual(settings[10], 0x42)
        XCTAssertEqual(Array(settings[88...]), Array(mine[88...]))
        XCTAssertEqual(SLOOPOrder(settings: Data(settings)), SLOOPOrder(settings: song.part("1")!.data), "with the song's order")
        XCTAssertEqual(SLOOPFlash.current(s, 0)?.copy, 1, "written to the other copy")
        XCTAssertEqual(SLOOPFlash.current(s, 0)?.h.seq, 2)
        XCTAssertEqual(Array(s[0xFD000]![64..<80]), [UInt8](repeating: 0x77, count: 16), "the side record kept")
        XCTAssertEqual(SLOOPFlash.read(s, 1).map { Data($0) }, song.part("2")?.data, "section A replaced")
        XCTAssertNotNil(s[0x97000], "the copy it had is still there")
        let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        XCTAssertEqual(j["package"] as? String, Data([1, 2, 3]).base64EncodedString())
    }

    func testRefusesADamagedSong() {
        var song = sloopSong()
        song.parts[0].crc ^= 1
        var s: SLOOPFlash.Sectors = [:]
        XCTAssertThrowsError(try SLOOPFlash.put(song, into: &s))
        XCTAssertTrue(s.isEmpty)
        XCTAssertThrowsError(try SLOOPFlash.sectors(ofSave: "{\"format\":\"x\"}"))
    }
}
