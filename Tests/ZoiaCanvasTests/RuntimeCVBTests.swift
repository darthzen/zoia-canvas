import Foundation
import Testing
@testable import ZoiaCanvas

/// Runtime coverage for the CV utility group (PatchRuntime+CVB):
/// IDs 10, 17, 18, 19, 22, 28, 31, 32, 45, 46, 48, 49, 50, 51, 52,
/// 77, 104, 105. Tests drive params directly on the runtime's nodes
/// (Node is a reference type) so edge timing is fully deterministic.
/// All timing math assumes 64-frame blocks at 48 kHz: dt = 1/750 s.
@Suite @MainActor struct RuntimeCVBTests {
    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// Renders `blocks` control blocks of 64 frames.
    private func render(_ runtime: PatchRuntime, _ blocks: Int = 1) {
        var left = [Float](repeating: 0, count: 64)
        var right = left
        for _ in 0..<blocks {
            runtime.render(frames: 64, outputL: &left, outputR: &right)
        }
    }

    // MARK: - 10 Sample and Hold

    @Test func sampleAndHoldSamplesOnTriggerEdge() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 10, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]

        node.params[0] = 0.3  // cv input
        render(runtime)
        #expect(node.cvOut[2] == 0, "holds initial 0 before any trigger")

        node.params[1] = 1  // trigger rising edge
        render(runtime)
        #expect(abs((node.cvOut[2] ?? -1) - 0.3) < 0.001)

        node.params[0] = 0.8
        render(runtime)
        #expect(abs((node.cvOut[2] ?? -1) - 0.3) < 0.001,
                "held while trigger stays high")

        node.params[1] = 0
        render(runtime)
        node.params[1] = 1
        render(runtime)
        #expect(abs((node.cvOut[2] ?? -1) - 0.8) < 0.001,
                "re-armed trigger samples the new input")
    }

    @Test func sampleAndHoldTrackMode() throws {
        let document = try makeDocument()
        let sh = try #require(document.addModule(typeID: 10, at: .zero))
        document.setOption(sh.id, optionIndex: 0, byte: 1)  // track & hold on
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]

        node.params[0] = 0.4
        render(runtime)
        #expect(abs((node.cvOut[2] ?? -1) - 0.4) < 0.001,
                "tracks input while trigger is low")

        node.params[1] = 1
        render(runtime)
        node.params[0] = 0.9
        render(runtime)
        #expect(abs((node.cvOut[2] ?? -1) - 0.4) < 0.001,
                "holds sampled value while trigger is high")

        node.params[1] = 0
        render(runtime)
        #expect(abs((node.cvOut[2] ?? -1) - 0.9) < 0.001,
                "follows input again when trigger falls")
    }

    // MARK: - 17 CV Invert / 51 CV Rectify / 45 Value

    @Test func cvInvertNegatesInput() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 17, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        runtime.nodes[0].params[0] = 0.25
        render(runtime)
        #expect(abs((runtime.nodes[0].cvOut[1] ?? 0) + 0.25) < 0.001)
    }

    @Test func valueOutputRangeOption() throws {
        let document = try makeDocument()
        let uni = try #require(document.addModule(typeID: 45, at: .zero))
        let bi = try #require(document.addModule(typeID: 45, at: .zero))
        document.setOption(bi.id, optionIndex: 0, byte: 1)  // -1 to 1
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        runtime.nodes[0].params[0] = 0.25
        runtime.nodes[1].params[0] = 0.25
        render(runtime)
        _ = uni
        #expect(abs((runtime.nodes[0].cvOut[1] ?? -9) - 0.25) < 0.001)
        #expect(abs((runtime.nodes[1].cvOut[1] ?? -9) + 0.5) < 0.001,
                "bipolar dial: 0.25 maps to -0.5")
    }

    @Test func cvRectifyFlipsNegativeValues() throws {
        let document = try makeDocument()
        let value = try #require(document.addModule(typeID: 45, at: .zero))
        let rectify = try #require(document.addModule(typeID: 51, at: .zero))
        document.setOption(value.id, optionIndex: 0, byte: 1)  // -1 to 1
        document.setParam(value.id, paramIndex: 0, fraction: 0.25)  // → -0.5
        document.connect(
            from: PortRef(module: value.id, blockPosition: 1, type: .cvOut),
            to: PortRef(module: rectify.id, blockPosition: 0, type: .cvIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime)
        #expect(abs((runtime.nodes[1].cvOut[1] ?? 0) - 0.5) < 0.001,
                "-0.5 rectifies to +0.5")
    }

    // MARK: - 18 Steps

    @Test func stepsQuantizesWaveCycle() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 18, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        node.params[1] = 2.0 / 61.0  // quant steps = 4

        // Drive a 100-block triangle (one rising 0.5-crossing per cycle).
        func triangle(_ block: Int) -> Float {
            let t = Float(block % 100) / 100
            return t < 0.5 ? t * 2 : 2 - t * 2
        }
        // Two warm-up cycles establish the tempo.
        for block in 0..<200 {
            node.params[0] = triangle(block)
            render(runtime)
        }
        var changes = 0
        var last = node.cvOut[2] ?? 0
        for block in 200..<300 {
            node.params[0] = triangle(block)
            render(runtime)
            let out = node.cvOut[2] ?? 0
            #expect(out >= 0 && out <= 1)
            if out != last { changes += 1 }
            last = out
        }
        #expect(changes >= 3 && changes <= 6,
                "4 steps per cycle expected, saw \(changes) changes")
    }

    // MARK: - 19 Slew Limiter

    @Test func slewLimiterRampsLinearly() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 19, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        node.params[0] = 1.0  // input steps to 1
        node.params[1] = 0.5  // slew rate dial → 0.77 s full range

        render(runtime, 100)  // 0.1333 s
        let early = node.cvOut[4] ?? -1
        #expect(abs(Double(early) - 0.1333 / 0.77) < 0.02, "linear ramp, got \(early)")
        render(runtime, 189)  // total 0.3853 s ≈ halfway
        let half = node.cvOut[4] ?? -1
        #expect(abs(Double(half) - 0.5) < 0.02, "got \(half)")

        node.params[1] = 0  // dial 0 → instant
        node.params[0] = 0.2
        render(runtime)
        #expect(abs((node.cvOut[4] ?? -1) - 0.2) < 0.001, "zero slew time jumps")
    }

    @Test func slewLimiterSeparateRiseFall() throws {
        let document = try makeDocument()
        let slew = try #require(document.addModule(typeID: 19, at: .zero))
        document.setOption(slew.id, optionIndex: 0, byte: 1)  // separate
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        // params: [input, rising lag, falling lag]
        node.params[0] = 1.0
        node.params[1] = 0    // instant rise
        node.params[2] = 0.5  // 0.77 s fall
        render(runtime)
        #expect(node.cvOut[4] == 1, "instant rise")

        node.params[0] = 0
        render(runtime, 75)  // 0.1 s of fall
        let fallen = node.cvOut[4] ?? -1
        #expect(abs(Double(fallen) - (1 - 0.1 / 0.77)) < 0.02, "got \(fallen)")
    }

    // MARK: - 22 Multiplier

    @Test func multiplierMultipliesAllInputs() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 22, at: .zero))
        let four = try #require(document.addModule(typeID: 22, at: .zero))
        document.setOption(four.id, optionIndex: 0, byte: 2)  // 4 inputs
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        runtime.nodes[0].params[0] = 0.5
        runtime.nodes[0].params[1] = 0.5
        for i in 0..<4 { runtime.nodes[1].params[i] = [0.5, 0.5, 1.0, 1.0][i] }
        render(runtime)
        #expect(abs((runtime.nodes[0].cvOut[8] ?? 0) - 0.25) < 0.001)
        #expect(abs((runtime.nodes[1].cvOut[8] ?? 0) - 0.25) < 0.001)

        runtime.nodes[1].params[3] = 0
        render(runtime)
        #expect(runtime.nodes[1].cvOut[8] == 0, "any zero input zeroes the product")
    }

    // MARK: - 28 Quantizer

    @Test func quantizerChromaticSnapsToNearestNote() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 28, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]

        node.params[0] = 60.4 / 127
        render(runtime)
        #expect(abs((node.cvOut[1] ?? 0) - 60.0 / 127) < 0.001)

        node.params[0] = 60.6 / 127
        render(runtime)
        #expect(abs((node.cvOut[1] ?? 0) - 61.0 / 127) < 0.001)
    }

    @Test func quantizerKeyAndScaleJacks() throws {
        let document = try makeDocument()
        let quant = try #require(document.addModule(typeID: 28, at: .zero))
        document.setOption(quant.id, optionIndex: 0, byte: 1)  // key/scale jacks
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        // params: [input, key, scale]. Key C = zone 3 of A…G#; major =
        // scale zone 1 of the 5 basic scales.
        node.params[1] = 3.5 / 12
        node.params[2] = 0.3

        node.params[0] = 61.4 / 127  // between C#4 and D4
        render(runtime)
        #expect(abs((node.cvOut[1] ?? 0) - 62.0 / 127) < 0.001, "snaps up to D")

        node.params[0] = 58.6 / 127
        render(runtime)
        #expect(abs((node.cvOut[1] ?? 0) - 59.0 / 127) < 0.001, "snaps to B")
    }

    @Test func quantizerExtendedScales() throws {
        let document = try makeDocument()
        let quant = try #require(document.addModule(typeID: 28, at: .zero))
        document.setOption(quant.id, optionIndex: 0, byte: 1)  // jacks
        document.setOption(quant.id, optionIndex: 1, byte: 1)  // extended
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        node.params[1] = 0.02          // key A
        node.params[2] = 11.5 / 13     // minor pentatonic (scale 11 of 13)
        node.params[0] = 70.6 / 127
        render(runtime)
        // A minor pentatonic pitch classes {9,0,2,4,7}: nearest is 72.
        #expect(abs((node.cvOut[1] ?? 0) - 72.0 / 127) < 0.001)
    }

    // MARK: - 31 In Switch / 32 Out Switch

    @Test func inSwitchSelectsBySelectCV() throws {
        let document = try makeDocument()
        let sw = try #require(document.addModule(typeID: 31, at: .zero))
        document.setOption(sw.id, optionIndex: 0, byte: 3)  // 4 inputs
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        for i in 0..<4 { node.params[i] = [0.1, 0.2, 0.3, 0.4][i] }

        node.params[4] = 0.6  // zone 2 of 4 → input 3
        render(runtime)
        #expect(abs((node.cvOut[17] ?? 0) - 0.3) < 0.001)

        node.params[4] = 0.05  // zone 0 → input 1
        render(runtime)
        #expect(abs((node.cvOut[17] ?? 0) - 0.1) < 0.001)
    }

    @Test func outSwitchRoutesToSelectedOutput() throws {
        let document = try makeDocument()
        let sw = try #require(document.addModule(typeID: 32, at: .zero))
        document.setOption(sw.id, optionIndex: 0, byte: 3)  // 4 outputs
        let single = try #require(document.addModule(typeID: 32, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        let node = runtime.nodes[0]
        node.params[0] = 0.7  // input
        node.params[1] = 0.3  // select zone 1 → output 2 (position 3)
        let one = runtime.nodes[1]
        one.params[0] = 0.7
        one.params[1] = 0  // single output, select 0 = off
        render(runtime)
        _ = single
        #expect(node.cvOut[2] == 0)
        #expect(abs((node.cvOut[3] ?? 0) - 0.7) < 0.001)
        #expect(node.cvOut[4] == 0)
        #expect(one.cvOut[2] == 0, "single-output switch is off at select 0")

        one.params[1] = 0.5
        render(runtime)
        #expect(abs((one.cvOut[2] ?? 0) - 0.7) < 0.001, "select above 0 turns it on")
    }

    // MARK: - 46 CV Delay

    @Test func cvDelayDelaysByLinearTime() throws {
        let document = try makeDocument()
        let delay = try #require(document.addModule(typeID: 46, at: .zero))
        document.setOption(delay.id, optionIndex: 0, byte: 1)  // linear dial
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        // 20 control blocks = 26.67 ms; linear dial spans 0…60 s.
        node.params[1] = Float((20.0 / 750.0) / 60.0)

        render(runtime, 3)
        node.params[0] = 1.0
        render(runtime, 10)
        #expect(node.cvOut[2] == 0, "step has not reached the output yet")
        render(runtime, 15)
        #expect(node.cvOut[2] == 1, "step arrives after ~20 blocks")
    }

    @Test func cvDelayExponentDialMinimum() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 46, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        node.params[0] = 0.6  // dial at 0 → 1.33 ms ≈ one block
        render(runtime, 2)
        #expect(abs((node.cvOut[2] ?? 0) - 0.6) < 0.001)
    }

    // MARK: - 48 CV Filter

    @Test func cvFilterReaches63PercentAtTimeConstant() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 48, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        node.params[0] = 1.0
        node.params[1] = 0.5  // dial → 283 ms
        render(runtime, 212)  // ≈ 0.283 s
        let out = Double(node.cvOut[2] ?? -1)
        #expect(abs(out - 0.632) < 0.035, "one tau ≈ 63%, got \(out)")
    }

    @Test func cvFilterSeparateRiseFall() throws {
        let document = try makeDocument()
        let filter = try #require(document.addModule(typeID: 48, at: .zero))
        document.setOption(filter.id, optionIndex: 0, byte: 1)  // separate
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        // params: [input, rise constant, fall constant]
        node.params[0] = 1.0
        node.params[1] = 0    // 1.33 ms rise ≈ instant at block rate
        node.params[2] = 0.5  // 283 ms fall
        render(runtime, 2)
        #expect((node.cvOut[2] ?? 0) > 0.99, "fast rise")

        node.params[0] = 0
        render(runtime, 212)
        let out = Double(node.cvOut[2] ?? -1)
        #expect(abs(out - 0.368) < 0.035, "one tau of decay ≈ 37%, got \(out)")
    }

    // MARK: - 49 Clock Divider

    /// Promotes a freshly added module to version 1 (dividend/divisor
    /// layout) — addModule creates version-0 modules.
    private func promoteToV1(_ document: PatchDocument, _ id: UUID) {
        if let index = document.modules.firstIndex(where: { $0.id == id }) {
            document.modules[index].version = 1
        }
        document.setOption(id, optionIndex: 0, byte: 0)  // re-size params
    }

    @Test func clockDividerDividesTapTempo() throws {
        let document = try makeDocument()
        let divider = try #require(document.addModule(typeID: 49, at: .zero))
        promoteToV1(document, divider.id)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        // params: [input, reset, dividend, divisor]; divisor dial → 2.
        node.params[3] = 1.0 / 31.0

        // Tap every 20 blocks for 600 blocks; expect ticks every 40.
        var ticks = 0
        for block in 0..<600 {
            node.params[0] = block % 20 == 0 ? 1 : 0
            render(runtime)
            if node.cvOut[3] == 1 { ticks += 1 }
        }
        #expect(ticks >= 10 && ticks <= 16, "expected ~14 divided ticks, got \(ticks)")

        // Reset halts the free-running clock until the next tap.
        node.params[0] = 0
        node.params[1] = 1
        render(runtime)
        node.params[1] = 0
        var haltedTicks = 0
        for _ in 0..<100 {
            render(runtime)
            if node.cvOut[3] == 1 { haltedTicks += 1 }
        }
        #expect(haltedTicks == 0, "no output while halted")

        node.params[0] = 1  // new tap resumes
        var resumedTicks = 0
        for _ in 0..<50 {
            render(runtime)
            if node.cvOut[3] == 1 { resumedTicks += 1 }
            node.params[0] = 0
        }
        #expect(resumedTicks >= 1, "tap after reset restarts the clock")
    }

    @Test func clockDividerCVControlFrequency() throws {
        let document = try makeDocument()
        let divider = try #require(document.addModule(typeID: 49, at: .zero))
        promoteToV1(document, divider.id)
        document.setOption(divider.id, optionIndex: 0, byte: 1)  // cv_control
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        node.params[0] = 0.25  // 10 Hz of the 0…40 Hz dial

        var ticks = 0
        for _ in 0..<750 {  // one second
            render(runtime)
            if node.cvOut[3] == 1 { ticks += 1 }
        }
        #expect(ticks >= 9 && ticks <= 11, "10 Hz clock, got \(ticks)")
    }

    @Test func clockDividerVersionZeroModifier() throws {
        let document = try makeDocument()
        let divider = try #require(document.addModule(typeID: 49, at: .zero))
        document.setOption(divider.id, optionIndex: 0, byte: 1)  // cv_control
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        // v0 params: [input, reset, modifier]; modifier dial → divide by 2.
        node.params[0] = 0.25       // 10 Hz
        node.params[2] = 1.0 / 31.0

        var ticks = 0
        for _ in 0..<750 {
            render(runtime)
            if node.cvOut[3] == 1 { ticks += 1 }
        }
        #expect(ticks >= 4 && ticks <= 6, "10 Hz / 2, got \(ticks)")
    }

    // MARK: - 50 Comparator

    @Test func comparatorSwitchesAtThreshold() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 50, at: .zero))
        let bipolar = try #require(document.addModule(typeID: 50, at: .zero))
        document.setOption(bipolar.id, optionIndex: 0, byte: 1)  // -1 to 1
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        for node in [runtime.nodes[0], runtime.nodes[1]] {
            node.params[0] = 0.6
            node.params[1] = 0.4
        }
        render(runtime)
        #expect(runtime.nodes[0].cvOut[2] == 1)
        #expect(runtime.nodes[1].cvOut[2] == 1)

        for node in [runtime.nodes[0], runtime.nodes[1]] { node.params[0] = 0.2 }
        render(runtime)
        #expect(runtime.nodes[0].cvOut[2] == 0)
        #expect(runtime.nodes[1].cvOut[2] == -1, "bipolar low state is -1")

        for node in [runtime.nodes[0], runtime.nodes[1]] { node.params[0] = 0.4 }
        render(runtime)
        #expect(runtime.nodes[0].cvOut[2] == 1, "equal inputs read as on")
    }

    // MARK: - 52 Trigger / 77 CV Flip Flop

    @Test func triggerEmitsOneBlockPulse() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 52, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]

        render(runtime)
        #expect(node.cvOut[1] == 0)
        node.params[0] = 1
        render(runtime)
        #expect(node.cvOut[1] == 1, "pulse on the rising edge")
        render(runtime)
        #expect(node.cvOut[1] == 0, "pulse lasts one control block")
        node.params[0] = 0
        render(runtime)
        node.params[0] = 1
        render(runtime)
        #expect(node.cvOut[1] == 1, "re-armed after the input falls")
    }

    @Test func flipFlopTogglesOnRisingEdges() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 77, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]

        node.params[0] = 1
        render(runtime)
        #expect(node.cvOut[1] == 1, "first rising edge sets the output")
        render(runtime)
        #expect(node.cvOut[1] == 1, "state latches while high")
        node.params[0] = 0
        render(runtime)
        #expect(node.cvOut[1] == 1, "state latches through low input")
        node.params[0] = 1
        render(runtime)
        #expect(node.cvOut[1] == 0, "second rising edge clears it")
    }

    // MARK: - 104 CV Mixer

    @Test func cvMixerAttenuvertsAndSums() throws {
        let document = try makeDocument()
        let mixer = try #require(document.addModule(typeID: 104, at: .zero))
        document.setOption(mixer.id, optionIndex: 0, byte: 1)  // 2 channels
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        // params: [in1, in2, atten1, atten2]
        node.params[0] = 0.5
        node.params[1] = 0.5
        node.params[2] = 1.0  // gain +1
        node.params[3] = 0.0  // gain -1
        render(runtime)
        #expect(abs(node.cvOut[16] ?? -1) < 0.001, "+0.5 and -0.5 cancel")

        node.params[3] = 0.5  // gain 0 mutes channel 2
        render(runtime)
        #expect(abs((node.cvOut[16] ?? 0) - 0.5) < 0.001)

        node.params[0] = 0.8
        node.params[1] = 0.8
        node.params[3] = 1.0
        render(runtime)
        #expect(node.cvOut[16] == 1, "summing mode clips 1.6 to 1")
    }

    @Test func cvMixerAverageMode() throws {
        let document = try makeDocument()
        let mixer = try #require(document.addModule(typeID: 104, at: .zero))
        document.setOption(mixer.id, optionIndex: 0, byte: 1)  // 2 channels
        document.setOption(mixer.id, optionIndex: 1, byte: 1)  // average
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        node.params[0] = 0.8
        node.params[1] = 0.8
        node.params[2] = 1.0
        node.params[3] = 1.0
        render(runtime)
        #expect(abs((node.cvOut[16] ?? 0) - 0.8) < 0.001, "mean avoids clipping")
    }

    // MARK: - 105 Logic Gate

    @Test func logicGateOperations() throws {
        let document = try makeDocument()
        for byte in [0, 1, 4, 6] {  // AND, OR, XOR, NOT
            let gate = try #require(document.addModule(typeID: 105, at: .zero))
            document.setOption(gate.id, optionIndex: 0, byte: UInt8(byte))
        }
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        runtime.nodes[0].params[0] = 1  // AND: 1,1
        runtime.nodes[0].params[1] = 1
        runtime.nodes[1].params[1] = 1  // OR: 0,1
        runtime.nodes[2].params[0] = 1  // XOR: 1,1
        runtime.nodes[2].params[1] = 1
        render(runtime)
        #expect(runtime.nodes[0].cvOut[39] == 1, "AND(1,1)")
        #expect(runtime.nodes[1].cvOut[39] == 1, "OR(0,1)")
        #expect(runtime.nodes[2].cvOut[39] == 0, "XOR(1,1)")
        #expect(runtime.nodes[3].cvOut[39] == 1, "NOT(0)")

        runtime.nodes[0].params[1] = 0
        runtime.nodes[2].params[1] = 0
        runtime.nodes[3].params[0] = 1
        render(runtime)
        #expect(runtime.nodes[0].cvOut[39] == 0, "AND(1,0)")
        #expect(runtime.nodes[2].cvOut[39] == 1, "XOR(1,0)")
        #expect(runtime.nodes[3].cvOut[39] == 0, "NOT(1)")
    }

    @Test func logicGateVariableInputsAndThreshold() throws {
        let document = try makeDocument()
        let wide = try #require(document.addModule(typeID: 105, at: .zero))
        document.setOption(wide.id, optionIndex: 1, byte: 2)  // 4 inputs, AND
        let thresholded = try #require(document.addModule(typeID: 105, at: .zero))
        document.setOption(thresholded.id, optionIndex: 2, byte: 1)  // threshold on
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        let and4 = runtime.nodes[0]
        for i in 0..<4 { and4.params[i] = 1 }
        let gate = runtime.nodes[1]
        // params: [in1, in2, threshold] — 0.4 is high against 0.3.
        gate.params[0] = 0.4
        gate.params[1] = 0.35
        gate.params[2] = 0.3
        render(runtime)
        #expect(and4.cvOut[39] == 1, "AND across 4 inputs")
        #expect(gate.cvOut[39] == 1, "custom threshold 0.3 reads 0.4/0.35 as high")

        and4.params[2] = 0
        gate.params[2] = 0.5
        render(runtime)
        #expect(and4.cvOut[39] == 0, "one low input breaks a 4-way AND")
        #expect(gate.cvOut[39] == 0, "raised threshold reads them as low")
    }
}
