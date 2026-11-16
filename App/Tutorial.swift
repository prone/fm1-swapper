import FM1Kit
import Foundation

/// A per-firmware tutorial: data, not code (Tutorials/<id>.json, bundled with the app).
/// Format: Tutorials/README.md. Drafted by Claude Code (.claude/commands/draft-tutorial.md)
/// from the firmware's documentation, then reviewed in the emulator before it ships.
struct Tutorial: Codable, Identifiable, Hashable {
    struct Match: Codable, Hashable {
        var families: [String]?
        var productPrefixes: [String]?
        var repos: [String]?
        var names: [String]?
        var sha256: [String]?
    }

    /// One emulator action. Exactly one of press / hold / release / turn / note / wait is set.
    struct Action: Codable, Hashable {
        var press: String?
        var hold: String?
        var release: String?
        var turn: String?
        var clicks: Int?
        var note: String?
        var ms: Int?
        var wait: Int?
    }

    /// What the user must do before the step counts as done.
    struct Await: Codable, Hashable {
        /// Controls pressed together; the last one completes it (e.g. ["SEQ", "C4"]).
        var press: [String]?
        /// A knob or encoder turned.
        var turn: String?
        /// Any note key (panel, keyboard or MIDI).
        var anyNote: Bool?
        var hint: String?
    }

    struct Step: Codable, Hashable, Identifiable {
        var id: String { title + text.prefix(24) }
        var title: String
        var text: String
        var highlight: [String]?
        var show: [Action]?
        var await: Await?
    }

    var format: Int
    var id: String
    var title: String
    var summary: String
    var firmwareVersion: String?
    var match: Match
    var sources: [String]
    var reviewed: Bool
    var author: String?
    var setup: [Action]?
    var steps: [Step]

    func matches(_ f: Firmware) -> Bool {
        if let s = match.sha256, s.contains(f.sha256) { return true }
        if let fams = match.families, fams.contains(f.family.rawValue) { return true }
        if let r = match.repos, !f.repo.isEmpty, r.contains(where: { $0.caseInsensitiveCompare(f.repo) == .orderedSame }) { return true }
        if let p = match.productPrefixes, p.contains(where: { f.product.hasPrefix($0) }) { return true }
        if let n = match.names, n.contains(where: { f.name.localizedCaseInsensitiveContains($0) }) { return true }
        return false
    }

    /// Every control name a tutorial may use (the FM-1 panel as fm1-emu draws it).
    static let controls: Set<String> = ["SCREEN", "KEYS", "MASTER", "SELECT", "PRESETS", "ALGORITHM", "KNOB1", "KNOB2", "KNOB3",
                                        "KNOB4", "OCT-", "OCT+", "FX", "SCL", "ENV", "LFO", "EDIT", "GLO", "HOME", "SAVE",
                                        "ARP", "SEQ", "PLAY", "REC"]
}

enum TutorialLibrary {
    static let all: [Tutorial] = {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: "Tutorials") ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []).filter { $0.lastPathComponent.hasPrefix("tutorial-") }
        return urls.compactMap { u in
            guard let d = try? Data(contentsOf: u) else { return nil }
            do { return try JSONDecoder().decode(Tutorial.self, from: d) } catch {
                NSLog("Tutorial \(u.lastPathComponent) failed to load: \(error)")
                return nil
            }
        }
        .sorted { $0.title < $1.title }
    }()

    /// The most specific tutorial for a firmware (an exact package before family-wide ones).
    static func tutorial(for f: Firmware) -> Tutorial? {
        all.first { $0.match.sha256?.contains(f.sha256) == true }
            ?? all.first { t in t.match.repos.map { r in r.contains { $0.caseInsensitiveCompare(f.repo) == .orderedSame } } == true && !f.repo.isEmpty }
            ?? all.first { $0.matches(f) }
    }

    static func byID(_ id: String) -> Tutorial? { all.first { $0.id == id } }
}
