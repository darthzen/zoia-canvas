import Foundation
import Testing
@testable import ZoiaCanvas

/// Runtime tests for the effect-b group: reverbs (25, 74, 79, 80, 67)
/// and modulation/time effects (29, 41, 43, 69, 70, 71, 75, 106, 107).
/// Each rig feeds an Audio Input module (typeID 1, stereo) into the
/// effect and reads the effect node's audioOut buffers directly.
@Suite @MainActor struct RuntimeEffectBTests {
    private static let blockSize = 480

    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// Audio input → effect. Options are set before params (options
    /// resize the param list). Returns the document and the effect id.
    private func rig(
        _ typeID: Int, options: [(Int, UInt8)] = [], params: [Double] = [],
        wireRight: Bool = false
    ) throws -> (PatchDocument, UUID) {
        let document = try makeDocument()
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let fx = try #require(document.addModule(typeID: typeID, at: .zero))
        for (index, byte) in options { document.setOption(fx.id, optionIndex: index, byte: byte) }
        for (index, value) in params.enumerated() {
            document.setParam(fx.id, paramIndex: index, fraction: value)
        }
        document.connect(
            from: PortRef(module: input.id, blockPosition: 0, type: .audioOut),
            to: PortRef(module: fx.id, blockPosition: 0, type: .audioIn))
        if wireRight {
            document.connect(
                from: PortRef(module: input.id, blockPosition: 1, type: .audioOut),
                to: PortRef(module: fx.id, blockPosition: 1, type: .audioIn))
        }
        return (document, fx.id)
    }

    /// Streams `inputL` through the runtime in blocks, collecting the
    /// effect node's audioOut at each requested block position. A tap
    /// whose buffer the module never writes collects zeros.
    private func run(
        _ document: PatchDocument, inputL: [Float], inputR: [Float] = [],
        taps: [Int], node: Int = 1
    ) -> (outs: [Int: [Float]], runtime: PatchRuntime) {
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var collected: [Int: [Float]] = [:]
        for tap in taps { collected[tap] = [] }
        var outL = [Float](repeating: 0, count: Self.blockSize)
        var outR = outL
        var i = 0
        while i < inputL.count {
            let end = min(i + Self.blockSize, inputL.count)
            var chunkL = Array(inputL[i..<end])
            var chunkR = inputR.isEmpty ? chunkL : Array(inputR[i..<end])
            if chunkL.count < Self.blockSize {
                chunkL += [Float](repeating: 0, count: Self.blockSize - chunkL.count)
                chunkR += [Float](repeating: 0, count: Self.blockSize - chunkR.count)
            }
            runtime.render(frames: Self.blockSize, inputL: chunkL, inputR: chunkR,
                           outputL: &outL, outputR: &outR)
            for tap in taps {
                collected[tap]! += runtime.nodes[node].audioOut[tap]
                    ?? [Float](repeating: 0, count: Self.blockSize)
            }
            i += Self.blockSize
        }
        return (collected, runtime)
    }

    private func rms(_ x: ArraySlice<Float>) -> Float {
        guard !x.isEmpty else { return 0 }
        return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
    }

    private func impulse(_ length: Int, at position: Int = 0) -> [Float] {
        var buffer = [Float](repeating: 0, count: length)
        buffer[position] = 1
        return buffer
    }

    /// Deterministic noise (no Double.random in tests).
    private func noise(_ length: Int) -> [Float] {
        var seed: UInt32 = 0x2F6E2B1
        return (0..<length).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) - 0.5
        }
    }

    // MARK: - Reverbs

    /// An impulse through Plate Reverb (full wet) leaves a tail that is
    /// still audible past 0.5 s and decays over time, on both outputs.
    @Test func plateReverbProducesDecayingStereoTail() throws {
        // Params (file order): decay, low eq, high eq, mix.
        let (document, _) = try rig(25, params: [0.5, 0.5, 0.5, 1.0])
        let (outs, _) = run(document, inputL: impulse(48000), taps: [4, 5])
        let left = outs[4]!
        let right = outs[5]!
        let early = rms(left[4800..<9600])
        let mid = rms(left[24000..<28800])
        let late = rms(left[43200..<48000])
        #expect(mid > 1e-4, "tail died before 0.5 s (mid rms \(mid))")
        #expect(early > late, "tail must decay: early \(early) late \(late)")
        #expect(rms(right[24000..<28800]) > 1e-4, "right tail missing")
    }

    /// Hall Reverb: mix 0 is bit-exact dry; mix 1 leaves a long tail.
    @Test func hallReverbMixCrossfadesDryToWet() throws {
        let burst = noise(2400) + [Float](repeating: 0, count: 45600)
        // Params (file order): decay, low eq, lpf freq, mix.
        let (dryDoc, _) = try rig(74, params: [0.5, 0.5, 0.5, 0.0])
        let (dryOuts, _) = run(dryDoc, inputL: burst, taps: [4])
        for i in 0..<2400 {
            #expect(abs(dryOuts[4]![i] - burst[i]) < 1e-6)
            if abs(dryOuts[4]![i] - burst[i]) >= 1e-6 { break }
        }

        let (wetDoc, _) = try rig(74, params: [0.5, 0.5, 0.5, 1.0])
        let (wetOuts, _) = run(wetDoc, inputL: burst, taps: [4])
        #expect(rms(wetOuts[4]![24000..<28800]) > 1e-4, "hall tail died before 0.5 s")
    }

    /// Room Reverb: the decay dial controls tail length.
    @Test func roomReverbDecayKnobControlsTail() throws {
        // Params (file order): decay, low eq, lpf freq, mix.
        let (short, _) = try rig(80, params: [0.05, 0.5, 0.5, 1.0])
        let (long, _) = try rig(80, params: [0.9, 0.5, 0.5, 1.0])
        let (shortOuts, _) = run(short, inputL: impulse(48000), taps: [6])
        let (longOuts, _) = run(long, inputL: impulse(48000), taps: [6])
        let shortTail = rms(shortOuts[6]![24000..<28800])
        let longTail = rms(longOuts[6]![24000..<28800])
        #expect(longTail > shortTail * 5,
                "decay dial: long \(longTail) should dwarf short \(shortTail)")
    }

    /// Reverb Lite: mono option produces no right output; the mono-to-
    /// stereo option does; the tail decays.
    @Test func reverbLiteChannelsOptionAndTail() throws {
        // Params (file order): decay, mix. Default channels 1in->1out.
        let (mono, _) = try rig(79, params: [0.5, 1.0])
        let (monoOuts, monoRuntime) = run(mono, inputL: impulse(48000), taps: [4])
        #expect(monoRuntime.nodes[1].audioOut[5] == nil, "mono lite must not write out R")
        let tail = rms(monoOuts[4]![24000..<28800])
        #expect(tail > 1e-4, "lite tail died before 0.5 s")
        #expect(rms(monoOuts[4]![4800..<9600]) > rms(monoOuts[4]![43200..<48000]))

        let (spread, _) = try rig(79, options: [(0, 1)], params: [0.5, 1.0])
        let (_, spreadRuntime) = run(spread, inputL: impulse(4800), taps: [4])
        #expect(spreadRuntime.nodes[1].audioOut[5] != nil, "1in->2out must write out R")
    }

    /// Ghostverb: decaying tail, and mono option writes no right out.
    @Test func ghostverbProducesTail() throws {
        // Params (file order): decay/feedback, rate, resonance, mix.
        let (document, _) = try rig(67, params: [0.7, 0.5, 0.6, 1.0])
        let (outs, runtime) = run(document, inputL: impulse(48000), taps: [6])
        let mid = rms(outs[6]![24000..<28800])
        #expect(mid > 1e-4, "ghost tail died before 0.5 s")
        #expect(rms(outs[6]![4800..<9600]) > rms(outs[6]![43200..<48000]), "tail must decay")
        #expect(runtime.nodes[1].audioOut[7] == nil, "1in->1out must not write out R")
    }

    // MARK: - Phaser / Univibe

    /// Phaser at 50% mix reshapes noise; at mix 0 it passes dry
    /// bit-exact; 1in->2out adds a right output.
    @Test func phaserAltersSignalAndHonorsMix() throws {
        let input = noise(24000)
        // Params (file order): rate, resonance, width, mix.
        let (wetDoc, _) = try rig(29, params: [0.5, 0.5, 0.7, 0.5])
        let (wetOuts, _) = run(wetDoc, inputL: input, taps: [5])
        var difference: Float = 0
        for i in 0..<input.count { difference += abs(wetOuts[5]![i] - input[i]) }
        #expect(difference / Float(input.count) > 0.01, "phaser left the signal untouched")

        let (dryDoc, _) = try rig(29, params: [0.5, 0.5, 0.7, 0.0])
        let (dryOuts, _) = run(dryDoc, inputL: input, taps: [5])
        let maxError = zip(dryOuts[5]!, input).map { abs($0 - $1) }.max() ?? 1
        #expect(maxError < 1e-6, "mix 0 must be exactly dry (err \(maxError))")

        let (stereo, _) = try rig(29, options: [(0, 1)], params: [0.5, 0.5, 0.7, 0.5])
        let (_, runtime) = run(stereo, inputL: impulse(4800), taps: [5])
        #expect(runtime.nodes[1].audioOut[6] != nil, "1in->2out must write out R")
    }

    /// The stages option changes the phaser's response (1 vs 8 stages).
    @Test func phaserStagesOptionChangesResponse() throws {
        let input = noise(24000)
        let (one, _) = try rig(29, options: [(2, 2)], params: [0.5, 0.0, 0.7, 0.5])   // 1 stage
        let (eight, _) = try rig(29, options: [(2, 5)], params: [0.5, 0.0, 0.7, 0.5]) // 8 stages
        let (oneOuts, _) = run(one, inputL: input, taps: [5])
        let (eightOuts, _) = run(eight, inputL: input, taps: [5])
        var difference: Float = 0
        for i in 0..<input.count { difference += abs(oneOuts[5]![i] - eightOuts[5]![i]) }
        #expect(difference / Float(input.count) > 0.005, "stage count had no effect")
    }

    /// Univibe throbs a sine (wet differs from dry), passes dry at mix 0,
    /// and honors the channels option.
    @Test func univibeSweepsAndHonorsChannels() throws {
        let input = (0..<24000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * 0.5 }
        // Params (file order): rate, depth, resonance, mix.
        let (wet, _) = try rig(107, params: [0.5, 1.0, 0.5, 0.5])
        let (wetOuts, wetRuntime) = run(wet, inputL: input, taps: [8])
        var difference: Float = 0
        for i in 0..<input.count { difference += abs(wetOuts[8]![i] - input[i]) }
        #expect(difference / Float(input.count) > 0.01, "univibe left the signal untouched")
        #expect(wetRuntime.nodes[1].audioOut[9] == nil, "1in->1out must not write out R")

        let (dry, _) = try rig(107, params: [0.5, 1.0, 0.5, 0.0])
        let (dryOuts, _) = run(dry, inputL: input, taps: [8])
        let maxError = zip(dryOuts[8]!, input).map { abs($0 - $1) }.max() ?? 1
        #expect(maxError < 1e-6, "mix 0 must be exactly dry")

        let (stereo, _) = try rig(107, options: [(0, 1)], params: [0.5, 1.0, 0.5, 0.5])
        let (_, stereoRuntime) = run(stereo, inputL: impulse(4800), taps: [8])
        #expect(stereoRuntime.nodes[1].audioOut[9] != nil, "1in->2out must write out R")
    }

    // MARK: - Tremolo

    /// Sine-wave tremolo at full depth swings the gain between ~0 and ~1.
    @Test func tremoloAmplitudeModulatesAtLFORate() throws {
        let input = [Float](repeating: 0.8, count: 48000)
        // Waveform option byte 3 = sine. Params: rate (cv .5 → 5.4 Hz), depth 1.
        let (document, _) = try rig(41, options: [(2, 3)], params: [0.5, 1.0])
        let (outs, _) = run(document, inputL: input, taps: [6])
        let out = outs[6]!
        // 10 ms windows over the second half (LFO settled).
        var windowRMS: [Float] = []
        var i = 24000
        while i + 480 <= 48000 {
            windowRMS.append(rms(out[i..<(i + 480)]))
            i += 480
        }
        let top = windowRMS.max() ?? 0
        let bottom = windowRMS.min() ?? 1
        #expect(top > 0.6, "tremolo peaks too low (\(top))")
        #expect(bottom < 0.2, "full depth must dip near silence (\(bottom))")
    }

    /// Square-waveform tremolo produces two-level output; the waveform
    /// option changes the shape versus sine.
    @Test func tremoloSquareWaveformGates() throws {
        let input = [Float](repeating: 0.8, count: 24000)
        let (document, _) = try rig(41, options: [(2, 4)], params: [0.5, 1.0])
        let (outs, _) = run(document, inputL: input, taps: [6])
        let out = outs[6]![2400...]
        let nearFull = out.filter { abs($0 - 0.8) < 0.05 }.count
        let nearZero = out.filter { abs($0) < 0.05 }.count
        #expect(Float(nearFull + nearZero) / Float(out.count) > 0.95,
                "square tremolo should sit at 0 or full gain")
        #expect(nearFull > 0 && nearZero > 0)
    }

    /// Tap tempo: square LFO taps at 4 Hz set the tremolo rate; the
    /// envelope then dips roughly 8 times in 2 s.
    @Test func tremoloTapTempoSetsRate() throws {
        let document = try makeDocument()
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let lfo = try #require(document.addModule(typeID: 5, at: .zero))
        let trem = try #require(document.addModule(typeID: 41, at: .zero))
        document.setOption(trem.id, optionIndex: 1, byte: 1)  // control: tap_tempo
        document.setOption(trem.id, optionIndex: 2, byte: 3)  // waveform: sine
        // LFO square at 4 Hz: 0.05 × 500^cv = 4 → cv ≈ 0.7050.
        document.setParam(lfo.id, paramIndex: 0, fraction: 0.7050)
        document.setParam(trem.id, paramIndex: 1, fraction: 1.0)  // depth
        document.connect(
            from: PortRef(module: input.id, blockPosition: 0, type: .audioOut),
            to: PortRef(module: trem.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: lfo.id, blockPosition: 3, type: .cvOut),
            to: PortRef(module: trem.id, blockPosition: 3, type: .cvIn))

        let constant = [Float](repeating: 0.8, count: 144000)  // 3 s
        let (outs, _) = run(document, inputL: constant, taps: [6], node: 2)
        let out = outs[6]!
        // Count envelope dips (window rms below 0.15) in the final 2 s.
        var dips = 0
        var inDip = false
        var i = 48000
        while i + 480 <= 144000 {
            let level = rms(out[i..<(i + 480)])
            if level < 0.15 {
                if !inDip { dips += 1 }
                inDip = true
            } else {
                inDip = false
            }
            i += 480
        }
        #expect((6...10).contains(dips), "expected ~8 dips at 4 Hz over 2 s, saw \(dips)")
    }

    // MARK: - Delays

    /// Delay w/Mod echoes an impulse at the dialed time (cv 0 → 62.5 ms
    /// = 3000 samples) and feedback produces a second repeat.
    @Test func delayWithModEchoesAtSetTime() throws {
        // Params (file order): time, feedback, mod rate, mod depth, mix.
        let (document, _) = try rig(43, params: [0.0, 0.75, 0.0, 0.0, 0.5])
        let (outs, _) = run(document, inputL: impulse(24000), taps: [8])
        let out = outs[8]!
        let echoRegion = 2900..<3100
        let echoPeak = out[echoRegion].map(abs).max() ?? 0
        let echoIndex = echoRegion.max { abs(out[$0]) < abs(out[$1]) }!
        #expect(echoPeak > 0.3, "first echo missing (peak \(echoPeak))")
        #expect(abs(echoIndex - 3000) <= 4, "echo at \(echoIndex), expected 3000")
        // Feedback at cv 0.75 (-2.5 dB) → second repeat near 6000.
        let repeatPeak = out[5900..<6100].map(abs).max() ?? 0
        #expect(repeatPeak > 0.2, "feedback repeat missing (peak \(repeatPeak))")
        // Quiet between repeats.
        #expect(out[4000..<5000].map(abs).max() ?? 1 < 0.05)
    }

    /// Tap tempo mode: taps at 4 Hz (12000 samples) set the echo time.
    @Test func delayWithModTapTempoSetsEchoTime() throws {
        let document = try makeDocument()
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let lfo = try #require(document.addModule(typeID: 5, at: .zero))
        let delay = try #require(document.addModule(typeID: 43, at: .zero))
        document.setOption(delay.id, optionIndex: 1, byte: 1)  // control: tap_tempo
        document.setParam(lfo.id, paramIndex: 0, fraction: 0.7050)  // 4 Hz square
        // Params: tap in, feedback, mod rate, mod depth, mix.
        document.setParam(delay.id, paramIndex: 4, fraction: 0.5)  // mix
        document.connect(
            from: PortRef(module: input.id, blockPosition: 0, type: .audioOut),
            to: PortRef(module: delay.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: lfo.id, blockPosition: 3, type: .cvOut),
            to: PortRef(module: delay.id, blockPosition: 5, type: .cvIn))

        let signal = impulse(72000, at: 30000)
        let (outs, _) = run(document, inputL: signal, taps: [8], node: 2)
        let out = outs[8]!
        let search = 35000..<50000
        let echoIndex = search.max { abs(out[$0]) < abs(out[$1]) }!
        #expect(abs(out[echoIndex]) > 0.3, "tap echo missing")
        #expect(abs(echoIndex - 42000) <= 1000,
                "tap echo at \(echoIndex), expected ≈42000 (impulse + 12000)")
    }

    /// Ping Pong: mono input, first repeat left at 1×delay, second
    /// repeat right at 2×delay — even with the feedback dial at zero.
    @Test func pingPongAlternatesLeftThenRight() throws {
        // Params (file order): time, feedback, mod rate, mod depth, mix.
        let (document, _) = try rig(75, params: [0.0, 0.0, 0.0, 0.0, 1.0])
        let (outs, _) = run(document, inputL: impulse(24000), taps: [8, 9])
        let left = outs[8]!
        let right = outs[9]!
        let leftEcho = left[2900..<3100].map(abs).max() ?? 0
        let rightAtOne = right[2900..<3100].map(abs).max() ?? 0
        let rightEcho = right[5900..<6100].map(abs).max() ?? 0
        let leftAtTwo = left[5900..<6100].map(abs).max() ?? 0
        #expect(leftEcho > 0.5, "left ping missing (\(leftEcho))")
        #expect(rightAtOne < 0.05, "right must be silent at 1×delay (\(rightAtOne))")
        #expect(rightEcho > 0.5, "right pong missing (\(rightEcho))")
        #expect(leftAtTwo < 0.05, "left must be silent at 2×delay with zero feedback")
    }

    /// Reverse Delay plays each recorded chunk backwards: a rising saw
    /// comes out as falling ramps once the first chunk has recorded.
    @Test func reverseDelayReversesChunks() throws {
        let chunk = 3000  // delay cv 0 → 62.5 ms
        let input = (0..<24000).map { Float($0 % chunk) / Float(chunk) * 0.9 }
        // Params (file order): time, feedback, pitch (0.5 → unity), mix.
        let (document, _) = try rig(106, params: [0.0, 0.0, 0.5, 1.0])
        let (outs, _) = run(document, inputL: input, taps: [8])
        let out = outs[8]!
        // From the second chunk on the wet path is reversed: falling.
        var falling = 0
        var counted = 0
        for i in 4000..<20000 {
            let diff = out[i] - out[i - 1]
            if abs(diff) > 0.5 { continue }  // chunk-boundary wrap
            counted += 1
            if diff < 0 { falling += 1 }
        }
        #expect(Float(falling) / Float(max(counted, 1)) > 0.8,
                "expected mostly falling output, got \(falling)/\(counted)")
        #expect(out[4000..<20000].map(abs).max() ?? 0 > 0.5, "wet output missing")
    }

    /// Reverse Delay pitch at +12 semitones plays the chunk at 2×: the
    /// second half of each playback window falls silent.
    @Test func reverseDelayPitchShiftDoublesPlaybackRate() throws {
        let input = (0..<24000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * 0.5 }
        let (document, _) = try rig(106, params: [0.0, 0.0, 1.0, 1.0]) // pitch cv 1 → +12 st
        let (outs, _) = run(document, inputL: input, taps: [8])
        let out = outs[8]!
        // Chunk 2 spans 6000..<9000; at 2× rate audio occupies its first half.
        let firstHalf = rms(out[6000..<7400])
        let secondHalf = rms(out[7600..<8900])
        #expect(firstHalf > 0.1, "pitch-shifted playback missing (\(firstHalf))")
        #expect(secondHalf < firstHalf * 0.2,
                "2× playback should exhaust the chunk early (\(secondHalf) vs \(firstHalf))")
    }

    // MARK: - Flanger / Chorus / Vibrato

    /// Flanger with the LFO stopped (rate 0) is a static comb: an
    /// impulse yields the dry spike plus one delayed copy inside 10 ms.
    @Test func flangerCombsAnImpulse() throws {
        // Params (file order): rate, regen, width, tone tilt, mix.
        let (document, _) = try rig(69, params: [0.0, 0.0, 0.5, 0.5, 0.5])
        let (outs, _) = run(document, inputL: impulse(4800), taps: [9])
        let out = outs[9]!
        #expect(abs(out[0] - 0.5) < 0.01, "dry half of the impulse missing (\(out[0]))")
        // 1960s type, phase 0 → tap at the 2.5 ms center (120 samples).
        let region = 100..<200
        let tapPeak = region.map { abs(out[$0]) }.max() ?? 0
        #expect(tapPeak > 0.3, "delayed comb tap missing (peak \(tapPeak))")
    }

    /// Chorus (rate 0): wet-only output is a 12 ms delayed copy on the
    /// left; the right channel of 1in->2out sits later (90° LFO offset).
    @Test func chorusDelaysAndOffsetsStereo() throws {
        // Params (file order): rate, width, tone tilt, mix.
        let (document, _) = try rig(70, options: [(0, 1)], params: [0.0, 0.5, 0.5, 1.0])
        let (outs, _) = run(document, inputL: impulse(4800), taps: [8, 9])
        let left = outs[8]!
        let right = outs[9]!
        let leftIndex = (0..<4800).max { abs(left[$0]) < abs(left[$1]) }!
        let rightIndex = (0..<4800).max { abs(right[$0]) < abs(right[$1]) }!
        // Center 12 ms = 576 samples (write-then-read tap lands at 575).
        #expect(abs(leftIndex - 575) <= 3, "left chorus tap at \(leftIndex), expected ≈575")
        // R LFO 90° ahead at phase 0 → sin = 1 → 12 + 8×0.5 = 16 ms.
        #expect(abs(rightIndex - 767) <= 3, "right chorus tap at \(rightIndex), expected ≈767")
    }

    /// Vibrato is wet-only: level is preserved while the LFO bends the
    /// signal enough that it stops matching the dry input.
    @Test func vibratoWobblesWetOnly() throws {
        let input = (0..<48000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * 0.5 }
        // Params (file order): rate (cv .5 → 5.4 Hz), width.
        let (document, _) = try rig(71, params: [0.5, 1.0])
        let (outs, _) = run(document, inputL: input, taps: [6])
        let out = outs[6]!
        let levelRatio = rms(out[24000..<48000]) / rms(input[24000..<48000])
        #expect(levelRatio > 0.7 && levelRatio < 1.3, "vibrato must preserve level (\(levelRatio))")
        var difference: Float = 0
        for i in 24000..<48000 { difference += abs(out[i] - input[i]) }
        #expect(difference / 24000 > 0.05, "vibrato left the signal unbent")
    }

    /// Vibrato waveform option changes the wobble shape (sine vs swung).
    @Test func vibratoWaveformOptionChangesOutput() throws {
        let input = (0..<24000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * 0.5 }
        let (sineDoc, _) = try rig(71, options: [(2, 0)], params: [0.5, 1.0])
        let (swungDoc, _) = try rig(71, options: [(2, 3)], params: [0.5, 1.0])
        let (sineOuts, _) = run(sineDoc, inputL: input, taps: [6])
        let (swungOuts, _) = run(swungDoc, inputL: input, taps: [6])
        var difference: Float = 0
        for i in 12000..<24000 { difference += abs(sineOuts[6]![i] - swungOuts[6]![i]) }
        #expect(difference / 12000 > 0.01, "waveform option had no effect")
    }
}
