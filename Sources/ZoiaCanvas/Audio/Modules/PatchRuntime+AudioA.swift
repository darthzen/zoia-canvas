import Foundation

/// Audio synthesis and filter modules — IDs 0 (SV Filter), 3 (Aliaser),
/// 7 (VCA), 8 (Audio Multiply), 9 (Bit Crusher), 14 (Oscillator),
/// 24 (Multi Filter), 27 (All Pass), 38 (Noise), 63 (Bit Modulator),
/// 65 (Inverter).
extension PatchRuntime {
    func renderAudioA(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 0: renderSVFilter(index, node, frames: ctx.frames)
        case 3: renderAliaser(index, node, frames: ctx.frames)
        case 7: renderVCA(index, node, frames: ctx.frames)
        case 8: renderAudioMultiply(index, node, frames: ctx.frames)
        case 9: renderBitCrusher(index, node, frames: ctx.frames)
        case 14: renderOscillator(index, node, frames: ctx.frames)
        case 24: renderMultiFilter(index, node, frames: ctx.frames)
        case 27: renderAllPass(index, node, frames: ctx.frames)
        case 38: renderNoise(index, node, frames: ctx.frames)
        case 63: renderBitModulator(index, node, frames: ctx.frames)
        case 65: renderInverter(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    // MARK: - 0 SV Filter

    /// Trapezoidal (Simper) state-variable filter — stable up to Nyquist,
    /// unlike the classic Chamberlin form.
    final class SVFilterState {
        var ic1: Double = 0
        var ic2: Double = 0
        var cutoff: Double = 0  // smoothed cutoff Hz; 0 = uninitialized
    }

    private func renderSVFilter(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(SVFilterState())
        // Frequency dial follows the documented filter curve (filterHz).
        let target = min(max(Self.filterHz(cvIn(node: index, block: 1)), 0.03),
                         sampleRate * 0.49)
        if node.optionText(3) == "smooth", state.cutoff > 0 {
            // Assumption: "smooth" slews the cutoff 15% of the remaining
            // distance per control block; "instant" jumps.
            state.cutoff += (target - state.cutoff) * 0.15
        } else {
            state.cutoff = target
        }
        let res = Double(min(max(cvIn(node: index, block: 2), 0), 1))
        // Assumption: resonance 0…1 maps damping k = 2…0.02 (k = 1/Q-ish;
        // small k = strong resonant peak).
        let k = max(2 * (1 - res), 0.02)
        let g = tan(.pi * state.cutoff / sampleRate)
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2

        let input = audioIn(node: index, block: 0, frames: frames)
        let wantLP = node.optionText(0) == "on"
        let wantHP = node.optionText(1) == "on"
        let wantBP = node.optionText(2) == "on"
        var lp = [Float](repeating: 0, count: frames)
        var hp = lp
        var bp = lp
        for i in 0..<frames {
            let x = Double(input[i])
            let v3 = x - state.ic2
            let v1 = a1 * state.ic1 + a2 * v3
            let v2 = state.ic2 + a2 * state.ic1 + a3 * v3
            state.ic1 = 2 * v1 - state.ic1
            state.ic2 = 2 * v2 - state.ic2
            lp[i] = Float(v2)
            if wantBP { bp[i] = Float(v1) }
            if wantHP { hp[i] = Float(x - k * v1 - v2) }
        }
        if wantLP { node.audioOut[3] = lp }
        if wantHP { node.audioOut[4] = hp }
        if wantBP { node.audioOut[5] = bp }
    }

    // MARK: - 3 Aliaser

    final class AliaserState {
        var held: Float = 0
        var countdown: Int = 0
    }

    private func renderAliaser(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(AliaserState())
        // Assumption: "# of samples" 0…1 maps linearly to a hold period of
        // 1…256 samples. The output is input minus its sample-held copy
        // (the "imperfections" of the aliased signal, per the manual) —
        // at 0 samples the held copy tracks the input and the module is
        // silent, matching the signal-hog/low-output description.
        let amount = Double(min(max(cvIn(node: index, block: 1), 0), 1))
        let period = max(1, Int((amount * 255).rounded()) + 1)
        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            if state.countdown <= 0 {
                state.held = input[i]
                state.countdown = period
            }
            state.countdown -= 1
            out[i] = input[i] - state.held
        }
        node.audioOut[2] = out
    }

    // MARK: - 7 VCA

    private func renderVCA(_ index: Int, _ node: Node, frames: Int) {
        // Assumption: the level knob is displayed in dB on hardware, but
        // the runtime treats CV as a linear gain 0…1 (calibrated by the
        // existing runtime tests; revisit against hardware later).
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

    // MARK: - 8 Audio Multiply

    private func renderAudioMultiply(_ index: Int, _ node: Node, frames: Int) {
        let a = audioIn(node: index, block: 0, frames: frames)
        let b = audioIn(node: index, block: 1, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames { out[i] = a[i] * b[i] }
        node.audioOut[2] = out
    }

    // MARK: - 9 Bit Crusher

    private func renderBitCrusher(_ index: Int, _ node: Node, frames: Int) {
        // Knob: "# bits crushed from 0-31". Assumption: internal
        // resolution is 24 bits, so effective depth = 24 − crushed,
        // clamped to ≥1 bit ("distortion becomes audible around 20 bits
        // reduced" fits a 24-bit source). With the fractions option off
        // the crushed amount is rounded to a whole number of bits;
        // fractional depths interpolate the quantizer step smoothly.
        var crushed = Double(min(max(cvIn(node: index, block: 1), 0), 1)) * 31
        if node.optionText(0) != "on" { crushed = crushed.rounded() }
        let bits = max(1.0, 24.0 - crushed)
        let levels = Float(pow(2.0, bits - 1))  // quantizer steps per polarity
        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            out[i] = (input[i] * levels).rounded() / levels
        }
        node.audioOut[2] = out
    }

    // MARK: - 14 Oscillator

    private func renderOscillator(_ index: Int, _ node: Node, frames: Int) {
        let hz = Self.pitchHz(cvIn(node: index, block: 0))
        let waveform = node.optionText(0)
        let fmOn = node.optionText(1) == "on"
        let dutyOn = node.optionText(2) == "on"
        // Option 3 (upsampling 2x) is a deliberate no-op: the offline
        // renderer accepts the extra aliasing of naive waveforms rather
        // than paying for 2x oversampling; behavior is otherwise
        // identical.
        let fm = fmOn ? audioIn(node: index, block: 1, frames: frames) : []
        // Assumption: duty cycle warps oscillator phase (pulse width for
        // square, skew for the other shapes), clamped to 1…99%.
        let duty = dutyOn
            ? Double(min(max(cvIn(node: index, block: 2), 0.01), 0.99))
            : 0.5

        var buffer = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var p = node.phase
            if dutyOn {
                p = p < duty ? p / duty * 0.5 : 0.5 + (p - duty) / (1 - duty) * 0.5
            }
            let value: Double
            switch waveform {
            case "square": value = p < 0.5 ? 1 : -1
            case "triangle": value = p < 0.5 ? p * 4 - 1 : 3 - p * 4
            case "sawtooth": value = p * 2 - 1
            default: value = sin(p * 2 * .pi)  // sine
            }
            buffer[i] = Float(value)
            // Assumption: FM input is linear through-zero — a ±1 modulator
            // swings the instantaneous frequency between 0 and 2× carrier.
            let f = fmOn ? hz * (1 + Double(fm[i])) : hz
            node.phase += f / sampleRate
            node.phase -= node.phase.rounded(.down)  // wrap into [0,1)
        }
        node.audioOut[3] = buffer
    }

    // MARK: - 24 Multi Filter

    /// Direct-form-I biquad memory for the Multi Filter.
    final class BiquadState {
        var x1: Double = 0, x2: Double = 0
        var y1: Double = 0, y2: Double = 0
    }

    // swiftlint:disable:next function_body_length
    private func renderMultiFilter(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(BiquadState())
        let shape = node.optionText(0)
        // Frequency dial follows the documented filter curve (filterHz).
        let freq = min(max(Self.filterHz(cvIn(node: index, block: 2)), 10),
                       sampleRate * 0.45)
        // Assumption: the q knob shows "width 1-100"; CV 0…1 maps to
        // width 1…100 linearly and Q = 20/width (narrow at low CV).
        let width = 1 + Double(min(max(cvIn(node: index, block: 3), 0), 1)) * 99
        let q = 20 / width
        // Assumption: gain CV 0…1 maps to −24…+24 dB, 0.5 = unity
        // (gain block only exists for bell/hi shelf/low shelf).
        let gainDB = (Double(cvIn(node: index, block: 1)) - 0.5) * 48
        let bigA = pow(10, gainDB / 40)

        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch shape {  // RBJ audio-EQ cookbook coefficients
        case "highpass":
            b0 = (1 + cosw) / 2; b1 = -(1 + cosw); b2 = (1 + cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case "bandpass":  // constant 0 dB peak gain
            b0 = alpha; b1 = 0; b2 = -alpha
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        case "bell":
            b0 = 1 + alpha * bigA; b1 = -2 * cosw; b2 = 1 - alpha * bigA
            a0 = 1 + alpha / bigA; a1 = -2 * cosw; a2 = 1 - alpha / bigA
        case "low_shelf":
            let s = 2 * sqrt(bigA) * alpha
            b0 = bigA * ((bigA + 1) - (bigA - 1) * cosw + s)
            b1 = 2 * bigA * ((bigA - 1) - (bigA + 1) * cosw)
            b2 = bigA * ((bigA + 1) - (bigA - 1) * cosw - s)
            a0 = (bigA + 1) + (bigA - 1) * cosw + s
            a1 = -2 * ((bigA - 1) + (bigA + 1) * cosw)
            a2 = (bigA + 1) + (bigA - 1) * cosw - s
        case "hi_shelf":
            let s = 2 * sqrt(bigA) * alpha
            b0 = bigA * ((bigA + 1) + (bigA - 1) * cosw + s)
            b1 = -2 * bigA * ((bigA - 1) + (bigA + 1) * cosw)
            b2 = bigA * ((bigA + 1) + (bigA - 1) * cosw - s)
            a0 = (bigA + 1) - (bigA - 1) * cosw + s
            a1 = 2 * ((bigA - 1) - (bigA + 1) * cosw)
            a2 = (bigA + 1) - (bigA - 1) * cosw - s
        default:  // lowpass
            b0 = (1 - cosw) / 2; b1 = 1 - cosw; b2 = (1 - cosw) / 2
            a0 = 1 + alpha; a1 = -2 * cosw; a2 = 1 - alpha
        }
        b0 /= a0; b1 /= a0; b2 /= a0; a1 /= a0; a2 /= a0

        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let x = Double(input[i])
            let y = b0 * x + b1 * state.x1 + b2 * state.x2
                - a1 * state.y1 - a2 * state.y2
            state.x2 = state.x1; state.x1 = x
            state.y2 = state.y1; state.y1 = y
            out[i] = Float(y)
        }
        node.audioOut[4] = out
    }

    // MARK: - 27 All Pass Filter

    final class AllPassState {
        var x1 = [Double](repeating: 0, count: 8)
        var y1 = [Double](repeating: 0, count: 8)
    }

    private func renderAllPass(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(AllPassState())
        let poles = min(max(node.optionInt(0), 1), 8)
        // Assumption: the "filter gain" CV 0…1 maps linearly to the
        // first-order allpass coefficient −0.95…+0.95 (magnitude stays
        // unity; only the phase relationship changes).
        let g = Double(min(max(cvIn(node: index, block: 1), 0), 1)) * 1.9 - 0.95
        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            var x = Double(input[i])
            for p in 0..<poles {
                // H(z) = (g + z⁻¹) / (1 + g·z⁻¹)
                let y = g * x + state.x1[p] - g * state.y1[p]
                state.x1[p] = x
                state.y1[p] = y
                x = y
            }
            out[i] = Float(x)
        }
        node.audioOut[2] = out
    }

    // MARK: - 38 Noise

    /// xorshift64* white-noise source, seeded from the node index so a
    /// given patch renders the same noise every run (tests rely on it).
    final class NoiseState {
        var seed: UInt64
        init(seed: UInt64) { self.seed = seed }
        func next() -> Float {
            seed ^= seed >> 12
            seed ^= seed << 25
            seed ^= seed >> 27
            let r = seed &* 0x2545_F491_4F6C_DD1D
            return Float(r >> 40) / Float(1 << 23) - 1  // [-1, 1)
        }
    }

    private func renderNoise(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(
            NoiseState(seed: 0x9E37_79B9_7F4A_7C15 &+ UInt64(index) &* 0xBF58_476D_1CE4_E5B9))
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames { out[i] = state.next() }
        node.audioOut[0] = out
    }

    // MARK: - 63 Bit Modulator

    private func renderBitModulator(_ index: Int, _ node: Node, frames: Int) {
        let a = audioIn(node: index, block: 0, frames: frames)
        let b = audioIn(node: index, block: 1, frames: frames)
        let op = node.optionText(0)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            // Assumption: samples combine as 16-bit two's-complement bit
            // patterns (the "unholy glitchy" byte-level logic op).
            let ua = UInt16(bitPattern: Int16(max(-32767, min(32767, a[i] * 32767))))
            let ub = UInt16(bitPattern: Int16(max(-32767, min(32767, b[i] * 32767))))
            let r: UInt16
            switch op {
            case "and": r = ua & ub
            case "or": r = ua | ub
            default: r = ua ^ ub  // xor
            }
            out[i] = Float(Int16(bitPattern: r)) / 32767
        }
        node.audioOut[2] = out
    }

    // MARK: - 65 Inverter

    private func renderInverter(_ index: Int, _ node: Node, frames: Int) {
        var out = audioIn(node: index, block: 0, frames: frames)
        for i in 0..<frames { out[i] = -out[i] }
        node.audioOut[1] = out
    }
}
