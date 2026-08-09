import Foundation

/// Analysis modules — IDs 12 (Env Follower), 36 (Onset Detector),
/// 58 (Pitch Detector).
extension PatchRuntime {
    func renderAnalysis(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 12: renderEnvFollower(index, node, frames: ctx.frames)
        case 36: renderOnsetDetector(index, node, frames: ctx.frames)
        case 58: renderPitchDetector(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    /// CV 0…1 → time in seconds. Assumption: ZOIA time dials are
    /// exponential; this maps 1 ms at 0 to 10 s at 1.
    private static func followerTime(_ cv: Float) -> Double {
        0.001 * pow(10, Double(min(max(cv, 0), 1)) * 4)
    }

    // MARK: - 12 Env Follower

    final class EnvFollowerState {
        var level: Double = 0
    }

    private func renderEnvFollower(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(EnvFollowerState())
        // Rise/fall blocks exist only when the option is on. Assumption:
        // with the option off the follower uses 5 ms rise / 150 ms fall.
        let riseT: Double
        let fallT: Double
        if node.optionText(0) == "on" {
            riseT = Self.followerTime(cvIn(node: index, block: 1))
            fallT = Self.followerTime(cvIn(node: index, block: 2))
        } else {
            riseT = 0.005
            fallT = 0.150
        }
        let riseCoef = exp(-1 / (riseT * sampleRate))
        let fallCoef = exp(-1 / (fallT * sampleRate))
        let input = audioIn(node: index, block: 0, frames: frames)
        for i in 0..<frames {
            let rectified = Double(abs(input[i]))
            let coef = rectified > state.level ? riseCoef : fallCoef
            state.level = coef * state.level + (1 - coef) * rectified
        }
        let cv: Double
        if node.optionText(1) == "linear" {
            cv = state.level
        } else {
            // Assumption: "log" maps −60…0 dBFS onto CV 0…1.
            let db = 20 * log10(max(state.level, 1e-6))
            cv = 1 + db / 60
        }
        node.cvOut[3] = Float(min(max(cv, 0), 1))
    }

    // MARK: - 36 Onset Detector

    final class OnsetState {
        var env: Double = 0
        var armed = true
        var gateSamples = 0
    }

    private func renderOnsetDetector(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(OnsetState())
        // Sensitivity block exists only when the option is on; the
        // default sensitivity is mid-scale. Assumption: threshold =
        // 0.05 + (1 − sensitivity) × 0.5, so higher CV fires on quieter
        // material; detection re-arms once the envelope falls to half the
        // threshold (hysteresis against double triggers).
        let sens = node.optionText(0) == "on"
            ? Double(min(max(cvIn(node: index, block: 1), 0), 1))
            : 0.5
        let threshold = 0.05 + (1 - sens) * 0.5
        let riseCoef = exp(-1 / (0.001 * sampleRate))   // 1 ms attack
        let fallCoef = exp(-1 / (0.100 * sampleRate))   // 100 ms release
        let gateLength = Int(0.010 * sampleRate)        // 10 ms trigger
        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let rectified = Double(abs(input[i]))
            let coef = rectified > state.env ? riseCoef : fallCoef
            state.env = coef * state.env + (1 - coef) * rectified
            if state.armed, state.env > threshold {
                state.armed = false
                state.gateSamples = gateLength
            } else if !state.armed, state.env < threshold * 0.5 {
                state.armed = true
            }
            if state.gateSamples > 0 {
                state.gateSamples -= 1
                out[i] = 1
            }
        }
        // The catalog types this output as audio, the manual calls it a
        // CV trigger — publish both so either kind of wire reads the gate.
        node.audioOut[2] = out
        node.cvOut[2] = out[frames - 1]
    }

    // MARK: - 58 Pitch Detector

    final class PitchState {
        var last: Float = 0
        var lastFrac: Double = 0
        var samplesSinceRise: Int = 0
        var period: Double = 0
    }

    private func renderPitchDetector(_ index: Int, _ node: Node, frames: Int) {
        // Assumption: pitch is tracked by timing rising zero crossings
        // with sub-sample interpolation and light smoothing — cheap and
        // accurate for clean periodic signals; complex or noisy material
        // can produce octave errors (autocorrelation left for later).
        let state = node.state(PitchState())
        let input = audioIn(node: index, block: 0, frames: frames)
        let minPeriod = Int(sampleRate / 6000)   // ignore > 6 kHz chatter
        let maxSilence = Int(sampleRate / 10)    // hold pitch below 10 Hz
        for i in 0..<frames {
            let x = input[i]
            state.samplesSinceRise += 1
            if state.last < 0, x >= 0, state.samplesSinceRise > minPeriod {
                let denom = Double(x - state.last)
                let frac = denom > 0 ? Double(x) / denom : 0
                let candidate = Double(state.samplesSinceRise) - frac + state.lastFrac
                state.period = state.period == 0
                    ? candidate
                    : state.period * 0.85 + candidate * 0.15
                state.lastFrac = frac
                state.samplesSinceRise = 0
            }
            if state.samplesSinceRise > maxSilence { state.samplesSinceRise = maxSilence }
            state.last = x
        }
        if state.period > 0 {
            let freq = sampleRate / state.period
            let note = 69 + 12 * log2(freq / 440)
            node.cvOut[1] = Float(min(max(note / 127, 0), 1))
        } else {
            node.cvOut[1] = 0
        }
    }
}
