import Foundation
import Testing
@testable import ZoiaCanvas

/// Runtime coverage for the Audio A group (SV Filter, Aliaser, VCA,
/// Audio Multiply, Bit Crusher, Oscillator, Multi Filter, All Pass,
/// Noise, Bit Modulator, Inverter) and the Analysis group (Env Follower,
/// Onset Detector, Pitch Detector).
@Suite @MainActor struct RuntimeAudioATests {
    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// CV fraction whose pitch mapping lands on `hz`.
    private func cvForHz(_ hz: Double) -> Double {
        (69 + 12 * log2(hz / 440)) / 127
    }

    private func rms(_ xs: [Float]) -> Float {
        guard !xs.isEmpty else { return 0 }
        return sqrt(xs.reduce(0) { $0 + $1 * $1 } / Float(xs.count))
    }

    private func render(_ runtime: PatchRuntime, blocks: Int, frames: Int = 480) {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        for _ in 0..<blocks { runtime.render(frames: frames, outputL: &left, outputR: &right) }
    }

    // MARK: - 0 SV Filter

    /// A 2 kHz tone through a 200 Hz SVF: lowpass out is attenuated,
    /// hipass out passes nearly unchanged.
    @Test func svFilterSeparatesBands() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let svf = try #require(document.addModule(typeID: 0, at: .zero))
        document.setOption(svf.id, optionIndex: 1, byte: 1)  // hipass out on
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(2000))
        document.setParam(svf.id, paramIndex: 0, fraction: cvForHz(200))
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: svf.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 20)  // settle
        render(runtime, blocks: 1)
        let input = rms(runtime.nodes[0].audioOut[3] ?? [])
        let low = rms(runtime.nodes[1].audioOut[3] ?? [])
        let high = rms(runtime.nodes[1].audioOut[4] ?? [])
        #expect(input > 0.5)
        #expect(low < input * 0.15, "lowpass rms \(low) vs input \(input)")
        #expect(high > input * 0.6, "hipass rms \(high) vs input \(input)")
    }

    /// Bandpass output passes a tone at the cutoff and rejects one three
    /// octaves above it; the option-gated outputs exist only when enabled.
    @Test func svFilterBandpassPeaksAtCutoff() throws {
        func bandpassRMS(inputHz: Double) throws -> (input: Float, band: Float, node: PatchRuntime.Node) {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let svf = try #require(document.addModule(typeID: 0, at: .zero))
            document.setOption(svf.id, optionIndex: 2, byte: 1)  // bandpass on
            document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(inputHz))
            document.setParam(svf.id, paramIndex: 0, fraction: cvForHz(300))
            document.setParam(svf.id, paramIndex: 1, fraction: 0.5)  // resonance
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: svf.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            render(runtime, blocks: 30)
            render(runtime, blocks: 1)
            return (rms(runtime.nodes[0].audioOut[3] ?? []),
                    rms(runtime.nodes[1].audioOut[5] ?? []),
                    runtime.nodes[1])
        }
        let center = try bandpassRMS(inputHz: 300)
        let far = try bandpassRMS(inputHz: 2400)
        #expect(center.band > center.input * 0.5, "center band \(center.band)")
        #expect(far.band < far.input * 0.3, "far band \(far.band)")
        // Hipass was never enabled: its output block is absent.
        #expect(center.node.audioOut[4] == nil)
    }

    // MARK: - 3 Aliaser

    /// At zero samples the aliaser is silent; raising the amount produces
    /// the "imperfection" signal.
    @Test func aliaserAmountControlsOutput() throws {
        func aliaserRMS(amount: Double) throws -> Float {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let alias = try #require(document.addModule(typeID: 3, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
            document.setParam(alias.id, paramIndex: 0, fraction: amount)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: alias.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            render(runtime, blocks: 10)
            render(runtime, blocks: 1)
            return rms(runtime.nodes[1].audioOut[2] ?? [])
        }
        #expect(try aliaserRMS(amount: 0) < 0.01)
        #expect(try aliaserRMS(amount: 0.5) > 0.05)
    }

    // MARK: - 7 VCA

    /// Stereo option: both channels scale by the shared level control.
    @Test func vcaStereoScalesBothChannels() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let vca = try #require(document.addModule(typeID: 7, at: .zero))
        document.setOption(vca.id, optionIndex: 0, byte: 1)  // stereo
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
        document.setParam(vca.id, paramIndex: 0, fraction: 0.5)  // level
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: vca.id, blockPosition: 1, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 5)
        let peakL = (runtime.nodes[1].audioOut[3] ?? []).map(abs).max() ?? 0
        let peakR = (runtime.nodes[1].audioOut[4] ?? []).map(abs).max() ?? 0
        #expect(peakL > 0.4 && peakL < 0.6, "left peak \(peakL)")
        #expect(peakR > 0.4 && peakR < 0.6, "right peak \(peakR)")
    }

    // MARK: - 8 Audio Multiply

    /// Feeding the same signal to both inputs squares it sample-exactly.
    @Test func audioMultiplySquaresSignal() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let mult = try #require(document.addModule(typeID: 8, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
        for block in [0, 1] {
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: mult.id, blockPosition: block, type: .audioIn))
        }
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 3)
        let input = try #require(runtime.nodes[0].audioOut[3])
        let out = try #require(runtime.nodes[1].audioOut[2])
        for i in 0..<input.count {
            #expect(abs(out[i] - input[i] * input[i]) < 1e-5)
        }
    }

    // MARK: - 9 Bit Crusher

    /// Heavy crushing collapses a sine onto a handful of quantizer steps,
    /// and the fractions option changes the result for non-whole depths.
    @Test func bitCrusherQuantizesAndFractionsMatter() throws {
        func crush(fraction: Double, fractionsOn: Bool) throws -> [Float] {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let crusher = try #require(document.addModule(typeID: 9, at: .zero))
            if fractionsOn { document.setOption(crusher.id, optionIndex: 0, byte: 1) }
            document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
            document.setParam(crusher.id, paramIndex: 0, fraction: fraction)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: crusher.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            render(runtime, blocks: 3)
            return runtime.nodes[1].audioOut[2] ?? []
        }
        // 20 bits crushed of 24 → 4 effective bits → ≤17 distinct levels.
        let crushed = try crush(fraction: 20.0 / 31.0, fractionsOn: false)
        let distinct = Set(crushed.map { Int(($0 * 1000).rounded()) })
        #expect(distinct.count > 2 && distinct.count <= 17,
                "\(distinct.count) distinct levels")
        // A non-whole crush amount only differs when fractions are on.
        let whole = try crush(fraction: 20.5 / 31.0, fractionsOn: false)
        let fractional = try crush(fraction: 20.5 / 31.0, fractionsOn: true)
        #expect(zip(whole, fractional).contains { abs($0 - $1) > 1e-6 })
    }

    // MARK: - 14 Oscillator

    /// Duty cycle at 25% skews the square wave: mean ≈ −0.5.
    @Test func oscillatorDutyCycleSkewsSquare() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        document.setOption(osc.id, optionIndex: 0, byte: 1)  // square
        document.setOption(osc.id, optionIndex: 2, byte: 1)  // duty cycle on
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
        document.setParam(osc.id, paramIndex: 1, fraction: 0.25)  // duty

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var sum: Float = 0
        var count = 0
        var left = [Float](repeating: 0, count: 480)
        var right = left
        for _ in 0..<100 {
            runtime.render(frames: 480, outputL: &left, outputR: &right)
            for sample in runtime.nodes[0].audioOut[3] ?? [] {
                sum += sample
                count += 1
            }
        }
        let mean = sum / Float(count)
        #expect(abs(mean + 0.5) < 0.05, "mean \(mean)")
    }

    /// Wiring a modulator into the FM input audibly changes the output.
    @Test func oscillatorFMInputModulates() throws {
        func carrierBuffer(wireFM: Bool) throws -> [Float] {
            let document = try makeDocument()
            let mod = try #require(document.addModule(typeID: 14, at: .zero))
            let carrier = try #require(document.addModule(typeID: 14, at: .zero))
            document.setOption(carrier.id, optionIndex: 1, byte: 1)  // fm in on
            document.setParam(mod.id, paramIndex: 0, fraction: cvForHz(100))
            document.setParam(carrier.id, paramIndex: 0, fraction: cvForHz(440))
            if wireFM {
                document.connect(
                    from: PortRef(module: mod.id, blockPosition: 3, type: .audioOut),
                    to: PortRef(module: carrier.id, blockPosition: 1, type: .audioIn))
            }
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            render(runtime, blocks: 9)
            render(runtime, blocks: 1)
            return runtime.nodes[1].audioOut[3] ?? []
        }
        let plain = try carrierBuffer(wireFM: false)
        let modulated = try carrierBuffer(wireFM: true)
        let maxDiff = zip(plain, modulated).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDiff > 0.5, "max difference \(maxDiff)")
    }

    // MARK: - 24 Multi Filter

    /// Lowpass at 500 Hz rejects a 4 kHz tone; highpass passes it.
    @Test func multiFilterLowpassAndHighpass() throws {
        func filterRMS(shapeByte: UInt8) throws -> (input: Float, out: Float) {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let filter = try #require(document.addModule(typeID: 24, at: .zero))
            document.setOption(filter.id, optionIndex: 0, byte: shapeByte)
            document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(4000))
            document.setParam(filter.id, paramIndex: 0, fraction: cvForHz(500))  // freq
            document.setParam(filter.id, paramIndex: 1, fraction: 0.1)  // q width
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: filter.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            render(runtime, blocks: 20)
            render(runtime, blocks: 1)
            return (rms(runtime.nodes[0].audioOut[3] ?? []),
                    rms(runtime.nodes[1].audioOut[4] ?? []))
        }
        let low = try filterRMS(shapeByte: 0)   // lowpass
        let high = try filterRMS(shapeByte: 3)  // highpass
        #expect(low.out < low.input * 0.2, "lowpass \(low.out) vs \(low.input)")
        #expect(high.out > high.input * 0.7, "highpass \(high.out) vs \(high.input)")
    }

    /// Bell with maximum gain boosts a tone at its center frequency; the
    /// gain block only exists for bell/shelf shapes.
    @Test func multiFilterBellBoostsAtCenter() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let filter = try #require(document.addModule(typeID: 24, at: .zero))
        document.setOption(filter.id, optionIndex: 0, byte: 2)  // bell
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(1000))
        document.setParam(filter.id, paramIndex: 0, fraction: 1.0)  // gain +24 dB
        document.setParam(filter.id, paramIndex: 1, fraction: cvForHz(1000))
        document.setParam(filter.id, paramIndex: 2, fraction: 0.1)  // q width
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: filter.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 30)
        render(runtime, blocks: 1)
        let input = rms(runtime.nodes[0].audioOut[3] ?? [])
        let out = rms(runtime.nodes[1].audioOut[4] ?? [])
        #expect(out > input * 2.5, "bell out \(out) vs input \(input)")
    }

    // MARK: - 27 All Pass Filter

    /// Magnitude is preserved while the waveform is phase shifted.
    @Test func allPassPreservesMagnitudeShiftsPhase() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let allpass = try #require(document.addModule(typeID: 27, at: .zero))
        document.setOption(allpass.id, optionIndex: 0, byte: 7)  // 8 poles
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(1000))
        // filter gain left at 0 → strongly negative coefficient.
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: allpass.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 30)
        render(runtime, blocks: 1)
        let input = try #require(runtime.nodes[0].audioOut[3])
        let out = try #require(runtime.nodes[1].audioOut[2])
        let inRMS = rms(input)
        let outRMS = rms(out)
        #expect(abs(outRMS - inRMS) < inRMS * 0.25,
                "rms in \(inRMS) out \(outRMS)")
        let diffRMS = rms(zip(input, out).map { $0 - $1 })
        #expect(diffRMS > inRMS * 0.2, "difference rms \(diffRMS)")
    }

    // MARK: - 38 Noise

    /// White noise has sane statistics, differs per node, and renders the
    /// same stream every run (deterministic seed).
    @Test func noiseIsDeterministicWhiteNoise() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 38, at: .zero))
        _ = try #require(document.addModule(typeID: 38, at: .zero))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 10, frames: 480)
        let a = try #require(runtime.nodes[0].audioOut[0])
        let b = try #require(runtime.nodes[1].audioOut[0])
        let level = rms(a)
        let mean = a.reduce(0, +) / Float(a.count)
        #expect(level > 0.4 && level < 0.75, "rms \(level)")
        #expect(abs(mean) < 0.08, "mean \(mean)")
        #expect((a.map(abs).max() ?? 2) <= 1)
        #expect(a != b, "both nodes emit the same stream")

        let runtime2 = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime2, blocks: 10, frames: 480)
        #expect(runtime2.nodes[0].audioOut[0] == a, "noise is not deterministic")
    }

    // MARK: - 63 Bit Modulator

    /// xor of a signal with itself is silence; and of a signal with
    /// itself is the signal.
    @Test func bitModulatorLogicTypes() throws {
        func modulate(typeByte: UInt8) throws -> (input: [Float], out: [Float]) {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let bitmod = try #require(document.addModule(typeID: 63, at: .zero))
            document.setOption(bitmod.id, optionIndex: 0, byte: typeByte)
            document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
            for block in [0, 1] {
                document.connect(
                    from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                    to: PortRef(module: bitmod.id, blockPosition: block, type: .audioIn))
            }
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            render(runtime, blocks: 3)
            return (runtime.nodes[0].audioOut[3] ?? [], runtime.nodes[1].audioOut[2] ?? [])
        }
        let xor = try modulate(typeByte: 0)
        #expect((xor.out.map(abs).max() ?? 1) < 1e-3, "xor(x,x) should be silent")
        let and = try modulate(typeByte: 1)
        let maxErr = zip(and.input, and.out).map { abs($0 - $1) }.max() ?? 1
        #expect(maxErr < 1e-3, "and(x,x) should pass the signal, err \(maxErr)")
    }

    // MARK: - 65 Inverter

    @Test func inverterFlipsPolarity() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let inverter = try #require(document.addModule(typeID: 65, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: inverter.id, blockPosition: 0, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 3)
        let input = try #require(runtime.nodes[0].audioOut[3])
        let out = try #require(runtime.nodes[1].audioOut[1])
        for i in 0..<input.count { #expect(out[i] == -input[i]) }
    }

    // MARK: - 12 Env Follower

    /// The follower tracks a gated burst up and back down (linear scale).
    @Test func envFollowerTracksBurst() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let vca = try #require(document.addModule(typeID: 7, at: .zero))
        let env = try #require(document.addModule(typeID: 12, at: .zero))
        document.setOption(env.id, optionIndex: 1, byte: 1)  // linear scale
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
        document.setParam(vca.id, paramIndex: 0, fraction: 1.0)  // level
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: vca.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: env.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 50)  // 0.5 s of signal
        let during = runtime.nodes[2].cvOut[3] ?? 0
        #expect(during > 0.4, "cv during burst \(during)")

        // Cut the VCA level: default fall (~150 ms) holds briefly then decays.
        let levelIndex = try #require(runtime.nodes[1].paramIndexByPosition[2])
        runtime.nodes[1].params[levelIndex] = 0
        render(runtime, blocks: 5)  // 50 ms of silence
        let shortly = runtime.nodes[2].cvOut[3] ?? 0
        #expect(shortly > 0.2, "cv shortly after burst \(shortly)")
        render(runtime, blocks: 100)  // 1 s of silence
        let after = runtime.nodes[2].cvOut[3] ?? 0
        #expect(after < 0.05, "cv after decay \(after)")
    }

    /// With the rise/fall option on, a long fall time slows the decay.
    @Test func envFollowerFallTimeBlockSlowsDecay() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let vca = try #require(document.addModule(typeID: 7, at: .zero))
        let env = try #require(document.addModule(typeID: 12, at: .zero))
        document.setOption(env.id, optionIndex: 0, byte: 1)  // rise/fall on
        document.setOption(env.id, optionIndex: 1, byte: 1)  // linear scale
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
        document.setParam(vca.id, paramIndex: 0, fraction: 1.0)
        document.setParam(env.id, paramIndex: 0, fraction: 0.0)   // rise 1 ms
        document.setParam(env.id, paramIndex: 1, fraction: 0.75)  // fall ~1 s
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: vca.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: env.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, blocks: 50)
        let levelIndex = try #require(runtime.nodes[1].paramIndexByPosition[2])
        runtime.nodes[1].params[levelIndex] = 0
        render(runtime, blocks: 30)  // 0.3 s of silence
        let held = runtime.nodes[2].cvOut[3] ?? 0
        #expect(held > 0.3, "long fall should still hold, cv \(held)")
    }

    // MARK: - 36 Onset Detector

    /// Two separated bursts produce exactly two trigger edges.
    @Test func onsetDetectorFiresPerBurst() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let vca = try #require(document.addModule(typeID: 7, at: .zero))
        let onset = try #require(document.addModule(typeID: 36, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
        document.setParam(vca.id, paramIndex: 0, fraction: 0.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: vca.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: onset.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let levelIndex = try #require(runtime.nodes[1].paramIndexByPosition[2])
        var edges = 0
        var lastGate: Float = 0
        func run(blocks: Int) {
            var left = [Float](repeating: 0, count: 480)
            var right = left
            for _ in 0..<blocks {
                runtime.render(frames: 480, outputL: &left, outputR: &right)
                let gate = runtime.nodes[2].cvOut[2] ?? 0
                if lastGate < 0.5, gate >= 0.5 { edges += 1 }
                lastGate = gate
            }
        }
        for _ in 0..<2 {
            runtime.nodes[1].params[levelIndex] = 1
            run(blocks: 10)  // 0.1 s burst
            runtime.nodes[1].params[levelIndex] = 0
            run(blocks: 30)  // 0.3 s silence
        }
        #expect(edges == 2, "saw \(edges) trigger edges")
    }

    /// The sensitivity block sets how quiet a burst may be and still fire.
    @Test func onsetDetectorSensitivityBlock() throws {
        func fires(sensitivity: Double) throws -> Bool {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let vca = try #require(document.addModule(typeID: 7, at: .zero))
            let onset = try #require(document.addModule(typeID: 36, at: .zero))
            document.setOption(onset.id, optionIndex: 0, byte: 1)  // sensitivity on
            document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(440))
            document.setParam(vca.id, paramIndex: 0, fraction: 0.3)  // quiet burst
            document.setParam(onset.id, paramIndex: 0, fraction: sensitivity)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
            document.connect(
                from: PortRef(module: vca.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: onset.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            var left = [Float](repeating: 0, count: 480)
            var right = left
            var fired = false
            for _ in 0..<20 {
                runtime.render(frames: 480, outputL: &left, outputR: &right)
                if (runtime.nodes[2].cvOut[2] ?? 0) >= 0.5 { fired = true }
            }
            return fired
        }
        #expect(try fires(sensitivity: 1.0), "high sensitivity should fire")
        #expect(try !fires(sensitivity: 0.0), "low sensitivity should stay quiet")
    }

    // MARK: - 58 Pitch Detector

    /// A sine at 440 Hz (and one at 880 Hz) is detected within a few Hz.
    @Test func pitchDetectorFindsSineFrequency() throws {
        func detect(hz: Double) throws -> Double {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let pitch = try #require(document.addModule(typeID: 58, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: cvForHz(hz))
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: pitch.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            render(runtime, blocks: 100)  // 1 s
            return PatchRuntime.pitchHz(runtime.nodes[1].cvOut[1] ?? 0)
        }
        let a4 = try detect(hz: 440)
        #expect(abs(a4 - 440) < 4, "detected \(a4) Hz for 440")
        let a5 = try detect(hz: 880)
        #expect(abs(a5 - 880) < 8, "detected \(a5) Hz for 880")
    }
}
