// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FM-1 Swapper contributors
import FM1Kit
import Observation
import SwiftUI

/// Steps through a Tutorial over the emulator: spotlights controls, plays "Show me" demos,
/// and waits for the user's own presses on "Your turn" steps.
@MainActor @Observable
final class TutorialPlayer {
    let tutorial: Tutorial
    private(set) var index = 0
    private(set) var awaitDone = false
    private(set) var busy = false
    private(set) var problem: String?
    private var held: Set<String> = []
    weak var emulator: EmulatorController?

    init(tutorial: Tutorial) { self.tutorial = tutorial }

    var step: Tutorial.Step {
        tutorial.steps.indices.contains(index) ? tutorial.steps[index] : Tutorial.Step(title: tutorial.title, text: "This tutorial has no steps.")
    }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == tutorial.steps.count - 1 }
    var progress: Double { Double(index + 1) / Double(max(tutorial.steps.count, 1)) }

    func begin() async {
        index = 0
        if let setup = tutorial.setup, !setup.isEmpty { await run(setup) }
        await enter()
    }

    func next() async { guard !isLast else { return }; index += 1; await enter() }
    func back() async { guard !isFirst else { return }; index -= 1; await enter() }
    func go(_ i: Int) async { index = max(0, min(i, tutorial.steps.count - 1)); await enter() }

    private func enter() async {
        awaitDone = step.await == nil
        held.removeAll()
        problem = nil
        if let unknown = await emulator?.spotlight(step.highlight ?? []), !unknown.isEmpty {
            problem = "Unknown control names: \(unknown.joined(separator: ", "))"
        }
    }

    func showMe() async {
        guard let show = step.show, !show.isEmpty else { return }
        await run(show)
    }

    private func run(_ actions: [Tutorial.Action]) async {
        busy = true
        defer { busy = false }
        // wait (up to a minute) for the synth to be started
        var waited = 0
        while let emulator, !(await emulator.isRunning()) {
            if waited == 0 { problem = "Tap Start on the synth, and the demo will play." }
            if waited > 120 { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 1
        }
        if waited > 0 { problem = nil }
        let r = await emulator?.perform(actions) ?? "no emulator"
        if r != "ok" { problem = r }
    }

    func stop() async { _ = await emulator?.spotlight([]) }

    // MARK: your turn

    /// A control touched by the user: panel names ("PLAY", "turn:KNOB1") or notes ("#60").
    func userEvent(_ name: String, down: Bool) {
        if down { held.insert(name) } else { held.remove(name); return }
        guard let a = step.await, !awaitDone else { return }
        if let t = a.turn, name == "turn:\(t)" || name == t { awaitDone = true }
        if a.anyNote == true, name.hasPrefix("#") { awaitDone = true }
        if let combo = a.press, let last = combo.last.map(Self.canonical), name == last {
            if combo.dropLast().map(Self.canonical).allSatisfy(held.contains) { awaitDone = true }
        }
    }

    /// "C4" -> "#60"; panel names unchanged.
    static func canonical(_ name: String) -> String {
        let pcs: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let first = name.uppercased().first, let pc = pcs[first], name.count >= 2 else { return name }
        var rest = name.dropFirst()
        var acc = 0
        if rest.first == "#" { acc = 1; rest = rest.dropFirst() } else if rest.first == "b" { acc = -1; rest = rest.dropFirst() }
        guard let oct = Int(rest) else { return name }
        return "#\((oct + 1) * 12 + pc + acc)"
    }

    var awaitText: String? {
        guard let a = step.await else { return nil }
        if let h = a.hint { return h }
        if let p = a.press { return "Press " + p.joined(separator: " + ") }
        if let t = a.turn { return "Turn \(t)" }
        if a.anyNote == true { return "Play any note" }
        return nil
    }
}

/// Where the tutorial card sits. It takes its own strip of the screen (the emulator shrinks to fit
/// beside it), so it never covers the synth's keys.
enum TutorialDock: String, CaseIterable, Identifiable {
    case bottom, top, left, right
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .bottom: "rectangle.bottomhalf.inset.filled"
        case .top: "rectangle.tophalf.inset.filled"
        case .left: "rectangle.lefthalf.inset.filled"
        case .right: "rectangle.righthalf.inset.filled"
        }
    }
    var isSide: Bool { self == .left || self == .right }
}

struct TutorialCard: View {
    @Bindable var player: TutorialPlayer
    @Binding var dock: TutorialDock
    let onClose: () -> Void
    @State private var showSources = false
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(player.step.title).font(.headline)
                Spacer()
                Text("\(player.index + 1) / \(player.tutorial.steps.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Menu {
                    Picker("Position", selection: $dock.animation()) {
                        ForEach(TutorialDock.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                } label: { Image(systemName: dock.symbol).foregroundStyle(.secondary) }
                    .accessibilityLabel("Move the tutorial")
                Button { withAnimation { collapsed.toggle() } } label: { Image(systemName: collapsed ? "chevron.up.circle.fill" : "chevron.down.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel(collapsed ? "Expand" : "Collapse")
                Button { onClose() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Close tutorial")
            }
            ProgressView(value: player.progress).tint(.orange)
            if !collapsed { details }
            if dock.isSide { Spacer(minLength: 0) }
        }
        .padding(14)
        .frame(width: dock.isSide ? 300 : nil)
        .frame(maxHeight: dock.isSide ? .infinity : nil, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(dock.isSide ? 6 : 0)
        .padding(.horizontal, dock.isSide ? 0 : 10)
        .padding(.vertical, dock.isSide ? 0 : 6)
    }

    @ViewBuilder private var details: some View {
            ScrollView {
                Text(player.step.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(maxHeight: dock.isSide ? 400 : 130)
            if let a = player.awaitText {
                Label(a, systemImage: player.awaitDone ? "checkmark.circle.fill" : "hand.point.up.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(player.awaitDone ? Color.green : Color.orange)
            }
            if let p = player.problem { Text(p).font(.caption).foregroundStyle(.red) }
            HStack {
                Button { Task { await player.back() } } label: { Label("Back", systemImage: "chevron.left").labelStyle(BackLabelStyle(iconOnly: dock.isSide)) }
                    .disabled(player.isFirst)
                Spacer()
                if player.step.show?.isEmpty == false {
                    Button { Task { await player.showMe() } } label: {
                        if player.busy { ProgressView() } else { Label("Show me", systemImage: "play.circle").lineLimit(1).fixedSize() }
                    }
                    .buttonStyle(.bordered).disabled(player.busy)
                }
                Spacer()
                if player.isLast {
                    Button("Finish") { onClose() }.buttonStyle(.borderedProminent)
                } else {
                    Button { Task { await player.next() } } label: {
                        Label(player.awaitDone ? "Next" : "Skip", systemImage: "chevron.right").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            HStack(spacing: 6) {
                if !player.tutorial.reviewed {
                    Text("DRAFT").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule()).foregroundStyle(.orange)
                }
                Button("Sources (\(player.tutorial.sources.count))") { showSources.toggle() }.font(.caption2)
                Spacer()
                Text("SMC-PAD: < back · > next").font(.caption2).foregroundStyle(.tertiary)
            }
            if showSources {
                ForEach(player.tutorial.sources, id: \.self) { s in
                    if let u = URL(string: s) { Link(s, destination: u).font(.caption2).lineLimit(1) }
                }
            }
    }
}

/// "Back" shrinks to its chevron in a side-docked card, where the row is narrow.
struct BackLabelStyle: LabelStyle {
    let iconOnly: Bool
    func makeBody(configuration: Configuration) -> some View {
        if iconOnly { configuration.icon } else { HStack(spacing: 4) { configuration.icon; configuration.title } }
    }
}
