import Foundation

/// CV generator modules — IDs 4 (Sequencer), 5 (LFO), 6 (ADSR),
/// 37 (Rhythm), 39 (Random), 47 (CV Loop), 85 (Tap to CV).
///
/// CV generators run at control rate: one evaluation per render block,
/// with dt = frames / sampleRate. Time-based state (envelopes, loops,
/// tap intervals) is therefore quantized to the block size.
extension PatchRuntime {
    func renderCVGenerators(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 4: renderSequencer(index, node)
        case 5: renderLFO(index, node, frames: ctx.frames)
        case 6: renderADSR(index, node, frames: ctx.frames)
        case 37: renderRhythm(index, node)
        case 39: renderRandom(index, node)
        case 47: renderCVLoop(index, node, frames: ctx.frames)
        case 85: renderTapToCV(index, node, frames: ctx.frames)
        default: return false
        }
        return true
    }

    // MARK: - 4 Sequencer

    /// Extra sequencer state beyond the shared Node fields: the key-input
    /// write cursor.
    private final class SequencerState {
        var writeCursor = 0
        var lastKeyGate: Float = 0
    }

    /// Options: 0 number_of_steps, 1 num_of_tracks, 2 restart_jack,
    /// 3 behavior (loop / one_shot / cv_step), 4 key_input, 5 pages
    /// (pages are a device-UI concern; no runtime effect).
    private func renderSequencer(_ index: Int, _ node: Node) {
        let steps = max(node.optionInt(0), 1)
        let tracks = max(node.optionInt(1), 1)
        let behavior = node.optionText(3)
        let gate = cvIn(node: index, block: 32)
        let restart = node.optionText(2) == "on" ? cvIn(node: index, block: 33) : 0

        // Queue start: rising edge rewinds to step 1 and clears one-shot
        // completion. (Assumption: reset applies immediately rather than
        // deferring to the next gate; doc's "queue" wording is ambiguous.)
        if restart >= 0.5, node.lastRestart < 0.5 {
            node.step = 0
            node.finished = false
        }
        node.lastRestart = restart

        if behavior == "cv_step" {
            // Assumption: cv_step reads the gate CV as a step address —
            // 0…1 spans the steps evenly, no edge detection.
            node.step = min(steps - 1, max(0, Int(gate * Float(steps))))
        } else if gate >= 0.5, node.lastGate < 0.5, !node.finished {
            node.step += 1
            if node.step >= steps {
                if behavior == "one_shot" {
                    node.step = steps - 1
                    node.finished = true
                } else {
                    node.step = 0
                }
            }
        }
        node.lastGate = gate

        // Key input: a rising key gate writes the key note CV into a step.
        // Assumption: "increment" writes at an advancing cursor; the other
        // modes write the currently playing step (the device's "selected"
        // step is a UI notion with no runtime counterpart).
        let keyMode = node.optionText(4)
        if keyMode != "off" {
            let state = node.state(SequencerState())
            let keyGate = cvIn(node: index, block: 35)
            if keyGate >= 0.5, state.lastKeyGate < 0.5 {
                let target = keyMode == "increment"
                    ? min(state.writeCursor, steps - 1) : node.step
                if let i = node.paramIndexByPosition[target] {
                    node.params[i] = cvIn(node: index, block: 34)
                }
                state.writeCursor = (state.writeCursor + 1) % steps
            }
            state.lastKeyGate = keyGate
        }

        // Track 1 = step params, CV-modulatable per the catalog doc
        // ("the first track can have each step controlled by CV") — not
        // the matrix's row 0, which is stale in 21 of 77 factory
        // instances. Tracks 2+ have no params; their rows in the
        // saved_data step matrix are the only storage.
        let stepValue = cvIn(node: index, block: node.step)
        for track in 0..<tracks {
            node.cvOut[36 + track] = track == 0
                ? stepValue
                : SequencerSavedData.step(node.savedData, track: track, step: node.step) ?? 0
        }
    }

    // MARK: - 5 LFO

    private final class LFOState {
        var randomValue = Double.random(in: 0...1)
        var tapElapsed: Double = -1  // -1 until the first tap arrives
        var tapPeriod: Double = 0    // 0 until two taps set an interval
        var lastTap: Float = 0
        var lastReset: Float = 0
    }

    /// Options: 0 waveform, 1 swing_control, 2 output range,
    /// 3 input (cv / tap / linear_cv), 4 phase_input, 5 phase_reset.
    private func renderLFO(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(LFOState())
        let dt = Double(frames) / sampleRate

        let hz: Double
        switch node.optionText(3) {
        case "tap":
            // Tap tempo: rising edges on the tap control set the period.
            let tap = cvIn(node: index, block: 1)
            if tap >= 0.5, state.lastTap < 0.5 {
                if state.tapElapsed > 0 { state.tapPeriod = state.tapElapsed }
                state.tapElapsed = 0
            } else if state.tapElapsed >= 0 {
                state.tapElapsed += dt
            }
            state.lastTap = tap
            // Assumption: the LFO holds still until two taps set a period.
            hz = state.tapPeriod > 0 ? 1 / state.tapPeriod : 0
        case "linear_cv":
            // Assumption: linear cv maps 0…1 → 0…25 Hz.
            hz = Double(max(cvIn(node: index, block: 0), 0)) * 25
        default:
            // cv mode: dial 0…1 sweeps ~0.05…25 Hz exponentially.
            // (Assumption; device curve not yet measured.)
            let control = cvIn(node: index, block: 0)
            hz = 0.05 * pow(25 / 0.05, Double(control))
        }

        // Phase reset: rising edge rewinds to the native starting point.
        if node.optionText(5) == "on" {
            let reset = cvIn(node: index, block: 5)
            if reset >= 0.5, state.lastReset < 0.5 { node.phase = 0 }
            state.lastReset = reset
        }

        let before = node.phase
        node.phase += hz * dt
        node.phase -= node.phase.rounded(.down)
        // Random waveform: a new value each cycle, held between wraps.
        if node.phase < before { state.randomValue = Double.random(in: 0...1) }

        // Phase input: offset in degrees; cv 0…1 = 0…360°.
        var phase = node.phase
        if node.optionText(4) == "on" {
            phase += Double(cvIn(node: index, block: 4))
            phase -= phase.rounded(.down)
        }

        // Swing: skews the half-cycle boundary. Assumption: cv -1…1 moves
        // the midpoint 0.05…0.95, 0 = symmetric (knob shows -100…100).
        if node.optionText(1) == "on" {
            let swing = Double(cvIn(node: index, block: 2))
            let mid = min(max(0.5 + swing * 0.45, 0.05), 0.95)
            phase = phase < mid
                ? phase / mid * 0.5
                : 0.5 + (phase - mid) / (1 - mid) * 0.5
        }

        let raw: Double
        switch node.optionText(0) {
        case "sine": raw = (sin(phase * 2 * .pi) + 1) / 2
        case "triangle": raw = phase < 0.5 ? phase * 2 : 2 - phase * 2
        case "sawtooth": raw = 1 - phase
        case "ramp": raw = phase
        case "random": raw = state.randomValue
        default: raw = phase < 0.5 ? 1 : 0  // square
        }
        let bipolar = node.optionText(2) == "-1 to 1"
        node.cvOut[3] = Float(bipolar ? raw * 2 - 1 : raw)
    }

    // MARK: - 6 ADSR

    private final class ADSRState {
        enum Stage { case idle, delay, attack, holdAD, decay, sustain, holdSR, release }
        var stage: Stage = .idle
        var value: Double = 0
        var segStart: Double = 0  // output level at entry to current stage
        var t: Double = 0         // time inside current stage
        var gateHeld = false
        var lastGate: Float = 0
        var lastRetrigger: Float = 0
    }

    /// Options: 0 retrigger_input, 1 initial_delay, 2 hold_attack_decay,
    /// 3 str (sustain/release present; default on), 4 immediate_release
    /// (default on), 5 hold_sustain_release, 6 time_scale.
    ///
    /// Segment shapes (assumption — analog-style exponential curves):
    /// attack (1−e^(−4p))/(1−e^(−4)); decay/release
    /// (e^(−5p)−e^(−5))/(1−e^(−5)), both normalized to land exactly on
    /// the segment target at p = 1.
    private func renderADSR(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(ADSRState())
        let dt = Double(frames) / sampleRate
        let hasSustain = node.optionText(3) != "off"
        let immediateRelease = node.optionText(4) != "off"
        let linearTime = node.optionText(6) == "linear"

        // Time knobs: linear = 0…10 s; exponent = 1 ms…10 s (assumption:
        // endpoints not measured against hardware). A block that is
        // neither active nor wired contributes zero time.
        func time(_ block: Int) -> Double {
            guard node.paramIndexByPosition[block] != nil
                || hasWire(node: index, block: block) else { return 0 }
            let v = Double(max(cvIn(node: index, block: block), 0))
            return linearTime ? v * 10 : 0.001 * pow(10_000, v)
        }
        func riseCurve(_ p: Double) -> Double { (1 - exp(-4 * p)) / (1 - exp(-4)) }
        func fallCurve(_ p: Double) -> Double { (exp(-5 * p) - exp(-5)) / (1 - exp(-5)) }
        func enter(_ stage: ADSRState.Stage) {
            state.stage = stage
            state.segStart = state.value
            state.t = 0
        }
        var sustainLevel: Double {
            hasSustain ? Double(min(max(cvIn(node: index, block: 6), 0), 1)) : 0
        }

        // Gate edges. Assumption: gate threshold 0.5, matching the other
        // runtime gates ("an increase in CV triggers the envelope").
        let gateCV = cvIn(node: index, block: 0)
        if gateCV >= 0.5, state.lastGate < 0.5 {
            state.gateHeld = true
            enter(.delay)
        } else if gateCV < 0.5, state.lastGate >= 0.5 {
            state.gateHeld = false
            if hasSustain {
                switch state.stage {
                case .delay:
                    // Assumption: release before the attack starts cancels.
                    state.stage = .idle
                case .attack, .holdAD, .decay:
                    // Immediate release ON skips ahead; OFF finishes the
                    // envelope as drawn (doc: "travel to the top of the
                    // attack and carry the CV output through").
                    if immediateRelease { enter(.holdSR) }
                case .sustain:
                    enter(.holdSR)
                case .idle, .holdSR, .release:
                    break
                }
            }
            // str off: the envelope always completes A→D→0 on its own.
        }
        state.lastGate = gateCV

        // Retrigger: rising edge relaunches the attack from the current
        // level while the note is held.
        if node.optionText(0) == "on" {
            let rt = cvIn(node: index, block: 1)
            if rt >= 0.5, state.lastRetrigger < 0.5, state.gateHeld {
                enter(.attack)
            }
            state.lastRetrigger = rt
        }

        // Advance the stage machine; zero-length stages cascade through.
        state.t += dt
        var advancing = true
        while advancing {
            advancing = false
            switch state.stage {
            case .idle:
                break
            case .delay:
                if state.t >= time(2) {
                    enter(.attack)
                    advancing = true
                }
            case .attack:
                let T = time(3)
                let p = T > 0 ? min(state.t / T, 1) : 1
                state.value = state.segStart + (1 - state.segStart) * riseCurve(p)
                if p >= 1 {
                    enter(.holdAD)
                    advancing = true
                }
            case .holdAD:
                state.value = 1
                if state.t >= time(4) {
                    enter(.decay)
                    advancing = true
                }
            case .decay:
                let target = hasSustain ? sustainLevel : 0
                let T = time(5)
                let p = T > 0 ? min(state.t / T, 1) : 1
                state.value = target + (state.segStart - target) * fallCurve(p)
                if p >= 1 {
                    if !hasSustain {
                        state.value = 0
                        state.stage = .idle
                    } else if state.gateHeld {
                        enter(.sustain)
                    } else {
                        enter(.holdSR)
                        advancing = true
                    }
                }
            case .sustain:
                state.value = sustainLevel
            case .holdSR:
                if state.t >= time(7) {
                    enter(.release)
                    advancing = true
                }
            case .release:
                let T = time(8)
                let p = T > 0 ? min(state.t / T, 1) : 1
                state.value = state.segStart * fallCurve(p)
                if p >= 1 {
                    state.value = 0
                    state.stage = .idle
                }
            }
        }

        node.cvOut[9] = Float(state.value)
    }

    // MARK: - 37 Rhythm

    private final class RhythmState {
        var recording = false
        var playing = false
        var buffer: [Float] = []
        var playIndex = 0
        var done: Float = 0
        var lastRec: Float = 0
        var lastPlay: Float = 0
    }

    /// Records the rhythm-in gate one sample per control block while
    /// recording, replays it once per play trigger.
    ///
    /// Assumption: recording runs while rec start-stop is held high (the
    /// doc's start/stop triggers collapse to that for a held gate), and
    /// "play done" latches high until the next record or play.
    private func renderRhythm(_ index: Int, _ node: Node) {
        let state = node.state(RhythmState())
        let rec = cvIn(node: index, block: 0)
        let play = cvIn(node: index, block: 2)

        if rec >= 0.5, state.lastRec < 0.5 {
            state.recording = true
            state.playing = false
            state.buffer.removeAll()
            state.done = 0
        } else if rec < 0.5, state.lastRec >= 0.5 {
            state.recording = false
        }
        state.lastRec = rec

        if state.recording, state.buffer.count < 1 << 20 {
            state.buffer.append(cvIn(node: index, block: 1) >= 0.5 ? 1 : 0)
        }

        if play >= 0.5, state.lastPlay < 0.5, !state.recording, !state.buffer.isEmpty {
            state.playing = true
            state.playIndex = 0
            state.done = 0
        }
        state.lastPlay = play

        var out: Float = 0
        if state.playing {
            out = state.buffer[state.playIndex]
            state.playIndex += 1
            if state.playIndex >= state.buffer.count {
                state.playing = false
                state.done = 1
            }
        }
        node.cvOut[4] = out
        if node.optionText(0) == "on" { node.cvOut[3] = state.done }
    }

    // MARK: - 39 Random

    private final class RandomState {
        var value = Float.random(in: 0...1)
        var lastTrigger: Float = 0
    }

    /// Options: 0 output range, 1 new_val_on_trig. Free-running mode
    /// draws a new value every control block.
    private func renderRandom(_ index: Int, _ node: Node) {
        let state = node.state(RandomState())
        if node.optionText(1) == "on" {
            let trigger = cvIn(node: index, block: 0)
            if trigger >= 0.5, state.lastTrigger < 0.5 {
                state.value = .random(in: 0...1)
            }
            state.lastTrigger = trigger
        } else {
            state.value = .random(in: 0...1)
        }
        let bipolar = node.optionText(0) == "-1 to 1"
        node.cvOut[1] = bipolar ? state.value * 2 - 1 : state.value
    }

    // MARK: - 47 CV Loop

    private final class CVLoopState {
        var buffer: [Float] = []
        var blockDur: Double = 0
        var recording = false
        var playing = false
        var position: Double = 0  // seconds into the recorded loop
        var lastOut: Float = 0
        var lastRecord: Float = 0
        var lastPlay: Float = 0
        var lastRestart: Float = 0
    }

    /// Options: 0 max_rec_time (seconds), 1 length_edit (start/stop
    /// position blocks). Record rise starts recording, record fall drops
    /// straight into playback (per the catalog doc); play rise/fall
    /// starts/stops playback; restart rise rewinds to the start position.
    ///
    /// Assumptions: playback speed knob 0…1 → 0…200 % (0.5 = unity, no
    /// reverse); start/stop position knobs 0…1 → 0…max-rec-time seconds;
    /// the output monitors the input while recording and reads 0 while
    /// stopped.
    private func renderCVLoop(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(CVLoopState())
        let dt = Double(frames) / sampleRate
        let maxSeconds = Double(max(node.optionInt(0), 1))
        let input = cvIn(node: index, block: 0)
        let record = cvIn(node: index, block: 1)
        let play = cvIn(node: index, block: 2)
        let restart = cvIn(node: index, block: 6)

        var start = 0.0
        var trimEnd = 0.0
        if node.optionText(1) == "on" {
            start = Double(max(cvIn(node: index, block: 4), 0)) * maxSeconds
            trimEnd = Double(max(cvIn(node: index, block: 5), 0)) * maxSeconds
        }

        if record >= 0.5, state.lastRecord < 0.5 {
            state.recording = true
            state.playing = false
            state.buffer.removeAll()
            state.blockDur = dt
        } else if record < 0.5, state.lastRecord >= 0.5, state.recording {
            state.recording = false
            state.playing = true
            state.position = start
        }
        state.lastRecord = record

        if play >= 0.5, state.lastPlay < 0.5, !state.recording {
            state.playing = true
            state.position = start
        } else if play < 0.5, state.lastPlay >= 0.5, !state.recording {
            state.playing = false
        }
        state.lastPlay = play

        if restart >= 0.5, state.lastRestart < 0.5 { state.position = start }
        state.lastRestart = restart

        if state.recording {
            if Double(state.buffer.count) * dt < maxSeconds {
                state.buffer.append(input)
            }
            state.lastOut = input
            node.cvOut[7] = input
            return
        }

        guard state.playing, !state.buffer.isEmpty, state.blockDur > 0 else {
            node.cvOut[7] = 0
            return
        }
        let length = Double(state.buffer.count) * state.blockDur
        let loopStart = min(start, length - state.blockDur)
        let loopEnd = max(length - trimEnd, loopStart + state.blockDur)
        let speed = Double(max(cvIn(node: index, block: 3), 0)) * 2
        if state.position >= loopEnd || state.position < loopStart {
            state.position = loopStart
        }
        let sample = min(state.buffer.count - 1,
                         max(0, Int(state.position / state.blockDur)))
        state.lastOut = state.buffer[sample]
        node.cvOut[7] = state.lastOut
        state.position += speed * dt
        if state.position >= loopEnd { state.position = loopStart }
    }

    // MARK: - 85 Tap to CV

    private final class TapToCVState {
        var elapsed: Double = -1  // -1 until the first tap arrives
        var interval: Double = 0
        var output: Float = 0
        var lastTap: Float = 0
    }

    /// Rising edges on the tap input measure an interval; the output is
    /// the interval mapped into the min…max time window.
    ///
    /// Assumptions: min/max time knobs 0…1 → 0…10 s; without the range
    /// option the window is 0…2 s; "exponential" maps the interval
    /// logarithmically across the window (min floored at 1 ms). The
    /// output holds its last value between taps. (Corpus note: on-file
    /// Tap-to-CV param count is active param blocks + 1; the trailing
    /// extra word is a decoder artifact with no runtime meaning.)
    private func renderTapToCV(_ index: Int, _ node: Node, frames: Int) {
        let state = node.state(TapToCVState())
        let dt = Double(frames) / sampleRate
        let tap = cvIn(node: index, block: 0)
        if tap >= 0.5, state.lastTap < 0.5 {
            if state.elapsed > 0 { state.interval = state.elapsed }
            state.elapsed = 0
        } else if state.elapsed >= 0 {
            state.elapsed += dt
        }
        state.lastTap = tap

        if state.interval > 0 {
            var minTime = 0.0
            var maxTime = 2.0
            if node.optionText(0) == "on" {
                minTime = Double(max(cvIn(node: index, block: 1), 0)) * 10
                maxTime = Double(max(cvIn(node: index, block: 2), 0)) * 10
                if maxTime <= minTime { maxTime = minTime + 0.001 }
            }
            let clamped = min(max(state.interval, minTime), maxTime)
            let fraction: Double
            if node.optionText(1) == "exponential" {
                let floor = max(minTime, 0.001)
                let span = log(maxTime / floor)
                fraction = span > 0 ? log(max(clamped, floor) / floor) / span : 0
            } else {
                fraction = (clamped - minTime) / (maxTime - minTime)
            }
            state.output = Float(min(max(fraction, 0), 1))
        }
        node.cvOut[3] = state.output
    }
}
