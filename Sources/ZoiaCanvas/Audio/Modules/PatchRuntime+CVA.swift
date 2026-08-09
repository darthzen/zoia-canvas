import Foundation

/// CV generator modules — IDs 4 (Sequencer), 5 (LFO), 6 (ADSR),
/// 37 (Rhythm), 39 (Random), 47 (CV Loop), 85 (Tap to CV).
extension PatchRuntime {
    func renderCVGenerators(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 4: renderSequencer(index, node)
        case 5: renderLFO(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    private func renderSequencer(_ index: Int, _ node: Node) {
        let steps = max(node.optionInt(0), 1)
        let tracks = max(node.optionInt(1), 1)
        let gate = cvIn(node: index, block: 32)
        let restart = node.optionText(2) == "on" ? cvIn(node: index, block: 33) : 0

        if restart >= 0.5, node.lastRestart < 0.5 {
            node.step = 0
            node.finished = false
        }
        node.lastRestart = restart

        if gate >= 0.5, node.lastGate < 0.5, !node.finished {
            node.step += 1
            if node.step >= steps {
                if node.optionText(3) == "one_shot" {
                    node.step = steps - 1
                    node.finished = true
                } else {
                    node.step = 0
                }
            }
        }
        node.lastGate = gate

        // Track 1 = step params (device-verified). Tracks 2+ live in
        // saved_data, not yet decoded: they output 0.
        let stepValue = node.paramIndexByPosition[node.step]
            .map { node.params[$0] } ?? 0
        for track in 0..<tracks {
            node.cvOut[36 + track] = track == 0 ? stepValue : 0
        }
    }

    private func renderLFO(_ index: Int, _ node: Node, frames: Int) {
        // cv input mode: dial 0…1 sweeps ~0.05…25 Hz exponentially.
        // (Assumption; device curve not yet measured.)
        let control = cvIn(node: index, block: 0)
        let hz = 0.05 * pow(25 / 0.05, Double(control))
        node.phase += hz * Double(frames) / sampleRate
        node.phase -= node.phase.rounded(.down)

        let bipolar = node.optionText(2) == "-1 to 1"
        let raw: Double
        switch node.optionText(0) {
        case "sine": raw = (sin(node.phase * 2 * .pi) + 1) / 2
        case "triangle": raw = node.phase < 0.5 ? node.phase * 2 : 2 - node.phase * 2
        case "sawtooth": raw = 1 - node.phase
        case "ramp": raw = node.phase
        case "random": raw = node.phase < 0.02 ? Double.random(in: 0...1) : lastLFOValue(node)
        default: raw = node.phase < 0.5 ? 1 : 0  // square
        }
        node.cvOut[3] = Float(bipolar ? raw * 2 - 1 : raw)
    }

    private func lastLFOValue(_ node: Node) -> Double { Double(node.cvOut[3] ?? 0) }
}
