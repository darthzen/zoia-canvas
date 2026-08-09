import Foundation

/// Drive, dynamics and EQ effects — IDs 11 (OD & Distortion),
/// 23 (Compressor), 40 (Gate), 42 (Tone Control), 66 (Fuzz),
/// 68 (Cabinet Sim), 72 (Env Filter), 73 (Ring Modulator).
///
/// Shared dial curves (fit to the catalog's dial marks):
/// - Frequency dials whose marks read 27.5 / 155.56 / 880 / 4978 / 23999 Hz
///   follow 27.5 × 2^(10·cv) capped at 23999 (2.5 octaves per quarter turn;
///   the top quarter caps at the device's stated maximum). The Ring
///   Modulator doc extends the same curve to negative CV (0.03 Hz at −1).
/// - OD/Fuzz output gain marks (−inf, −27.73, −13.86, −5.75, 0 dB) fit
///   amplitude = cv^2.303 (13.86 dB per doubling of cv).
/// - Filter Q marks 1 / 5.62 / 31.62 / 177.83 / 1000 fit Q = 10^(3·cv).
extension PatchRuntime {
    func renderEffectA(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 11: renderODDistortion(index, node, frames: ctx.frames)
        case 23: renderCompressor(index, node, frames: ctx.frames)
        case 40: renderGate(index, node, frames: ctx.frames)
        case 42: renderToneControl(index, node, frames: ctx.frames)
        case 66: renderFuzz(index, node, frames: ctx.frames)
        case 68: renderCabinetSim(index, node, frames: ctx.frames)
        case 72: renderEnvFilter(index, node, frames: ctx.frames)
        case 73: renderRingModulator(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    // MARK: - 11 OD & Distortion

    /// Blocks: audio in 0, input gain 1 (0…32 dB), audio out 2,
    /// output gain 3. Option: model.
    private func renderODDistortion(_ index: Int, _ node: Node, frames: Int) {
        let pre = pow(10, max(0, cvIn(node: index, block: 1)) * 32 / 20)
        let post = pow(max(0, cvIn(node: index, block: 3)), 2.303)
        let model = node.optionText(0)
        var buffer = audioIn(node: index, block: 0, frames: frames)
        for i in 0..<frames {
            let x = buffer[i] * pre
            // Assumption: per-model clipping curves are plausible shapes
            // chosen for distinct character, not measured from hardware.
            let y: Float
            switch model {
            case "germ":     // germanium: soft, asymmetric (even harmonics)
                y = tanhf(2 * x + 0.3) - tanhf(0.3)
            case "classic":  // hard clip
                y = min(max(x, -0.8), 0.8)
            case "pushed":   // symmetric cubic soft clip
                y = abs(x) < 1 ? 1.5 * (x - x * x * x / 3) : (x > 0 ? 1 : -1)
            case "edgy":     // hot arctan front end
                y = (2 / .pi) * atanf(4 * x)
            default:         // plexi: smooth tanh saturation
                y = tanhf(1.5 * x)
            }
            buffer[i] = y * post
        }
        node.audioOut[2] = buffer
    }

    // MARK: - 66 Fuzz

    /// Blocks: audio in 0, input gain 1 (0…40 dB), output gain 2,
    /// audio out 3. Option: model.
    private func renderFuzz(_ index: Int, _ node: Node, frames: Int) {
        let pre = pow(10, max(0, cvIn(node: index, block: 1)) * 40 / 20)
        let post = pow(max(0, cvIn(node: index, block: 2)), 2.303)
        let model = node.optionText(0)
        let state = node.state(EAFuzzState())
        // Assumption: "scoopy" is a hard clip into a fixed −9 dB mid dip at
        // 800 Hz; the other models are waveshaper flavours, not hardware
        // measurements.
        let scoop = eaPeaking(sampleRate: sampleRate, hz: 800, q: 0.8, dB: -9)
        var buffer = audioIn(node: index, block: 0, frames: frames)
        for i in 0..<frames {
            let x = buffer[i] * pre
            var y: Float
            switch model {
            case "burly":    // thick, heavy saturation
                y = tanhf(3 * x)
            case "scoopy":   // hard clip + mid scoop
                y = min(max(x, -0.7), 0.7) / 0.7
                y = state.scoop.process(y, scoop)
            case "ugly":     // foldback
                var v = x
                var folds = 0
                while abs(v) > 1, folds < 8 {
                    v = v > 0 ? 2 - v : -2 - v
                    folds += 1
                }
                y = v
            default:         // efuzzy: gentle exponential squash
                y = x >= 0 ? 1 - expf(-x) : expf(x) - 1
            }
            buffer[i] = y * post
        }
        node.audioOut[3] = buffer
    }

    // MARK: - 23 Compressor

    /// Blocks: in L 0, in R 1*, threshold 2, attack 3*, release 4*,
    /// ratio 5*, out L 6, out R 7*, sidechain 8*. Options: attack ctrl,
    /// release ctrl, ratio ctrl, channels, sidechain.
    private func renderCompressor(_ index: Int, _ node: Node, frames: Int) {
        let stereo = node.optionText(3) == "stereo"
        let external = node.optionText(4) == "external"
        // Threshold −80…0 dB, attack 0…10 ms, release 0.01…2 s (all linear
        // per the dial marks), ratio 1 + 19.2·cv fitting 1/5.8/10.5/15.3/inf.
        let thresholdDB = -80 * (1 - max(0, cvIn(node: index, block: 2)))
        let attackMs = node.optionText(0) == "on"
            ? max(0, cvIn(node: index, block: 3)) * 10 : 5.0
        let releaseS = node.optionText(1) == "on"
            ? 0.01 + max(0, cvIn(node: index, block: 4)) * 1.99 : 1.05
        let ratio: Float
        if node.optionText(2) == "on" {
            let cv = max(0, cvIn(node: index, block: 5))
            ratio = cv >= 0.999 ? .infinity : 1 + 19.2 * cv
        } else {
            ratio = 10.5
        }
        var left = audioIn(node: index, block: 0, frames: frames)
        var right = stereo ? audioIn(node: index, block: 1, frames: frames) : []
        let sidechain = external ? audioIn(node: index, block: 8, frames: frames) : []
        let attackCoef = eaCoef(seconds: Double(attackMs) / 1000, sampleRate: sampleRate)
        let releaseCoef = eaCoef(seconds: Double(releaseS), sampleRate: sampleRate)
        let thresholdLin = pow(10, thresholdDB / 20)
        let slope: Float = ratio.isInfinite ? 1 : 1 - 1 / ratio
        let state = node.state(EACompressorState())
        for i in 0..<frames {
            // Peak detector with attack/release ballistics, one shared gain
            // for both channels (doc: stereo sides compress in parallel).
            let detector: Float
            if external { detector = abs(sidechain[i]) }
            else if stereo { detector = max(abs(left[i]), abs(right[i])) }
            else { detector = abs(left[i]) }
            let coef = detector > state.envelope ? attackCoef : releaseCoef
            state.envelope += (detector - state.envelope) * coef
            var gain: Float = 1
            if state.envelope > thresholdLin {
                let overDB = 20 * log10f(state.envelope / thresholdLin)
                gain = pow(10, -overDB * slope / 20)
            }
            left[i] *= gain
            if stereo { right[i] *= gain }
        }
        node.audioOut[6] = left
        if stereo { node.audioOut[7] = right }
    }

    // MARK: - 40 Gate

    /// Blocks: in L 0, in R 1*, threshold 2, attack 3*, release 4*,
    /// out L 5, out R 6*, sidechain 7*. Options: attack ctrl, release ctrl,
    /// channels, sidechain.
    private func renderGate(_ index: Int, _ node: Node, frames: Int) {
        let stereo = node.optionText(2) == "stereo"
        let external = node.optionText(3) == "external"
        // Threshold −110…0 dB, attack 0…100 ms, release 0.05…2 s, all
        // linear per the dial marks; fixed defaults from the doc.
        let thresholdDB = -110 * (1 - max(0, cvIn(node: index, block: 2)))
        let attackMs = node.optionText(0) == "on"
            ? max(0, cvIn(node: index, block: 3)) * 100 : 50.5
        let releaseS = node.optionText(1) == "on"
            ? 0.05 + max(0, cvIn(node: index, block: 4)) * 1.95 : 1.03
        var left = audioIn(node: index, block: 0, frames: frames)
        var right = stereo ? audioIn(node: index, block: 1, frames: frames) : []
        let sidechain = external ? audioIn(node: index, block: 7, frames: frames) : []
        // Assumption: detector ballistics 1 ms rise / 25 ms fall; the
        // attack/release params shape the gate's gain ramp, not detection.
        let detectorRise = eaCoef(seconds: 0.001, sampleRate: sampleRate)
        let detectorFall = eaCoef(seconds: 0.025, sampleRate: sampleRate)
        let openCoef = eaCoef(seconds: Double(attackMs) / 1000, sampleRate: sampleRate)
        let closeCoef = eaCoef(seconds: Double(releaseS), sampleRate: sampleRate)
        let thresholdLin = pow(10, thresholdDB / 20)
        let state = node.state(EAGateState())
        for i in 0..<frames {
            let detector: Float
            if external { detector = abs(sidechain[i]) }
            else if stereo { detector = max(abs(left[i]), abs(right[i])) }
            else { detector = abs(left[i]) }
            let envCoef = detector > state.envelope ? detectorRise : detectorFall
            state.envelope += (detector - state.envelope) * envCoef
            let target: Float = state.envelope > thresholdLin ? 1 : 0
            state.gain += (target - state.gain) * (target > state.gain ? openCoef : closeCoef)
            left[i] *= state.gain
            if stereo { right[i] *= state.gain }
        }
        node.audioOut[5] = left
        if stereo { node.audioOut[6] = right }
    }

    // MARK: - 42 Tone Control

    /// Blocks: in L 0, in R 1*, low shelf 2, mid gain 1 3, mid freq 1 4,
    /// mid gain 2 5*, mid freq 2 6*, high shelf 7, out L 8, out R 9*.
    /// Options: channels, num mid bands.
    private func renderToneControl(_ index: Int, _ node: Node, frames: Int) {
        let stereo = node.optionText(0) == "stereo"
        let twoMidBands = node.optionInt(1) == 2
        func gainDB(_ block: Int) -> Double {
            (Double(max(0, cvIn(node: index, block: block))) - 0.5) * 36  // −18…+18 dB
        }
        // Assumption: shelf corners are not documented — 200 Hz low /
        // 3 kHz high, with wide (Q 0.7) mid peaking bands.
        var coeffs: [EACoeffs] = [
            eaLowShelf(sampleRate: sampleRate, hz: 200, dB: gainDB(2)),
            eaPeaking(sampleRate: sampleRate,
                      hz: eaDialHz(max(0, cvIn(node: index, block: 4))),
                      q: 0.7, dB: gainDB(3)),
        ]
        if twoMidBands {
            coeffs.append(eaPeaking(sampleRate: sampleRate,
                                    hz: eaDialHz(max(0, cvIn(node: index, block: 6))),
                                    q: 0.7, dB: gainDB(5)))
        }
        coeffs.append(eaHighShelf(sampleRate: sampleRate, hz: 3000, dB: gainDB(7)))

        let state = node.state(EAToneState())
        let channels = stereo ? 2 : 1
        if state.filters.count != channels || state.filters.first?.count != coeffs.count {
            state.filters = (0..<channels).map { _ in coeffs.map { _ in EABiquad() } }
        }
        for channel in 0..<channels {
            var buffer = audioIn(node: index, block: channel, frames: frames)
            for i in 0..<frames {
                var sample = buffer[i]
                for (band, coefficient) in coeffs.enumerated() {
                    sample = state.filters[channel][band].process(sample, coefficient)
                }
                buffer[i] = sample
            }
            node.audioOut[channel == 0 ? 8 : 9] = buffer
        }
    }

    // MARK: - 68 Cabinet Sim

    /// Blocks: in L 0, in R 1*, out L 2, out R 3*. Options: channels, type.
    ///
    /// Assumption: implemented as fixed filter cascades (12 dB/oct high
    /// pass, presence peak, two 12 dB/oct low-pass stages) whose corners
    /// approximate each cabinet's published character — not convolution
    /// with measured impulse responses.
    private func renderCabinetSim(_ index: Int, _ node: Node, frames: Int) {
        let stereo = node.optionText(0) == "stereo"
        let cab: (hp: Double, peakHz: Double, peakDB: Double, lp: Double)
        switch node.optionText(1) {
        case "2x12_dark":    cab = (80, 1200, 2, 3500)
        case "2x12_modern":  cab = (75, 2500, 4, 4800)
        case "1x12":         cab = (90, 2200, 2, 4500)
        case "1x8_lofi":     cab = (200, 1500, 4, 2500)
        case "1x12_vintage": cab = (85, 1600, 2, 3800)
        case "4x12_hifi":    cab = (60, 3000, 2, 6500)
        default:             cab = (70, 2000, 3, 5000)  // 4x12_full
        }
        let coeffs = [
            eaHighPass(sampleRate: sampleRate, hz: cab.hp),
            eaPeaking(sampleRate: sampleRate, hz: cab.peakHz, q: 1, dB: cab.peakDB),
            eaLowPass(sampleRate: sampleRate, hz: cab.lp),
            eaLowPass(sampleRate: sampleRate, hz: cab.lp),
        ]
        let state = node.state(EACabState())
        let channels = stereo ? 2 : 1
        if state.filters.count != channels {
            state.filters = (0..<channels).map { _ in coeffs.map { _ in EABiquad() } }
        }
        for channel in 0..<channels {
            var buffer = audioIn(node: index, block: channel, frames: frames)
            for i in 0..<frames {
                var sample = buffer[i]
                for (stage, coefficient) in coeffs.enumerated() {
                    sample = state.filters[channel][stage].process(sample, coefficient)
                }
                buffer[i] = sample
            }
            node.audioOut[channel == 0 ? 2 : 3] = buffer
        }
    }

    // MARK: - 72 Env Filter

    /// Blocks: in L 0, in R 1*, sensitivity 2, min freq 3, max freq 4,
    /// filter Q 5, out L 6, out R 7*. Options: channels, filter type,
    /// direction.
    private func renderEnvFilter(_ index: Int, _ node: Node, frames: Int) {
        let channels = node.optionText(0)  // 1in->1out / 1in->2out / stereo
        let filterType = node.optionText(1)  // bpf / hpf / lpf
        let down = node.optionText(2) == "down"
        let stereo = channels == "stereo"
        let sensitivity = max(0, cvIn(node: index, block: 2))
        let minHz = eaDialHz(max(0, cvIn(node: index, block: 3)))
        let maxHz = eaDialHz(max(0, cvIn(node: index, block: 4)))
        // Q = 10^(3·cv) per the dial marks, capped for float stability.
        let q = min(max(pow(10, Double(max(0, cvIn(node: index, block: 5))) * 3), 0.5), 25)
        let k = Float(1 / q)
        var left = audioIn(node: index, block: 0, frames: frames)
        var right = stereo ? audioIn(node: index, block: 1, frames: frames) : []
        // Assumption: envelope ballistics 3 ms rise / 200 ms fall, and the
        // sweep amount is min(1, envelope × sensitivity × 4) — full-scale
        // audio at sensitivity ≥ 0.3 reaches the top of the sweep.
        let rise = eaCoef(seconds: 0.003, sampleRate: sampleRate)
        let fall = eaCoef(seconds: 0.2, sampleRate: sampleRate)
        let state = node.state(EAEnvFilterState())
        var out = [Float](repeating: 0, count: frames)
        var outR = stereo ? [Float](repeating: 0, count: frames) : []
        for i in 0..<frames {
            let detector = stereo ? max(abs(left[i]), abs(right[i])) : abs(left[i])
            state.envelope += (detector - state.envelope)
                * (detector > state.envelope ? rise : fall)
            let sweep = Double(min(1, state.envelope * sensitivity * 4))
            let hz = down ? maxHz * pow(minHz / maxHz, sweep)
                          : minHz * pow(maxHz / minHz, sweep)
            let g = Float(tan(.pi * min(hz, sampleRate * 0.45) / sampleRate))
            let a1 = 1 / (1 + g * (g + k))
            for channel in 0..<(stereo ? 2 : 1) {
                let x = channel == 0 ? left[i] : right[i]
                let v3 = x - state.ic2[channel]
                let v1 = a1 * (state.ic1[channel] + g * v3)
                let v2 = state.ic2[channel] + g * v1
                state.ic1[channel] = 2 * v1 - state.ic1[channel]
                state.ic2[channel] = 2 * v2 - state.ic2[channel]
                let y: Float
                switch filterType {
                case "hpf": y = x - k * v1 - v2
                case "lpf": y = v2
                default: y = k * v1  // bpf, unity gain at center
                }
                if channel == 0 { out[i] = y } else { outR[i] = y }
            }
        }
        node.audioOut[6] = out
        switch channels {
        case "stereo": node.audioOut[7] = outR
        case "1in->2out": node.audioOut[7] = out
        default: break
        }
    }

    // MARK: - 73 Ring Modulator

    /// Blocks: audio in 0, frequency 1 (internal carrier) OR ext in 2
    /// (external carrier), duty cycle 3*, mix 4, audio out 5.
    /// Options: waveform, ext audio in, duty cycle, upsampling.
    private func renderRingModulator(_ index: Int, _ node: Node, frames: Int) {
        let waveform = node.optionText(0)
        let external = node.optionText(1) == "on"
        let dutyOn = node.optionText(2) == "on"
        // Assumption: the upsampling option only improves carrier aliasing
        // on hardware; this renderer always generates at native rate.
        let mix = max(0, cvIn(node: index, block: 4))
        var buffer = audioIn(node: index, block: 0, frames: frames)
        let carrierIn = external ? audioIn(node: index, block: 2, frames: frames) : []
        // Doc-specified curve: cv 0…1 → 27.5…23999 Hz, cv −1…0 → 0.03…27.5.
        let increment = eaDialHz(cvIn(node: index, block: 1)) / sampleRate
        let duty = dutyOn
            ? Double(min(max(cvIn(node: index, block: 3), 0.05), 0.95)) : 0.5
        for i in 0..<frames {
            let carrier: Float
            if external {
                carrier = carrierIn[i]
            } else {
                // Duty cycle warps the phase: square becomes PWM, the other
                // shapes skew. (Assumption: applied to all waveforms.)
                let p = node.phase
                let w = p < duty ? 0.5 * p / duty : 0.5 + 0.5 * (p - duty) / (1 - duty)
                switch waveform {
                case "square": carrier = w < 0.5 ? 1 : -1
                case "triangle": carrier = Float(w < 0.5 ? 4 * w - 1 : 3 - 4 * w)
                case "sawtooth": carrier = Float(2 * w - 1)
                default: carrier = Float(sin(2 * .pi * w))  // sine
                }
                node.phase += increment
                if node.phase >= 1 { node.phase -= 1 }
            }
            buffer[i] = buffer[i] * (1 - mix) + buffer[i] * carrier * mix
        }
        node.audioOut[5] = buffer
    }
}

// MARK: - File-scope DSP helpers

/// Frequency dial: 27.5 × 2^(10·cv), 0.03…23999 Hz (see extension doc).
private func eaDialHz(_ cv: Float) -> Double {
    min(max(27.5 * pow(2, Double(cv) * 10), 0.03), 23999)
}

/// One-pole smoothing coefficient for a time constant in seconds.
private func eaCoef(seconds: Double, sampleRate: Double) -> Float {
    seconds <= 0 ? 1 : Float(1 - exp(-1 / (sampleRate * seconds)))
}

private struct EACoeffs {
    var b0, b1, b2, a1, a2: Float
}

private final class EABiquad {
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    func process(_ x: Float, _ c: EACoeffs) -> Float {
        let y = c.b0 * x + c.b1 * x1 + c.b2 * x2 - c.a1 * y1 - c.a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

private func eaNormalized(_ b0: Double, _ b1: Double, _ b2: Double,
                          _ a0: Double, _ a1: Double, _ a2: Double) -> EACoeffs {
    EACoeffs(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
             a1: Float(a1 / a0), a2: Float(a2 / a0))
}

private func eaClampHz(_ hz: Double, _ sampleRate: Double) -> Double {
    min(max(hz, 10), sampleRate * 0.45)
}

// RBJ Audio EQ Cookbook biquads.

private func eaPeaking(sampleRate: Double, hz: Double, q: Double, dB: Double) -> EACoeffs {
    let a = pow(10, dB / 40)
    let w = 2 * Double.pi * eaClampHz(hz, sampleRate) / sampleRate
    let alpha = sin(w) / (2 * q)
    let c = cos(w)
    return eaNormalized(1 + alpha * a, -2 * c, 1 - alpha * a,
                        1 + alpha / a, -2 * c, 1 - alpha / a)
}

private func eaLowShelf(sampleRate: Double, hz: Double, dB: Double) -> EACoeffs {
    let a = pow(10, dB / 40)
    let w = 2 * Double.pi * eaClampHz(hz, sampleRate) / sampleRate
    let c = cos(w)
    let alpha = sin(w) / 2 * sqrt(2.0)  // shelf slope S = 1
    let sq = 2 * sqrt(a) * alpha
    return eaNormalized(
        a * ((a + 1) - (a - 1) * c + sq),
        2 * a * ((a - 1) - (a + 1) * c),
        a * ((a + 1) - (a - 1) * c - sq),
        (a + 1) + (a - 1) * c + sq,
        -2 * ((a - 1) + (a + 1) * c),
        (a + 1) + (a - 1) * c - sq)
}

private func eaHighShelf(sampleRate: Double, hz: Double, dB: Double) -> EACoeffs {
    let a = pow(10, dB / 40)
    let w = 2 * Double.pi * eaClampHz(hz, sampleRate) / sampleRate
    let c = cos(w)
    let alpha = sin(w) / 2 * sqrt(2.0)
    let sq = 2 * sqrt(a) * alpha
    return eaNormalized(
        a * ((a + 1) + (a - 1) * c + sq),
        -2 * a * ((a - 1) + (a + 1) * c),
        a * ((a + 1) + (a - 1) * c - sq),
        (a + 1) - (a - 1) * c + sq,
        2 * ((a - 1) - (a + 1) * c),
        (a + 1) - (a - 1) * c - sq)
}

private func eaLowPass(sampleRate: Double, hz: Double, q: Double = 0.7071) -> EACoeffs {
    let w = 2 * Double.pi * eaClampHz(hz, sampleRate) / sampleRate
    let alpha = sin(w) / (2 * q)
    let c = cos(w)
    return eaNormalized((1 - c) / 2, 1 - c, (1 - c) / 2,
                        1 + alpha, -2 * c, 1 - alpha)
}

private func eaHighPass(sampleRate: Double, hz: Double, q: Double = 0.7071) -> EACoeffs {
    let w = 2 * Double.pi * eaClampHz(hz, sampleRate) / sampleRate
    let alpha = sin(w) / (2 * q)
    let c = cos(w)
    return eaNormalized((1 + c) / 2, -(1 + c), (1 + c) / 2,
                        1 + alpha, -2 * c, 1 - alpha)
}

// MARK: - Per-node state

private final class EACompressorState { var envelope: Float = 0 }

private final class EAGateState {
    var envelope: Float = 0
    var gain: Float = 0
}

private final class EAToneState { var filters: [[EABiquad]] = [] }

private final class EACabState { var filters: [[EABiquad]] = [] }

private final class EAEnvFilterState {
    var envelope: Float = 0
    var ic1 = [Float](repeating: 0, count: 2)
    var ic2 = [Float](repeating: 0, count: 2)
}

private final class EAFuzzState { let scoop = EABiquad() }
