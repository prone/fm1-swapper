// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import XCTest
@testable import FM1Kit

/// Captured from a real SMC-PAD by github.com/spectalive/smc-pad (reference/gatt_unlock.txt, Apache-2.0).
let capturedUnlock: [String] = [
        "00 59 11 00 00 00 FF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 05 00 00 00 00 F1 03 00 06",
        "00 59 23 08 00 00 05 F1 03 00 00 F1 03 00 12",
        "00 59 23 08 00 00 05 E2 07 00 00 F1 03 00 1D",
        "00 59 23 08 00 00 05 D3 0B 00 00 F1 03 00 28",
        "00 59 23 08 00 00 05 C4 0F 00 00 F1 03 00 33",
        "00 59 23 08 00 00 05 B5 13 00 00 F1 03 00 3E",
        "00 59 23 08 00 00 05 A6 17 00 00 F1 03 00 49",
        "00 59 23 08 00 00 05 97 1B 00 00 F1 03 00 54",
        "00 59 23 08 00 00 05 88 1F 00 00 F1 03 00 5F",
        "00 59 23 08 00 00 05 79 23 00 00 F1 03 00 6A",
        "00 59 23 08 00 00 05 6A 27 00 00 F1 03 00 75",
        "00 59 23 08 00 00 05 5B 2B 00 00 F1 03 00 80",
        "00 59 23 08 00 00 05 4C 2F 00 00 F1 03 00 8B",
        "00 59 23 08 00 00 05 3D 33 00 00 F1 03 00 96",
        "00 59 23 08 00 00 05 2E 37 00 00 F1 03 00 A1",
        "00 59 23 08 00 00 05 1F 3B 00 00 F1 03 00 AC",
        "00 59 23 08 00 00 05 10 3F 00 00 F1 03 00 B7",
        "00 59 23 08 00 00 05 01 43 00 00 F1 03 00 C2",
        "00 59 23 08 00 00 05 F2 46 00 00 F1 03 00 CE",
        "00 59 23 08 00 00 05 E3 4A 00 00 F1 03 00 D9",
        "00 59 23 08 00 00 05 D4 4E 00 00 F1 03 00 E4",
        "00 59 23 08 00 00 05 C5 52 00 00 F1 03 00 EF",
        "00 59 23 08 00 00 05 B6 56 00 00 F1 03 00 FA",
        "00 59 23 08 00 00 05 A7 5A 00 00 F1 03 00 05",
        "00 59 23 08 00 00 05 98 5E 00 00 F1 03 00 10",
        "00 59 23 08 00 00 05 89 62 00 00 F1 03 00 1B",
        "00 59 23 08 00 00 05 7A 66 00 00 F1 03 00 26",
        "00 59 23 08 00 00 05 6B 6A 00 00 F1 03 00 31",
        "00 59 23 08 00 00 05 5C 6E 00 00 3C 00 00 F4",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF",
        "00 59 23 08 00 00 04 00 00 00 00 0C 00 00 EF"
    ]
let capturedColorWrite = "00 59 22 0B 00 00 05 18 04 00 00 03 00 00 00 00 00 DB"

func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

final class SMCPadTests: XCTestCase {
    func testUnlockMatchesCapture() {
        XCTAssertEqual(SMCPadProtocol.unlock.map(hex), capturedUnlock)
    }

    func testColorWriteMatchesCapture() {
        XCTAssertEqual(SMCPadProtocol.colorAddress(note: 36), 0x418)
        XCTAssertEqual(hex(SMCPadProtocol.colorWrite(note: 36, r: 0, g: 0, b: 0)), capturedColorWrite)
        XCTAssertEqual(SMCPadProtocol.colorAddress(note: 52), 0x418 + 16 * 26)
    }

    func testSameServiceProtocolAsFM1() {
        // the discovery message MIDI Suite sends is the FM-1 updater's handshake
        XCTAssertEqual(Sinco.sysex(Sinco.queryName), OTAProtocol.handshakeQuery)
        XCTAssertEqual(Sinco.fromSysex(Sinco.sysex(Sinco.queryName)), Sinco.queryName)
    }

    func testFramesAcrossChunks() {
        let reply = Sinco.packet(0x11, Array("SMC-PAD_004".utf8) + [UInt8](repeating: 0, count: 16))
        var buf = Array(reply.prefix(10))
        XCTAssertTrue(Sinco.frames(&buf).isEmpty)
        buf += reply.dropFirst(10) + Sinco.packet(0x00, [0])
        let f = Sinco.frames(&buf)
        XCTAssertEqual(f.count, 2)
        XCTAssertEqual(SMCPadProtocol.name(fromReply: f[0]), "SMC-PAD_004")
        XCTAssertTrue(buf.isEmpty)
    }
}
