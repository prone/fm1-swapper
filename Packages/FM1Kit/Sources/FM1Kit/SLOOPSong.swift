// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import Foundation

// A SLOOP song as data you can edit: the loop in progress, sections A–D and the song order, read from a saved
// song (or a SLOOP backup) and written back as one. The layouts follow SLOOP 2.6 and later (isod89/sloop-fm1
// `firmware/src/project.c` project_t "FUN6", `core.h` step_t / dstep_t, `arranger.h` arr_config_t at bytes 48–83 of
// the settings, the same bytes SLOOP's own web editor edits). Older formats are left as they are and not edited.
//
// The edits match SLOOP's web editor (its piano roll: a NOTE step holds a chord of up to 4 notes, the TIE steps
// after it hold it, a REST is silence; the drum track is 16 lanes). Every pattern is at most 64 steps, so a section is
// a few bars; a longer song is the sections chained in the song order (16 entries, each 1–64 bars).

// MARK: Sections (project_t)

/// A section (or the loop in progress): SLOOP's format-6 project, 4 tracks.
public struct SLOOPPattern: Equatable, Sendable {
    public static let magic: UInt32 = 0x4655_4E36          // "FUN6"
    public static let size = 3816
    static let trackBase = 76, trackSize = 934, sumAt = 3812

    public private(set) var raw: [UInt8]

    /// A section's bytes; nil when the data isn't a format-6 project (empty, or written by SLOOP 2.5 or older).
    public init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count == Self.size, SysExCoding.le32(b, 0) == Self.magic, SysExCoding.le32(b, 4) == UInt32(Self.size),
              SysExCoding.le32(b, Self.sumAt) == Self.fnv(b[0..<Self.sumAt]) else { return nil }
        raw = b
    }

    /// The bytes to send, with the checksum SLOOP checks on load.
    public var data: Data {
        var b = raw
        let s = Self.fnv(b[0..<Self.sumAt])
        for i in 0..<4 { b[Self.sumAt + i] = UInt8(truncatingIfNeeded: s >> (8 * i)) }
        return Data(b)
    }

    /// Same content (the checksum is worked out when the bytes are sent).
    public static func == (a: SLOOPPattern, b: SLOOPPattern) -> Bool { a.raw[0..<sumAt] == b.raw[0..<sumAt] }

    /// The tempo (G_BPM, 40–240).
    public var bpm: Int {
        get { Int(Int16(bitPattern: UInt16(raw[8]) | UInt16(raw[9]) << 8)) }
        set { let v = UInt16(max(40, min(240, newValue))); raw[8] = UInt8(v & 255); raw[9] = UInt8(v >> 8) }
    }

    public subscript(track k: Int) -> SLOOPTrack {
        get { SLOOPTrack(raw: Array(raw[Self.trackBase + k * Self.trackSize ..< Self.trackBase + (k + 1) * Self.trackSize]), isDrum: k == SLOOPTrack.drumTrack) }
        set { raw.replaceSubrange(Self.trackBase + k * Self.trackSize ..< Self.trackBase + (k + 1) * Self.trackSize, with: newValue.raw) }
    }

    /// How many bars the section plays as a loop: its longest track (SLOOP's section_bars).
    public var bars: Int { max(1, min(64, (0..<4).map { self[track: $0].bars }.max() ?? 1)) }

    static func fnv(_ b: ArraySlice<UInt8>) -> UInt32 {
        var s: UInt32 = 0x811C_9DC5
        for x in b { s = (s ^ UInt32(x)) &* 16_777_619 }
        return s
    }
}

// MARK: Tracks and steps

/// One step: 10 bytes. On a synth track: notes 0–3, the count, time (0 note, 1 tie, 2 rest), flags, velocity, levels,
/// ratchets. On the drum track: a bit per lane, then 2 bits of level and of ratchet per lane.
public struct SLOOPStep: Equatable, Sendable {
    public var b: [UInt8]
    public init(_ b: [UInt8]) { self.b = b }

    public static let rest = SLOOPStep([0, 0, 0, 0, 0, 2, 0, 0, 0, 0])
    public static let tie = SLOOPStep([0, 0, 0, 0, 0, 1, 0, 0, 0, 0])
    public static let emptyDrum = SLOOPStep([UInt8](repeating: 0, count: 10))
    static func note(_ pitch: UInt8) -> SLOOPStep { SLOOPStep([pitch, 0, 0, 0, 1, 0, 0, 96, 0, 0]) }

    public var isNote: Bool { b[5] == 0 && b[4] > 0 }
    public var isTie: Bool { b[5] == 1 }
    public var notes: [UInt8] { Array(b[0..<Int(min(b[4], 4))]) }
    public var velocity: Int { Int(b[7]) }

    mutating func setNotes(_ n: [UInt8]) {
        for i in 0..<4 { b[i] = i < n.count ? n[i] : 0 }
        b[4] = UInt8(n.count)
    }

    public func drum(_ lane: Int) -> Bool { (b[lane >> 3] >> (lane & 7)) & 1 == 1 }
    public var drumLanes: Int { Int(b[0]) | Int(b[1]) << 8 }
    mutating func setDrum(_ lane: Int, _ on: Bool) {
        let sh = (lane & 3) * 2, i = (lane >> 2) & 3
        if on { b[lane >> 3] |= 1 << (lane & 7) } else { b[lane >> 3] &= ~(1 << (lane & 7)) }
        b[2 + i] &= ~(3 << sh)
        b[6 + i] &= ~(3 << sh)
    }
}

/// A chord on a synth track: it starts at step `at`, lasts `length` steps (the NOTE step and its ties).
public struct SLOOPChord: Equatable, Sendable {
    public let at: Int, length: Int, notes: [UInt8], velocity: Int
}

/// Steps copied out of a track: their bytes, nudges/conditions and parameter locks, to paste anywhere on a track of
/// the same kind.
public struct SLOOPClip: Equatable, Sendable {
    public let isDrum: Bool
    public let steps: [SLOOPStep]
    let mf: [UInt8]
    let locks: [(step: Int, param: UInt8, val: [UInt8])]
    public var count: Int { steps.count }

    public static func == (a: SLOOPClip, b: SLOOPClip) -> Bool {
        a.isDrum == b.isDrum && a.steps == b.steps && a.mf == b.mf && a.locks.map { [UInt8($0.step), $0.param] + $0.val } == b.locks.map { [UInt8($0.step), $0.param] + $0.val }
    }
}

public struct SLOOPTrack: Equatable, Sendable {
    public static let drumTrack = 3
    public static let maxSteps = 64
    /// Steps in a 4/4 bar for each step length (SLOOP's DIV: 1/4, 1/8, 1/16, 1/32, 8T, 16T, 1/2, 1 bar, 2 bars).
    public static let stepsPerBarForDiv: [Double] = [4, 8, 16, 32, 12, 24, 2, 1, 0.5]
    public static let divNames = ["1/4", "1/8", "1/16", "1/32", "8T", "16T", "1/2", "1 bar", "2 bars"]
    /// The drum track's 16 sounds, as SLOOP names them (one per white key).
    public static let drumLanes = ["KICK", "KICK 2", "SNARE", "CLAP", "HAT", "OPEN HAT", "PEDAL", "RIM", "SNARE 2",
                                   "LOW TOM", "HI TOM", "CRASH", "RIDE", "SHAKER", "CONGA", "COWBELL"]
    static let lenAt = 29 * 2, divAt = 30 * 2, stepsAt = 134, mfAt = 774, locksAt = 838, nLocks = 24

    public internal(set) var raw: [UInt8]
    public let isDrum: Bool

    /// LEN: the steps the pattern plays (1–64).
    public var length: Int {
        get { max(1, min(Self.maxSteps, Int(Int16(bitPattern: UInt16(raw[Self.lenAt]) | UInt16(raw[Self.lenAt + 1]) << 8)))) }
        set { let v = UInt16(max(1, min(Self.maxSteps, newValue))); raw[Self.lenAt] = UInt8(v & 255); raw[Self.lenAt + 1] = UInt8(v >> 8) }
    }
    /// DIV: the length of one step, an index into `divNames` (2: 1/16).
    public var div: Int {
        get { max(0, min(8, Int(raw[Self.divAt]))) }
        set { raw[Self.divAt] = UInt8(max(0, min(8, newValue))); raw[Self.divAt + 1] = 0 }
    }
    public var stepsPerBar: Double { Self.stepsPerBarForDiv[div] }
    /// Whole steps in a bar, or nil when a step is longer than a bar (bar edits don't apply).
    public var barSteps: Int? { stepsPerBar >= 1 ? Int(stepsPerBar) : nil }
    public var bars: Int { Int((Double(length) / stepsPerBar).rounded(.up)) }

    public func step(_ i: Int) -> SLOOPStep { SLOOPStep(Array(raw[Self.stepsAt + i * 10 ..< Self.stepsAt + i * 10 + 10])) }
    mutating func setStep(_ i: Int, _ s: SLOOPStep) { raw.replaceSubrange(Self.stepsAt + i * 10 ..< Self.stepsAt + i * 10 + 10, with: s.b) }
    var empty: SLOOPStep { isDrum ? .emptyDrum : .rest }

    // Reads of one step's bytes in place (no allocation: the grids and the loops below call them per step).
    private func byte(_ i: Int, _ k: Int) -> UInt8 { raw[Self.stepsAt + i * 10 + k] }
    func isNote(_ i: Int) -> Bool { byte(i, 5) == 0 && byte(i, 4) > 0 }
    func isTie(_ i: Int) -> Bool { byte(i, 5) == 1 }
    /// Whether drum `lane` plays on step `i`.
    public func drum(at i: Int, lane: Int) -> Bool { (byte(i, lane >> 3) >> (lane & 7)) & 1 == 1 }
    /// No note or drum hit in the steps it plays.
    public var isSilent: Bool { (0..<length).allSatisfy { isDrum ? byte($0, 0) | byte($0, 1) == 0 : !isNote($0) } }

    // MARK: Synth track: the piano roll (SLOOP's web editor, ROLL)

    public var chords: [SLOOPChord] {
        guard !isDrum else { return [] }
        var out: [SLOOPChord] = []
        for i in 0..<length where isNote(i) {
            var d = 1
            while i + d < length, isTie(i + d) { d += 1 }
            let s = step(i)
            out.append(SLOOPChord(at: i, length: d, notes: s.notes, velocity: s.velocity))
        }
        return out
    }

    /// The NOTE step of the chord sounding at step i, or nil.
    public func owner(_ i: Int) -> Int? {
        var k = i
        while k >= 0 {
            if isNote(k) { return k }
            if !isTie(k) { return nil }
            k -= 1
        }
        return nil
    }

    private mutating func cutTies(from end: Int) {
        var k = end
        while k < length, isTie(k) { setStep(k, .rest); k += 1 }
    }

    /// Puts `pitch` at step `at` for `steps` steps. On a chord's first step it joins the chord (4 notes at most);
    /// inside a held chord, that chord ends there and a new one starts.
    public mutating func place(_ pitch: UInt8, at: Int, steps dur: Int) {
        guard !isDrum, at >= 0, at < length else { return }
        let s = step(at)
        if s.isNote {
            guard !s.notes.contains(pitch), s.notes.count < 4 else { return }
            var n = s; n.setNotes(s.notes + [pitch]); setStep(at, n)
            return
        }
        setStep(at, .note(pitch & 127))
        var k = 1
        while k < dur, at + k < length, !isNote(at + k) { setStep(at + k, .tie); k += 1 }
        cutTies(from: at + k)
    }

    /// Takes `pitch` off the chord starting at `at`; the last note leaves rests where the chord was.
    public mutating func remove(_ pitch: UInt8, at: Int) {
        guard !isDrum, at >= 0, at < length else { return }
        let s = step(at)
        guard s.isNote, s.notes.contains(pitch) else { return }
        let left = s.notes.filter { $0 != pitch }
        if left.isEmpty { setStep(at, .rest); cutTies(from: at + 1) } else { var n = s; n.setNotes(left); setStep(at, n) }
    }

    // MARK: Drum track

    public mutating func toggleDrum(lane: Int, at: Int) {
        guard isDrum, at >= 0, at < Self.maxSteps, (0..<16).contains(lane) else { return }
        var s = step(at); s.setDrum(lane, !s.drum(lane)); setStep(at, s)
    }

    // MARK: Whole track and bars

    /// Every step empty, no nudges, no locks. The sound and LEN stay.
    public mutating func clear() {
        for i in 0..<Self.maxSteps { setStep(i, empty) }
        clearExtras(0..<Self.maxSteps)
    }

    /// Empties some steps (their nudges and locks too); LEN stays.
    public mutating func clear(_ r: Range<Int>) {
        let r = r.clamped(to: 0..<Self.maxSteps)
        for i in r { setStep(i, empty) }
        clearExtras(r)
        tidy()
    }

    /// Adds `steps` empty steps at the end (LEN grows, 64 at most).
    public mutating func extend(by steps: Int) {
        let from = length, to = min(Self.maxSteps, length + steps)
        guard to > from else { return }
        clear(from..<to)
        length = to
    }

    private mutating func clearExtras(_ r: Range<Int>) {
        for i in r { raw[Self.mfAt + i] = 0 }
        for l in 0..<Self.nLocks {
            let at = Self.locksAt + l * 4
            if raw[at] != 0xFF, r.contains(Int(raw[at])) { raw.replaceSubrange(at..<at + 4, with: [0xFF, 0, 0, 0]) }
        }
    }

    public func copy(_ r: Range<Int>) -> SLOOPClip {
        let r = r.clamped(to: 0..<Self.maxSteps)
        var locks: [(Int, UInt8, [UInt8])] = []
        for l in 0..<Self.nLocks {
            let at = Self.locksAt + l * 4
            if raw[at] != 0xFF, r.contains(Int(raw[at])) { locks.append((Int(raw[at]) - r.lowerBound, raw[at + 1], [raw[at + 2], raw[at + 3]])) }
        }
        return SLOOPClip(isDrum: isDrum, steps: r.map(step), mf: Array(raw[Self.mfAt + r.lowerBound ..< Self.mfAt + r.upperBound]), locks: locks)
    }

    /// Writes the clip over the steps from `at` (what doesn't fit in 64 steps is dropped); LEN grows to cover it.
    /// Returns false for a clip from the other kind of track.
    @discardableResult
    public mutating func paste(_ clip: SLOOPClip, at: Int) -> Bool {
        guard clip.isDrum == isDrum, at >= 0, at < Self.maxSteps else { return false }
        let n = min(clip.count, Self.maxSteps - at)
        clearExtras(at..<at + n)
        for i in 0..<n { setStep(at + i, clip.steps[i]); raw[Self.mfAt + at + i] = clip.mf[i] }
        for l in clip.locks where l.step < n {
            guard let free = (0..<Self.nLocks).first(where: { raw[Self.locksAt + $0 * 4] == 0xFF }) else { break }
            raw.replaceSubrange(Self.locksAt + free * 4 ..< Self.locksAt + free * 4 + 4, with: [UInt8(at + l.step), l.param] + l.val)
        }
        if at + n > length { length = at + n }
        cutTies(from: at + n)                         // a chord the clip cut into doesn't run on into its last note
        tidy()
        return true
    }

    /// Makes room at `at` and pastes the clip there: the steps after it move later, LEN grows (64 at most; steps
    /// pushed past 64 are dropped).
    @discardableResult
    public mutating func insert(_ clip: SLOOPClip, at: Int) -> Bool {
        guard clip.isDrum == isDrum, at >= 0, at <= length, at < Self.maxSteps else { return false }
        let newLength = min(Self.maxSteps, length + clip.count)
        move(from: at, to: at + clip.count)
        length = newLength
        return paste(clip, at: at)
    }

    /// Takes steps out; the steps after them move earlier and LEN shrinks (1 at least).
    public mutating func delete(_ r: Range<Int>) {
        let r = r.clamped(to: 0..<length)
        guard !r.isEmpty else { return }
        let newLength = max(1, length - r.count)
        move(from: r.upperBound, to: r.lowerBound)
        length = newLength
        tidy()
    }

    /// Moves the steps from `from` to the end so they start at `to` (with their nudges and locks); steps pushed past
    /// 64 are dropped, the steps left behind are empty.
    private mutating func move(from: Int, to: Int) {
        guard from != to else { return }
        let n = Self.maxSteps
        let steps = (0..<n).map(step), mf = Array(raw[Self.mfAt ..< Self.mfAt + n])
        let lo = min(from, to)
        for i in lo..<n {
            let src = i - to + from
            let ok = src >= from && src < n
            setStep(i, ok ? steps[src] : empty)
            raw[Self.mfAt + i] = ok ? mf[src] : 0
        }
        for l in 0..<Self.nLocks {
            let at = Self.locksAt + l * 4
            guard raw[at] != 0xFF else { continue }
            let s = Int(raw[at])
            if s >= from {
                let d = s - from + to
                if d < n { raw[at] = UInt8(d) } else { raw.replaceSubrange(at..<at + 4, with: [0xFF, 0, 0, 0]) }
            } else if s >= lo {                                        // (moving earlier: steps overwritten)
                raw.replaceSubrange(at..<at + 4, with: [0xFF, 0, 0, 0])
            }
        }
    }

    /// A tie with no chord before it (left by a cut or a paste) becomes a rest: one pass, tracking whether a chord
    /// is still sounding.
    mutating func tidy() {
        guard !isDrum else { return }
        var sounding = false
        for i in 0..<Self.maxSteps {
            if isNote(i) { sounding = true } else if isTie(i) { if !sounding { setStep(i, .rest) } } else { sounding = false }
        }
    }
}

// MARK: The song order (arr_config_t in the settings)

public struct SLOOPOrder: Equatable, Sendable {
    public struct Entry: Equatable, Sendable, Hashable {
        public var section: Int, bars: Int
        public init(section: Int, bars: Int) { self.section = section; self.bars = bars }
    }
    public static let at = 48, maxEntries = 16, maxBars = 64
    static let settingsMagic: UInt32 = 0x5045_5233                 // "PER3"
    public var entries: [Entry]
    public var loops: Bool
    public init(entries: [Entry], loops: Bool) { self.entries = entries; self.loops = loops }

    /// The order in a settings object, or nil when the settings have none (SLOOP before 2.5).
    public init?(settings d: Data) {
        let b = [UInt8](d)
        guard b.count >= Self.at + 36, SysExCoding.le32(b, 0) == Self.settingsMagic else { return nil }
        let n = Int(b[Self.at])
        guard (1...Self.maxEntries).contains(n) else { return nil }
        entries = (0..<n).map { i in Entry(section: Int(b[Self.at + 4 + 2 * i]) & 3, bars: max(1, min(64, Int(b[Self.at + 5 + 2 * i])))) }
        loops = b[Self.at + 1] == 1
    }

    /// The settings with this order in them (the other entries as SLOOP fills them: A–D, 4 bars).
    public func written(into d: Data) -> Data {
        var b = [UInt8](d)
        b[Self.at] = UInt8(entries.count)
        b[Self.at + 1] = loops ? 1 : 0
        b[Self.at + 2] = 0; b[Self.at + 3] = 0
        for i in 0..<Self.maxEntries {
            let e = i < entries.count ? entries[i] : Entry(section: i % 4, bars: 4)
            b[Self.at + 4 + 2 * i] = UInt8(e.section & 3)
            b[Self.at + 5 + 2 * i] = UInt8(max(1, min(64, e.bars)))
        }
        return Data(b)
    }

    public var totalBars: Int { entries.reduce(0) { $0 + $1.bars } }
}

// MARK: The whole song

public struct SLOOPSongDoc: Equatable, Sendable {
    /// Where a pattern lives: the loop in progress, or a section 0–3 (A–D).
    public enum Slot: Hashable, Sendable, CaseIterable, Identifiable {
        case loop, a, b, c, d
        public var id: Self { self }
        public var name: String { switch self { case .loop: "Loop"; case .a: "A"; case .b: "B"; case .c: "C"; case .d: "D" } }
        public var objectID: String { switch self { case .loop: "0"; case .a: "2"; case .b: "3"; case .c: "4"; case .d: "5" } }
        public static func section(_ i: Int) -> Slot { [.a, .b, .c, .d][i & 3] }
        public var sectionIndex: Int? { switch self { case .loop: nil; case .a: 0; case .b: 1; case .c: 2; case .d: 3 } }
    }

    public var patterns: [Slot: SLOOPPattern]
    /// Slots whose data is there but in a format this can't edit (written by an older SLOOP); they are kept as they are.
    public let locked: Set<Slot>
    public var order: SLOOPOrder?
    let base: DeviceArchive

    public init(_ archive: DeviceArchive) throws {
        guard archive.format == SLOOPArchive.format else { throw FM1Error.badPackage("This isn't a SLOOP song.") }
        base = archive
        var p: [Slot: SLOOPPattern] = [:], locked: Set<Slot> = []
        for s in Slot.allCases {
            guard let d = archive.part(s.objectID)?.data, !d.isEmpty else { continue }
            if let x = SLOOPPattern(d) { p[s] = x } else { locked.insert(s) }
        }
        guard p[.loop] != nil || locked.contains(.loop) else { throw FM1Error.badPackage("The song is missing the loop in progress.") }
        patterns = p
        self.locked = locked
        order = archive.part("1").flatMap { SLOOPOrder(settings: $0.data) }
    }

    public static func == (a: SLOOPSongDoc, b: SLOOPSongDoc) -> Bool { a.patterns == b.patterns && a.order == b.order && a.locked == b.locked }

    public func isEmpty(_ s: Slot) -> Bool { patterns[s] == nil && !locked.contains(s) }

    /// Copies a whole pattern (sounds, steps, tempo) into another slot.
    public mutating func copy(_ from: Slot, to: Slot) {
        guard from != to, let p = patterns[from], !locked.contains(to) else { return }
        patterns[to] = p
    }

    /// Empties a section (not the loop). Song-order entries that played it stay; SLOOP says "EMPTY SECTION" for them.
    public mutating func erase(_ s: Slot) {
        guard s != .loop, !locked.contains(s) else { return }
        patterns[s] = nil
    }

    /// Order entries that point at an empty section (SLOOP won't play the song in song mode until they're filled).
    public var emptyEntries: [Int] {
        guard let o = order else { return [] }
        return o.entries.indices.filter { isEmpty(.section(o.entries[$0].section)) }
    }

    /// The song as a saved song again: the edited slots, the order in the settings, the rest as it was.
    public func archive() -> DeviceArchive {
        var a = base
        a.created = Date()
        a.parts = base.parts.map { part in
            if let s = Slot.allCases.first(where: { $0.objectID == part.id }), !locked.contains(s) {
                return .init(id: part.id, label: part.label, data: patterns[s]?.data ?? Data())
            }
            if part.id == "1", let o = order { return .init(id: part.id, label: part.label, data: o.written(into: part.data)) }
            return part
        }
        for s in Slot.allCases where !a.parts.contains(where: { $0.id == s.objectID }) {
            if let p = patterns[s] { a.parts.append(.init(id: s.objectID, label: SLOOPArchive.label(UInt8(s.objectID)!), data: p.data)) }
        }
        return a
    }
}

// MARK: Song files

/// A saved SLOOP song as a file to share between devices (AirDrop, Files, iCloud Drive) and with the web app:
/// the song's objects (loop, settings, sections A–D) as a DeviceArchive in JSON, its name in `info["name"]`.
public enum SLOOPSongFile {
    public static let fileExtension = "fm1song"
    public static let typeIdentifier = "org.fm1swapper.song"

    /// The file for a song (only its song objects, whatever else the archive holds).
    public static func encode(_ archive: DeviceArchive, name: String) throws -> Data {
        var a = archive
        a.parts = a.parts.filter { UInt8($0.id).map(SLOOPArchive.songIDs.contains) ?? false }
        a.info["name"] = name
        a.info["contents"] = "song"
        return try a.encoded()
    }

    public static func fileName(_ name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "SLOOP song" : String(safe.prefix(80))).\(fileExtension)"
    }

    /// Reads a song file (or a whole SLOOP backup, of which only the song is kept), checked as a load would check
    /// it. Returns the song and the name it was saved under, if the file has one.
    public static func decode(_ data: Data) throws -> (archive: DeviceArchive, name: String?) {
        guard var a = try? DeviceArchive.decode(data) else { throw FM1Error.badPackage("This isn't an FM-1 Swapper song file.") }
        guard a.format == SLOOPArchive.format else { throw FM1Error.badPackage("This file isn't a SLOOP song.") }
        a.parts = a.parts.filter { UInt8($0.id).map(SLOOPArchive.songIDs.contains) ?? false }
        _ = try SLOOPArchive.restoreOrder(a)                                  // checksums, and the loop is there
        let name = a.info["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        a.info["contents"] = "song"
        a.info["name"] = nil
        return (a, name?.isEmpty == false ? name : nil)
    }

    /// Whether two songs hold the same song data (to skip importing one twice).
    public static func same(_ a: DeviceArchive, _ b: DeviceArchive) -> Bool {
        func key(_ x: DeviceArchive) -> [String: UInt32] {
            Dictionary(x.parts.filter { UInt8($0.id).map(SLOOPArchive.songIDs.contains) ?? false }.map { ($0.id, $0.crc) }, uniquingKeysWith: { a, _ in a })
        }
        return a.format == b.format && key(a) == key(b)
    }
}

// MARK: Import from audio

/// One 4-bar section found in audio (the song editor's Import from audio; the analysis runs in
/// `App/AudioImport/`, built from `web/src/audio/`): 64 16ths of bassline, chords, lead and drums.
public struct SLOOPAudioSection: Codable, Sendable, Equatable {
    public struct Note: Codable, Sendable, Equatable { public let step, len, pitch: Int }
    public struct Chord: Codable, Sendable, Equatable { public let step, len: Int; public let pitches: [Int] }
    public struct Hit: Codable, Sendable, Equatable { public let step: Int; public let lanes: [Int] }
    /// Where it starts in the audio (seconds), and its tempo there.
    public let start, bpm: Double
    public let bass, lead: [Note]
    public let keys: [Chord]
    public let drums: [Hit]
    /// A loop of the song: how often it plays, each part's own length in steps ("bass", "keys", "lead", "drums": 16,
    /// 32 or 64), and whether it's a weak find. Absent for a stretch picked by hand.
    public var repeats: Int? = nil
    public var lengths: [String: Int]? = nil
    public var unsure: Bool? = nil
}

/// What goes where when sections are imported.
public struct SLOOPImportPlan: Sendable {
    public enum Part: String, CaseIterable, Sendable { case bass, keys, lead, drums }
    public var sections: [SLOOPAudioSection]
    /// The song section (0–3: A–D) each goes to; as many as `sections`.
    public var targets: [Int]
    /// The track each part goes on (0–2; the drums on 3); nil: not imported.
    public var tracks: [Part: Int]
    /// Every section's (and the loop's) tempo; nil: as they are.
    public var tempo: Int?
    /// The song order becomes the imported sections, 4 bars each.
    public var order: Bool
    public static let defaultTracks: [Part: Int] = [.bass: 0, .keys: 1, .lead: 2, .drums: SLOOPTrack.drumTrack]
    public init(sections: [SLOOPAudioSection], targets: [Int], tracks: [Part: Int] = defaultTracks, tempo: Int?, order: Bool) {
        self.sections = sections; self.targets = targets; self.tracks = tracks; self.tempo = tempo; self.order = order
    }
}

extension SLOOPSongDoc {
    /// The sections' parts onto the tracks chosen (64 16ths each; the tracks' sounds stay); an empty target section
    /// starts as a copy of the loop. The same as the web app's applyImport (web/src/audio/toSong.ts).
    public mutating func apply(_ plan: SLOOPImportPlan) {
        for (i, sec) in plan.sections.enumerated() where i < plan.targets.count {
            let slot = Slot.section(plan.targets[i])
            guard !locked.contains(slot) else { continue }
            if patterns[slot] == nil { copy(patterns[.loop] != nil ? .loop : .a, to: slot) }
            guard var p = patterns[slot] else { continue }
            if let t = plan.tempo { p.bpm = t }
            func fresh(_ part: SLOOPImportPlan.Part) -> Int? {
                guard let k = plan.tracks[part], (0..<4).contains(k) else { return nil }
                p[track: k].div = 2
                p[track: k].length = sec.lengths?[part.rawValue] ?? SLOOPTrack.maxSteps   // (a loop's part: its pattern's length)
                p[track: k].clear()
                return k
            }
            if let k = fresh(.bass) { for n in sec.bass { p[track: k].place(UInt8(clamping: n.pitch), at: n.step, steps: n.len) } }
            if let k = fresh(.keys) { for c in sec.keys { for n in c.pitches { p[track: k].place(UInt8(clamping: n), at: c.step, steps: c.len) } } }
            if let k = fresh(.lead) { for n in sec.lead { p[track: k].place(UInt8(clamping: n.pitch), at: n.step, steps: n.len) } }
            if let k = fresh(.drums), p[track: k].isDrum {
                for h in sec.drums { for l in h.lanes { p[track: k].toggleDrum(lane: l, at: h.step) } }
            }
            patterns[slot] = p
        }
        // the loop is what SLOOP plays when it starts: a silent one gets the first piece, so the song plays at once
        if let k = plan.targets.first, !locked.contains(.loop), let l = patterns[.loop],
           (0..<4).allSatisfy({ l[track: $0].isSilent }) { copy(.section(k), to: .loop) }
        if let t = plan.tempo, !locked.contains(.loop) { patterns[.loop]?.bpm = t }
        if plan.order, let o = order { order = SLOOPOrder(entries: plan.targets.map { .init(section: $0, bars: 4) }, loops: o.loops) }
    }
}

// MARK: A new, blank song

public enum SLOOPBlankSong {
    /// SLOOP 2.8.5's own starting project (what it plays when blank: 90 BPM, 808 bass, Rhodes, Lofi flute, the 808 kit,
    /// 16 steps of 1/16, no notes), as SLOOP wrote it to flash.
    static let defaultProject = Data(base64Encoded: [
        "Nk5VRugOAABaAAAAAAAAAAEAPABGAFoAWgA8ACgAPAAAAAAAAAAoAAEAAAAAAFpUAAAAAAAAAABAIGQAEAAAAAAAAAABAAAAAADAAmgAAABwAA",
        "AANAAAABIAAAD3/zwAAAAAAAAAAAAAAAAAAAAAAAIAAQBAAAAAfwAAAAAAAAAAAAAA6P8QAAIAAABAAAAAAAAAAAAAAgA7AAAAAAABAAAAAAAo",
        "AAAAAQABAH8AAAAAAAAAAAADAAAAAAAAAH8AAAAwAAAAAEBgYH8AAAAAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAA",
        "AAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAA",
        "AAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAA",
        "AAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAA",
        "AgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAA",
        "AAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAA",
        "AAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAA",
        "AAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAA",
        "AgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA",
        "/wAAAP8AAAD/AAAA/wAAAP8AAABoAAAAVQAjADcAAAAAAAAAFwBUAAAAAAAAAAAAAAAAABoAAAACAAEAQAAAAH8AAAAAAAAAAAAAAAAAEAACAA",
        "AAQAAAAB4ADAAaAAAAAAAAAAAAAAAAAAAAKAAAAAEAAQB/AAAAAAAAAAAABAABAAEADgAaACMAAAAAAABAYGB/AAAAAAABAAAAAAAAAgAAAAAA",
        "AAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAA",
        "AAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAAC",
        "AAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAA",
        "AAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAA",
        "AAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAA",
        "AAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAAC",
        "AAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAA",
        "AAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/w",
        "AAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAAaAAMAFAAeAA8AAAAAAAAAP//WQAAAAAAKAABAAAAAAAAAAAA",
        "AgABAEAAAAB/AAAAAAAAAAAAAAAAABAAAgAAAEAAAAAQABoAHgACAAAAAAAAAAAAAAAAACgAAAABAAEAfwAAAAAAAAAAAAUAAAAMAAEAZAAAAA",
        "AAAAAAQGBgfwAAAAAABAUAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIA",
        "AAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAA",
        "AAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAA",
        "AAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAA",
        "ACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIA",
        "AAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAA",
        "AAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAA",
        "AAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAAACAAAAAAAAAAAAAgAAAAAAAAAAAAIAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAA",
        "AP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAGgACgBGAFoAPA",
        "AAAAAAAAAAADwAAAAAAAAAAAAAAAAAAAAAAAIAAQBAAAAAfwAAAAAAAAAAAAAAAAAQAAIAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoAAAA",
        "AQABAH8AAAAAAAAAAAAFAAAAAAAAAAAAAAAAAAAAAEBgYH8AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "AAAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAAAP8AAAD/AAAA/wAA",
        "AP8AAAD/AAAA/wAAAP8AAADKvI8I",
    ].joined())!

    /// SLOOP's default settings (project.c persist_t, panel.c PANEL_DEFAULT): "PER3", colour theme 0, low-cut and zoom off,
    /// the default button and knob map ("PAN5"), the default song order (arranger.h arr_defaults: A B C D, 4 bars), lights 0.
    static var defaultSettings: Data {
        var b = [UInt8](repeating: 0, count: 88)
        b.replaceSubrange(0..<4, with: [0x33, 0x52, 0x45, 0x50])
        b.replaceSubrange(16..<20, with: [0x35, 0x4E, 0x41, 0x50])
        b.replaceSubrange(20..<34, with: [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 0, 1])
        b.replaceSubrange(34..<41, with: [0, 1, 6, 2, 3, 4, 5])
        b.replaceSubrange(41..<48, with: [1, 1, 1, 1, 1, 1, 1])
        return SLOOPOrder(entries: (0..<4).map { .init(section: $0, bars: 4) }, loops: false).written(into: Data(b))
    }

    /// A new song: SLOOP's starting project as the loop, sections A–D empty, SLOOP's default settings.
    public static func archive(firmware: String = "FELUCCA 2.8.5") -> DeviceArchive {
        var parts: [DeviceArchive.Part] = [.init(id: "0", label: SLOOPArchive.label(0), data: defaultProject),
                                           .init(id: "1", label: SLOOPArchive.label(1), data: defaultSettings)]
        for id: UInt8 in 2...5 { parts.append(.init(id: "\(id)", label: SLOOPArchive.label(id), data: Data())) }
        return DeviceArchive(format: SLOOPArchive.format, family: .felucca, firmware: firmware, parts: parts,
                             info: ["identity": firmware, "contents": "song"])
    }
}
