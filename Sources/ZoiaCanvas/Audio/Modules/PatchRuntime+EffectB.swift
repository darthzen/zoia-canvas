import Foundation

/// Modulation, time-based effects and reverbs — IDs 25 (Plate Reverb),
/// 29 (Phaser), 41 (Tremolo), 43 (Delay w/Mod), 67 (Ghostverb),
/// 69 (Flanger), 70 (Chorus), 71 (Vibrato), 74 (Hall Reverb),
/// 75 (Ping Pong Delay), 79 (Reverb Lite), 80 (Room Reverb),
/// 106 (Reverse Delay), 107 (Univibe).
///
/// Shared curve assumptions (documented once, used throughout):
/// - Dial curves with five catalog knots (value at cv 0, .25, .5, .75, 1)
///   are interpolated piecewise-linearly between knots. // Assumption:
///   the device's exact taper is unpublished; the knots come from the
///   catalog's paramDefaults ranges.
/// - Feedback/regen/resonance dials labeled in dB with knots
///   [-inf, -12, -6, -2.5, 0] map through the same piecewise curve in dB;
///   below cv 0.25 gain ramps linearly from 0 to the -12 dB point.
///   // Assumption: smooth approach to -inf.
/// - "mix" (0 fully dry … 100 fully wet) is a linear crossfade
///   out = dry×(1−mix) + wet×mix. // Assumption: device law unmeasured.
/// - Tap tempo measures the interval between rising edges (≥0.5) of the
///   tap CV at control-block granularity. // Assumption: block-rate taps.
/// - "cv_direct" control mode uses the control CV (0…1) directly as the
///   sweep/LFO position instead of an internal LFO.
extension PatchRuntime {
    func renderEffectB(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 25: renderClassicReverb(index, node, frames: ctx.frames, kind: .plate)
        case 29: renderPhaserModule(index, node, frames: ctx.frames)
        case 41: renderTremoloModule(index, node, frames: ctx.frames)
        case 43: renderDelayWithMod(index, node, frames: ctx.frames)
        case 67: renderGhostverb(index, node, frames: ctx.frames)
        case 69: renderFlangerModule(index, node, frames: ctx.frames)
        case 70: renderChorusModule(index, node, frames: ctx.frames)
        case 71: renderVibratoModule(index, node, frames: ctx.frames)
        case 74: renderClassicReverb(index, node, frames: ctx.frames, kind: .hall)
        case 75: renderPingPongDelay(index, node, frames: ctx.frames)
        case 79: renderReverbLite(index, node, frames: ctx.frames)
        case 80: renderClassicReverb(index, node, frames: ctx.frames, kind: .room)
        case 106: renderReverseDelay(index, node, frames: ctx.frames)
        case 107: renderUnivibe(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    // MARK: - Shared curves

    /// Piecewise-linear dial with 5 knots at cv 0, .25, .5, .75, 1.
    private func ebDial(_ cv: Float, _ knots: [Double]) -> Double {
        let x = Double(min(max(cv, 0), 1)) * 4
        let i = min(Int(x), 3)
        return knots[i] + (knots[i + 1] - knots[i]) * (x - Double(i))
    }

    /// LFO rate dial: 0…40 Hz (knots 0, 1.53, 5.4, 15.2, 40).
    private func ebRateHz(_ cv: Float) -> Double { ebDial(cv, [0, 1.53, 5.4, 15.2, 40]) }

    /// Feedback dial in dB (knots -inf, -12, -6, -2.5, 0) → linear gain.
    private func ebFeedbackGain(_ cv: Float) -> Float {
        let c = min(max(cv, 0), 1)
        if c <= 0 { return 0 }
        if c < 0.25 {
            // Assumption: linear gain ramp from silence to the -12 dB knot.
            return Float(pow(10, -12.0 / 20)) * c / 0.25
        }
        return Float(pow(10, ebDial(c, [-24, -12, -6, -2.5, 0]) / 20))
    }

    /// Update tap-tempo state from the tap CV once per control block.
    private func ebUpdateTap(_ mod: EBMod, gate: Float, frames: Int) {
        if gate >= 0.5, mod.lastTap < 0.5 {
            if mod.samplesSinceTap > 32, mod.samplesSinceTap < sampleRate * 30 {
                mod.tapPeriod = mod.samplesSinceTap
            }
            mod.samplesSinceTap = 0
        }
        mod.lastTap = gate
        mod.samplesSinceTap += Double(frames)
    }

    /// Resolve the rate/tap/cv_direct control trio for LFO-driven effects.
    /// Returns Hz to run the internal LFO at, or nil for cv_direct along
    /// with the direct CV value.
    private func ebControlHz(
        _ index: Int, _ node: Node, mod: EBMod, frames: Int,
        control: String, ratePos: Int, tapPos: Int, directPos: Int
    ) -> (hz: Double?, direct: Float) {
        switch control {
        case "tap_tempo":
            ebUpdateTap(mod, gate: cvIn(node: index, block: tapPos), frames: frames)
            return (mod.tapPeriod > 0 ? sampleRate / mod.tapPeriod : 0, 0)
        case "cv_direct":
            return (nil, cvIn(node: index, block: directPos))
        default:
            return (ebRateHz(cvIn(node: index, block: ratePos)), 0)
        }
    }

    /// "a:b" tap-ratio text → delay-time multiplier per tap interval.
    private func ebTapRatio(_ text: String) -> Double {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[1] != 0 else { return 1 }
        return parts[0] / parts[1]
    }

    /// One-pole lowpass coefficient for a cutoff frequency.
    private func ebLPCoeff(_ hz: Double) -> Float {
        Float(1 - exp(-2 * .pi * min(hz, sampleRate * 0.45) / sampleRate))
    }

    // MARK: - Plate / Hall / Room Reverb (25, 74, 80)

    private enum EBReverbKind { case plate, hall, room }

    /// Schroeder-style: 4 parallel damped combs + 2 series allpasses per
    /// channel. The three reverbs differ by comb/allpass delay sets and
    /// damping. // Assumption: the device algorithms are unpublished;
    /// sizes chosen so room < plate < hall in loop length, and hall is
    /// darkest (most damping), plate brightest.
    private func renderClassicReverb(_ index: Int, _ node: Node, frames: Int, kind: EBReverbKind) {
        let combMs: [Double], apMs: [Double], damp: Float
        let decayPos: Int, lowPos: Int, highPos: Int, mixPos: Int, outL: Int, outR: Int
        let highIsShelf: Bool
        switch kind {
        case .plate:
            combMs = [21.3, 23.9, 26.7, 29.9]; apMs = [3.7, 5.9]; damp = 0.20
            decayPos = 3; lowPos = 6; highPos = 7; mixPos = 2; outL = 4; outR = 5
            highIsShelf = true
        case .hall:
            combMs = [42.1, 47.9, 53.3, 59.9]; apMs = [6.1, 8.3]; damp = 0.45
            decayPos = 2; lowPos = 6; highPos = 7; mixPos = 3; outL = 4; outR = 5
            highIsShelf = false
        case .room:
            combMs = [26.9, 29.7, 32.1, 34.9]; apMs = [4.3, 6.1]; damp = 0.35
            decayPos = 2; lowPos = 3; highPos = 4; mixPos = 5; outL = 6; outR = 7
            highIsShelf = false
        }

        let st = node.state(EBReverbState(combMs: combMs, apMs: apMs, sampleRate: sampleRate))
        // Decay knots 0…inf seconds; "inf" capped at 120 s (near-freeze).
        let rt60 = ebDial(cvIn(node: index, block: decayPos), [0.05, 2.62, 4.12, 8.6, 120])
        let mix = cvIn(node: index, block: mixPos)
        let lowGain = Float(pow(10, Double(cvIn(node: index, block: lowPos) * 16 - 8) / 20))
        let highCV = cvIn(node: index, block: highPos)
        let highGain = Float(pow(10, Double(highCV * 16 - 8) / 20))
        // Hall/Room high control is an LPF cutoff dial 1700…4700 Hz.
        let lpfA = ebLPCoeff(1700 + 3000 * Double(highCV))
        let lowA = ebLPCoeff(250)
        let shelfA = ebLPCoeff(2000)

        let inL = audioIn(node: index, block: 0, frames: frames)
        // Assumption: with nothing wired to input R the mono input feeds
        // both reverb channels.
        let inR = hasWire(node: index, block: 1) ? audioIn(node: index, block: 1, frames: frames) : inL

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        for i in 0..<frames {
            for ch in 0..<2 {
                let dry = ch == 0 ? inL[i] : inR[i]
                let channel = st.channels[ch]
                var wet = channel.process(dry * 0.5, rt60: rt60, damp: damp, sampleRate: sampleRate)
                // Low shelf on the wet signal.
                let low = channel.eqLow.process(wet, lowA)
                wet += (lowGain - 1) * low
                if highIsShelf {
                    let high = wet - channel.eqHigh.process(wet, shelfA)
                    wet += (highGain - 1) * high
                } else {
                    wet = channel.eqHigh.process(wet, lpfA)
                }
                let out = dry * (1 - mix) + wet * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
        }
        node.audioOut[outL] = bufL
        node.audioOut[outR] = bufR
    }

    // MARK: - Reverb Lite (79)

    /// Cheaper mono engine: 3 combs + 1 allpass; the mono wet feeds both
    /// outputs. // Assumption: "lite" trades stereo spread for CPU.
    private func renderReverbLite(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBReverbState(
            combMs: [25.3, 29.5, 33.7], apMs: [5.3], sampleRate: sampleRate, channels: 1))
        let rt60 = ebDial(cvIn(node: index, block: 2), [0.05, 2.62, 4.12, 8.6, 120])
        let mix = cvIn(node: index, block: 3)
        let stereoIn = node.optionText(0) == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        for i in 0..<frames {
            let dryL = inL[i], dryR = inR[i]
            let wet = st.channels[0].process(
                (dryL + dryR) * 0.35, rt60: rt60, damp: 0.35, sampleRate: sampleRate)
            bufL[i] = dryL * (1 - mix) + wet * mix
            bufR[i] = dryR * (1 - mix) + wet * mix
        }
        node.audioOut[4] = bufL
        if node.optionText(0) != "1in->1out" { node.audioOut[5] = bufR }
    }

    // MARK: - Ghostverb (67)

    /// Reverb with heavily modulated comb feedback per the doc ("ghostly
    /// modulation"). Comb read taps wobble with an internal LFO whose
    /// speed is `rate` and excursion scales with `resonance`.
    /// // Assumption: modulation depth up to ~2 ms; decay CV maps to comb
    /// feedback 0.5…0.99.
    private func renderGhostverb(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBGhostState(sampleRate: sampleRate))
        let decay = cvIn(node: index, block: 2)
        let hz = ebDial(cvIn(node: index, block: 3), [0.05, 0.54, 1.03, 1.51, 2])
        let resonance = cvIn(node: index, block: 4)
        let mix = cvIn(node: index, block: 5)
        let feedback = 0.5 + 0.49 * decay
        let modDepth = Double(resonance) * 0.002 * sampleRate

        let stereoIn = node.optionText(0) == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let increment = hz / sampleRate
        for i in 0..<frames {
            let phase = st.mod.phase
            for ch in 0..<2 {
                let dry = ch == 0 ? inL[i] : inR[i]
                let channel = st.channels[ch]
                var sum: Float = 0
                for (c, comb) in channel.combs.enumerated() {
                    let wobble = sin(2 * .pi * (phase + Double(c) * 0.25 + Double(ch) * 0.13))
                    sum += comb.process(
                        dry * 0.4,
                        readDelay: comb.baseDelay + modDepth * wobble,
                        feedback: feedback, damp: 0.3)
                }
                var wet = sum * 0.4
                wet = channel.allpass.process(wet)
                let out = dry * (1 - mix) + wet * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
            st.mod.phase += increment
            if st.mod.phase >= 1 { st.mod.phase -= 1 }
        }
        node.audioOut[6] = bufL
        if node.optionText(0) != "1in->1out" { node.audioOut[7] = bufR }
    }

    // MARK: - Phaser (29)

    /// Cascaded first-order allpass stages swept exponentially around
    /// 800 Hz (200…3200 Hz at full width). // Assumption: sweep range and
    /// center are unpublished; resonance feeds the chain output back into
    /// its input; the second channel's LFO runs 90° behind for stereo
    /// movement.
    private func renderPhaserModule(_ index: Int, _ node: Node, frames: Int) {
        let stages = max(node.optionInt(2), 1)
        let st = node.state(EBPhaserState(stages: stages))
        let (hz, direct) = ebControlHz(
            index, node, mod: st.mod, frames: frames,
            control: node.optionText(1), ratePos: 3, tapPos: 7, directPos: 8)
        let feedback = ebFeedbackGain(cvIn(node: index, block: 4)) * 0.9
        let width = cvIn(node: index, block: 9)
        let mix = cvIn(node: index, block: 2)

        let channels = node.optionText(0)
        let stereoIn = channels == "2in->2out"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL
        let rightActive = channels != "1in->1out"

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let increment = (hz ?? 0) / sampleRate
        for i in 0..<frames {
            for ch in 0...(rightActive ? 1 : 0) {
                let position: Double
                if hz != nil {
                    let offset = ch == 1 ? 0.25 : 0
                    position = (sin(2 * .pi * (st.mod.phase + offset)) + 1) / 2
                } else {
                    position = Double(direct)
                }
                let swept = 0.5 + (position - 0.5) * Double(width)
                let freq = 200 * pow(16, swept)
                let t = tan(.pi * min(freq, sampleRate * 0.45) / sampleRate)
                let c = Float((1 - t) / (1 + t))
                let dry = ch == 1 ? inR[i] : inL[i]
                var y = dry + st.lastOut[ch] * feedback
                for s in 0..<stages { y = st.chains[ch][s].process(y, c) }
                st.lastOut[ch] = y
                let out = dry * (1 - mix) + y * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
            st.mod.phase += increment
            if st.mod.phase >= 1 { st.mod.phase -= 1 }
        }
        node.audioOut[5] = bufL
        if rightActive { node.audioOut[6] = bufR }
    }

    // MARK: - Tremolo (41)

    /// Amplitude modulation: gain = 1 − depth × (1 − shape). Waveform
    /// shapes: // Assumption: "fender-ish" is a rounded sine
    /// (smoothstepped), "vox-ish" a sharper power-of-3 throb; both
    /// channels share one LFO with no phase offset.
    private func renderTremoloModule(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBTremoloState())
        let (hz, direct) = ebControlHz(
            index, node, mod: st.mod, frames: frames,
            control: node.optionText(1), ratePos: 2, tapPos: 3, directPos: 4)
        let depth = cvIn(node: index, block: 5)
        let channels = node.optionText(0)
        let stereoIn = channels == "2in->2out"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL
        let waveform = node.optionText(2)

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let increment = (hz ?? 0) / sampleRate
        for i in 0..<frames {
            let shape: Double
            if hz != nil {
                let p = st.mod.phase
                let sine = (sin(2 * .pi * p) + 1) / 2
                switch waveform {
                case "triangle": shape = p < 0.5 ? p * 2 : 2 - p * 2
                case "sine": shape = sine
                case "square": shape = p < 0.5 ? 1 : 0
                case "vox-ish": shape = sine * sine * sine
                default: shape = sine * sine * (3 - 2 * sine)  // fender-ish
                }
                st.mod.phase += increment
                if st.mod.phase >= 1 { st.mod.phase -= 1 }
            } else {
                shape = Double(direct)
            }
            let gain = 1 - depth * Float(1 - shape)
            bufL[i] = inL[i] * gain
            bufR[i] = inR[i] * gain
        }
        node.audioOut[6] = bufL
        if channels != "1in->1out" { node.audioOut[7] = bufR }
    }

    // MARK: - Delay w/Mod (43)

    /// Delay line with a sine-modulated read tap, feedback with a
    /// type-dependent tone/saturation stage, and dry/wet mix.
    /// // Assumption: mod depth 1 sweeps the tap ±5 ms; tape ≈ 5 kHz
    /// lowpass in the loop, old tape ≈ 2.5 kHz + soft clip, bbd ≈ 3 kHz
    /// + soft clip.
    private func renderDelayWithMod(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBDelayModState(sampleRate: sampleRate, lines: 2))
        let control = node.optionText(1)
        let delaySeconds: Double
        if control == "tap_tempo" {
            ebUpdateTap(st.mod, gate: cvIn(node: index, block: 5), frames: frames)
            let ratio = ebTapRatio(node.optionText(3))
            let seconds = st.tapSeconds(sampleRate: sampleRate, ratio: ratio)
            delaySeconds = min(max(seconds, 0.0625), 2.0)
        } else {
            delaySeconds = ebDial(cvIn(node: index, block: 2), [62.5, 546.9, 1031, 1516, 2000]) / 1000
        }
        let feedback = ebFeedbackGain(cvIn(node: index, block: 3))
        let modHz = ebRateHz(cvIn(node: index, block: 4))
        let modDepth = Double(cvIn(node: index, block: 6)) * 0.005 * sampleRate
        let mix = cvIn(node: index, block: 7)
        let (fbA, saturate) = ebDelayTypeFilter(node.optionText(2))

        let channels = node.optionText(0)
        let stereoIn = channels == "2in->2out"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let delaySamples = max(delaySeconds * sampleRate, 1)
        let increment = modHz / sampleRate
        let lineCount = stereoIn ? 2 : 1
        for i in 0..<frames {
            let modOffset = modDepth * sin(2 * .pi * st.mod.phase)
            for ch in 0..<lineCount {
                let dry = ch == 1 ? inR[i] : inL[i]
                let wet = st.lines[ch].read(delaySamples + modOffset)
                var fb = st.fbFilters[ch].process(wet, fbA)
                if saturate { fb = tanh(fb * 1.5) / 1.5 }
                st.lines[ch].write(dry + fb * feedback)
                let out = dry * (1 - mix) + wet * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
            if !stereoIn { bufR[i] = bufL[i] }
            st.mod.phase += increment
            if st.mod.phase >= 1 { st.mod.phase -= 1 }
        }
        node.audioOut[8] = bufL
        if channels != "1in->1out" { node.audioOut[9] = bufR }
    }

    /// Delay "type" option → (feedback lowpass coefficient, saturation).
    private func ebDelayTypeFilter(_ type: String) -> (Float, Bool) {
        switch type {
        case "tape": return (ebLPCoeff(5000), false)
        case "old_tape": return (ebLPCoeff(2500), true)
        case "bbd": return (ebLPCoeff(3000), true)
        default: return (1, false)  // clean: no filtering
        }
    }

    // MARK: - Ping Pong Delay (75)

    /// Two cross-coupled delay lines. Mono modes: input feeds the left
    /// line, the left tap feeds the right line at unity (so repeats
    /// alternate L, R, L…), and the right tap returns through the
    /// feedback dial. Stereo: symmetric cross-feedback.
    /// // Assumption: cross-coupling topology unpublished; this yields
    /// the documented alternating repeats.
    private func renderPingPongDelay(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBDelayModState(sampleRate: sampleRate, lines: 2))
        let control = node.optionText(1)
        let delaySeconds: Double
        switch control {
        case "tap_tempo":
            ebUpdateTap(st.mod, gate: cvIn(node: index, block: 3), frames: frames)
            let ratio = ebTapRatio(node.optionText(3))
            delaySeconds = min(max(st.tapSeconds(sampleRate: sampleRate, ratio: ratio), 0.0625), 2.0)
        case "cv_direct":
            // Assumption: cv_direct dials the time through the same taper.
            delaySeconds = ebDial(cvIn(node: index, block: 3), [62.5, 546.9, 1031, 1516, 2000]) / 1000
        default:
            delaySeconds = ebDial(cvIn(node: index, block: 2), [62.5, 546.9, 1031, 1516, 2000]) / 1000
        }
        let feedback = ebFeedbackGain(cvIn(node: index, block: 4))
        let modHz = ebRateHz(cvIn(node: index, block: 5))
        let modDepth = Double(cvIn(node: index, block: 6)) * 0.005 * sampleRate
        let mix = cvIn(node: index, block: 7)
        let (fbA, saturate) = ebDelayTypeFilter(node.optionText(2))

        let stereoIn = node.optionText(0) == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : [Float](repeating: 0, count: frames)

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let delaySamples = max(delaySeconds * sampleRate, 1)
        let increment = modHz / sampleRate
        for i in 0..<frames {
            let modOffset = modDepth * sin(2 * .pi * st.mod.phase)
            let wetL = st.lines[0].read(delaySamples + modOffset)
            let wetR = st.lines[1].read(delaySamples + modOffset)
            var fbL = st.fbFilters[0].process(wetR, fbA)
            var fbR = st.fbFilters[1].process(wetL, fbA)
            if saturate {
                fbL = tanh(fbL * 1.5) / 1.5
                fbR = tanh(fbR * 1.5) / 1.5
            }
            if stereoIn {
                st.lines[0].write(inL[i] + fbL * feedback)
                st.lines[1].write(inR[i] + fbR * feedback)
            } else {
                st.lines[0].write(inL[i] + fbL * feedback)
                st.lines[1].write(fbR)  // unity ping → pong
            }
            let dryL = inL[i]
            let dryR = stereoIn ? inR[i] : inL[i]
            bufL[i] = dryL * (1 - mix) + wetL * mix
            bufR[i] = dryR * (1 - mix) + wetR * mix
            st.mod.phase += increment
            if st.mod.phase >= 1 { st.mod.phase -= 1 }
        }
        node.audioOut[8] = bufL
        node.audioOut[9] = bufR
    }

    // MARK: - Flanger (69)

    /// Short modulated delay summed with dry, with regeneration and a
    /// tilt EQ on the wet path. Types: // Assumption: 1960s sweeps
    /// 0.5…4.5 ms, 1970s 0.5…9.5 ms, thru-0 delays the dry path 3 ms so
    /// the wet tap crosses through zero.
    private func renderFlangerModule(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBFlangerState(sampleRate: sampleRate))
        let (hz, direct) = ebControlHz(
            index, node, mod: st.mod, frames: frames,
            control: node.optionText(1), ratePos: 2, tapPos: 3, directPos: 4)
        let regen = ebFeedbackGain(cvIn(node: index, block: 5)) * 0.95
        let width = Double(cvIn(node: index, block: 6))
        let tilt = Double(cvIn(node: index, block: 7) * 16 - 8)
        let mix = cvIn(node: index, block: 8)
        let type = node.optionText(2)

        let centerMs: Double, depthMs: Double, dryDelayMs: Double
        switch type {
        case "1970s": centerMs = 5.0; depthMs = 4.5 * width; dryDelayMs = 0
        case "thru_0": centerMs = 3.0; depthMs = 3.0 * width; dryDelayMs = 3.0
        default: centerMs = 2.5; depthMs = 2.0 * width; dryDelayMs = 0  // 1960s
        }
        let gLow = Float(pow(10, -tilt / 40))
        let gHigh = Float(pow(10, tilt / 40))
        let tiltA = ebLPCoeff(800)

        let stereoIn = node.optionText(0) == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL
        let rightActive = node.optionText(0) != "1in->1out"

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let increment = (hz ?? 0) / sampleRate
        let msToSamples = sampleRate / 1000
        for i in 0..<frames {
            for ch in 0...(rightActive ? 1 : 0) {
                let position: Double
                if hz != nil {
                    let offset = ch == 1 ? 0.25 : 0
                    position = sin(2 * .pi * (st.mod.phase + offset))
                } else {
                    position = Double(direct) * 2 - 1
                }
                let delay = max((centerMs + depthMs * position) * msToSamples, 1)
                let input = ch == 1 ? inR[i] : inL[i]
                var wet = st.lines[ch].read(delay)
                st.lines[ch].write(input + wet * regen)
                // Tilt EQ on the wet path.
                let low = st.tiltFilters[ch].process(wet, tiltA)
                wet = low * gLow + (wet - low) * gHigh
                let dry = dryDelayMs > 0
                    ? st.dryLines[ch].readAfterWrite(input, dryDelayMs * msToSamples)
                    : input
                let out = dry * (1 - mix) + wet * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
            st.mod.phase += increment
            if st.mod.phase >= 1 { st.mod.phase -= 1 }
        }
        node.audioOut[9] = bufL
        if rightActive { node.audioOut[10] = bufR }
    }

    // MARK: - Chorus (70)

    /// Modulated delay around 12 ms mixed with dry; width scales the
    /// excursion (±8 ms at full width); tilt EQ on the wet path; the
    /// right channel's LFO runs 90° behind. // Assumption: center/depth
    /// values unpublished.
    private func renderChorusModule(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBFlangerState(sampleRate: sampleRate))
        let (hz, direct) = ebControlHz(
            index, node, mod: st.mod, frames: frames,
            control: node.optionText(1), ratePos: 2, tapPos: 3, directPos: 4)
        let width = Double(cvIn(node: index, block: 5))
        let tilt = Double(cvIn(node: index, block: 6) * 16 - 8)
        let mix = cvIn(node: index, block: 7)
        let gLow = Float(pow(10, -tilt / 40))
        let gHigh = Float(pow(10, tilt / 40))
        let tiltA = ebLPCoeff(800)

        let stereoIn = node.optionText(0) == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL
        let rightActive = node.optionText(0) != "1in->1out"

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let increment = (hz ?? 0) / sampleRate
        let msToSamples = sampleRate / 1000
        for i in 0..<frames {
            for ch in 0...(rightActive ? 1 : 0) {
                let position: Double
                if hz != nil {
                    let offset = ch == 1 ? 0.25 : 0
                    position = sin(2 * .pi * (st.mod.phase + offset))
                } else {
                    position = Double(direct) * 2 - 1
                }
                let delay = max((12 + 8 * width * position) * msToSamples, 1)
                let input = ch == 1 ? inR[i] : inL[i]
                var wet = st.lines[ch].readAfterWrite(input, delay)
                let low = st.tiltFilters[ch].process(wet, tiltA)
                wet = low * gLow + (wet - low) * gHigh
                let out = input * (1 - mix) + wet * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
            st.mod.phase += increment
            if st.mod.phase >= 1 { st.mod.phase -= 1 }
        }
        node.audioOut[8] = bufL
        if rightActive { node.audioOut[9] = bufR }
    }

    // MARK: - Vibrato (71)

    /// Wet-only modulated delay (pitch wobble). Width sets the excursion
    /// (up to ~7.5 ms around a matching center so pitch bends both ways).
    /// // Assumption: swung waveforms are asymmetric variants — swung
    /// sine warps the phase, swung is a 70/30 triangle.
    private func renderVibratoModule(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBFlangerState(sampleRate: sampleRate))
        let (hz, direct) = ebControlHz(
            index, node, mod: st.mod, frames: frames,
            control: node.optionText(1), ratePos: 2, tapPos: 3, directPos: 4)
        let width = Double(cvIn(node: index, block: 5))
        let depthMs = 0.5 + 7 * width
        let waveform = node.optionText(2)

        let stereoIn = node.optionText(0) == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL
        let rightActive = node.optionText(0) != "1in->1out"

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let increment = (hz ?? 0) / sampleRate
        let msToSamples = sampleRate / 1000
        for i in 0..<frames {
            let bip: Double
            if hz != nil {
                let p = st.mod.phase
                switch waveform {
                case "triangle": bip = (p < 0.5 ? p * 2 : 2 - p * 2) * 2 - 1
                case "swung_sine": bip = sin(2 * .pi * pow(p, 1.4))
                case "swung":
                    let tri = p < 0.7 ? p / 0.7 : (1 - p) / 0.3
                    bip = tri * 2 - 1
                default: bip = sin(2 * .pi * p)  // sine
                }
                st.mod.phase += increment
                if st.mod.phase >= 1 { st.mod.phase -= 1 }
            } else {
                bip = Double(direct) * 2 - 1
            }
            let delay = max((1 + depthMs * (1 + bip) / 2) * msToSamples, 1)
            for ch in 0...(rightActive ? 1 : 0) {
                let input = ch == 1 ? inR[i] : inL[i]
                let wet = st.lines[ch].readAfterWrite(input, delay)
                if ch == 0 { bufL[i] = wet } else { bufR[i] = wet }
            }
        }
        node.audioOut[6] = bufL
        if rightActive { node.audioOut[7] = bufR }
    }

    // MARK: - Reverse Delay (106)

    /// Records chunks of `delay time` length and plays each finished
    /// chunk backwards at a pitch-shifted rate while the next records.
    /// // Assumption: pitch cv maps linearly to ±12 semitones (playback
    /// rate 2^(semi/12)); a fast chunk (rate > 1) goes silent once
    /// exhausted; the reversed wet feeds back into the record input.
    private func renderReverseDelay(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBReverseState())
        let control = node.optionText(1)
        let delaySeconds: Double
        if control == "rate" {
            delaySeconds = ebDial(cvIn(node: index, block: 2), [62.5, 359.4, 656.3, 953.1, 1250]) / 1000
        } else {
            ebUpdateTap(st.mod, gate: cvIn(node: index, block: 3), frames: frames)
            // tap_ratio is a CV block here: quantized into the ratio list.
            // Assumption: 0…1 indexes the documented 10 ratios.
            let ratios: [Double] = [1, 2.0 / 3, 0.5, 1.0 / 3, 3.0 / 8, 0.25, 3.0 / 16, 0.125, 0.0625, 0.03125]
            let ratioIndex = min(Int((cvIn(node: index, block: 4) * 9).rounded()), 9)
            let seconds = st.mod.tapPeriod > 0
                ? st.mod.tapPeriod / sampleRate * ratios[ratioIndex] : 0.0625
            delaySeconds = min(max(seconds, 0.0625), 1.25)
        }
        let feedback = ebFeedbackGain(cvIn(node: index, block: 5))
        let semitones = Double(cvIn(node: index, block: 6)) * 24 - 12
        let rate = pow(2, semitones / 12)
        let mix = cvIn(node: index, block: 7)

        let stereo = node.optionText(0) == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereo ? audioIn(node: index, block: 1, frames: frames) : inL
        let chunkLen = max(Int(delaySeconds * sampleRate), 16)

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        for i in 0..<frames {
            for ch in 0...(stereo ? 1 : 0) {
                let channel = st.channels[ch]
                if channel.rec.isEmpty { channel.rec = [Float](repeating: 0, count: chunkLen) }
                let dry = ch == 1 ? inR[i] : inL[i]
                // Reversed, pitch-shifted read of the finished chunk.
                var wet: Float = 0
                let readPos = Double(channel.play.count - 1) - channel.playPos
                if !channel.play.isEmpty, readPos >= 0 {
                    let i0 = Int(readPos)
                    let frac = Float(readPos - Double(i0))
                    let s0 = channel.play[i0]
                    let s1 = i0 > 0 ? channel.play[i0 - 1] : s0
                    wet = s0 * (1 - frac) + s1 * frac
                    channel.playPos += rate
                }
                channel.rec[channel.recIdx] = dry + wet * feedback
                channel.recIdx += 1
                if channel.recIdx >= channel.rec.count {
                    channel.play = channel.rec
                    channel.playPos = 0
                    channel.rec = [Float](repeating: 0, count: chunkLen)
                    channel.recIdx = 0
                }
                let out = dry * (1 - mix) + wet * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
            if !stereo { bufR[i] = bufL[i] }
        }
        node.audioOut[8] = bufL
        if stereo { node.audioOut[9] = bufR }
    }

    // MARK: - Univibe (107)

    /// Staged-allpass phaser variant: four first-order stages at
    /// staggered center frequencies (the classic lamp/LDR stagger), all
    /// swept together. // Assumption: stage centers 110/320/830/2150 Hz,
    /// depth sweeps ±1.3 octaves, resonance feeds back up to 0.75.
    private func renderUnivibe(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(EBPhaserState(stages: 4))
        let (hz, direct) = ebControlHz(
            index, node, mod: st.mod, frames: frames,
            control: node.optionText(1), ratePos: 2, tapPos: 3, directPos: 4)
        let depth = Double(cvIn(node: index, block: 5))
        let feedback = cvIn(node: index, block: 6) * 0.75
        let mix = cvIn(node: index, block: 7)
        let baseFreqs: [Double] = [110, 320, 830, 2150]

        let channels = node.optionText(0)
        let stereoIn = channels == "stereo"
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL
        let rightActive = channels != "1in->1out"

        var bufL = [Float](repeating: 0, count: frames)
        var bufR = bufL
        let increment = (hz ?? 0) / sampleRate
        for i in 0..<frames {
            for ch in 0...(rightActive ? 1 : 0) {
                let position: Double
                if hz != nil {
                    let offset = ch == 1 ? 0.25 : 0
                    position = sin(2 * .pi * (st.mod.phase + offset))
                } else {
                    position = Double(direct) * 2 - 1
                }
                let sweep = pow(2, position * depth * 1.3)
                let dry = ch == 1 ? inR[i] : inL[i]
                var y = dry + st.lastOut[ch] * feedback
                for s in 0..<4 {
                    let freq = min(baseFreqs[s] * sweep, sampleRate * 0.45)
                    let t = tan(.pi * freq / sampleRate)
                    let c = Float((1 - t) / (1 + t))
                    y = st.chains[ch][s].process(y, c)
                }
                st.lastOut[ch] = y
                let out = dry * (1 - mix) + y * mix
                if ch == 0 { bufL[i] = out } else { bufR[i] = out }
            }
            st.mod.phase += increment
            if st.mod.phase >= 1 { st.mod.phase -= 1 }
        }
        node.audioOut[8] = bufL
        if rightActive { node.audioOut[9] = bufR }
    }
}

// MARK: - DSP primitives (effect-b private)

/// Circular delay line with fractional (linear-interpolated) reads.
/// `read(d)` returns the sample written `d` samples ago; call it before
/// `write` within a sample.
private final class EBDelayLine {
    private var buffer: [Float]
    private var writeIndex = 0

    init(capacity: Int) {
        buffer = [Float](repeating: 0, count: max(capacity, 8))
    }

    func write(_ x: Float) {
        buffer[writeIndex] = x
        writeIndex += 1
        if writeIndex == buffer.count { writeIndex = 0 }
    }

    func read(_ delay: Double) -> Float {
        let d = min(max(delay, 1), Double(buffer.count - 2))
        let whole = Int(d)
        let frac = Float(d - Double(whole))
        let count = buffer.count
        let i0 = ((writeIndex - whole) % count + count) % count
        let i1 = (i0 - 1 + count) % count
        return buffer[i0] * (1 - frac) + buffer[i1] * frac
    }

    /// Write then read — for taps with no feedback into the same line.
    func readAfterWrite(_ x: Float, _ delay: Double) -> Float {
        write(x)
        return read(delay)
    }
}

/// One-pole lowpass; `a` is the smoothing coefficient (1 = bypass).
private struct EBOnePole {
    var y: Float = 0
    mutating func process(_ x: Float, _ a: Float) -> Float {
        y += (x - y) * a
        return y
    }
}

/// First-order allpass y[n] = c·x[n] + x[n−1] − c·y[n−1] (phaser stage).
private struct EBAllpass1 {
    var x1: Float = 0
    var y1: Float = 0
    mutating func process(_ x: Float, _ c: Float) -> Float {
        let y = c * x + x1 - c * y1
        x1 = x
        y1 = y
        return y
    }
}

/// Schroeder allpass diffuser with fixed delay and g = 0.5.
private final class EBSchroederAllpass {
    private let line: EBDelayLine
    private let delay: Double
    private let g: Float = 0.5

    init(delaySamples: Int) {
        delay = Double(max(delaySamples, 2))
        line = EBDelayLine(capacity: max(delaySamples, 2) + 4)
    }

    func process(_ x: Float) -> Float {
        let v = line.read(delay)
        let y = v - g * x
        line.write(x + g * y)
        return y
    }
}

/// Feedback comb with one-pole damping in the loop; the read tap may be
/// modulated (Ghostverb).
private final class EBComb {
    private let line: EBDelayLine
    let baseDelay: Double
    private var lp: Float = 0

    init(delaySamples: Int, modHeadroom: Int = 0) {
        baseDelay = Double(max(delaySamples, 4))
        line = EBDelayLine(capacity: max(delaySamples, 4) + modHeadroom + 4)
    }

    func process(_ x: Float, readDelay: Double? = nil, feedback: Float, damp: Float) -> Float {
        let out = line.read(readDelay ?? baseDelay)
        lp += (out - lp) * (1 - damp)
        line.write(x + lp * feedback)
        return out
    }
}

/// LFO phase plus tap-tempo bookkeeping.
private final class EBMod {
    var phase: Double = 0
    var lastTap: Float = 0
    var samplesSinceTap: Double = .greatestFiniteMagnitude / 2
    var tapPeriod: Double = 0
}

/// Comb bank + allpass chain + wet-EQ memory for one reverb channel.
private final class EBReverbChannel {
    let combs: [EBComb]
    let allpasses: [EBSchroederAllpass]
    var eqLow = EBOnePole()
    var eqHigh = EBOnePole()

    init(combMs: [Double], apMs: [Double], sampleRate: Double, offsetMs: Double) {
        combs = combMs.map {
            EBComb(delaySamples: Int(($0 + offsetMs) * sampleRate / 1000))
        }
        allpasses = apMs.map {
            EBSchroederAllpass(delaySamples: Int(($0 + offsetMs * 0.3) * sampleRate / 1000))
        }
    }

    func process(_ x: Float, rt60: Double, damp: Float, sampleRate: Double) -> Float {
        var sum: Float = 0
        for comb in combs {
            let seconds = comb.baseDelay / sampleRate
            let g = rt60 > 0.001 ? Float(pow(10, -3 * seconds / rt60)) : 0
            sum += comb.process(x, feedback: min(g, 0.9997), damp: damp)
        }
        var out = sum / Float(combs.count) * 1.6
        for ap in allpasses { out = ap.process(out) }
        return out
    }
}

private final class EBReverbState {
    let channels: [EBReverbChannel]

    init(combMs: [Double], apMs: [Double], sampleRate: Double, channels count: Int = 2) {
        // Right channel offset +0.61 ms decorrelates the stereo tail.
        channels = (0..<count).map {
            EBReverbChannel(combMs: combMs, apMs: apMs, sampleRate: sampleRate,
                            offsetMs: $0 == 1 ? 0.61 : 0)
        }
    }
}

/// Ghostverb: modulated combs + diffuser per channel.
private final class EBGhostChannel {
    let combs: [EBComb]
    let allpass: EBSchroederAllpass

    init(sampleRate: Double, offsetMs: Double) {
        let headroom = Int(0.003 * sampleRate)
        combs = [31.1, 37.3, 41.9, 44.9].map {
            EBComb(delaySamples: Int(($0 + offsetMs) * sampleRate / 1000), modHeadroom: headroom)
        }
        allpass = EBSchroederAllpass(delaySamples: Int(5.9 * sampleRate / 1000))
    }
}

private final class EBGhostState {
    let channels: [EBGhostChannel]
    let mod = EBMod()

    init(sampleRate: Double) {
        channels = [EBGhostChannel(sampleRate: sampleRate, offsetMs: 0),
                    EBGhostChannel(sampleRate: sampleRate, offsetMs: 0.61)]
    }
}

/// Phaser / Univibe: allpass chains per channel + shared LFO.
private final class EBPhaserState {
    var chains: [[EBAllpass1]]
    var lastOut: [Float] = [0, 0]
    let mod = EBMod()

    init(stages: Int) {
        chains = [[EBAllpass1]](
            repeating: [EBAllpass1](repeating: EBAllpass1(), count: stages), count: 2)
    }
}

private final class EBTremoloState {
    let mod = EBMod()
}

/// Delay w/Mod and Ping Pong: delay lines + feedback tone filters + LFO.
private final class EBDelayModState {
    var lines: [EBDelayLine]
    var fbFilters: [EBOnePole]
    let mod = EBMod()

    init(sampleRate: Double, lines count: Int) {
        // 2 s max delay + mod headroom.
        let capacity = Int(sampleRate * 2.1)
        lines = (0..<count).map { _ in EBDelayLine(capacity: capacity) }
        fbFilters = [EBOnePole](repeating: EBOnePole(), count: count)
    }

    func tapSeconds(sampleRate: Double, ratio: Double) -> Double {
        tapPeriodSeconds(sampleRate: sampleRate) * ratio
    }

    private func tapPeriodSeconds(sampleRate: Double) -> Double {
        mod.tapPeriod > 0 ? mod.tapPeriod / sampleRate : 0.0625
    }
}

/// Flanger / Chorus / Vibrato: short modulated lines (30 ms headroom),
/// tilt-EQ memory, and (thru-0) delayed-dry lines.
private final class EBFlangerState {
    var lines: [EBDelayLine]
    var dryLines: [EBDelayLine]
    var tiltFilters: [EBOnePole]
    let mod = EBMod()

    init(sampleRate: Double) {
        let capacity = Int(sampleRate * 0.03)
        lines = (0..<2).map { _ in EBDelayLine(capacity: capacity) }
        dryLines = (0..<2).map { _ in EBDelayLine(capacity: capacity) }
        tiltFilters = [EBOnePole](repeating: EBOnePole(), count: 2)
    }
}

/// Reverse delay: per-channel record/play chunk pair.
private final class EBReverseChannel {
    var rec: [Float] = []
    var play: [Float] = []
    var recIdx = 0
    var playPos: Double = 0
}

private final class EBReverseState {
    let channels = [EBReverseChannel(), EBReverseChannel()]
    let mod = EBMod()
}
