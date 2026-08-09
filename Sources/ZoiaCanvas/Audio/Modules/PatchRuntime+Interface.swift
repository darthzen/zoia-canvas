import Foundation

// MARK: - Per-node state (interface group)

/// Pushbutton / stompswitch / UI button state. `pressed` belongs to the
/// physical control surface: the canvas UI will set it when the user
/// touches the module. Until that UI exists, a CV wired into the button's
/// block acts as the finger (≥ 0.5 = pressed) — that is also how the
/// tests drive these modules.
final class ButtonState {
    var pressed = false
    var latch = false
    var lastPress: Float = 0
    /// UI Button: last displayed colour/brightness value, for a future UI.
    var display: Float = 0
}

/// Keyboard: which key (0-based) the user is holding. Set by the future
/// canvas UI; tests set it directly.
final class KeyboardState {
    var pressedKey = -1
    var wasDown = false
    var lastKey = -1
}

/// Midi Notes In voice allocator.
final class MidiNotesInState {
    struct Voice {
        var note = -1
        var velocity = 0
        var gate = false
        var justAssigned = false
        /// Filled by the greedy option (doubling a sounding note); such
        /// voices are stolen first when a genuinely new note needs a slot.
        var isGreedy = false
    }
    struct Held {
        var note: Int
        var velocity: Int
        var order: Int
    }
    var voices: [Voice] = []
    var held: [Held] = []
    var counter = 0
    var roundRobin = 0
}

/// Latched value for MIDI CC In / Pressure / Pitch Bend inputs.
final class MidiValueState { var value: Float = 0 }

/// Midi CC Out: last transmitted 0–127 value, to send only on change.
final class MidiCCOutState { var lastSent = -1 }

/// Midi Clock In tempo tracker (24 ppqn).
final class MidiClockInState {
    var tickPeriod: Double = 0        // samples between clock ticks
    var samplesSinceTick: Double = 0
    var running = false
    var quarterPhase: Double = 0
    var resetPulse = false
}

/// Midi Clock Out generator.
final class MidiClockOutState {
    var quarterHz: Double = 0
    var samplesSinceTap: Double = 0
    var lastTap: Float = 0
    var tickPhase: Double = 0
    var lastSent: Float = 0
    var lastReset: Float = 0
    var lastSendPos: Float = 0
}

/// External control values that no hardware backs in this app (CPort
/// expression/CV, Euroburo CV jacks). The future IO layer reads/writes
/// these; until then they are stubs the tests can poke.
final class ExternalCVState {
    /// CPort Exp/CV In: pedal travel / sensed voltage as a 0…1 fraction.
    var value: Float = 0
    /// CPort CV Out / Euro CV Out: the would-be jack voltage, in volts.
    var volts: Float = 0
}

/// Euro CV In: jack voltage plus the schmitt-trigger clock-filter state.
final class EuroCVInState {
    var volts: Float = 0
    var schmitt: Float = 0
}

/// Device Control: tracked would-be device state (bypass / stomp aux /
/// performance). Stub — there is no app-level behaviour to control yet.
final class DeviceControlState { var engaged = false }

// MARK: - Interface modules

/// Interface modules: audio/CV/MIDI to and from the outside world.
/// Owned by the interface group — IDs 1, 2, 15, 16, 20, 21, 35, 44,
/// 54–56, 60–62, 81, 82, 84, 86–101, 103.
extension PatchRuntime {
    func renderInterface(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 1: renderAudioInput(node, ctx)
        case 2: renderAudioOutput(index, node, &ctx)
        case 15, 97, 98:  // Pushbutton, Euro Pushbutton 1/2
            renderButton(index, node, outBlock: 1, actionOption: 0, normallyOption: 1)
        case 16: renderKeyboard(index, node)
        case 20: renderMidiNotesIn(node, events: ctx.incoming)
        case 21: renderMidiCCIn(node, events: ctx.incoming)
        case 35: renderMidiPressure(node, events: ctx.incoming)
        case 44:  // Stompswitch: single block doubles as press target.
            renderButton(index, node, outBlock: 0, actionOption: 1, normallyOption: 2)
        case 54: renderCportExpCVIn(node)
        case 55: renderCportCVOut(index, node)
        case 56: renderUIButton(index, node)
        case 60: renderMidiNoteOut(index, node)
        case 61: renderMidiCCOut(index, node)
        case 62: renderMidiPCOut(index, node)
        case 81: renderPixel(index, node, frames: ctx.frames)
        case 82: renderMidiClockIn(node, events: ctx.incoming, frames: ctx.frames)
        case 84: renderMidiClockOut(index, node, frames: ctx.frames)
        case 86: renderMidiPitchBend(node, events: ctx.incoming)
        case 87, 99, 100, 101: renderEuroCVOut(index, node)
        case 88, 89, 90, 91: renderEuroCVIn(node)
        case 92: renderEuroHeadphoneAmp(index, node, &ctx)
        case 93: renderEuroAudioInput(node, ctx, right: false)
        case 94: renderEuroAudioInput(node, ctx, right: true)
        case 95: renderEuroAudioOutput(index, node, &ctx, right: false)
        case 96: renderEuroAudioOutput(index, node, &ctx, right: true)
        case 103: renderDeviceControl(index, node)
        default: return false
        }
        return true
    }

    // MARK: Audio I/O (1, 2)

    private func renderAudioInput(_ node: Node, _ ctx: RenderContext) {
        let silence = [Float](repeating: 0, count: ctx.frames)
        switch node.optionText(0) {
        case "left":
            node.audioOut[0] = ctx.inputL.count == ctx.frames ? ctx.inputL : silence
        case "right":
            node.audioOut[1] = ctx.inputR.count == ctx.frames ? ctx.inputR : silence
        default:
            node.audioOut[0] = ctx.inputL.count == ctx.frames ? ctx.inputL : silence
            node.audioOut[1] = ctx.inputR.count == ctx.frames ? ctx.inputR : silence
        }
    }

    private func renderAudioOutput(_ index: Int, _ node: Node, _ ctx: inout RenderContext) {
        // gain_control option adds a gain cv block at position 2. The doc
        // labels the dial "+20dB to -100dB"; assumption: linear in dB, so
        // cv 0…1 → -100…+20 dB (0 dB at cv = 5/6).
        let gain: Float
        if node.optionText(0) == "on" {
            let cv = max(cvIn(node: index, block: 2), 0)
            gain = pow(10, (cv * 120 - 100) / 20)
        } else {
            gain = 1
        }
        let left = audioIn(node: index, block: 0, frames: ctx.frames)
        let right = audioIn(node: index, block: 1, frames: ctx.frames)
        switch node.optionText(1) {
        case "left":
            for i in 0..<ctx.frames { ctx.outputL[i] += left[i] * gain }
        case "right":
            for i in 0..<ctx.frames { ctx.outputR[i] += right[i] * gain }
        default:
            for i in 0..<ctx.frames {
                ctx.outputL[i] += left[i] * gain
                ctx.outputR[i] += right[i] * gain
            }
        }
    }

    // MARK: Buttons (15, 44, 56, 97, 98)

    /// Shared pushbutton/stompswitch behaviour. The press source is the
    /// UI-owned `ButtonState.pressed`, with a CV wired into block 0
    /// standing in until the canvas UI drives buttons directly.
    private func renderButton(_ index: Int, _ node: Node, outBlock: Int,
                              actionOption: Int, normallyOption: Int) {
        let st = node.state(ButtonState())
        let press: Float = st.pressed ? 1 : cvIn(node: index, block: 0)
        let latching = node.optionText(actionOption) == "latching"
        if latching, press >= 0.5, st.lastPress < 0.5 { st.latch.toggle() }
        st.lastPress = press
        let engaged = latching ? st.latch : press >= 0.5
        let normallyOne = node.optionText(normallyOption) == "one"
        node.cvOut[outBlock] = engaged != normallyOne ? 1 : 0
    }

    private func renderUIButton(_ index: Int, _ node: Node) {
        let st = node.state(ButtonState())
        let input = cvIn(node: index, block: 0)
        // The `in` value selects colour/brightness on hardware (per the
        // basic/extended range option); record it for a future UI to draw.
        st.display = input
        if node.optionText(0) == "enabled" {
            // Assumption: with no physical button yet, `pressed` or an
            // `in` at/above 0.5 counts as pushed (doc: outputs 1 when
            // the button is pushed, momentary).
            node.cvOut[1] = (st.pressed || input >= 0.5) ? 1 : 0
        }
    }

    // MARK: Pixel (81)

    private func renderPixel(_ index: Int, _ node: Node, frames: Int) {
        // Pixel has no outputs on the device; cvOut here is display state
        // (brightness) stored for a future UI to read. The editor never
        // starts a cable at an input block, so patches can't observe it.
        if node.optionText(0) == "audio" {
            let buffer = audioIn(node: index, block: 1, frames: frames)
            var peak: Float = 0
            for sample in buffer { peak = max(peak, abs(sample)) }
            node.cvOut[1] = peak
        } else {
            node.cvOut[0] = cvIn(node: index, block: 0)
        }
    }

    // MARK: Keyboard (16)

    private func renderKeyboard(_ index: Int, _ node: Node) {
        let st = node.state(KeyboardState())
        let noteCount = max(node.optionInt(0), 1)
        // Note params occupy positions 0…24, then 28…42 (25–27 belong to
        // the note/gate/trigger outputs).
        var trigger: Float = 0
        if st.pressedKey >= 0, st.pressedKey < noteCount {
            let position = st.pressedKey < 25 ? st.pressedKey : st.pressedKey + 3
            node.cvOut[25] = cvIn(node: index, block: position)
            node.cvOut[26] = 1
            if !st.wasDown || st.lastKey != st.pressedKey { trigger = 1 }
            st.wasDown = true
            st.lastKey = st.pressedKey
        } else {
            // Note out holds its last value after release, like the pedal.
            if node.cvOut[25] == nil { node.cvOut[25] = 0 }
            node.cvOut[26] = 0
            st.wasDown = false
        }
        node.cvOut[27] = trigger
    }

    // MARK: Midi Notes In (20)

    private func renderMidiNotesIn(_ node: Node, events: [MidiEvent]) {
        let st = node.state(MidiNotesInState())
        let channel = node.optionInt(0)
        let voiceCount = min(max(node.optionInt(1), 1), 8)
        if st.voices.count != voiceCount {
            st.voices = Array(repeating: MidiNotesInState.Voice(), count: voiceCount)
        }
        let priority = node.optionText(2)
        let greedy = node.optionText(3) == "yes"
        let velocityOn = node.optionText(4) == "on"
        let lowNote = node.optionInt(5)
        let highNote = node.optionInt(6)
        let triggerOn = node.optionText(7) == "on"

        for v in st.voices.indices { st.voices[v].justAssigned = false }

        for event in events where event.channel == channel {
            switch event.kind {
            case .noteOn(let velocity) where velocity > 0:
                guard event.note >= lowNote, event.note <= highNote else { continue }
                st.held.removeAll { $0.note == event.note }
                st.held.append(.init(note: event.note, velocity: velocity, order: st.counter))
                st.counter += 1
                if priority == "RoundRobin" {
                    // Round robin: each noteOn claims the next voice in the
                    // cycle, stealing whatever it held.
                    let v = st.roundRobin % voiceCount
                    st.roundRobin += 1
                    st.voices[v] = .init(note: event.note, velocity: velocity,
                                         gate: true, justAssigned: true)
                }
            case .noteOff, .noteOn:  // noteOn velocity 0 = noteOff
                st.held.removeAll { $0.note == event.note }
                if priority == "RoundRobin" {
                    for v in st.voices.indices where st.voices[v].note == event.note {
                        st.voices[v].gate = false
                    }
                }
            default:
                break
            }
        }

        if priority != "RoundRobin" {
            // Which held notes sound when more are held than voices exist.
            var sounding = st.held
            if sounding.count > voiceCount {
                switch priority {
                case "oldest": sounding.sort { $0.order < $1.order }
                case "highest": sounding.sort { $0.note > $1.note }
                case "lowest": sounding.sort { $0.note < $1.note }
                default: sounding.sort { $0.order > $1.order }  // newest
                }
                sounding = Array(sounding.prefix(voiceCount))
            }
            let soundingNotes = Set(sounding.map(\.note))
            // Release voices whose note stopped sounding; keep stable ones.
            for v in st.voices.indices
            where st.voices[v].gate && !soundingNotes.contains(st.voices[v].note) {
                st.voices[v].gate = false
            }
            // Assign notes not yet on a voice, oldest first, preferring a
            // voice that last played the same note (no spurious retrigger).
            let placed = Set(st.voices.filter(\.gate).map(\.note))
            let pending = sounding.filter { !placed.contains($0.note) }
                .sorted { $0.order < $1.order }
            for held in pending {
                let slot = st.voices.firstIndex { !$0.gate && $0.note == held.note }
                    ?? st.voices.firstIndex { !$0.gate }
                    ?? st.voices.firstIndex(where: \.isGreedy)
                guard let slot else { break }
                st.voices[slot] = .init(note: held.note, velocity: held.velocity,
                                        gate: true, justAssigned: true)
            }
            // Greedy: idle voices double up on the sounding notes.
            if greedy, !sounding.isEmpty {
                var next = 0
                for v in st.voices.indices where !st.voices[v].gate {
                    let held = sounding[next % sounding.count]
                    next += 1
                    st.voices[v] = .init(note: held.note, velocity: held.velocity,
                                         gate: true,
                                         justAssigned: st.voices[v].note != held.note,
                                         isGreedy: true)
                }
            }
        }

        // Voice v occupies catalog positions 4v … 4v+3.
        for (v, voice) in st.voices.enumerated() {
            let base = v * 4
            if voice.note >= 0 {
                node.cvOut[base] = Float(voice.note) / 127
                if velocityOn { node.cvOut[base + 2] = Float(voice.velocity) / 127 }
            } else {
                if node.cvOut[base] == nil { node.cvOut[base] = 0 }
                if velocityOn, node.cvOut[base + 2] == nil { node.cvOut[base + 2] = 0 }
            }
            node.cvOut[base + 1] = voice.gate ? 1 : 0
            if triggerOn { node.cvOut[base + 3] = voice.justAssigned ? 1 : 0 }
        }
    }

    // MARK: Midi Note Out (60)

    private func renderMidiNoteOut(_ index: Int, _ node: Node) {
        let channel = node.optionInt(0)
        let gate = cvIn(node: index, block: 1)
        let note = min(max(Int((cvIn(node: index, block: 0) * 127).rounded()), 0), 127)
        func velocity() -> Int {
            node.optionText(1) == "on"
                ? max(Int((cvIn(node: index, block: 2) * 127).rounded()), 1)
                : 100
        }
        if gate >= 0.5, node.lastGate < 0.5 {
            if node.activeNote >= 0 { midi?.noteOff(channel: channel, note: node.activeNote) }
            midi?.noteOn(channel: channel, note: note, velocity: velocity())
            node.activeNote = note
        } else if gate >= 0.5, node.activeNote >= 0, note != node.activeNote {
            // Note cv moved while the gate is high. Assumption: the device
            // retriggers (off then on) rather than sliding.
            midi?.noteOff(channel: channel, note: node.activeNote)
            midi?.noteOn(channel: channel, note: note, velocity: velocity())
            node.activeNote = note
        } else if gate < 0.5, node.lastGate >= 0.5, node.activeNote >= 0 {
            midi?.noteOff(channel: channel, note: node.activeNote)
            node.activeNote = -1
        }
        node.lastGate = gate
    }

    // MARK: Midi CC / Pressure / Pitch Bend In (21, 35, 86)

    private func renderMidiCCIn(_ node: Node, events: [MidiEvent]) {
        let st = node.state(MidiValueState())
        let channel = node.optionInt(0)
        let controller = node.optionInt(1)
        for event in events where event.channel == channel {
            if case .controlChange(let c, let value) = event.kind, c == controller {
                st.value = Float(value) / 127
            }
        }
        node.cvOut[0] = node.optionText(2) == "-1 to 1" ? st.value * 2 - 1 : st.value
    }

    private func renderMidiPressure(_ node: Node, events: [MidiEvent]) {
        let st = node.state(MidiValueState())
        let channel = node.optionInt(0)
        for event in events where event.channel == channel {
            if case .channelPressure(let pressure) = event.kind {
                st.value = Float(pressure) / 127
            }
        }
        node.cvOut[0] = st.value
    }

    private func renderMidiPitchBend(_ node: Node, events: [MidiEvent]) {
        let st = node.state(MidiValueState())
        let channel = node.optionInt(0)
        for event in events where event.channel == channel {
            if case .pitchBend(let value) = event.kind {
                // Assumption: bipolar output, 8192 (centre) → 0.
                st.value = Float(value - 8192) / 8192
            }
        }
        node.cvOut[0] = st.value
    }

    // MARK: Midi CC / PC Out (61, 62)

    private func renderMidiCCOut(_ index: Int, _ node: Node) {
        let st = node.state(MidiCCOutState())
        let value = min(max(Int((cvIn(node: index, block: 0) * 127).rounded()), 0), 127)
        if value != st.lastSent {
            midi?.controlChange(channel: node.optionInt(0),
                                controller: node.optionInt(1), value: value)
            st.lastSent = value
        }
    }

    private func renderMidiPCOut(_ index: Int, _ node: Node) {
        let trigger = cvIn(node: index, block: 1)
        if trigger >= 0.5, node.lastGate < 0.5 {
            let program = min(max(Int((cvIn(node: index, block: 0) * 127).rounded()), 0), 127)
            midi?.programChange(channel: node.optionInt(0), program: program)
        }
        node.lastGate = trigger
    }

    // MARK: Midi Clock In (82)

    private func renderMidiClockIn(_ node: Node, events: [MidiEvent], frames: Int) {
        let st = node.state(MidiClockInState())
        for event in events {
            switch event.kind {
            case .clockTick:
                if st.samplesSinceTick > 0 { st.tickPeriod = st.samplesSinceTick }
                st.samplesSinceTick = 0
                st.running = true
            case .songPosition(let sixteenths) where sixteenths == 0:
                st.resetPulse = true
            default:
                break
            }
        }
        st.samplesSinceTick += Double(frames)
        // Doc: run out reflects clock presence, not transport. Assumption:
        // the clock counts as lost after 8 missed ticks (min 1 s).
        if st.tickPeriod > 0, st.samplesSinceTick > max(st.tickPeriod * 8, sampleRate) {
            st.running = false
        }
        let modifier = Self.beatMultiplier(node.optionText(3))
        if st.running, st.tickPeriod > 0 {
            // 24 ppqn: a quarter note spans 24 tick periods.
            let quarterSamples = st.tickPeriod * 24 / modifier
            st.quarterPhase += Double(frames) / quarterSamples
            st.quarterPhase -= st.quarterPhase.rounded(.down)
        }
        node.cvOut[0] = st.running ? (st.quarterPhase < 0.5 ? 1 : 0) : 0
        // Clock out: ramp resetting on each tick. Assumption: the doc's
        // "log sawtooth" is approximated by a linear 1→0 decay per tick.
        node.cvOut[1] = st.tickPeriod > 0
            ? Float(max(0, 1 - st.samplesSinceTick / st.tickPeriod)) : 0
        node.cvOut[2] = st.resetPulse ? 1 : 0
        st.resetPulse = false
        node.cvOut[3] = st.running ? 1 : 0
    }

    private static func beatMultiplier(_ text: String) -> Double {
        if text.hasPrefix("1/"), let divisor = Double(text.dropFirst(2)), divisor > 0 {
            return 1 / divisor
        }
        return Double(text) ?? 1
    }

    // MARK: Midi Clock Out (84)

    private func renderMidiClockOut(_ index: Int, _ node: Node, frames: Int) {
        let st = node.state(MidiClockOutState())
        if node.optionText(0) == "cv_control" {
            // Assumption: dial 0…1 sweeps 30…480 BPM exponentially
            // (cv 0.5 = 120 BPM); device curve not yet measured.
            let cv = Double(max(cvIn(node: index, block: 0), 0))
            st.quarterHz = 30 * pow(16, cv) / 60
        } else {
            let tap = cvIn(node: index, block: 0)
            if tap >= 0.5, st.lastTap < 0.5 {
                if st.samplesSinceTap > 0, st.samplesSinceTap < sampleRate * 4 {
                    st.quarterHz = sampleRate / st.samplesSinceTap
                }
                st.samplesSinceTap = 0
            }
            st.lastTap = tap
            st.samplesSinceTap += Double(frames)
        }
        if node.optionText(1) == "enabled" {
            // "sent": rising cv → continue, falling → stop (clock keeps
            // ticking either way, per the doc).
            let sent = cvIn(node: index, block: 1)
            if sent >= 0.5, st.lastSent < 0.5 { midi?.clockContinue() }
            if sent < 0.5, st.lastSent >= 0.5 { midi?.clockStop() }
            st.lastSent = sent
        }
        if node.optionText(2) == "enabled" {
            let reset = cvIn(node: index, block: 2)
            if reset >= 0.5, st.lastReset < 0.5 {
                // Assumption: stop / SPP 0 / start sent back-to-back rather
                // than spread over three consecutive clock pulses.
                midi?.clockStop()
                midi?.songPosition(sixteenths: 0)
                midi?.clockStart()
            }
            st.lastReset = reset
        }
        if node.optionText(3) == "enabled" {
            let sendPos = cvIn(node: index, block: 3)
            if sendPos >= 0.5, st.lastSendPos < 0.5 {
                // Assumption: song position cv 0…1 spans the full 14-bit
                // MIDI-beat range.
                let position = min(max(Int((cvIn(node: index, block: 4) * 16383).rounded()),
                                       0), 16383)
                midi?.clockStop()
                midi?.songPosition(sixteenths: position)
            }
            st.lastSendPos = sendPos
        }
        guard st.quarterHz > 0 else { return }
        st.tickPhase += st.quarterHz * 24 * Double(frames) / sampleRate
        while st.tickPhase >= 1 {
            st.tickPhase -= 1
            midi?.clockTick()
        }
    }

    // MARK: CPort (54, 55) — stubs, no hardware

    private func renderCportExpCVIn(_ node: Node) {
        // Stub: no CPort hardware; a future IO layer sets state.value
        // (0…1 pedal travel / sensed voltage fraction).
        let st = node.state(ExternalCVState())
        node.cvOut[0] = node.optionText(0) == "-1 to 1" ? st.value * 2 - 1 : st.value
    }

    private func renderCportCVOut(_ index: Int, _ node: Node) {
        // Stub: interprets the input per the range option and stores the
        // would-be jack voltage (0–5 V) for a future IO layer.
        let st = node.state(ExternalCVState())
        let value = cvIn(node: index, block: 0)
        let fraction = node.optionText(0) == "-1 to 1" ? (value + 1) / 2 : max(value, 0)
        st.volts = fraction * 5
    }

    // MARK: Euro CV (87–91, 99–101) — stubs, no hardware

    private static func euroRange(_ text: String) -> (lo: Float, hi: Float) {
        switch text {
        case "0 to 5V": return (0, 5)
        case "-5 to 5V": return (-5, 5)
        default: return (0, 10)
        }
    }

    private func renderEuroCVIn(_ node: Node) {
        // Stub: no Euroburo jacks; a future IO layer sets state.volts.
        let st = node.state(EuroCVInState())
        var volts = st.volts
        // Transpose C: doc says +0.25 — read as volts (3 semitones at
        // 1 V/oct). Assumption.
        if node.optionText(3) == "C" { volts += 0.25 }
        let range = Self.euroRange(node.optionText(1))
        var fraction = (volts - range.lo) / (range.hi - range.lo)
        fraction = min(max(fraction, 0), 1)
        let thresholds: [String: (low: Float, high: Float)] =
            ["2,8": (0.2, 0.8), "1,4": (0.1, 0.4), "5,5": (0.5, 0.5)]
        if let t = thresholds[node.optionText(2)] {
            // Clock filter: schmitt trigger over the input range.
            if fraction < t.low { st.schmitt = 0 }
            if fraction >= t.high { st.schmitt = 1 }
            fraction = st.schmitt
        }
        node.cvOut[0] = node.optionText(0) == "-1 to 1" ? fraction * 2 - 1 : fraction
    }

    private func renderEuroCVOut(_ index: Int, _ node: Node) {
        // Stub: computes and stores the would-be jack voltage for a
        // future IO layer; no hardware to drive.
        let st = node.state(ExternalCVState())
        let value = cvIn(node: index, block: 0)
        let fraction = node.optionText(1) == "-1 to 1" ? (value + 1) / 2 : max(value, 0)
        let range = Self.euroRange(node.optionText(0))
        var volts = range.lo + fraction * (range.hi - range.lo)
        if node.optionText(2) == "C" { volts -= 0.25 }  // doc: -0.25 V
        st.volts = volts
    }

    // MARK: Euro audio (92–96)

    private func renderEuroAudioInput(_ node: Node, _ ctx: RenderContext, right: Bool) {
        // Mono alias of the main capture channels: input 1 = left,
        // input 2 = right.
        let source = right ? ctx.inputR : ctx.inputL
        let pad: Float
        switch node.optionText(0) {
        case "6dB": pad = pow(10, -6.0 / 20)
        case "12dB": pad = pow(10, -12.0 / 20)
        default: pad = 1
        }
        let buffer = source.count == ctx.frames
            ? source : [Float](repeating: 0, count: ctx.frames)
        node.audioOut[0] = pad == 1 ? buffer : buffer.map { $0 * pad }
    }

    private func renderEuroAudioOutput(_ index: Int, _ node: Node,
                                       _ ctx: inout RenderContext, right: Bool) {
        // Mono alias of the main mix channels: output 1 = left,
        // output 2 = right.
        let input = audioIn(node: index, block: 0, frames: ctx.frames)
        if right {
            for i in 0..<ctx.frames { ctx.outputR[i] += input[i] }
        } else {
            for i in 0..<ctx.frames { ctx.outputL[i] += input[i] }
        }
    }

    private func renderEuroHeadphoneAmp(_ index: Int, _ node: Node,
                                        _ ctx: inout RenderContext) {
        // Assumption: modelled as a level control on the main mix — the
        // hardware feeds a separate headphone jack this app doesn't have.
        // Applies to whatever was mixed before this node in list order.
        let level = max(cvIn(node: index, block: 0), 0)
        for i in 0..<ctx.frames {
            ctx.outputL[i] *= level
            ctx.outputR[i] *= level
        }
    }

    // MARK: Device Control (103) — stub

    private func renderDeviceControl(_ index: Int, _ node: Node) {
        // Stub: consumes the CV and tracks the would-be device state;
        // there is no app-level bypass/perform/stomp-aux to control yet.
        let st = node.state(DeviceControlState())
        let block: Int
        switch node.optionText(0) {
        case "stomp aux": block = 1
        case "perform": block = 2
        default: block = 0  // bypass
        }
        st.engaged = cvIn(node: index, block: block) >= 0.5
    }
}
