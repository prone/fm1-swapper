import Foundation
import XCTest
@testable import FM1Kit

/// A synthetic .fwsc: random content with the 20 identity marker bytes set.
func makePackage(product: String, size: Int = 200_000) -> Data {
    var g = SystemRandomNumberGenerator()
    var raw = (0..<size).map { _ in UInt8.random(in: 0...255, using: &g) }
    let chars = Array(product.utf8)
    for i in 0..<20 { raw[i * 0x30 + 0x2F] = i < chars.count ? UInt8((Int(chars[i]) + i + 1) & 0xFF) : 0x7D }
    return Data(raw)
}

final class CodingTests: XCTestCase {
    func testPack7RoundTrip() {
        for n in [0, 1, 6, 7, 8, 64, 513] {
            let d = (0..<n).map { UInt8(($0 * 37 + 11) & 0xFF) }
            let p = SysExCoding.pack7(d)
            XCTAssert(p.allSatisfy { $0 < 128 })
            XCTAssertEqual(SysExCoding.unpack7(p), d)
            XCTAssertEqual(SysExCoding.unpack7Strict(p), d)
        }
    }

    func testMaskPackRoundTrip() throws {
        let d = (0..<300).map { UInt8(($0 * 91) & 0xFF) }
        let p = SysExCoding.maskPack(d)
        XCTAssert(p.allSatisfy { $0 < 128 })
        XCTAssertEqual(try SysExCoding.maskUnpack(p, size: d.count), d)
    }

    func testCRC32() {
        XCTAssertEqual(SysExCoding.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testU32() throws {
        for v: UInt32 in [0, 1, 300, 0xFFFF_FFFF, 81920] {
            XCTAssertEqual(try SysExCoding.u32From7(SysExCoding.u32To7(v)), v)
        }
    }

    func testOTAFramesRoundTrip() {
        let req = OTAProtocol.request(addr: 0x1234, len: 512, flags: 3)
        XCTAssertEqual(OTAProtocol.parseRequest(req), .init(flags: 3, addr: 0x1234, len: 512))
        XCTAssertEqual(OTAProtocol.parseIdentity(OTAProtocol.identityReply("FM-1_918"))?.text, "FM-1_918")
    }

    func testUMPSysExRoundTrip() {
        for n in [0, 1, 6, 7, 12, 13, 700] {
            let msg = [0xF0] + (0..<n).map { UInt8($0 & 0x7F) } + [0xF7]
            var a = SysEx7Assembler()
            let words = SysEx7Assembler.words(for: msg)
            let out = words.withUnsafeBufferPointer { a.feed($0) }
            XCTAssertEqual(out, [msg], "n=\(n)")
        }
    }

    func testIdentityFamilies() {
        XCTAssertEqual(DeviceIdentity(text: "FM-1_015")?.family, .official)
        XCTAssertEqual(DeviceIdentity(text: "FM-1_918")?.family, .felucca)
        XCTAssertEqual(DeviceIdentity(text: "FM-1_8000014")?.family, .fm1Open)
        XCTAssertEqual(DeviceIdentity(text: "ota-FM-1_001")?.family, .updateLoader)
        XCTAssertEqual(DeviceIdentity(text: "ota-FM-1_001")?.baseModel, "FM-1")
        XCTAssertNil(DeviceIdentity(text: "garbage"))
    }
}

final class PackageTests: XCTestCase {
    func testSyntheticPackage() throws {
        let data = makePackage(product: "FM-1_918")
        let p = try FirmwarePackage(data: data)
        XCTAssertEqual(p.product, "FM-1_918")
        XCTAssertEqual(p.model, "FM-1")
        XCTAssertEqual(p.logicalImage.count, data.count - 20)
        XCTAssertNil(p.stock)
    }

    func testRejectsJunk() {
        XCTAssertThrowsError(try FirmwarePackage(data: Data(count: 10)))
        XCTAssertThrowsError(try FirmwarePackage(data: Data(repeating: 0x7D, count: 5000)))
    }

    /// FM1_TEST_FWSC=/path/to/felucca-1.8.2.fwsc swift test
    func testRealPackage() throws {
        guard let path = ProcessInfo.processInfo.environment["FM1_TEST_FWSC"] else { throw XCTSkip("FM1_TEST_FWSC not set") }
        let p = try FirmwarePackage(data: try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(p.product, "FM-1_918")
        XCTAssertEqual(p.sha256, "770ea7c756088d08ac59a193f1ae78126476c3c8251a86938c837ead5ab0048a")
        XCTAssertEqual(p.identity?.family, .felucca)
    }
}

final class WorkbenchTests: XCTestCase {
    /// FM1_TEST_WORKBENCH=/path/to/FM1-Open-V14-Workbench.html swift test
    func testExtractsPackages() throws {
        guard let path = ProcessInfo.processInfo.environment["FM1_TEST_WORKBENCH"] else { throw XCTSkip("FM1_TEST_WORKBENCH not set") }
        let found = WorkbenchExtractor.packages(inHTML: try Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(found.map(\.product), ["FM-1_8000014", "FM-1_015"])
        XCTAssertEqual(found[1].package.stock?.version, "V15")
        XCTAssertEqual(found[0].package.identity?.family, .fm1Open)
        XCTAssertEqual(found[0].hardwareValidated, false)
    }

    func testSyntheticWorkbench() {
        let pkg = makePackage(product: "FM-1_8000099")
        let sha = try! FirmwarePackage(data: pkg).sha256
        let html = #"<script>const P=[{"schema":1,"product":"FM-1_8000099","release_version":"V99","sha256":"\#(sha)","data":"\#(pkg.base64EncodedString())"}]</script>"#
        let found = WorkbenchExtractor.packages(inHTML: Data(html.utf8))
        XCTAssertEqual(found.first?.releaseVersion, "V99")
        let bad = html.replacingOccurrences(of: sha, with: String(repeating: "0", count: 64))
        XCTAssertTrue(WorkbenchExtractor.packages(inHTML: Data(bad.utf8)).isEmpty)
    }
}

final class UpdaterTests: XCTestCase {
    func testFullInstallAgainstSimulator() async throws {
        let pkg = try FirmwarePackage(data: makePackage(product: "FM-1_918"))
        let dev = VirtualFM1(identity: "FM-1_015")
        dev.expectedSize = pkg.logicalImage.count
        dev.newIdentity = "FM-1_918"
        let up = OTAUpdater(provider: SimProvider(device: dev), timing: .fast)
        let steps = StepLog()
        let id = try await up.install(pkg) { steps.add($0) }
        XCTAssertEqual(id.text, "FM-1_918")
        XCTAssertEqual(dev.installed, pkg.logicalImage)
        XCTAssertTrue(steps.items.contains(.loader))
        XCTAssertEqual(steps.items.last, .done("FM-1_918"))
    }

    func testWrongModelRefused() async throws {
        let pkg = try FirmwarePackage(data: makePackage(product: "SMK-37_100"))
        let dev = VirtualFM1(identity: "FM-1_015")
        let up = OTAUpdater(provider: SimProvider(device: dev), timing: .fast)
        do {
            _ = try await up.install(pkg)
            XCTFail("should refuse")
        } catch let e as FM1Error {
            XCTAssertEqual(e, .wrongModel(device: "FM-1_015", package: "SMK-37_100"))
        }
        XCTAssertNil(dev.installed)
    }

    func testInterruptedWriteThenResume() async throws {
        let pkg = try FirmwarePackage(data: makePackage(product: "FM-1_8000014"))
        let dev = VirtualFM1(identity: "FM-1_015")
        dev.expectedSize = pkg.logicalImage.count
        dev.newIdentity = "FM-1_8000014"
        dev.dropAfter = 40
        let up = OTAUpdater(provider: SimProvider(device: dev), timing: .fast)
        do { _ = try await up.install(pkg); XCTFail("should stop") } catch let e as FM1Error {
            if case .stopped = e {} else { XCTFail("\(e)") }
        }
        XCTAssertTrue(dev.loader)
        let id = try await up.resume(pkg)
        XCTAssertEqual(id?.text, "FM-1_8000014")
        XCTAssertEqual(dev.installed, pkg.logicalImage)
    }

    func testNotFoundWithoutDevice() async {
        let dev = VirtualFM1(identity: "FM-1_015")
        dev.attached = false
        let up = OTAUpdater(provider: SimProvider(device: dev), timing: .fast)
        let found = await up.identify()
        XCTAssertNil(found)
    }
}

final class ArchiveTests: XCTestCase {
    func connect(_ dev: VirtualFM1) async throws -> ConnectedDevice {
        let up = OTAUpdater(provider: SimProvider(device: dev), timing: .fast)
        guard let d = await up.find() else { throw FM1Error.notFound }
        return d
    }

    func testFeluccaCaptureAndRestore() async throws {
        let dev = VirtualFM1(identity: "FM-1_918")
        for id in FeluccaArchive.ids where id < 32 { dev.feluccaObjects[id] = (0..<(id < 2 ? 3000 : 700)).map { UInt8(($0 + Int(id)) & 0xFF) } }
        dev.feluccaObjects[32] = (0..<2000).map { UInt8($0 & 0xFF) }
        let device = try await connect(dev)
        let archive = try await Archives.capture(device)
        XCTAssertEqual(archive.family, .felucca)
        XCTAssertEqual(archive.parts.count, FeluccaArchive.ids.count)
        XCTAssertEqual(archive.part("0")?.data, Data(dev.feluccaObjects[0]!))

        // round-trip through the stored JSON and Felucca's own file format
        let stored = try DeviceArchive.decode(try archive.encoded())
        XCTAssertEqual(stored.parts, archive.parts)
        XCTAssertEqual(stored.created.timeIntervalSince1970, archive.created.timeIntervalSince1970, accuracy: 0.001)
        let native = try FeluccaArchive.fromNativeJSON(try FeluccaArchive.nativeJSON(archive))
        XCTAssertEqual(native.parts.map(\.data), archive.parts.map(\.data))

        let original = dev.feluccaObjects
        dev.feluccaObjects = [:]
        try await Archives.restore(stored, to: device)
        for id in FeluccaArchive.ids where id < 32 { XCTAssertEqual(dev.feluccaObjects[id] ?? [], original[id] ?? [], "object \(id)") }
        XCTAssertEqual(dev.feluccaObjects[32]?.count, 2000)
        XCTAssertEqual(Array(dev.feluccaObjects[32]![512...]), Array(original[32]![512...]))
    }

    func testOldFeluccaRefusesArchive() async throws {
        let dev = VirtualFM1(identity: "FM-1_906")
        dev.feluccaInfoSupported = false
        let device = try await connect(dev)
        do { _ = try await Archives.capture(device); XCTFail() } catch let e as FM1Error {
            if case .unsupported = e {} else { XCTFail("\(e)") }
        }
    }

    func testFM1OpenCaptureAndRestore() async throws {
        let dev = VirtualFM1(identity: "FM-1_8000014")
        dev.openProject = (0..<4264).map { UInt8(($0 * 7) & 0xFF) }
        let device = try await connect(dev)
        let archive = try await Archives.capture(device)
        XCTAssertEqual(archive.family, .fm1Open)
        XCTAssertEqual(archive.part("project")?.data.count, 4264)
        XCTAssertEqual(archive.parts.filter { $0.id.hasPrefix("timbre") }.count, 8)
        XCTAssertEqual(archive.parts.filter { $0.id.hasPrefix("dx7") }.count, 4)
        XCTAssertEqual(archive.part("samples")?.data, Data(dev.openSamples))
        XCTAssertTrue(archive.info["slotNames"]?.hasPrefix("SLOT 0|SLOT 1") ?? false)
        let files = try archive.exportFiles()
        XCTAssertEqual(files.count, 4)
        XCTAssertEqual(files[0].data.count, 4096 + 8)

        let project = dev.openProject, dx7 = dev.openDX7, timbres = dev.openTimbres, samples = dev.openSamples
        dev.openProject = []; dev.openDX7 = Array(repeating: [], count: 4); dev.openTimbres = Array(repeating: [], count: 8); dev.openSamples = []
        try await Archives.restore(archive, to: device)
        XCTAssertEqual(dev.openProject, project)
        XCTAssertEqual(dev.openDX7, dx7)
        XCTAssertEqual(dev.openTimbres, timbres)
        XCTAssertEqual(dev.openSamples, samples)
    }

    func testOfficialHasNoArchive() async throws {
        let dev = VirtualFM1(identity: "FM-1_016")
        let device = try await connect(dev)
        do { _ = try await Archives.capture(device); XCTFail() } catch let e as FM1Error {
            if case .unsupported = e {} else { XCTFail("\(e)") }
        }
    }
}

final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [UpdateStep] = []
    func add(_ s: UpdateStep) { lock.withLock { if _items.last != s, !isProgress(s) || !isProgress(_items.last) { _items.append(s) } } }
    private func isProgress(_ s: UpdateStep?) -> Bool {
        switch s { case .verify, .write: true; default: false }
    }
    var items: [UpdateStep] { lock.withLock { _items } }
}

final class MonitorTests: XCTestCase {
    func testUMPToMIDI1() {
        let words: [UInt32] = [0x2090_3C64, 0x20C0_0500, 0x10F8_0000, 0x3001_0102, 0x0000_0000, 0x20E0_0040]
        let out = words.withUnsafeBufferPointer { UMPToMIDI1.messages($0) }
        XCTAssertEqual(out, [[0x90, 0x3C, 0x64], [0xC0, 0x05], [0xF8], [0xE0, 0x00, 0x40]])
    }
}
