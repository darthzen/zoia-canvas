import Foundation

/// CV utility modules — IDs 10 (Sample and Hold), 17 (CV Invert),
/// 18 (Steps), 19 (Slew Limiter), 22 (Multiplier), 28 (Quantizer),
/// 31 (In Switch), 32 (Out Switch), 45 (Value), 46 (CV Delay),
/// 48 (CV Filter), 49 (Clock Divider), 50 (Comparator), 51 (CV Rectify),
/// 52 (Trigger), 77 (CV Flip Flop), 104 (CV Mixer), 105 (Logic Gate).
///
/// All processing here is control-rate: one update per render call, with
/// dt = frames / sampleRate. Gates fire on a rising edge through 0.5.

// MARK: - Per-node state

private final class HoldState {
    var held: Float = 0
}

private final class StepsState {
    var lastIn: Float = 0
    var sinceRise: Double = 0
    var period: Double = 0  // 0 = tempo not yet known
    var stepTimer: Double = 0
    var held: Float = 0
}

private final class SmoothState {
    var y: Float = 0
}

private final class CVDelayState {
    var buffer: [Float] = []
    var writeIndex = 0
}

/// Quantizer scale interval sets. The basic list is per the fw doc
/// (chromatic, major, natural/harmonic/melodic minor). The extended
/// option's additions are an assumption (modes + pentatonics + blues);
/// the device list is not documented in the catalog.
private let quantizerBasicScales: [[Int]] = [
    Array(0...11),               // chromatic
    [0, 2, 4, 5, 7, 9, 11],      // major
    [0, 2, 3, 5, 7, 8, 10],      // natural minor
    [0, 2, 3, 5, 7, 8, 11],      // harmonic minor
    [0, 2, 3, 5, 7, 9, 11],      // melodic minor
]
private let quantizerExtendedScales: [[Int]] = quantizerBasicScales + [
    [0, 2, 3, 5, 7, 9, 10],      // dorian
    [0, 1, 3, 5, 7, 8, 10],      // phrygian
    [0, 2, 4, 6, 7, 9, 11],      // lydian
    [0, 2, 4, 5, 7, 9, 10],      // mixolydian
    [0, 1, 3, 5, 6, 8, 10],      // locrian
    [0, 2, 4, 7, 9],             // major pentatonic
    [0, 3, 5, 7, 10],            // minor pentatonic
    [0, 3, 5, 6, 7, 10],         // blues
]

private final class ClockDividerState {
    var lastIn: Float = 0
    var lastReset: Float = 0
    var sinceTap: Double = 0
    var period: Double = 0  // 0 = no tap tempo yet
    var tickTimer: Double = 0
    var started = false
    var halted = false
}

extension PatchRuntime {
    func renderCVUtilities(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        let dt = Double(ctx.frames) / sampleRate
        switch node.typeID {
        case 10: renderSampleHold(index, node)
        case 17: node.cvOut[1] = -cvIn(node: index, block: 0)
        case 18: renderSteps(index, node, dt)
        case 19: renderSlewLimiter(index, node, dt)
        case 22: renderMultiplier(index, node)
        case 28: renderQuantizer(index, node)
        case 31: renderInSwitch(index, node)
        case 32: renderOutSwitch(index, node)
        case 45: renderValue(index, node)
        case 46: renderCVDelay(index, node, ctx.frames)
        case 48: renderCVFilter(index, node, dt)
        case 49: renderClockDivider(index, node, dt)
        case 50: renderComparator(index, node)
        case 51: node.cvOut[1] = abs(cvIn(node: index, block: 0))
        case 52: renderTrigger(index, node)
        case 77: renderFlipFlop(index, node)
        case 104: renderCVMixer(index, node)
        case 105: renderLogicGate(index, node)
        default: return false
        }
        return true
    }

    // MARK: - Shared curves

    /// ZOIA time dials are exponential between the catalog's five anchor
    /// values (at dial 0, 0.25, 0.5, 0.75, 1). Interpolation between
    /// anchors is geometric, or linear when an endpoint is 0.
    /// (Assumption: the device curve between anchors is not documented;
    /// anchor ratios are near-constant ≈14.6× so geometric fits.)
    private func dialTime(_ dial: Float, _ anchors: [Double]) -> Double {
        let t = Double(min(max(dial, 0), 1)) * 4
        let seg = min(Int(t), 3)
        let frac = t - Double(seg)
        let a = anchors[seg], b = anchors[seg + 1]
        if a > 0, b > 0 { return a * pow(b / a, frac) }
        return a + (b - a) * frac
    }

    /// Slew Limiter dial → seconds (catalog range anchors, unit s).
    private var slewAnchors: [Double] { [0, 0.09, 0.77, 6.82, 60] }
    /// CV Filter / CV Delay dial → seconds (catalog anchors are ms).
    private var msAnchors: [Double] { [0.00133, 0.0187, 0.283, 4.12, 60] }

    /// Splits 0…1 into `n` equal zones and returns the zone index —
    /// the in/out switch "divides value from 0-1 between channels" rule.
    private func zone(_ value: Float, _ n: Int) -> Int {
        min(max(Int(value * Float(n)), 0), n - 1)
    }

    // MARK: - 10 Sample and Hold

    private func renderSampleHold(_ index: Int, _ node: Node) {
        let state = node.state(HoldState())
        let input = cvIn(node: index, block: 0)
        let trigger = cvIn(node: index, block: 1)
        if trigger >= 0.5, node.lastGate < 0.5 { state.held = input }
        node.lastGate = trigger
        if node.optionText(0) == "on", trigger < 0.5 {
            // track & hold: output follows input while trigger is low.
            node.cvOut[2] = input
        } else {
            node.cvOut[2] = state.held
        }
    }

    // MARK: - 18 Steps

    private func renderSteps(_ index: Int, _ node: Node, _ dt: Double) {
        let state = node.state(StepsState())
        let input = cvIn(node: index, block: 0)
        // quant steps dial: 2…63 linear. (Assumption: linear mapping.)
        let steps = max(2, min(63, 2 + Int((cvIn(node: index, block: 1) * 61).rounded())))

        if input >= 0.5, state.lastIn < 0.5 {
            // Rising edge = one wave cycle; its duration sets the tempo.
            if state.sinceRise > 0 { state.period = state.sinceRise }
            state.sinceRise = 0
            state.stepTimer = 0
            state.held = input
        } else {
            state.sinceRise += dt
            if state.period > 0 {
                state.stepTimer += dt
                let stepDuration = state.period / Double(steps)
                if state.stepTimer >= stepDuration {
                    state.held = input
                    state.stepTimer -= stepDuration
                }
            } else {
                // Assumption: before the first full cycle establishes a
                // tempo, the output follows the input.
                state.held = input
            }
        }
        state.lastIn = input
        node.cvOut[2] = state.held
    }

    // MARK: - 19 Slew Limiter

    private func renderSlewLimiter(_ index: Int, _ node: Node, _ dt: Double) {
        let state = node.state(SmoothState())
        let input = cvIn(node: index, block: 0)
        // Assumption: the time dial is the time to traverse the full
        // 0…1 CV range at the limited rate (linear portamento).
        let riseTime: Double
        let fallTime: Double
        if node.optionText(0) == "separate" {
            riseTime = dialTime(cvIn(node: index, block: 2), slewAnchors)
            fallTime = dialTime(cvIn(node: index, block: 3), slewAnchors)
        } else {
            let t = dialTime(cvIn(node: index, block: 1), slewAnchors)
            riseTime = t
            fallTime = t
        }
        let delta = input - state.y
        let time = delta >= 0 ? riseTime : fallTime
        if time <= dt {
            state.y = input
        } else {
            let maxStep = Float(dt / time)
            state.y += min(max(delta, -maxStep), maxStep)
        }
        node.cvOut[4] = state.y
    }

    // MARK: - 22 Multiplier

    private func renderMultiplier(_ index: Int, _ node: Node) {
        let count = max(2, node.optionInt(0))
        var product: Float = 1
        for block in 0..<count { product *= cvIn(node: index, block: block) }
        node.cvOut[8] = min(max(product, -1), 1)
    }

    // MARK: - 28 Quantizer

    private func renderQuantizer(_ index: Int, _ node: Node) {
        let input = min(max(cvIn(node: index, block: 0), 0), 1)
        let target = input * 127

        var allowed: Set<Int> = Set(0...11)
        if node.optionText(0) == "yes" {
            // key dial spans A…G#: 12 equal zones; A is pitch class 9
            // relative to the MIDI C-based octave.
            let keyIndex = zone(cvIn(node: index, block: 2), 12)
            let key = (9 + keyIndex) % 12
            let scales = node.optionText(1) == "extended"
                ? quantizerExtendedScales : quantizerBasicScales
            let scale = scales[zone(cvIn(node: index, block: 3), scales.count)]
            allowed = Set(scale.map { (key + $0) % 12 })
        }

        // Nearest allowed MIDI note; ties resolve downward.
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for note in 0...127 where allowed.contains(note % 12) {
            let distance = abs(target - Float(note))
            if distance < bestDistance {
                bestDistance = distance
                best = note
            }
        }
        node.cvOut[1] = Float(best) / 127
    }

    // MARK: - 31 In Switch / 32 Out Switch

    private func renderInSwitch(_ index: Int, _ node: Node) {
        let count = max(1, node.optionInt(0))
        let select = cvIn(node: index, block: 16)
        if count == 1 {
            // Single input: select 0 = off, above 0 = on (mirrors the
            // documented single-output Out Switch rule).
            node.cvOut[17] = select > 0 ? cvIn(node: index, block: 0) : 0
        } else {
            node.cvOut[17] = cvIn(node: index, block: zone(select, count))
        }
    }

    private func renderOutSwitch(_ index: Int, _ node: Node) {
        let count = max(1, node.optionInt(0))
        let input = cvIn(node: index, block: 0)
        let select = cvIn(node: index, block: 1)
        if count == 1 {
            node.cvOut[2] = select > 0 ? input : 0
            return
        }
        let selected = zone(select, count)
        for out in 0..<count {
            node.cvOut[2 + out] = out == selected ? input : 0
        }
    }

    // MARK: - 45 Value

    private func renderValue(_ index: Int, _ node: Node) {
        let v = cvIn(node: index, block: 0)
        if node.optionText(0) == "-1 to 1" {
            // Assumption: the 0…1 dial spans the bipolar range.
            node.cvOut[1] = min(max(v * 2 - 1, -1), 1)
        } else {
            node.cvOut[1] = v
        }
    }

    // MARK: - 46 CV Delay

    private func renderCVDelay(_ index: Int, _ node: Node, _ frames: Int) {
        let state = node.state(CVDelayState())
        if state.buffer.isEmpty {
            // 60 s of control-rate history, sized on first render.
            let capacity = Int((60 * sampleRate / Double(frames)).rounded(.up)) + 2
            state.buffer = [Float](repeating: 0, count: capacity)
        }
        let dial = cvIn(node: index, block: 1)
        // Option "linear" maps the dial straight to 0…60 s; "exponent"
        // follows the catalog's ms anchor curve.
        let delaySeconds = node.optionText(0) == "linear"
            ? Double(min(max(dial, 0), 1)) * 60
            : dialTime(dial, msAnchors)
        let capacity = state.buffer.count
        let delayBlocks = min(max(Int((delaySeconds * sampleRate / Double(frames)).rounded()), 0),
                              capacity - 1)
        state.buffer[state.writeIndex] = cvIn(node: index, block: 0)
        let readIndex = (state.writeIndex - delayBlocks + capacity) % capacity
        node.cvOut[2] = state.buffer[readIndex]
        state.writeIndex = (state.writeIndex + 1) % capacity
    }

    // MARK: - 48 CV Filter

    private func renderCVFilter(_ index: Int, _ node: Node, _ dt: Double) {
        let state = node.state(SmoothState())
        let input = cvIn(node: index, block: 0)
        // One-pole smoothing; the time constant is exactly the doc's
        // "time to reach 63% / decay to 37%" tau.
        let tau: Double
        if node.optionText(0) == "separate" {
            tau = dialTime(cvIn(node: index, block: input >= state.y ? 3 : 4), msAnchors)
        } else {
            tau = dialTime(cvIn(node: index, block: 1), msAnchors)
        }
        if tau <= dt {
            state.y = input
        } else {
            state.y += Float(1 - exp(-dt / tau)) * (input - state.y)
        }
        node.cvOut[2] = state.y
    }

    // MARK: - 49 Clock Divider

    private func renderClockDivider(_ index: Int, _ node: Node, _ dt: Double) {
        let state = node.state(ClockDividerState())
        // Version ≥1 carries dividend/divisor blocks (positions 4/5);
        // version 0 has a single "modifier" dial at position 2, treated
        // as a 1…32 divisor. (Assumption for v0: divide only.)
        let dividend: Double
        let divisor: Double
        if node.paramIndexByPosition[4] != nil || hasWire(node: index, block: 4) {
            dividend = Double(1 + Int((cvIn(node: index, block: 4) * 31).rounded()))
            divisor = Double(1 + Int((cvIn(node: index, block: 5) * 31).rounded()))
        } else {
            dividend = 1
            divisor = Double(1 + Int((cvIn(node: index, block: 2) * 31).rounded()))
        }

        let reset = cvIn(node: index, block: 1)
        let resetEdge = reset >= 0.5 && state.lastReset < 0.5
        state.lastReset = reset

        var tick = false
        if node.optionText(0) == "cv_control" {
            // Dial is a frequency, 0…40 Hz linear (catalog range;
            // assumption: linear response).
            if resetEdge { state.tickTimer = 0 }
            let hz = Double(min(max(cvIn(node: index, block: 0), 0), 1)) * 40
            let outHz = hz * dividend / divisor
            if outHz > 0 {
                state.tickTimer += dt * outHz
                if state.tickTimer >= 1 {
                    tick = true
                    state.tickTimer -= state.tickTimer.rounded(.down)
                }
            }
        } else {
            // tap mode: rising edges at the input set the tempo.
            if resetEdge { state.halted = true }
            let input = cvIn(node: index, block: 0)
            state.sinceTap += dt
            if input >= 0.5, state.lastIn < 0.5 {
                if state.started { state.period = state.sinceTap }
                state.sinceTap = 0
                if state.halted || !state.started {
                    // First tap (or tap after a reset) restarts the
                    // clock aligned to it.
                    state.halted = false
                    state.started = true
                    state.tickTimer = 0
                    tick = state.period > 0
                }
            }
            state.lastIn = input
            if !tick, !state.halted, state.started, state.period > 0 {
                let tickPeriod = state.period * divisor / dividend
                state.tickTimer += dt
                if state.tickTimer >= tickPeriod {
                    tick = true
                    state.tickTimer -= tickPeriod
                }
            }
        }
        node.cvOut[3] = tick ? 1 : 0
    }

    // MARK: - 50 Comparator

    private func renderComparator(_ index: Int, _ node: Node) {
        let positive = cvIn(node: index, block: 0)
        let negative = cvIn(node: index, block: 1)
        let low: Float = node.optionText(0) == "-1 to 1" ? -1 : 0
        node.cvOut[2] = positive >= negative ? 1 : low
    }

    // MARK: - 52 Trigger / 77 CV Flip Flop

    private func renderTrigger(_ index: Int, _ node: Node) {
        let input = cvIn(node: index, block: 0)
        // One control-block pulse per rising edge.
        node.cvOut[1] = (input >= 0.5 && node.lastGate < 0.5) ? 1 : 0
        node.lastGate = input
    }

    private func renderFlipFlop(_ index: Int, _ node: Node) {
        let input = cvIn(node: index, block: 0)
        if input >= 0.5, node.lastGate < 0.5 { node.step = node.step == 0 ? 1 : 0 }
        node.lastGate = input
        node.cvOut[1] = Float(node.step)
    }

    // MARK: - 104 CV Mixer

    private func renderCVMixer(_ index: Int, _ node: Node) {
        let count = max(1, node.optionInt(0))
        var sum: Float = 0
        for channel in 0..<count {
            // Attenuverter dial: 1.0 passes, 0.5 mutes, 0.0 inverts.
            let gain = min(max(cvIn(node: index, block: 8 + channel) * 2 - 1, -1), 1)
            sum += cvIn(node: index, block: channel) * gain
        }
        if node.optionText(1) == "average" {
            node.cvOut[16] = sum / Float(count)
        } else {
            node.cvOut[16] = min(max(sum, -1), 1)  // summing clips
        }
    }

    // MARK: - 105 Logic Gate

    private func renderLogicGate(_ index: Int, _ node: Node) {
        let operation = node.optionText(0)
        // Threshold option adds a dial; otherwise a gate is high at
        // ≥0.5 like every other gate input.
        let threshold = node.optionText(2) == "on"
            ? cvIn(node: index, block: 38) : 0.5

        let result: Bool
        if operation == "NOT" {
            result = !(cvIn(node: index, block: 0) >= threshold)
        } else {
            let count = max(2, node.optionInt(1))
            var highs = 0
            for input in 0..<count where cvIn(node: index, block: input) >= threshold {
                highs += 1
            }
            switch operation {
            case "OR": result = highs > 0
            case "NOR": result = highs == 0
            case "NAND": result = highs != count
            case "XOR": result = highs % 2 == 1  // multi-input XOR = odd parity
            case "XNOR": result = highs % 2 == 0
            default: result = highs == count  // AND
            }
        }
        node.cvOut[39] = result ? 1 : 0
    }
}
