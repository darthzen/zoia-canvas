import Foundation
import Testing
@testable import ZoiaCanvas

/// Runtime tests for the drive/dynamics/EQ effect group — IDs 11, 23, 40,
/// 42, 66, 68, 72, 73. All patches are built through PatchDocument and
/// rendered offline; assertions read the effect node's audio output block.
@Suite @MainActor struct RuntimeEffectATests {
    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// Renders `blocks` control blocks and returns the samples the given
    /// node wrote to `block` during the last `keepLast` blocks.
    private func collect(_ runtime: PatchRuntime, node: Int, block: Int,
                         blocks: Int, keepLast: Int? = nil,
                         frames: Int = 480) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        let keepFrom = blocks - (keepLast ?? blocks)
        var kept: [Float] = []
        for i in 0..<blocks {
            runtime.render(frames: frames, outputL: &left, outputR: &right)
            if i >= keepFrom, let buffer = runtime.nodes[node].audioOut[block] {
                kept.append(contentsOf: buffer)
            }
        }
        return kept
    }

    private func rms(_ samples: [Float]) -> Double {
        samples.isEmpty ? 0
            : sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) }
                   / Double(samples.count))
    }

    /// Goertzel power at one frequency, normalized by window length².
    private func power(_ samples: [Float], hz: Double,
                       sampleRate: Double = 48000) -> Double {
        let coeff = 2 * cos(2 * Double.pi * hz / sampleRate)
        var s1 = 0.0, s2 = 0.0
        for x in samples {
            let s0 = Double(x) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let n = Double(samples.count)
        return (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n * n)
    }

    // MARK: - 11 OD & Distortion

    /// Full input gain must square off a sine (crest factor near 1), and
    /// output gain at zero must mute the module.
    @Test func odDistortionClipsAndOutputGainMutes() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let od = try #require(document.addModule(typeID: 11, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(od.id, paramIndex: 0, fraction: 1.0)  // +32 dB in
        document.setParam(od.id, paramIndex: 1, fraction: 1.0)  // 0 dB out
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: od.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let clipped = collect(runtime, node: 1, block: 2, blocks: 10, keepLast: 5)
        let peak = Double(clipped.map(abs).max() ?? 0)
        #expect(peak <= 1.01, "peak \(peak)")
        #expect(rms(clipped) / peak > 0.85,
                "crest \(rms(clipped) / peak) — expected near-square wave")

        runtime.nodes[1].params[1] = 0  // output gain → −inf dB
        let muted = collect(runtime, node: 1, block: 2, blocks: 5)
        #expect((muted.map(abs).max() ?? 1) < 0.001)
    }

    @Test func odDistortionModelsDiffer() throws {
        func renderModel(_ byte: UInt8) throws -> [Float] {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let od = try #require(document.addModule(typeID: 11, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
            document.setOption(od.id, optionIndex: 0, byte: byte)
            document.setParam(od.id, paramIndex: 0, fraction: 0.5)
            document.setParam(od.id, paramIndex: 1, fraction: 1.0)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: od.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            return collect(runtime, node: 1, block: 2, blocks: 5)
        }
        let plexi = try renderModel(0)
        let germ = try renderModel(1)
        let difference = zip(plexi, germ).map { abs($0 - $1) }
        #expect((difference.max() ?? 0) > 0.05, "models should shape differently")
    }

    // MARK: - 66 Fuzz

    @Test func fuzzClipsAndModelsDiffer() throws {
        func renderModel(_ byte: UInt8) throws -> [Float] {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let fuzz = try #require(document.addModule(typeID: 66, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
            document.setOption(fuzz.id, optionIndex: 0, byte: byte)
            document.setParam(fuzz.id, paramIndex: 0, fraction: 1.0)  // +40 dB
            document.setParam(fuzz.id, paramIndex: 1, fraction: 1.0)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: fuzz.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            return collect(runtime, node: 1, block: 3, blocks: 10, keepLast: 5)
        }
        let efuzzy = try renderModel(0)
        let peak = Double(efuzzy.map(abs).max() ?? 0)
        #expect(rms(efuzzy) / peak > 0.85, "fuzz should flatten a sine")

        let scoopy = try renderModel(2)
        let difference = zip(efuzzy, scoopy).map { abs($0 - $1) }
        #expect((difference.max() ?? 0) > 0.05)
    }

    // MARK: - 23 Compressor

    /// A 0 dB sine over a −40 dB threshold must be reduced by ~36 dB at the
    /// default 10.5:1 ratio; raising the threshold to 0 dB restores unity.
    @Test func compressorReducesLoudSignal() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let comp = try #require(document.addModule(typeID: 23, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(comp.id, paramIndex: 0, fraction: 0.5)  // −40 dB
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: comp.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let compressed = collect(runtime, node: 1, block: 6, blocks: 50, keepLast: 10)
        let quiet = rms(compressed)
        #expect(quiet > 0.001 && quiet < 0.05, "rms \(quiet) after 36 dB reduction")

        runtime.nodes[1].params[0] = 1.0  // threshold 0 dB → no reduction
        let unity = rms(collect(runtime, node: 1, block: 6, blocks: 20, keepLast: 10))
        #expect(unity > 0.6, "rms \(unity) with threshold at 0 dB")
    }

    /// With the ratio block enabled: 1:1 passes untouched, the dial's top
    /// (inf:1) limits output to the threshold level.
    @Test func compressorRatioControl() throws {
        func renderRatio(_ fraction: Double) throws -> Double {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let comp = try #require(document.addModule(typeID: 23, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
            document.setOption(comp.id, optionIndex: 0, byte: 1)  // attack ctrl
            document.setOption(comp.id, optionIndex: 1, byte: 1)  // release ctrl
            document.setOption(comp.id, optionIndex: 2, byte: 1)  // ratio ctrl
            document.setParam(comp.id, paramIndex: 0, fraction: 0.5)  // −40 dB
            document.setParam(comp.id, paramIndex: 1, fraction: 0)    // 0 ms
            document.setParam(comp.id, paramIndex: 2, fraction: 0)    // 10 ms
            document.setParam(comp.id, paramIndex: 3, fraction: fraction)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: comp.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            return rms(collect(runtime, node: 1, block: 6, blocks: 30, keepLast: 10))
        }
        #expect(try renderRatio(0) > 0.5, "1:1 must not compress")
        #expect(try renderRatio(1) < 0.02, "inf:1 must limit to −40 dB")
    }

    /// External sidechain: a loud input with a silent sidechain passes at
    /// unity; feeding the sidechain engages the compression.
    @Test func compressorExternalSidechain() throws {
        func renderSidechain(fed: Bool) throws -> Double {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let comp = try #require(document.addModule(typeID: 23, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
            document.setOption(comp.id, optionIndex: 4, byte: 1)  // external
            document.setParam(comp.id, paramIndex: 0, fraction: 0.5)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: comp.id, blockPosition: 0, type: .audioIn))
            if fed {
                document.connect(
                    from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                    to: PortRef(module: comp.id, blockPosition: 8, type: .audioIn))
            }
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            return rms(collect(runtime, node: 1, block: 6, blocks: 50, keepLast: 10))
        }
        #expect(try renderSidechain(fed: false) > 0.6,
                "silent sidechain must leave the signal alone")
        #expect(try renderSidechain(fed: true) < 0.05,
                "fed sidechain must duck the signal")
    }

    /// Stereo mode: one detector, the same gain applied to both channels.
    @Test func compressorStereoSharesGain() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let comp = try #require(document.addModule(typeID: 23, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setOption(comp.id, optionIndex: 3, byte: 1)  // stereo
        document.setParam(comp.id, paramIndex: 0, fraction: 0.5)
        for input in [0, 1] {
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: comp.id, blockPosition: input, type: .audioIn))
        }
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let left = collect(runtime, node: 1, block: 6, blocks: 50, keepLast: 10)
        let right = try #require(runtime.nodes[1].audioOut[7])
        #expect(rms(left) < 0.05, "stereo compression engaged")
        let lastLeft = Array(left.suffix(right.count))
        #expect(zip(lastLeft, right).allSatisfy { abs($0 - $1) < 1e-6 },
                "both channels share one gain curve")
    }

    // MARK: - 40 Gate

    /// Signal above threshold passes; below threshold the gate stays shut.
    @Test func gateSilencesBelowThreshold() throws {
        func renderGate(threshold: Double) throws -> Double {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let vca = try #require(document.addModule(typeID: 7, at: .zero))
            let gate = try #require(document.addModule(typeID: 40, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
            document.setParam(vca.id, paramIndex: 0, fraction: 0.005)  // −46 dB
            document.setParam(gate.id, paramIndex: 0, fraction: threshold)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
            document.connect(
                from: PortRef(module: vca.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: gate.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            return rms(collect(runtime, node: 2, block: 5, blocks: 50, keepLast: 10))
        }
        // −46 dB signal: threshold −55 dB opens, threshold −11 dB stays shut.
        #expect(try renderGate(threshold: 0.5) > 0.002)
        #expect(try renderGate(threshold: 0.9) < 0.0005)
    }

    /// A loud external sidechain holds the gate open for a quiet signal
    /// that would otherwise be muted.
    @Test func gateExternalSidechainOpens() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let vca = try #require(document.addModule(typeID: 7, at: .zero))
        let gate = try #require(document.addModule(typeID: 40, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(vca.id, paramIndex: 0, fraction: 0.005)
        document.setOption(gate.id, optionIndex: 3, byte: 1)  // external
        document.setParam(gate.id, paramIndex: 0, fraction: 0.9)  // −11 dB
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: vca.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: gate.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: gate.id, blockPosition: 7, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let out = rms(collect(runtime, node: 2, block: 5, blocks: 50, keepLast: 10))
        #expect(out > 0.002, "loud sidechain must hold the gate open")
    }

    // MARK: - 42 Tone Control

    /// Renders a sine through Tone Control and returns steady-state rms.
    private func toneRMS(note: Double, secondMidBand: Bool = false,
                         set: [(Int, Double)]) throws -> Double {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let tone = try #require(document.addModule(typeID: 42, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: note / 127.0)
        if secondMidBand { document.setOption(tone.id, optionIndex: 1, byte: 1) }
        let paramCount = secondMidBand ? 6 : 4
        for i in 0..<paramCount { document.setParam(tone.id, paramIndex: i, fraction: 0.5) }
        for (i, value) in set { document.setParam(tone.id, paramIndex: i, fraction: value) }
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: tone.id, blockPosition: 0, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        return rms(collect(runtime, node: 1, block: 8, blocks: 40, keepLast: 20))
    }

    @Test func toneControlLowShelf() throws {
        // 55 Hz sine, low shelf ±18 dB → ~36 dB spread.
        let boosted = try toneRMS(note: 33, set: [(0, 1.0)])
        let cut = try toneRMS(note: 33, set: [(0, 0.0)])
        #expect(boosted / cut > 15, "boost/cut ratio \(boosted / cut)")
        #expect(boosted > 0.707, "shelf must boost above unity")
    }

    @Test func toneControlMidBandBoostsChosenFrequency() throws {
        // Mid band centered on 440 Hz (dial cv 0.4), +18 dB vs flat.
        let boosted = try toneRMS(note: 69, set: [(1, 1.0), (2, 0.4)])
        let flat = try toneRMS(note: 69, set: [])
        #expect(boosted / flat > 4, "mid boost ratio \(boosted / flat)")
        // The same boost centered two octaves up must leave 440 Hz alone.
        let offCenter = try toneRMS(note: 69, set: [(1, 1.0), (2, 0.6)])
        #expect(offCenter / flat < 2)
    }

    @Test func toneControlHighShelf() throws {
        let boosted = try toneRMS(note: 123, set: [(3, 1.0)])
        let flat = try toneRMS(note: 123, set: [])
        #expect(boosted / flat > 4, "high shelf ratio \(boosted / flat)")
    }

    /// num mid bands = 2 adds a second peaking band with its own params.
    @Test func toneControlSecondMidBand() throws {
        let boosted = try toneRMS(note: 69, secondMidBand: true,
                                  set: [(3, 1.0), (4, 0.4)])
        let flat = try toneRMS(note: 69, secondMidBand: true, set: [])
        #expect(boosted / flat > 4, "second mid band ratio \(boosted / flat)")
    }

    // MARK: - 68 Cabinet Sim

    private func cabinetRMS(note: Double, type: UInt8 = 0) throws -> Double {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let cab = try #require(document.addModule(typeID: 68, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: note / 127.0)
        document.setOption(cab.id, optionIndex: 1, byte: type)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: cab.id, blockPosition: 0, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        return rms(collect(runtime, node: 1, block: 2, blocks: 30, keepLast: 15))
    }

    @Test func cabinetSimRollsOffHighs() throws {
        let mids = try cabinetRMS(note: 69)    // 440 Hz
        let highs = try cabinetRMS(note: 123)  // ~10 kHz
        #expect(mids > 0.4, "440 Hz should pass near unity, rms \(mids)")
        #expect(highs < 0.2 * mids, "10 kHz must roll off, \(highs) vs \(mids)")
    }

    @Test func cabinetSimTypesDiffer() throws {
        // 3520 Hz sits under the 4x12_hifi corner but past 1x8_lofi's.
        let hifi = try cabinetRMS(note: 105, type: 6)
        let lofi = try cabinetRMS(note: 105, type: 4)
        #expect(hifi > 2 * lofi, "hifi \(hifi) vs lofi \(lofi)")
    }

    @Test func cabinetSimStereo() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let cab = try #require(document.addModule(typeID: 68, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setOption(cab.id, optionIndex: 0, byte: 1)  // stereo
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: cab.id, blockPosition: 1, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let left = collect(runtime, node: 1, block: 2, blocks: 20, keepLast: 10)
        let right = try #require(runtime.nodes[1].audioOut[3])
        #expect(rms(right) > 0.3, "wired right channel must pass audio")
        #expect(rms(left) < 0.001, "unwired left channel must stay silent")
    }

    // MARK: - 72 Env Filter

    private func envFilterRMS(sensitivity: Double, filterType: UInt8 = 2,
                              direction: UInt8 = 0) throws -> Double {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let filter = try #require(document.addModule(typeID: 72, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 105.0 / 127.0)  // 3520 Hz
        document.setOption(filter.id, optionIndex: 1, byte: filterType)
        document.setOption(filter.id, optionIndex: 2, byte: direction)
        document.setParam(filter.id, paramIndex: 0, fraction: sensitivity)
        document.setParam(filter.id, paramIndex: 1, fraction: 0.2)   // min 110 Hz
        document.setParam(filter.id, paramIndex: 2, fraction: 1.0)   // max 24 kHz
        document.setParam(filter.id, paramIndex: 3, fraction: 0.33)  // Q ≈ 10
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: filter.id, blockPosition: 0, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        return rms(collect(runtime, node: 1, block: 6, blocks: 40, keepLast: 10))
    }

    /// LPF sweeping up: at zero sensitivity the cutoff sits at min freq and
    /// blocks a bright sine; a hot envelope sweeps the cutoff up to let it
    /// through.
    @Test func envFilterSweepsWithSensitivity() throws {
        let closed = try envFilterRMS(sensitivity: 0)
        let open = try envFilterRMS(sensitivity: 1)
        #expect(closed < 0.02, "cutoff at 110 Hz must block 3520 Hz, rms \(closed)")
        #expect(open > 0.3, "swept-up cutoff must pass 3520 Hz, rms \(open)")
    }

    /// Direction "down": zero envelope parks the cutoff at max freq instead.
    @Test func envFilterDirectionDown() throws {
        let up = try envFilterRMS(sensitivity: 0, direction: 0)
        let down = try envFilterRMS(sensitivity: 0, direction: 1)
        #expect(down > 0.3, "down direction starts open, rms \(down)")
        #expect(down > 10 * up)
    }

    // MARK: - 73 Ring Modulator

    /// 440 Hz input × 110 Hz internal sine carrier at full wet must move
    /// the energy to the 330/550 Hz sidebands.
    @Test func ringModProducesSumAndDifferenceTones() throws {
        func renderMix(_ mix: Double) throws -> [Float] {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let ring = try #require(document.addModule(typeID: 73, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
            document.setParam(ring.id, paramIndex: 0, fraction: 0.2)  // 110 Hz
            document.setParam(ring.id, paramIndex: 1, fraction: mix)
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: ring.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            return collect(runtime, node: 1, block: 5, blocks: 10)  // 0.1 s
        }
        let wet = try renderMix(1.0)
        let carrierLeak = power(wet, hz: 440)
        #expect(power(wet, hz: 330) > 10 * carrierLeak,
                "difference tone missing: \(power(wet, hz: 330)) vs \(carrierLeak)")
        #expect(power(wet, hz: 550) > 10 * carrierLeak, "sum tone missing")

        let dry = try renderMix(0.0)
        #expect(power(dry, hz: 440) > 10 * max(power(dry, hz: 330), power(dry, hz: 550)),
                "mix 0 must be fully dry")
    }

    /// ext audio in: a wired oscillator replaces the internal carrier.
    @Test func ringModExternalCarrier() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let carrier = try #require(document.addModule(typeID: 14, at: .zero))
        let ring = try #require(document.addModule(typeID: 73, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.setParam(carrier.id, paramIndex: 0, fraction: 45.0 / 127.0)  // 110 Hz
        document.setOption(ring.id, optionIndex: 1, byte: 1)  // ext audio in
        document.setParam(ring.id, paramIndex: 0, fraction: 1.0)  // mix
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: ring.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: carrier.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: ring.id, blockPosition: 2, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let out = collect(runtime, node: 2, block: 5, blocks: 10)
        let leak = power(out, hz: 440)
        #expect(power(out, hz: 330) > 10 * leak, "difference tone from ext carrier")
        #expect(power(out, hz: 550) > 10 * leak, "sum tone from ext carrier")
    }

    /// Duty cycle on a square carrier: 10% duty has a DC-offset carrier, so
    /// the dry 440 Hz component leaks through where 50% duty cancels it.
    @Test func ringModDutyCycle() throws {
        func renderDuty(_ duty: Double) throws -> [Float] {
            let document = try makeDocument()
            let osc = try #require(document.addModule(typeID: 14, at: .zero))
            let ring = try #require(document.addModule(typeID: 73, at: .zero))
            document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
            document.setOption(ring.id, optionIndex: 0, byte: 1)  // square
            document.setOption(ring.id, optionIndex: 2, byte: 1)  // duty ctrl
            document.setParam(ring.id, paramIndex: 0, fraction: 0.2)   // 110 Hz
            document.setParam(ring.id, paramIndex: 1, fraction: duty)
            document.setParam(ring.id, paramIndex: 2, fraction: 1.0)   // mix
            document.connect(
                from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
                to: PortRef(module: ring.id, blockPosition: 0, type: .audioIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            return collect(runtime, node: 1, block: 5, blocks: 10)
        }
        let narrow = try renderDuty(0.1)
        let square = try renderDuty(0.5)
        #expect(power(narrow, hz: 440) > 5 * power(square, hz: 440),
                "narrow duty must leak the carrier's DC into 440 Hz")
    }
}
