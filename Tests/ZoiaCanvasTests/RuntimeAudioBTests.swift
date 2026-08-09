import Foundation
import Testing
@testable import ZoiaCanvas

/// Runtime tests for the audio routing / delay / sampling group —
/// IDs 13, 26, 30, 33, 34, 53, 57, 59, 64, 76, 78, 83, 102.
///
/// Pattern: build a PatchDocument, wire an oscillator (ID 14, rendered by
/// the AudioA group) into the module under test, then read the module's
/// `audioOut` buffers directly. Time-varying CV (record buttons, switches)
/// is driven by mutating `runtime.nodes[i].params` between renders.
@Suite @MainActor struct RuntimeAudioBTests {
    private static let frames = 480

    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// Renders one block and returns nothing; node buffers carry the result.
    private func renderBlock(_ runtime: PatchRuntime) {
        var l = [Float](repeating: 0, count: Self.frames)
        var r = l
        runtime.render(frames: Self.frames, outputL: &l, outputR: &r)
    }

    private func paramIndex(_ runtime: PatchRuntime, node: Int, position: Int) throws -> Int {
        try #require(runtime.nodes[node].paramIndexByPosition[position])
    }

    private func risingCrossings(_ samples: [Float]) -> Int {
        var count = 0
        var last: Float = 0
        for s in samples {
            if last < 0, s >= 0 { count += 1 }
            last = s
        }
        return count
    }

    // MARK: - 13 Delay Line

    @Test func delayLineDelaysByExpectedSamples() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let delay = try #require(document.addModule(typeID: 13, at: .zero))
        document.setOption(delay.id, optionIndex: 0, byte: 5)  // max time 100ms
        document.setOption(delay.id, optionIndex: 2, byte: 1)  // interpolation off
        document.setOption(delay.id, optionIndex: 3, byte: 1)  // CV input linear
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(delay.id, paramIndex: 0, fraction: 0.5)  // 50 ms = 2400 smp
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: delay.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var input: [Float] = []
        var output: [Float] = []
        for _ in 0..<12 {
            renderBlock(runtime)
            input += runtime.nodes[0].audioOut[3] ?? []
            output += runtime.nodes[1].audioOut[4] ?? []
        }
        for i in stride(from: 2400, to: input.count, by: 37) {
            #expect(abs(output[i] - input[i - 2400]) < 1e-4,
                    "sample \(i): \(output[i]) vs \(input[i - 2400])")
        }
    }

    @Test func delayLineTapTempoSetsDelayAndModulationScalesIt() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let delay = try #require(document.addModule(typeID: 13, at: .zero))
        document.setOption(delay.id, optionIndex: 1, byte: 1)  // tap tempo yes
        document.setOption(delay.id, optionIndex: 2, byte: 1)  // interpolation off
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: delay.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let tapIdx = try paramIndex(runtime, node: 1, position: 3)
        let modIdx = try paramIndex(runtime, node: 1, position: 2)

        var input: [Float] = []
        var output: [Float] = []
        func step(tap: Float) {
            runtime.nodes[1].params[tapIdx] = tap
            renderBlock(runtime)
            input += runtime.nodes[0].audioOut[3] ?? []
            output += runtime.nodes[1].audioOut[4] ?? []
        }
        step(tap: 1)                       // first tap
        for _ in 0..<4 { step(tap: 0) }    // 5 blocks between edges = 2400 smp
        step(tap: 1)                       // second tap → interval 2400
        for _ in 0..<10 { step(tap: 0) }
        // From the second tap onward the line delays by 2400 samples.
        for i in stride(from: 4800, to: input.count, by: 53) {
            #expect(abs(output[i] - input[i - 2400]) < 1e-4, "sample \(i)")
        }
        // Modulation scales the tapped time: +0.5 → 2400 × 1.5 = 3600.
        runtime.nodes[1].params[modIdx] = 0.5
        for _ in 0..<10 { step(tap: 0) }
        for i in stride(from: input.count - 2400, to: input.count, by: 53) {
            #expect(abs(output[i] - input[i - 3600]) < 1e-4, "sample \(i)")
        }
    }

    // MARK: - 26 Buffer Delay

    @Test func bufferDelayDelaysByWholeBuffers() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let buf = try #require(document.addModule(typeID: 26, at: .zero))
        document.setOption(buf.id, optionIndex: 0, byte: 3)  // 3 buffers
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: buf.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var inBlocks: [[Float]] = []
        var outBlocks: [[Float]] = []
        for _ in 0..<7 {
            renderBlock(runtime)
            inBlocks.append(runtime.nodes[0].audioOut[3] ?? [])
            outBlocks.append(runtime.nodes[1].audioOut[1] ?? [])
        }
        // First 3 output blocks are silence, then input shifted by 3 blocks.
        for k in 0..<3 {
            #expect(outBlocks[k].allSatisfy { $0 == 0 }, "block \(k) not silent")
        }
        for k in 3..<7 {
            #expect(outBlocks[k] == inBlocks[k - 3], "block \(k) mismatched")
        }
    }

    // MARK: - 30 Looper

    @Test func looperRecordsAndLoopsPlayback() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let looper = try #require(document.addModule(typeID: 30, at: .zero))
        document.setOption(looper.id, optionIndex: 2, byte: 1)  // playback: loop
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: looper.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recIdx = try paramIndex(runtime, node: 1, position: 1)
        let restartIdx = try paramIndex(runtime, node: 1, position: 2)
        let speedIdx = try paramIndex(runtime, node: 1, position: 3)
        runtime.nodes[1].params[speedIdx] = 0.5  // unity speed

        var recordedInput: [Float] = []
        // Record 4 blocks: rising edge starts, second rising edge stops.
        runtime.nodes[1].params[recIdx] = 1
        for block in 0..<4 {
            if block == 3 { runtime.nodes[1].params[recIdx] = 0 }
            renderBlock(runtime)
            recordedInput += runtime.nodes[0].audioOut[3] ?? []
        }
        runtime.nodes[1].params[recIdx] = 1  // stop edge → playback begins
        var playback: [Float] = []
        for _ in 0..<5 {
            renderBlock(runtime)
            playback += runtime.nodes[1].audioOut[6] ?? []
        }
        // First pass reproduces the recording, then wraps to the start.
        for i in stride(from: 0, to: recordedInput.count, by: 41) {
            #expect(abs(playback[i] - recordedInput[i]) < 1e-5, "sample \(i)")
        }
        for i in stride(from: 0, to: Self.frames, by: 41) {
            #expect(abs(playback[recordedInput.count + i] - recordedInput[i]) < 1e-5,
                    "wrapped sample \(i)")
        }

        // Double speed in fixed-length mode: content at 2× for the first
        // half of the loop period, then a silent gap.
        runtime.nodes[1].params[recIdx] = 0
        runtime.nodes[1].params[speedIdx] = 0.6  // 32^(2·0.6−1) = 2×
        runtime.nodes[1].params[restartIdx] = 1
        var fast: [Float] = []
        for _ in 0..<4 {
            renderBlock(runtime)
            fast += runtime.nodes[1].audioOut[6] ?? []
        }
        for i in stride(from: 0, to: 960, by: 37) {
            #expect(abs(fast[i] - recordedInput[2 * i]) < 1e-3, "2× sample \(i)")
        }
        #expect(fast[962..<1920].allSatisfy { $0 == 0 }, "fixed-length gap not silent")
    }

    // MARK: - 33 Audio In Switch

    @Test func audioInSwitchSelectsAndCrossfades() throws {
        let document = try makeDocument()
        let oscA = try #require(document.addModule(typeID: 14, at: .zero))
        let oscB = try #require(document.addModule(typeID: 14, at: .zero))
        let sw = try #require(document.addModule(typeID: 33, at: .zero))
        document.setOption(sw.id, optionIndex: 0, byte: 1)  // 2 inputs
        document.setOption(oscB.id, optionIndex: 0, byte: 1)  // square
        document.setParam(oscA.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(oscB.id, paramIndex: 0, fraction: 50.0 / 127.0)
        document.connect(
            from: PortRef(module: oscA.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: sw.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: oscB.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: sw.id, blockPosition: 1, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let selIdx = try paramIndex(runtime, node: 2, position: 16)

        renderBlock(runtime)
        #expect(runtime.nodes[2].audioOut[17] == runtime.nodes[0].audioOut[3])

        // Selection change with fades on: the transition block starts at the
        // old source and ends exactly at the new one.
        runtime.nodes[2].params[selIdx] = 0.9
        renderBlock(runtime)
        let out = try #require(runtime.nodes[2].audioOut[17])
        let a = try #require(runtime.nodes[0].audioOut[3])
        let b = try #require(runtime.nodes[1].audioOut[3])
        #expect(abs(out[0] - a[0]) < 0.02, "crossfade start should be near old input")
        #expect(abs(out[Self.frames - 1] - b[Self.frames - 1]) < 1e-6)

        renderBlock(runtime)
        #expect(runtime.nodes[2].audioOut[17] == runtime.nodes[1].audioOut[3])
    }

    // MARK: - 34 Audio Out Switch

    @Test func audioOutSwitchRoutesToSelectedOutput() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let sw = try #require(document.addModule(typeID: 34, at: .zero))
        document.setOption(sw.id, optionIndex: 0, byte: 1)  // 2 outputs
        document.setOption(sw.id, optionIndex: 1, byte: 1)  // fades off
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: sw.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let selIdx = try paramIndex(runtime, node: 1, position: 1)

        renderBlock(runtime)
        #expect(runtime.nodes[1].audioOut[2] == runtime.nodes[0].audioOut[3])
        #expect(runtime.nodes[1].audioOut[3]?.allSatisfy { $0 == 0 } == true)

        runtime.nodes[1].params[selIdx] = 1
        renderBlock(runtime)
        #expect(runtime.nodes[1].audioOut[3] == runtime.nodes[0].audioOut[3])
        #expect(runtime.nodes[1].audioOut[2]?.allSatisfy { $0 == 0 } == true)
    }

    // MARK: - 53 Stereo Spread

    @Test func stereoSpreadHaasDelaysSecondOutput() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let spread = try #require(document.addModule(typeID: 53, at: .zero))
        document.setOption(spread.id, optionIndex: 0, byte: 1)  // haas
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        // Delay dial at 0 → anchor minimum 2 ms = 96 samples exactly.
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: spread.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var input: [Float] = []
        var out1: [Float] = []
        var out2: [Float] = []
        for _ in 0..<4 {
            renderBlock(runtime)
            input += runtime.nodes[0].audioOut[3] ?? []
            out1 += runtime.nodes[1].audioOut[4] ?? []
            out2 += runtime.nodes[1].audioOut[5] ?? []
        }
        #expect(out1 == input, "haas out 1 must be the dry input")
        for i in stride(from: 96, to: input.count, by: 43) {
            #expect(abs(out2[i] - input[i - 96]) < 1e-4, "sample \(i)")
        }
    }

    @Test func stereoSpreadMidSideEncodes() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let spread = try #require(document.addModule(typeID: 53, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(spread.id, paramIndex: 0, fraction: 2.0 / 3.0)  // side gain 0 dB
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: spread.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        renderBlock(runtime)
        let input = try #require(runtime.nodes[0].audioOut[3])
        let mid = try #require(runtime.nodes[1].audioOut[4])
        let side = try #require(runtime.nodes[1].audioOut[5])
        // With input only on channel 1: mid = side = input / 2.
        // (setParam quantizes the 0 dB side gain to +0.00002 dB, so the
        // side comparison needs a little slack.)
        for i in stride(from: 0, to: Self.frames, by: 31) {
            #expect(abs(mid[i] - input[i] / 2) < 1e-5)
            #expect(abs(side[i] - input[i] / 2) < 1e-4)
        }
    }

    // MARK: - 57 Audio Panner

    @Test func pannerFollowsEqualPowerLaw() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let pan = try #require(document.addModule(typeID: 57, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: pan.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let panIdx = try paramIndex(runtime, node: 1, position: 2)

        runtime.nodes[1].params[panIdx] = 0  // hard left
        renderBlock(runtime)
        #expect(runtime.nodes[1].audioOut[3] == runtime.nodes[0].audioOut[3])
        #expect(runtime.nodes[1].audioOut[4]?.allSatisfy { $0 == 0 } == true)

        runtime.nodes[1].params[panIdx] = 1  // hard right
        renderBlock(runtime)
        #expect(runtime.nodes[1].audioOut[4]?.map(abs).max() ?? 0 > 0.5)
        #expect(runtime.nodes[1].audioOut[3]?.map(abs).max() ?? 1 < 1e-6)

        runtime.nodes[1].params[panIdx] = 0.5  // center: −3 dB each side
        renderBlock(runtime)
        let input = try #require(runtime.nodes[0].audioOut[3])
        let left = try #require(runtime.nodes[1].audioOut[3])
        for i in stride(from: 0, to: Self.frames, by: 31) {
            #expect(abs(left[i] - input[i] * 0.70711) < 1e-4)
        }
    }

    // MARK: - 59 Pitch Shifter

    private func shifterCrossings(pitchCV: Double) throws -> Int {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let shift = try #require(document.addModule(typeID: 59, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)  // 440 Hz
        document.setParam(shift.id, paramIndex: 0, fraction: pitchCV)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: shift.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        for _ in 0..<20 { renderBlock(runtime) }  // 0.2 s warmup
        var out: [Float] = []
        for _ in 0..<100 {  // 1 s measured
            renderBlock(runtime)
            out += runtime.nodes[1].audioOut[2] ?? []
        }
        return risingCrossings(out)
    }

    @Test func pitchShifterMovesSineFrequency() throws {
        // Dial is −60…+60 semitones linear: cv 0.5 = no shift,
        // cv 0.6 = +12 st, cv 0.4 = −12 st.
        let unity = try shifterCrossings(pitchCV: 0.5)
        #expect(abs(unity - 440) <= 20, "\(unity) crossings at unity")
        let octaveUp = try shifterCrossings(pitchCV: 0.6)
        #expect(abs(octaveUp - 880) <= 90, "\(octaveUp) crossings at +12 st")
        let octaveDown = try shifterCrossings(pitchCV: 0.4)
        #expect(abs(octaveDown - 220) <= 45, "\(octaveDown) crossings at -12 st")
    }

    // MARK: - 64 Audio Balance

    @Test func audioBalanceCrossfadesInputs() throws {
        let document = try makeDocument()
        let oscA = try #require(document.addModule(typeID: 14, at: .zero))
        let oscB = try #require(document.addModule(typeID: 14, at: .zero))
        let bal = try #require(document.addModule(typeID: 64, at: .zero))
        document.setParam(oscA.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(oscB.id, paramIndex: 0, fraction: 45.0 / 127.0)
        document.connect(
            from: PortRef(module: oscA.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: bal.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: oscB.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: bal.id, blockPosition: 1, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let mixIdx = try paramIndex(runtime, node: 2, position: 2)

        renderBlock(runtime)  // mix 0 → all input 1
        #expect(runtime.nodes[2].audioOut[3] == runtime.nodes[0].audioOut[3])

        runtime.nodes[2].params[mixIdx] = 1
        renderBlock(runtime)
        #expect(runtime.nodes[2].audioOut[3] == runtime.nodes[1].audioOut[3])

        runtime.nodes[2].params[mixIdx] = 0.5
        renderBlock(runtime)
        let a = try #require(runtime.nodes[0].audioOut[3])
        let b = try #require(runtime.nodes[1].audioOut[3])
        let out = try #require(runtime.nodes[2].audioOut[3])
        for i in stride(from: 0, to: Self.frames, by: 31) {
            #expect(abs(out[i] - (a[i] + b[i]) / 2) < 1e-5)
        }
    }

    // MARK: - 76 Audio Mixer

    @Test func audioMixerSumsWithGain() throws {
        let document = try makeDocument()
        let oscA = try #require(document.addModule(typeID: 14, at: .zero))
        let oscB = try #require(document.addModule(typeID: 14, at: .zero))
        let mixer = try #require(document.addModule(typeID: 76, at: .zero))
        document.setParam(oscA.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(oscB.id, paramIndex: 0, fraction: 45.0 / 127.0)
        document.connect(
            from: PortRef(module: oscA.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: mixer.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: oscB.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: mixer.id, blockPosition: 2, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let gain1 = try paramIndex(runtime, node: 2, position: 16)
        let gain2 = try paramIndex(runtime, node: 2, position: 17)
        // Fader is linear in dB (−100…+20): cv 5/6 = 0 dB, cv 2/3 = −20 dB.
        runtime.nodes[2].params[gain1] = 5.0 / 6.0
        runtime.nodes[2].params[gain2] = 5.0 / 6.0

        renderBlock(runtime)
        var a = try #require(runtime.nodes[0].audioOut[3])
        var b = try #require(runtime.nodes[1].audioOut[3])
        var out = try #require(runtime.nodes[2].audioOut[32])
        for i in stride(from: 0, to: Self.frames, by: 31) {
            #expect(abs(out[i] - (a[i] + b[i])) < 1e-4, "unity sum sample \(i)")
        }

        runtime.nodes[2].params[gain2] = 2.0 / 3.0  // −20 dB → 0.1×
        renderBlock(runtime)
        a = try #require(runtime.nodes[0].audioOut[3])
        b = try #require(runtime.nodes[1].audioOut[3])
        out = try #require(runtime.nodes[2].audioOut[32])
        for i in stride(from: 0, to: Self.frames, by: 31) {
            #expect(abs(out[i] - (a[i] + 0.1 * b[i])) < 1e-4, "gained sum sample \(i)")
        }
    }

    @Test func audioMixerStereoPanning() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let mixer = try #require(document.addModule(typeID: 76, at: .zero))
        document.setOption(mixer.id, optionIndex: 1, byte: 1)  // stereo
        document.setOption(mixer.id, optionIndex: 2, byte: 1)  // panning on
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: mixer.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let gain1 = try paramIndex(runtime, node: 1, position: 16)
        let pan1 = try paramIndex(runtime, node: 1, position: 24)
        runtime.nodes[1].params[gain1] = 5.0 / 6.0  // 0 dB

        runtime.nodes[1].params[pan1] = 0  // mono source hard left
        renderBlock(runtime)
        var input = try #require(runtime.nodes[0].audioOut[3])
        var outL = try #require(runtime.nodes[1].audioOut[32])
        for i in stride(from: 0, to: Self.frames, by: 31) {
            #expect(abs(outL[i] - input[i]) < 1e-4, "hard-left L sample \(i)")
        }
        #expect(runtime.nodes[1].audioOut[33]?.map(abs).max() ?? 1 < 1e-6)

        runtime.nodes[1].params[pan1] = 1  // hard right
        renderBlock(runtime)
        input = try #require(runtime.nodes[0].audioOut[3])
        outL = try #require(runtime.nodes[1].audioOut[32])
        let outR = try #require(runtime.nodes[1].audioOut[33])
        for i in stride(from: 0, to: Self.frames, by: 31) {
            #expect(abs(outR[i] - input[i]) < 1e-4, "hard-right R sample \(i)")
        }
        #expect(outL.map(abs).max() ?? 1 < 1e-6)
    }

    // MARK: - 78 Diffuser

    @Test func diffuserIsPureDelayAtZeroGainAndStableAtHighGain() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let diff = try #require(document.addModule(typeID: 78, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        // gain 0, size 0 → 80 samples, width min, rate 0 → static delay.
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: diff.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var input: [Float] = []
        var output: [Float] = []
        for _ in 0..<4 {
            renderBlock(runtime)
            input += runtime.nodes[0].audioOut[3] ?? []
            output += runtime.nodes[1].audioOut[5] ?? []
        }
        for i in stride(from: 80, to: input.count, by: 29) {
            #expect(abs(output[i] - input[i - 80]) < 1e-4, "sample \(i)")
        }

        // Full gain must stay bounded (allpass, not a runaway comb).
        let gainIdx = try paramIndex(runtime, node: 1, position: 1)
        runtime.nodes[1].params[gainIdx] = 1
        var peak: Float = 0
        for _ in 0..<100 {
            renderBlock(runtime)
            let block = runtime.nodes[1].audioOut[5] ?? []
            peak = max(peak, block.map(abs).max() ?? 0)
            #expect(block.allSatisfy { $0.isFinite })
        }
        #expect(peak < 10, "diffuser peak \(peak)")
    }

    // MARK: - 83 Granular

    @Test func granularProducesGrainsAndFreezeSilencesEmptyBuffer() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let gran = try #require(document.addModule(typeID: 83, at: .zero))
        document.setOption(gran.id, optionIndex: 0, byte: 3)  // 4 grains
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: gran.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[1]
        node.params[try paramIndex(runtime, node: 1, position: 2)] = 0.1  // grain size
        node.params[try paramIndex(runtime, node: 1, position: 3)] = 0.1  // position
        node.params[try paramIndex(runtime, node: 1, position: 4)] = 0.8  // density
        node.params[try paramIndex(runtime, node: 1, position: 5)] = 0.5  // texture
        node.params[try paramIndex(runtime, node: 1, position: 6)] = 0.5  // unity speed

        var tail: [Float] = []
        for block in 0..<50 {  // 0.5 s
            renderBlock(runtime)
            if block >= 30 { tail += node.audioOut[8] ?? [] }
        }
        let rms = (tail.reduce(Float(0)) { $0 + $1 * $1 } / Float(tail.count)).squareRoot()
        #expect(rms > 0.005, "granular RMS \(rms)")
        #expect(tail.allSatisfy { $0.isFinite })
        // Mono option mirrors the left output on the right block.
        #expect(node.audioOut[9] == node.audioOut[8])

        // Frozen from the very first render: the buffer never fills, so the
        // module stays silent.
        let frozenRuntime = PatchRuntime(document: document, sampleRate: 48000)
        let frozen = frozenRuntime.nodes[1]
        frozen.params[try paramIndex(frozenRuntime, node: 1, position: 7)] = 1
        for _ in 0..<10 { renderBlock(frozenRuntime) }
        #expect(frozen.audioOut[8]?.allSatisfy { $0 == 0 } == true)
    }

    // MARK: - 102 Sampler

    @Test func samplerRecordsThenPlaysBackOnce() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let sampler = try #require(document.addModule(typeID: 102, at: .zero))
        document.setOption(sampler.id, optionIndex: 0, byte: 1)  // record: new sample
        document.setOption(sampler.id, optionIndex: 3, byte: 1)  // cv outputs on
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: sampler.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[1]
        let recIdx = try paramIndex(runtime, node: 1, position: 2)
        let playIdx = try paramIndex(runtime, node: 1, position: 3)
        node.params[try paramIndex(runtime, node: 1, position: 4)] = 0.5  // unity speed
        node.params[try paramIndex(runtime, node: 1, position: 6)] = 0    // start 0
        node.params[try paramIndex(runtime, node: 1, position: 7)] = 1    // full length

        // Record 4 blocks while the gate is high.
        var recorded: [Float] = []
        node.params[recIdx] = 1
        for _ in 0..<4 {
            renderBlock(runtime)
            recorded += runtime.nodes[0].audioOut[3] ?? []
        }
        node.params[recIdx] = 0
        renderBlock(runtime)  // falling edge closes the sample

        // Trigger playback: the whole selection plays once, then stops.
        node.params[playIdx] = 1
        var playback: [Float] = []
        var sawEndPulse = false
        var positions: [Float] = []
        for _ in 0..<6 {
            renderBlock(runtime)
            playback += node.audioOut[10] ?? []
            if node.cvOut[9] == 1 { sawEndPulse = true }
            positions.append(node.cvOut[8] ?? -1)
        }
        for i in stride(from: 0, to: recorded.count, by: 41) {
            #expect(abs(playback[i] - recorded[i]) < 1e-5, "sample \(i)")
        }
        #expect(playback[recorded.count...].allSatisfy { $0 == 0 },
                "trigger mode must stop after the selection")
        #expect(sawEndPulse, "loop end cv out never pulsed")
        #expect(positions[1] > 0.2 && positions[1] < 0.6,
                "position cv \(positions[1]) after two blocks")
        // Left and right outputs mirror a mono recording.
        #expect(node.audioOut[11] == node.audioOut[10])
    }
}
