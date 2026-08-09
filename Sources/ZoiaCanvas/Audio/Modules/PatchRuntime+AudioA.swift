import Foundation

/// Audio synthesis and filter modules — IDs 0 (SV Filter), 3 (Aliaser),
/// 7 (VCA), 8 (Audio Multiply), 9 (Bit Crusher), 14 (Oscillator),
/// 24 (Multi Filter), 27 (All Pass), 38 (Noise), 63 (Bit Modulator),
/// 65 (Inverter).
extension PatchRuntime {
    func renderAudioA(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 7: renderVCA(index, node, frames: ctx.frames)
        case 14: renderOscillator(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    private func renderVCA(_ index: Int, _ node: Node, frames: Int) {
        let level = cvIn(node: index, block: 2)
        var left = audioIn(node: index, block: 0, frames: frames)
        for i in 0..<frames { left[i] *= level }
        node.audioOut[3] = left
        if node.optionText(0) == "stereo" {
            var right = audioIn(node: index, block: 1, frames: frames)
            for i in 0..<frames { right[i] *= level }
            node.audioOut[4] = right
        }
    }

    private func renderOscillator(_ index: Int, _ node: Node, frames: Int) {
        let hz = Self.pitchHz(cvIn(node: index, block: 0))
        let increment = hz / sampleRate
        var buffer = [Float](repeating: 0, count: frames)
        let waveform = node.optionText(0)
        for i in 0..<frames {
            let value: Double
            switch waveform {
            case "square": value = node.phase < 0.5 ? 1 : -1
            case "triangle": value = node.phase < 0.5 ? node.phase * 4 - 1 : 3 - node.phase * 4
            case "sawtooth": value = node.phase * 2 - 1
            default: value = sin(node.phase * 2 * .pi)  // sine
            }
            buffer[i] = Float(value)
            node.phase += increment
            if node.phase >= 1 { node.phase -= 1 }
        }
        node.audioOut[3] = buffer
    }
}
