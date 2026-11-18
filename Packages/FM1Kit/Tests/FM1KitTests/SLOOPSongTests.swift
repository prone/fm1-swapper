// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation
import XCTest
@testable import FM1Kit

/// A format-6 SLOOP project built byte by byte (project.c project_t): BPM 120, every track 16 steps of 1/16, all rests
/// (the drum track: empty steps), no locks, a checksum SLOOP accepts.
func sloopProject(bpm: Int16 = 120, fill: UInt8 = 0) -> Data {
    var b = [UInt8](repeating: 0, count: 3816)
    func put32(_ v: UInt32, _ at: Int) { for i in 0..<4 { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * i)) } }
    put32(0x4655_4E36, 0); put32(3816, 4)
    b[8] = UInt8(bpm & 255); b[9] = UInt8(bpm >> 8)
    for k in 0..<4 {
        let t = 76 + k * 934
        b[t + 58] = 16; b[t + 60] = 2                      // LEN 16, DIV 1/16
        b[t + 122] = fill                                  // (a byte that tells two projects apart)
        for i in 0..<64 where k != 3 { b[t + 134 + i * 10 + 5] = 2 }   // rests
        for l in 0..<24 { b[t + 838 + l * 4] = 0xFF }
    }
    put32(SLOOPPattern.fnv(b[0..<3812]), 3812)
    return Data(b)
}

func sloopSettings(order: [(Int, Int)] = [(0, 4), (1, 4), (2, 4), (3, 4)]) -> Data {
    var b = [UInt8](repeating: 7, count: 88)
    b[0] = 0x33; b[1] = 0x52; b[2] = 0x45; b[3] = 0x50
    return SLOOPOrder(entries: order.map { .init(section: $0.0, bars: $0.1) }, loops: false).written(into: Data(b))
}

func sloopSong(sections: [Int] = [0]) -> DeviceArchive {
    var parts: [DeviceArchive.Part] = [.init(id: "0", label: "Loop in progress", data: sloopProject()),
                                       .init(id: "1", label: "Settings and song order", data: sloopSettings())]
    for i in 0..<4 { parts.append(.init(id: "\(i + 2)", label: SLOOPArchive.label(UInt8(i + 2)), data: sections.contains(i) ? sloopProject(fill: UInt8(i + 1)) : Data())) }
    return DeviceArchive(format: SLOOPArchive.format, family: .felucca, firmware: "FELUCCA 2.8.5", parts: parts, info: ["contents": "song"])
}

final class SLOOPSongTests: XCTestCase {
    func testReadsAndWritesAProject() throws {
        let p = try XCTUnwrap(SLOOPPattern(sloopProject()))
        XCTAssertEqual(p.bpm, 120)
        XCTAssertEqual(p[track: 0].length, 16)
        XCTAssertEqual(p[track: 0].bars, 1)
        XCTAssertTrue(p[track: 3].isDrum)
        XCTAssertEqual(p.data, sloopProject())
        var bad = [UInt8](sloopProject()); bad[200] ^= 1
        XCTAssertNil(SLOOPPattern(Data(bad)), "a wrong checksum is refused")
        XCTAssertNil(SLOOPPattern(Data()))
    }

    func testEditsKeepTheChecksumRight() throws {
        var p = try XCTUnwrap(SLOOPPattern(sloopProject()))
        p[track: 0].place(60, at: 0, steps: 4)
        let again = try XCTUnwrap(SLOOPPattern(p.data), "SLOOP would accept the edited section")
        XCTAssertEqual(again[track: 0].chords, [SLOOPChord(at: 0, length: 4, notes: [60], velocity: 96)])
    }

    func testPianoRollMatchesSLOOPsEditor() throws {
        var t = try XCTUnwrap(SLOOPPattern(sloopProject()))[track: 0]
        t.place(60, at: 0, steps: 4)
        t.place(64, at: 0, steps: 1)                         // joins the chord, keeps its length
        XCTAssertEqual(t.chords, [SLOOPChord(at: 0, length: 4, notes: [60, 64], velocity: 96)])
        t.place(67, at: 2, steps: 4)                         // inside the held chord: it ends there
        XCTAssertEqual(t.chords.map(\.at), [0, 2])
        XCTAssertEqual(t.chords.map(\.length), [2, 4])
        t.remove(60, at: 0); t.remove(64, at: 0)
        XCTAssertEqual(t.chords.map(\.at), [2])
        XCTAssertFalse(t.step(1).isTie, "the last note's ties become rests")
        for p in [61, 62, 63, 65] { t.place(UInt8(p), at: 8, steps: 1) }
        t.place(66, at: 8, steps: 1)
        XCTAssertEqual(t.chords.last?.notes.count, 4, "4 notes at most")
    }

    func testPasteIntoAHeldChordCutsItsTies() throws {
        var t = try XCTUnwrap(SLOOPPattern(sloopProject()))[track: 0]
        t.place(60, at: 0, steps: 16)
        var one = try XCTUnwrap(SLOOPPattern(sloopProject()))[track: 0]
        one.place(64, at: 0, steps: 1)
        t.paste(one.copy(0..<1), at: 4)
        XCTAssertEqual(t.chords.map(\.length), [4, 1], "the pasted note is as long as it was, the held one ends at it")
        var u = try XCTUnwrap(SLOOPPattern(sloopProject()))[track: 0]
        u.place(60, at: 0, steps: 8)
        u.insert(one.copy(0..<2), at: 4)
        XCTAssertEqual(u.chords.map(\.at), [0, 4])
        XCTAssertEqual(u.chords.map(\.length), [4, 1], "the held chord ends at the insert; its old ties after it are rests")
    }

    func testDrumLanes() throws {
        var t = try XCTUnwrap(SLOOPPattern(sloopProject()))[track: 3]
        t.toggleDrum(lane: 0, at: 0); t.toggleDrum(lane: 9, at: 4)
        XCTAssertTrue(t.drum(at: 0, lane: 0)); XCTAssertTrue(t.drum(at: 4, lane: 9)); XCTAssertFalse(t.drum(at: 4, lane: 1))
        XCTAssertEqual(t.step(4).b[1], 0b10, "lane 9 is bit 1 of the second byte")
        t.toggleDrum(lane: 0, at: 0)
        XCTAssertEqual(t.step(0), .emptyDrum)
        t.place(60, at: 0, steps: 1)
        XCTAssertTrue(t.chords.isEmpty, "no notes on the drum track")
    }

    func testCopyPasteInsertDeleteBars() throws {
        var t = try XCTUnwrap(SLOOPPattern(sloopProject()))[track: 0]
        t.place(60, at: 0, steps: 2); t.place(62, at: 8, steps: 1)
        t.raw[SLOOPTrack.mfAt + 8] = 5                                        // a nudge on step 8
        t.raw.replaceSubrange(SLOOPTrack.locksAt ..< SLOOPTrack.locksAt + 4, with: [8, 1, 9, 0])   // a lock on step 8
        let bar = t.copy(0..<16)
        XCTAssertTrue(t.insert(bar, at: 16), "bar 1 copied after itself")
        XCTAssertEqual(t.length, 32)
        XCTAssertEqual(t.chords.map(\.at), [0, 8, 16, 24])
        XCTAssertEqual(t.raw[SLOOPTrack.mfAt + 24], 5, "the nudge came with it")
        XCTAssertEqual(t.copy(16..<32).locks.map(\.step), [8], "and the lock")
        t.insert(bar, at: 0)                                                 // a new bar 1: the others move later
        XCTAssertEqual(t.length, 48)
        XCTAssertEqual(t.chords.map(\.at), [0, 8, 16, 24, 32, 40])
        XCTAssertEqual(t.copy(0..<48).locks.map(\.step).sorted(), [8, 24, 40])
        t.delete(0..<16)
        XCTAssertEqual(t.length, 32)
        XCTAssertEqual(t.chords.map(\.at), [0, 8, 16, 24])
        XCTAssertEqual(t.copy(0..<64).locks.map(\.step).sorted(), [8, 24])
        t.delete(1..<16)                                                     // cuts the first chord's tie
        XCTAssertEqual(t.chords.first, SLOOPChord(at: 0, length: 1, notes: [60], velocity: 96))
        var full = t
        for _ in 0..<8 { full.insert(bar, at: 0) }
        XCTAssertEqual(full.length, 64, "64 steps at most")
        let drum = try XCTUnwrap(SLOOPPattern(sloopProject()))[track: 3]
        XCTAssertFalse(t.paste(drum.copy(0..<16), at: 0), "drum steps don't paste on a synth track")
        var p2 = t
        p2.paste(t.copy(0..<1), at: 60)
        XCTAssertEqual(p2.length, 61, "LEN grows to cover a paste")
    }

    func testOrderInTheSettings() throws {
        let s = sloopSettings(order: [(0, 4), (0, 4), (1, 8), (3, 2)])
        var o = try XCTUnwrap(SLOOPOrder(settings: s))
        XCTAssertEqual(o.entries, [.init(section: 0, bars: 4), .init(section: 0, bars: 4), .init(section: 1, bars: 8), .init(section: 3, bars: 2)])
        XCTAssertEqual(o.totalBars, 18)
        o.entries.append(.init(section: 2, bars: 64)); o.loops = true
        let w = [UInt8](o.written(into: s))
        XCTAssertEqual(Array(w[48..<50]), [5, 1])
        XCTAssertEqual(Array(w[60..<62]), [2, 64])
        XCTAssertEqual(Array(w[0..<48]), Array([UInt8](s)[0..<48]), "the rest of the settings untouched")
        XCTAssertEqual(Array(w[84...]), Array([UInt8](s)[84...]))
        XCTAssertNil(SLOOPOrder(settings: Data(repeating: 0, count: 88)))
    }

    func testDocumentRoundTrip() throws {
        var doc = try SLOOPSongDoc(sloopSong(sections: [0]))
        XCTAssertTrue(doc.isEmpty(.b))
        XCTAssertEqual(doc.emptyEntries, [1, 2, 3], "B, C and D are empty but in the order")
        doc.patterns[.loop]![track: 0].place(60, at: 0, steps: 1)
        doc.copy(.loop, to: .b)
        doc.order = SLOOPOrder(entries: [.init(section: 0, bars: 4), .init(section: 1, bars: 2)], loops: true)
        XCTAssertEqual(doc.emptyEntries, [])
        let a = doc.archive()
        XCTAssertNoThrow(try SLOOPArchive.restoreOrder(a), "it restores as any saved song")
        let back = try SLOOPSongDoc(a)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(back.patterns[.b]?[track: 0].chords.first?.notes, [60])
        doc.erase(.b)
        XCTAssertEqual(try SLOOPSongDoc(doc.archive()).isEmpty(.b), true)
    }

    func testOlderFormatsAreKeptAsTheyAre() throws {
        var a = sloopSong(sections: [0])
        let old = Data([0x35, 0x4E, 0x55, 0x46] + [UInt8](repeating: 1, count: 3836))   // a "FUN5" section
        a.parts[2] = .init(id: "2", label: "Section A", data: old)
        var doc = try SLOOPSongDoc(a)
        XCTAssertTrue(doc.locked.contains(.a))
        XCTAssertFalse(doc.isEmpty(.a))
        doc.copy(.loop, to: .a)
        XCTAssertEqual(doc.archive().part("2")?.data, old)
    }
}

final class SLOOPSongFileTests: XCTestCase {
    func testRoundTripKeepsTheNameAndOnlyTheSong() throws {
        var a = sloopSong(sections: [0, 2])
        a.parts.append(.init(id: "32", label: "Sample slot USR1", data: Data(repeating: 9, count: 100)))
        let file = try SLOOPSongFile.encode(a, name: "Night drive")
        let (back, name) = try SLOOPSongFile.decode(file)
        XCTAssertEqual(name, "Night drive")
        XCTAssertNil(back.info["name"])
        XCTAssertEqual(back.parts.map(\.id), ["0", "1", "2", "3", "4", "5"], "samples aren't part of a song")
        XCTAssertTrue(SLOOPSongFile.same(back, a))
        XCTAssertEqual(SLOOPSongFile.fileName("A/B: mix?"), "A-B- mix-.fm1song")
    }

    func testRefusesOtherFiles() throws {
        XCTAssertThrowsError(try SLOOPSongFile.decode(Data("{}".utf8)))
        var felucca = sloopSong(); felucca.format = "felucca-backup"
        XCTAssertThrowsError(try SLOOPSongFile.decode(felucca.encoded()))
        var damaged = sloopSong()
        damaged.parts[0].crc ^= 1
        XCTAssertThrowsError(try SLOOPSongFile.decode(damaged.encoded()), "a damaged song is refused")
    }

    func testReadsTheWebAppsJSON() throws {
        // the web app's DeviceArchive: base64 data, created in seconds since 1970, family as a string
        let json = """
        {"format":"sloop-backup","family":"felucca","firmware":"FELUCCA 2.8.5","created":1763350000.5,
         "parts":[{"id":"0","label":"Loop in progress","data":"\(sloopProject().base64EncodedString())","crc":\(SysExCoding.crc32(sloopProject()))},
                  {"id":"1","label":"Settings and song order","data":"\(sloopSettings().base64EncodedString())","crc":\(SysExCoding.crc32(sloopSettings()))}],
         "info":{"contents":"song","name":"From the web"}}
        """
        let (a, name) = try SLOOPSongFile.decode(Data(json.utf8))
        XCTAssertEqual(name, "From the web")
        XCTAssertNoThrow(try SLOOPSongDoc(a))
    }
}

final class SLOOPAudioImportTests: XCTestCase {
    func testAppliesPartsToTracksAndKeepsSounds() throws {
        var doc = try SLOOPSongDoc(sloopSong(sections: [0]))
        let json = """
        {"start": 1.2, "bpm": 92, "bass": [{"step": 0, "len": 4, "pitch": 36}], "lead": [{"step": 8, "len": 1, "pitch": 72}],
         "keys": [{"step": 4, "len": 2, "pitches": [60, 64]}], "drums": [{"step": 0, "lanes": [0, 4]}, {"step": 4, "lanes": [2]}]}
        """
        let sec = try JSONDecoder().decode(SLOOPAudioSection.self, from: Data(json.utf8))
        let soundByte = doc.patterns[.a]![track: 0].raw[122]
        doc.apply(SLOOPImportPlan(sections: [sec, sec], targets: [0, 2], tempo: 92, order: true))
        for slot in [SLOOPSongDoc.Slot.a, .c] {
            let p = try XCTUnwrap(doc.patterns[slot])
            XCTAssertEqual(p.bpm, 92)
            XCTAssertEqual(p[track: 0].length, 64)
            XCTAssertEqual(p[track: 0].div, 2)
            XCTAssertEqual(p[track: 0].chords, [SLOOPChord(at: 0, length: 4, notes: [36], velocity: 96)])
            XCTAssertEqual(p[track: 1].chords.first?.notes, [60, 64])
            XCTAssertEqual(p[track: 2].chords.first?.at, 8)
            XCTAssertTrue(p[track: 3].drum(at: 0, lane: 0) && p[track: 3].drum(at: 0, lane: 4) && p[track: 3].drum(at: 4, lane: 2))
            XCTAssertNotNil(SLOOPPattern(p.data), "SLOOP would load it")
        }
        XCTAssertEqual(doc.patterns[.a]![track: 0].raw[122], soundByte, "the track's sound stays")
        XCTAssertTrue(doc.isEmpty(.b))
        XCTAssertEqual(doc.patterns[.loop]?.bpm, 92)
        XCTAssertEqual(doc.order?.entries, [.init(section: 0, bars: 4), .init(section: 2, bars: 4)])
    }

    func testSkippedPartsAndNoTempoLeaveThingsAsTheyAre() throws {
        var doc = try SLOOPSongDoc(sloopSong(sections: [0]))
        let sec = SLOOPAudioSection(start: 0, bpm: 92, bass: [.init(step: 0, len: 4, pitch: 36)], lead: [.init(step: 8, len: 1, pitch: 72)], keys: [], drums: [])
        var tracks = SLOOPImportPlan.defaultTracks; tracks[.lead] = nil
        doc.apply(SLOOPImportPlan(sections: [sec], targets: [0], tracks: tracks, tempo: nil, order: false))
        XCTAssertEqual(doc.patterns[.a]![track: 2].length, 16, "the lead's track untouched")
        XCTAssertEqual(doc.patterns[.a]!.bpm, 120)
        XCTAssertEqual(doc.order?.entries.count, 4)
    }
}
