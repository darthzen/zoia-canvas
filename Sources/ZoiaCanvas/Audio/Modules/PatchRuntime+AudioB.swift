import Foundation

/// Audio routing, delay and sampling modules — IDs 13 (Delay Line),
/// 26 (Buffer Delay), 30 (Looper), 33 (Audio In Switch),
/// 34 (Audio Out Switch), 53 (Stereo Spread), 57 (Audio Panner),
/// 59 (Pitch Shifter), 64 (Audio Balance), 76 (Audio Mixer),
/// 78 (Diffuser), 83 (Granular), 102 (Sampler).
extension PatchRuntime {
    func renderAudioB(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 13: renderDelayLine(index, node, frames: ctx.frames)
        case 26: renderBufferDelay(index, node, frames: ctx.frames)
        case 30: renderLooper(index, node, frames: ctx.frames)
        case 33: renderAudioInSwitch(index, node, frames: ctx.frames)
        case 34: renderAudioOutSwitch(index, node, frames: ctx.frames)
        case 53: renderStereoSpread(index, node, frames: ctx.frames)
        case 57: renderAudioPanner(index, node, frames: ctx.frames)
        case 59: renderPitchShifter(index, node, frames: ctx.frames)
        case 64: renderAudioBalance(index, node, frames: ctx.frames)
        case 76: renderAudioMixer(index, node, frames: ctx.frames)
        case 78: renderDiffuser(index, node, frames: ctx.frames)
        case 83: renderGranular(index, node, frames: ctx.frames)
        case 102: renderSampler(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    // MARK: - 13 Delay Line

    private func renderDelayLine(_ index: Int, _ node: Node, frames: Int) {
        let maxT = abSeconds(node.optionText(0))
        let maxSamples = maxT * sampleRate
        let st = node.state(ABDelayLineState(capacity: Int(maxSamples) + 4))
        let tapMode = node.optionText(1) == "yes"
        let interpolate = node.optionText(2) == "on"

        var target: Double
        if tapMode {
            // Block-granular tap detection. Assumption: tapped time is the
            // interval between the last two rising edges on tap tempo in.
            let tap = cvIn(node: index, block: 3)
            if tap >= 0.5, st.lastTap < 0.5 {
                if st.samplesSinceTap > 0 { st.tapInterval = st.samplesSinceTap }
                st.samplesSinceTap = 0
            }
            st.lastTap = tap
            st.samplesSinceTap += Double(frames)
            // Assumption: modulation in scales the tapped time as
            // interval × (1 + mod), mod being the CV sum in -1…1.
            let mod = cvIn(node: index, block: 2)
            target = st.tapInterval * (1 + Double(mod))
        } else {
            let cv = max(0, cvIn(node: index, block: 1))
            if node.optionText(3) == "linear" {
                target = Double(cv) * maxSamples
            } else {
                // Exponential dial: geometric through the catalog
                // paramDefaults anchors (0.02 ms / 0.6 / 18.3 / 540 /
                // 16000 ms at 16 s max) — 0.02 ms floor, equal ratios.
                let minT = 0.00002
                target = minT * pow(maxT / minT, Double(cv)) * sampleRate
            }
        }
        target = min(max(target, 0), maxSamples)

        if st.currentDelay < 0 { st.currentDelay = target }
        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            if interpolate {
                // Assumption: ~40 ms slew produces the tape-style sweeps the
                // interpolation option describes.
                st.currentDelay += (target - st.currentDelay) * 0.0005
            } else {
                st.currentDelay = target
            }
            st.ring.push(input[i])
            out[i] = interpolate
                ? st.ring.read(st.currentDelay)
                : st.ring.readNearest(Int(st.currentDelay.rounded()))
        }
        node.audioOut[4] = out
    }

    // MARK: - 26 Buffer Delay

    private func renderBufferDelay(_ index: Int, _ node: Node, frames: Int) {
        let n = node.optionInt(0)
        let input = audioIn(node: index, block: 0, frames: frames)
        guard n > 0 else {
            node.audioOut[1] = input
            return
        }
        let st = node.state(ABBufferDelayState())
        st.queue.append(input)
        if st.queue.count > n {
            node.audioOut[1] = st.queue.removeFirst()
        } else {
            node.audioOut[1] = [Float](repeating: 0, count: frames)
        }
    }

    // MARK: - 30 Looper

    private func renderLooper(_ index: Int, _ node: Node, frames: Int) {
        let capacity = max(Int(abSeconds(node.optionText(0)) * sampleRate), 1)
        let st = node.state(ABLooperState(capacity: capacity))
        let loopMode = node.optionText(2) == "loop"
        let lengthEdit = node.optionText(1) == "on"
        let preSpeed = node.optionText(3) == "pre_speed"
        let hearWhileRec = node.optionText(4) == "yes"
        let hasReverse = node.optionText(5) == "yes"
        let hasOverdub = node.optionText(6) == "yes"
        let hasStopPlay = node.optionText(7) == "yes"

        let speed = abSpeedFactor(cvIn(node: index, block: 3))
        let reverse = hasReverse && cvIn(node: index, block: 7) >= 0.5
        let recorded = Double(st.recorded)
        let start = lengthEdit
            ? Double(min(max(cvIn(node: index, block: 4), 0), 1)) * recorded : 0
        let window = lengthEdit
            ? Double(min(max(cvIn(node: index, block: 5), 0), 1)) * (recorded - start)
            : recorded - start

        // Record button: rising edge advances the state machine.
        // Assumption: in "playback: once" the loop auto-plays when recording
        // ends; in "playback: loop" the cycle is record→overdub→play (per
        // doc) when overdub is enabled, record→play→record otherwise.
        let rec = cvIn(node: index, block: 1)
        if rec >= 0.5, st.lastRecord < 0.5 {
            switch st.mode {
            case .empty:
                st.mode = .recording
                st.recorded = 0
                st.playing = false
            case .recording:
                st.mode = (loopMode && hasOverdub) ? .overdubbing : .playing
                st.playing = true
                st.paused = false
                st.pos = reverse ? Double(st.recorded) : 0
                st.outElapsed = 0
            case .overdubbing:
                st.mode = .playing
            case .playing:
                if loopMode && hasOverdub {
                    st.mode = .overdubbing
                } else {
                    st.mode = .recording
                    st.recorded = 0
                    st.playing = false
                }
            }
        }
        st.lastRecord = rec

        let restart = cvIn(node: index, block: 2)
        if restart >= 0.5, st.lastRestart < 0.5, st.recorded > 0 {
            st.pos = reverse ? start + window : start
            st.outElapsed = 0
            st.playing = true
            st.paused = false
            if st.mode == .empty { st.mode = .playing }
        }
        st.lastRestart = restart

        if hasStopPlay {
            let stop = cvIn(node: index, block: 9)
            if stop >= 0.5, st.lastStop < 0.5 { st.paused.toggle() }
            st.lastStop = stop
        }
        if hasOverdub {
            let reset = cvIn(node: index, block: 8)
            if reset >= 0.5, st.lastReset < 0.5 {
                st.mode = .empty
                st.recorded = 0
                st.playing = false
                st.paused = false
            }
            st.lastReset = reset
        }

        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        // "fixed" plays for the original wall-clock duration; "pre_speed"
        // plays the full content however long that takes.
        let period = preSpeed ? window / max(speed, 0.001) : window

        for i in 0..<frames {
            switch st.mode {
            case .recording:
                if st.recorded < capacity {
                    st.buffer[st.recorded] = input[i]
                    st.recorded += 1
                }
                if hearWhileRec { out[i] = input[i] }
            case .overdubbing, .playing:
                guard st.playing, !st.paused, window >= 1, st.recorded > 0 else { break }
                let p = st.pos
                if p >= start, p < start + window, p < recorded {
                    let i0 = Int(p)
                    let i1 = min(i0 + 1, st.recorded - 1)
                    let frac = Float(p - Double(i0))
                    out[i] = st.buffer[i0] + (st.buffer[i1] - st.buffer[i0]) * frac
                    if st.mode == .overdubbing { st.buffer[i0] += input[i] }
                }
                st.pos += reverse ? -speed : speed
                st.outElapsed += 1
                if st.outElapsed >= period {
                    if loopMode {
                        st.pos = reverse ? start + window : start
                        st.outElapsed = 0
                    } else {
                        st.playing = false
                    }
                }
            case .empty:
                break
            }
        }
        node.audioOut[6] = out
    }

    // MARK: - 33 Audio In Switch

    /// Input positions per catalog block order. Inputs 15/16 repeat
    /// positions 14/15 — that layout comes straight from the catalog and is
    /// preserved as-is (they alias inputs 13/14 at runtime).
    private static let inSwitchPositions = [0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13, 14, 15, 14, 15]

    private func renderAudioInSwitch(_ index: Int, _ node: Node, frames: Int) {
        let n = min(max(node.optionInt(0), 1), Self.inSwitchPositions.count)
        let fades = node.optionText(1) == "on"
        let cv = min(max(cvIn(node: index, block: 16), 0), 1)
        // Single-input case: the select dial reads "off / ch X sel" in the
        // catalog — cv 0 mutes the lone input.
        if n == 1, cv <= 0 {
            node.audioOut[17] = [Float](repeating: 0, count: frames)
            return
        }
        let target = min(Int(cv * Float(n)), n - 1)
        let st = node.state(ABSwitchState())
        if st.current < 0 || st.current >= n { st.current = target }

        var out = audioIn(node: index, block: Self.inSwitchPositions[target], frames: frames)
        if target != st.current {
            let old = audioIn(node: index, block: Self.inSwitchPositions[st.current], frames: frames)
            if fades {
                // Clickless: linear crossfade across one render block.
                for i in 0..<frames {
                    let t = Float(i + 1) / Float(frames)
                    out[i] = old[i] * (1 - t) + out[i] * t
                }
            }
            st.current = target
        }
        node.audioOut[17] = out
    }

    // MARK: - 34 Audio Out Switch

    private func renderAudioOutSwitch(_ index: Int, _ node: Node, frames: Int) {
        let n = min(max(node.optionInt(0), 1), 16)
        let fades = node.optionText(1) == "on"
        let cv = min(max(cvIn(node: index, block: 1), 0), 1)
        // Single-output case: cv 0 reads "off" — route nothing.
        if n == 1, cv <= 0 {
            node.audioOut[2] = [Float](repeating: 0, count: frames)
            return
        }
        let target = min(Int(cv * Float(n)), n - 1)
        let st = node.state(ABSwitchState())
        if st.current < 0 || st.current >= n { st.current = target }

        let input = audioIn(node: index, block: 0, frames: frames)
        let zero = [Float](repeating: 0, count: frames)
        for k in 0..<n {
            if k == target {
                if fades, target != st.current {
                    var faded = input
                    for i in 0..<frames {
                        faded[i] *= Float(i + 1) / Float(frames)
                    }
                    node.audioOut[2 + k] = faded
                } else {
                    node.audioOut[2 + k] = input
                }
            } else if k == st.current, fades, target != st.current {
                var faded = input
                for i in 0..<frames {
                    faded[i] *= 1 - Float(i + 1) / Float(frames)
                }
                node.audioOut[2 + k] = faded
            } else {
                node.audioOut[2 + k] = zero
            }
        }
        st.current = target
    }

    // MARK: - 53 Stereo Spread

    private func renderStereoSpread(_ index: Int, _ node: Node, frames: Int) {
        if node.optionText(0) == "haas" {
            // Haas delay dial: catalog anchors 2…34.98 ms, linear.
            let st = node.state(ABSpreadState(capacity: Int(0.035 * sampleRate) + 4))
            let cv = Double(min(max(cvIn(node: index, block: 3), 0), 1))
            let delay = (2 + cv * 32.98) / 1000 * sampleRate
            let input = audioIn(node: index, block: 0, frames: frames)
            var delayed = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                st.ring.push(input[i])
                delayed[i] = st.ring.read(delay)
            }
            node.audioOut[4] = input
            node.audioOut[5] = delayed
        } else {
            // Mid-side encode. Side gain dial: catalog anchors −40…+20 dB,
            // linear in dB (unity at cv = 2/3).
            let g = Float(pow(10, (Double(cvIn(node: index, block: 2)) * 60 - 40) / 20))
            let in1 = audioIn(node: index, block: 0, frames: frames)
            let in2 = audioIn(node: index, block: 1, frames: frames)
            var mid = [Float](repeating: 0, count: frames)
            var side = mid
            for i in 0..<frames {
                mid[i] = (in1[i] + in2[i]) / 2
                side[i] = (in1[i] - in2[i]) / 2 * g
            }
            node.audioOut[4] = mid
            node.audioOut[5] = side
        }
    }

    // MARK: - 57 Audio Panner

    private func renderAudioPanner(_ index: Int, _ node: Node, frames: Int) {
        let p = min(max(cvIn(node: index, block: 2), 0), 1)
        let gL: Float
        let gR: Float
        switch node.optionText(1) {
        case "linear":
            gL = 1 - p
            gR = p
        case "-4.5dB":
            gL = (Float(cos(Double(p) * .pi / 2)) * (1 - p)).squareRoot()
            gR = (Float(sin(Double(p) * .pi / 2)) * p).squareRoot()
        default:  // equal_pwr
            gL = Float(cos(Double(p) * .pi / 2))
            gR = Float(sin(Double(p) * .pi / 2))
        }
        let in1 = audioIn(node: index, block: 0, frames: frames)
        let in2 = node.optionText(0) == "2in->2out"
            ? audioIn(node: index, block: 1, frames: frames) : in1
        var outL = [Float](repeating: 0, count: frames)
        var outR = outL
        for i in 0..<frames {
            outL[i] = in1[i] * gL
            outR[i] = in2[i] * gR
        }
        node.audioOut[3] = outL
        node.audioOut[4] = outR
    }

    // MARK: - 59 Pitch Shifter

    private func renderPitchShifter(_ index: Int, _ node: Node, frames: Int) {
        // Dual-tap ring-buffer (coarse granular) shifter: two read taps a
        // half-window apart sweep through a ~43 ms window, gated by
        // sin(π·phase) so their squared gains sum to one.
        // Pitch CV: catalog paramDefaults range −60…+60 semitones, linear
        // (unity at 0.5).
        let st = node.state(ABShifterState())
        let semis = Double(cvIn(node: index, block: 1)) * 120 - 60
        let ratio = pow(2, semis / 12)
        let window = 2048.0
        let inc = (ratio - 1) / window
        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            st.ring.push(input[i])
            st.phase -= inc
            st.phase -= st.phase.rounded(.down)  // wrap into [0,1)
            var p2 = st.phase + 0.5
            p2 -= p2.rounded(.down)
            let g1 = Float(sin(.pi * st.phase))
            let g2 = Float(sin(.pi * p2))
            out[i] = st.ring.read(st.phase * window) * g1
                + st.ring.read(p2 * window) * g2
        }
        node.audioOut[2] = out
    }

    // MARK: - 64 Audio Balance

    private func renderAudioBalance(_ index: Int, _ node: Node, frames: Int) {
        let m = min(max(cvIn(node: index, block: 2), 0), 1)
        let in1L = audioIn(node: index, block: 0, frames: frames)
        let in2L = audioIn(node: index, block: 1, frames: frames)
        var outL = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            outL[i] = in1L[i] * (1 - m) + in2L[i] * m
        }
        node.audioOut[3] = outL
        if node.optionText(0) == "stereo" {
            let in1R = audioIn(node: index, block: 4, frames: frames)
            let in2R = audioIn(node: index, block: 5, frames: frames)
            var outR = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                outR[i] = in1R[i] * (1 - m) + in2R[i] * m
            }
            node.audioOut[6] = outR
        }
    }

    // MARK: - 76 Audio Mixer

    private func renderAudioMixer(_ index: Int, _ node: Node, frames: Int) {
        let channels = min(max(node.optionInt(0), 2), 8)
        let stereo = node.optionText(1) == "stereo"
        let panOn = node.optionText(2) == "on"
        var outL = [Float](repeating: 0, count: frames)
        var outR = outL
        for ch in 0..<channels {
            let g = min(max(cvIn(node: index, block: 16 + ch), 0), 1)
            // Gain fader: catalog anchors −100…+20 dB, linear in dB
            // (unity at cv = 5/6); cv 0 snaps to silence.
            let amp = g == 0 ? 0 : Float(pow(10, (Double(g) * 120 - 100) / 20))
            let inL = audioIn(node: index, block: 2 * ch, frames: frames)
            if !stereo {
                for i in 0..<frames { outL[i] += inL[i] * amp }
                continue
            }
            let p = panOn ? min(max(cvIn(node: index, block: 24 + ch), 0), 1) : 0.5
            if hasWire(node: index, block: 2 * ch + 1) {
                // Stereo source: balance law, unity at center.
                let inR = audioIn(node: index, block: 2 * ch + 1, frames: frames)
                let bl = min(1, 2 * (1 - p)) * amp
                let br = min(1, 2 * p) * amp
                for i in 0..<frames {
                    outL[i] += inL[i] * bl
                    outR[i] += inR[i] * br
                }
            } else {
                // Mono source: equal-power pan between the two buses.
                let bl = Float(cos(Double(p) * .pi / 2)) * amp
                let br = Float(sin(Double(p) * .pi / 2)) * amp
                for i in 0..<frames {
                    outL[i] += inL[i] * bl
                    outR[i] += inL[i] * br
                }
            }
        }
        node.audioOut[32] = outL
        if stereo { node.audioOut[33] = outR }
    }

    // MARK: - 78 Diffuser

    private func renderDiffuser(_ index: Int, _ node: Node, frames: Int) {
        // Single modulated Schroeder allpass; ranges from the catalog
        // paramDefaults anchors: size 80…5000 samples (linear), mod width
        // 3…500 samples (linear), mod rate 0…5.9 s.
        // Assumption: mod rate is the modulation period in seconds
        // (0 = static), and the 0 dB top of the gain dial is capped at
        // coefficient 0.97 for stability.
        let st = node.state(ABDiffuserState())
        let g = abFeedbackDial(cvIn(node: index, block: 1))
        let size = 80 + Double(min(max(cvIn(node: index, block: 2), 0), 1)) * 4920
        let width = 3 + Double(min(max(cvIn(node: index, block: 3), 0), 1)) * 497
        let period = Double(min(max(cvIn(node: index, block: 4), 0), 1)) * 5.9
        let phaseInc = period > 0.0001 ? 1 / (period * sampleRate) : 0
        let input = audioIn(node: index, block: 0, frames: frames)
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            st.phase += phaseInc
            st.phase -= st.phase.rounded(.down)
            let delay = max(size + width * sin(2 * .pi * st.phase), 1)
            // v[n-D] read relative to the sample about to be pushed.
            let vd = st.ring.read(delay - 1)
            let v = input[i] + g * vd
            st.ring.push(v)
            out[i] = -g * v + vd
        }
        node.audioOut[5] = out
    }

    // MARK: - 83 Granular

    private func renderGranular(_ index: Int, _ node: Node, frames: Int) {
        // NOTE: this module's block layout carries a preserved zoia_lib bug —
        // every block stays active regardless of the channels option. Blocks
        // are used at their catalog positions as-is.
        let maxGrain = abSeconds(node.optionText(4))
        let capacity = max(Int(maxGrain * 2 * sampleRate), 4)
        let st = node.state(ABGranularState(capacity: capacity))
        let numGrains = min(max(node.optionInt(0), 1), 8)
        let stereo = node.optionText(1) == "stereo"
        let posTap = node.optionText(2) == "tap_tempo"
        let sizeTap = node.optionText(3) == "tap_tempo"

        // Tap-tempo variants measure the interval between rising edges on
        // the same block the CV dial would use (block-granular).
        if sizeTap {
            let cv = cvIn(node: index, block: 2)
            if cv >= 0.5, st.lastSizeTap < 0.5 {
                if st.sizeTapCounter > 0 { st.sizeTapInterval = st.sizeTapCounter / sampleRate }
                st.sizeTapCounter = 0
            }
            st.lastSizeTap = cv
            st.sizeTapCounter += Double(frames)
        }
        if posTap {
            let cv = cvIn(node: index, block: 3)
            if cv >= 0.5, st.lastPosTap < 0.5 {
                if st.posTapCounter > 0 { st.posTapInterval = st.posTapCounter / sampleRate }
                st.posTapCounter = 0
            }
            st.lastPosTap = cv
            st.posTapCounter += Double(frames)
        }

        let sizeSeconds = sizeTap
            ? min(st.sizeTapInterval, maxGrain)
            : Double(min(max(cvIn(node: index, block: 2), 0), 1)) * maxGrain
        let grainLen = max(sizeSeconds, 0.005) * sampleRate
        let posSeconds = posTap
            ? min(st.posTapInterval, maxGrain)
            : Double(min(max(cvIn(node: index, block: 3), 0), 1)) * maxGrain
        let posDelay = min(posSeconds * sampleRate, Double(capacity) - grainLen - 2)
        let density = Double(min(max(cvIn(node: index, block: 4), 0), 1))
        let texture = Double(min(max(cvIn(node: index, block: 5), 0), 1))
        // Speed/pitch: catalog anchors 3.1…3200 %, 32^(2·cv−1).
        let speed = abSpeedFactor(cvIn(node: index, block: 6))
        let frozen = cvIn(node: index, block: 7) >= 0.5
        // Assumption: density sets grain overlap 0.05…4 relative to grain
        // length; grain count stays capped at the num grains option.
        let spawnInterval = grainLen / (0.05 + density * 3.95)
        let taper = max(texture, 0.02)

        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereo ? audioIn(node: index, block: 1, frames: frames) : inL
        var outL = [Float](repeating: 0, count: frames)
        var outR = outL

        for i in 0..<frames {
            if !frozen {
                st.bufL[st.write] = inL[i]
                st.bufR[st.write] = inR[i]
                st.write = (st.write + 1) % capacity
                st.filled = min(st.filled + 1, capacity)
            }
            st.spawnCountdown -= 1
            if st.spawnCountdown <= 0, st.grains.count < numGrains, st.filled > 0 {
                let startPos = Double(st.write) - posDelay - grainLen
                st.grains.append(ABGrain(age: 0, length: grainLen,
                                         readPos: startPos, speed: speed))
                st.spawnCountdown = spawnInterval
            }
            var sumL: Float = 0
            var sumR: Float = 0
            var g = 0
            while g < st.grains.count {
                let env = abTukey(st.grains[g].age / st.grains[g].length, taper: taper)
                sumL += abWrapLerp(st.bufL, st.grains[g].readPos) * env
                sumR += abWrapLerp(st.bufR, st.grains[g].readPos) * env
                st.grains[g].readPos += st.grains[g].speed
                st.grains[g].age += 1
                if st.grains[g].age >= st.grains[g].length {
                    st.grains.remove(at: g)
                } else {
                    g += 1
                }
            }
            outL[i] = sumL
            outR[i] = sumR
        }
        node.audioOut[8] = outL
        node.audioOut[9] = stereo ? outR : outL
    }

    // MARK: - 102 Sampler

    private func renderSampler(_ index: Int, _ node: Node, frames: Int) {
        // Record-buffer only: loading sample files from saved_data is out of
        // scope, so playback material must be recorded through the inputs.
        // Assumption: 32 s record capacity.
        let capacity = Int(32 * sampleRate)
        let st = node.state(ABSamplerState(capacity: capacity))
        let recordMode = node.optionText(0)
        let playbackMode = node.optionText(1)
        let hasDirection = node.optionText(2) == "on"
        let cvOuts = node.optionText(3) == "on"

        if recordMode != "disabled" {
            // Recording runs while the gate is high (begins on the positive
            // change, ends on the negative change).
            let rec = cvIn(node: index, block: 2)
            if rec >= 0.5, st.lastRecord < 0.5 {
                st.recording = true
                st.recHead = 0
                if recordMode == "new sample" { st.recorded = 0 }
            } else if rec < 0.5, st.lastRecord >= 0.5, st.recording {
                st.recording = false
                if recordMode == "new sample" { st.recorded = st.recHead }
            }
            st.lastRecord = rec
        }

        let recorded = Double(st.recorded)
        let start = Double(min(max(cvIn(node: index, block: 6), 0), 1)) * recorded
        let window = Double(min(max(cvIn(node: index, block: 7), 0), 1)) * (recorded - start)
        let end = start + window
        // Speed/pitch: catalog anchors 3.1…3200 %, 32^(2·cv−1).
        let speed = abSpeedFactor(cvIn(node: index, block: 4))
        let reverse = hasDirection && cvIn(node: index, block: 5) >= 0.5

        let play = cvIn(node: index, block: 3)
        if play >= 0.5, st.lastPlay < 0.5, st.recorded > 0 {
            st.playing = true
            st.pos = reverse ? end : start
        } else if play < 0.5, st.lastPlay >= 0.5, playbackMode == "gate" {
            st.playing = false
        }
        st.lastPlay = play

        let stereoIn = hasWire(node: index, block: 1)
        let inL = audioIn(node: index, block: 0, frames: frames)
        let inR = stereoIn ? audioIn(node: index, block: 1, frames: frames) : inL
        var outL = [Float](repeating: 0, count: frames)
        var outR = outL
        var endPulse = false

        for i in 0..<frames {
            if st.recording {
                switch recordMode {
                case "new sample":
                    if st.recHead < capacity {
                        st.bufL[st.recHead] = inL[i]
                        st.bufR[st.recHead] = inR[i]
                        st.recHead += 1
                        st.recorded = st.recHead
                    }
                case "overdub":
                    if st.recorded > 0 {
                        let idx = st.recHead % st.recorded
                        st.bufL[idx] += inL[i]
                        st.bufR[idx] += inR[i]
                        st.recHead += 1
                    }
                case "punch-in":
                    if st.recorded > 0 {
                        let idx = st.recHead % st.recorded
                        st.bufL[idx] = inL[i]
                        st.bufR[idx] = inR[i]
                        st.recHead += 1
                    }
                default:
                    break
                }
            }
            if st.playing, window >= 1 {
                let p = min(max(st.pos, 0), recorded - 1)
                let i0 = Int(p)
                let i1 = min(i0 + 1, st.recorded - 1)
                let frac = Float(p - Double(i0))
                outL[i] = st.bufL[i0] + (st.bufL[i1] - st.bufL[i0]) * frac
                outR[i] = st.bufR[i0] + (st.bufR[i1] - st.bufR[i0]) * frac
                st.pos += reverse ? -speed : speed
                if st.pos >= end || st.pos < start {
                    endPulse = true
                    if playbackMode == "loop" {
                        st.pos = reverse ? end : start
                    } else {
                        st.playing = false
                    }
                }
            }
        }
        node.audioOut[10] = outL
        node.audioOut[11] = outR
        if cvOuts {
            node.cvOut[8] = recorded > 0 ? Float(min(max(st.pos / recorded, 0), 1)) : 0
            node.cvOut[9] = endPulse ? 1 : 0
        }
    }
}

// MARK: - Shared helpers (file-scoped)

/// "1s"/"16s"/"100ms" catalog option text → seconds.
private func abSeconds(_ text: String) -> Double {
    if text.hasSuffix("ms") { return (Double(text.dropLast(2)) ?? 0) / 1000 }
    if text.hasSuffix("s") { return Double(text.dropLast()) ?? 0 }
    return Double(text) ?? 0
}

/// Feedback/gain dial with catalog anchors -inf / −12 / −6 / −2.5 / 0 dB:
/// piecewise-linear in dB above cv 0.25, linear amplitude ramp to zero
/// below (matches the effect-group convention for this anchor set); the
/// 0 dB top is capped at 0.97 to keep feedback structures stable.
private func abFeedbackDial(_ cv: Float) -> Float {
    let x = Double(min(max(cv, 0), 1))
    guard x > 0 else { return 0 }
    let dB: Double
    switch x {
    case ..<0.25: return Float(x / 0.25) * 0.2512  // ramp to 10^(-12/20)
    case ..<0.5: dB = -12 + (x - 0.25) / 0.25 * 6
    case ..<0.75: dB = -6 + (x - 0.5) / 0.25 * 3.5
    default: dB = -2.5 + (x - 0.75) / 0.25 * 2.5
    }
    return min(Float(pow(10, dB / 20)), 0.97)
}

/// Speed/pitch dials (looper, granular, sampler): catalog paramDefaults
/// anchors 3.1 / 17.7 / 100 / 565.7 / 3200 % fit 32^(2·cv−1) exactly —
/// five octaves either way, unity at 0.5.
private func abSpeedFactor(_ cv: Float) -> Double {
    pow(32, Double(min(max(cv, 0), 1)) * 2 - 1)
}

/// Tukey (tapered cosine) grain envelope; taper 0.02 ≈ near-rectangular,
/// taper 1 = full Hann.
private func abTukey(_ x: Double, taper: Double) -> Float {
    guard x >= 0, x <= 1 else { return 0 }
    let half = taper / 2
    if x < half { return Float(0.5 * (1 - cos(.pi * x / half))) }
    if x > 1 - half { return Float(0.5 * (1 - cos(.pi * (1 - x) / half))) }
    return 1
}

/// Linear-interpolated read from a circular buffer at an absolute
/// (possibly negative) sample position.
private func abWrapLerp(_ buffer: [Float], _ pos: Double) -> Float {
    let count = buffer.count
    guard count > 1 else { return 0 }
    var p = pos.truncatingRemainder(dividingBy: Double(count))
    if p < 0 { p += Double(count) }
    let i = Int(p)
    let f = Float(p - Double(i))
    let a = buffer[i]
    let b = buffer[(i + 1) % count]
    return a + (b - a) * f
}

/// Ring buffer addressed by delay behind the most recent push.
private final class ABRing {
    private var data: [Float]
    private var write = 0

    init(_ capacity: Int) {
        data = [Float](repeating: 0, count: max(capacity, 4))
    }

    func push(_ x: Float) {
        data[write] = x
        write = (write + 1) % data.count
    }

    /// Sample `delay` samples behind the last push, linear interpolation.
    func read(_ delay: Double) -> Float {
        let d = min(max(delay, 0), Double(data.count - 2))
        let i = Int(d)
        let frac = Float(d - Double(i))
        let a = data[(write - 1 - i % data.count + 2 * data.count) % data.count]
        let b = data[(write - 2 - i % data.count + 2 * data.count) % data.count]
        return a + (b - a) * frac
    }

    func readNearest(_ delay: Int) -> Float {
        let d = min(max(delay, 0), data.count - 1)
        return data[(write - 1 - d + 2 * data.count) % data.count]
    }
}

// MARK: - Per-node state containers

private final class ABDelayLineState {
    let ring: ABRing
    var currentDelay: Double = -1  // sentinel: initialise to target on first render
    var lastTap: Float = 0
    var tapInterval: Double = 0
    var samplesSinceTap: Double = 0
    init(capacity: Int) { ring = ABRing(capacity) }
}

private final class ABBufferDelayState {
    var queue: [[Float]] = []
}

private final class ABLooperState {
    enum Mode { case empty, recording, overdubbing, playing }
    var buffer: [Float]
    var recorded = 0
    var mode: Mode = .empty
    var playing = false
    var paused = false
    var pos: Double = 0
    var outElapsed: Double = 0
    var lastRecord: Float = 0
    var lastRestart: Float = 0
    var lastStop: Float = 0
    var lastReset: Float = 0
    init(capacity: Int) { buffer = [Float](repeating: 0, count: capacity) }
}

private final class ABSwitchState {
    var current = -1
}

private final class ABSpreadState {
    let ring: ABRing
    init(capacity: Int) { ring = ABRing(capacity) }
}

private final class ABShifterState {
    let ring = ABRing(4096)
    var phase: Double = 0
}

private final class ABDiffuserState {
    let ring = ABRing(5600)
    var phase: Double = 0
}

private struct ABGrain {
    var age: Double
    var length: Double
    var readPos: Double
    var speed: Double
}

private final class ABGranularState {
    var bufL: [Float]
    var bufR: [Float]
    var write = 0
    var filled = 0
    var grains: [ABGrain] = []
    var spawnCountdown: Double = 0
    var lastPosTap: Float = 0
    var lastSizeTap: Float = 0
    var posTapInterval: Double = 0
    var sizeTapInterval: Double = 0
    var posTapCounter: Double = 0
    var sizeTapCounter: Double = 0
    init(capacity: Int) {
        bufL = [Float](repeating: 0, count: capacity)
        bufR = bufL
    }
}

private final class ABSamplerState {
    var bufL: [Float]
    var bufR: [Float]
    var recorded = 0
    var recording = false
    var recHead = 0
    var playing = false
    var pos: Double = 0
    var lastRecord: Float = 0
    var lastPlay: Float = 0
    init(capacity: Int) {
        bufL = [Float](repeating: 0, count: capacity)
        bufR = bufL
    }
}
