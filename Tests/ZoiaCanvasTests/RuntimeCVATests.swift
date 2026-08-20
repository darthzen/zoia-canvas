import Foundation
import Testing
@testable import ZoiaCanvas

/// Runtime coverage for the CV generator group — IDs 4 (Sequencer),
/// 5 (LFO), 6 (ADSR), 37 (Rhythm), 39 (Random), 47 (CV Loop),
/// 85 (Tap to CV).
///
/// Tests drive CV inputs by poking `runtime.nodes[i].params` between
/// render blocks (deterministic, no wiring needed) and read module
/// outputs from `cvOut` by catalog block position. 64-frame blocks at
/// 48 kHz → 750 control blocks per second.
@Suite @MainActor struct RuntimeCVATests {
    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// Sets a live CV input by catalog block position (unquantized).
    private func setCV(_ runtime: PatchRuntime, node: Int, block: Int, _ value: Float) {
        guard let index = runtime.nodes[node].paramIndexByPosition[block] else {
            Issue.record("node \(node) has no param at block \(block)")
            return
        }
        runtime.nodes[node].params[index] = value
    }

    /// Renders control blocks, returning the node's cv output per block.
    @discardableResult
    private func renderCollect(_ runtime: PatchRuntime, node: Int, block: Int,
                               blocks: Int, frames: Int = 64) -> [Float] {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        var seen: [Float] = []
        for _ in 0..<blocks {
            runtime.render(frames: frames, outputL: &left, outputR: &right)
            seen.append(runtime.nodes[node].cvOut[block] ?? 0)
        }
        return seen
    }

    /// One-block high pulse into a CV input (rising edge + return low).
    private func pulse(_ runtime: PatchRuntime, node: Int, block: Int) {
        setCV(runtime, node: node, block: block, 1)
        renderCollect(runtime, node: node, block: block, blocks: 1)
        setCV(runtime, node: node, block: block, 0)
        renderCollect(runtime, node: node, block: block, blocks: 1)
    }

    private func risingEdges(_ values: [Float], from initial: Float = 1) -> Int {
        var count = 0
        var last = initial
        for v in values {
            if last < 0.5, v >= 0.5 { count += 1 }
            last = v
        }
        return count
    }

    // MARK: - Sequencer (4)

    /// cv_step behavior: the gate CV addresses the step directly.
    @Test func sequencerCVStepAddressesSteps() throws {
        let document = try makeDocument()
        let seq = try #require(document.addModule(typeID: 4, at: .zero))
        document.setOption(seq.id, optionIndex: 0, byte: 3)  // 4 steps
        document.setOption(seq.id, optionIndex: 3, byte: 2)  // cv_step
        for (i, v) in [0.1, 0.3, 0.5, 0.7].enumerated() {
            document.setParam(seq.id, paramIndex: i, fraction: v)
        }
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        setCV(runtime, node: 0, block: 32, 0.6)  // step index 2
        var out = renderCollect(runtime, node: 0, block: 34, blocks: 1)
        #expect(abs(out[0] - 0.5) < 0.01, "gate 0.6 → \(out[0])")

        setCV(runtime, node: 0, block: 32, 0)
        out = renderCollect(runtime, node: 0, block: 34, blocks: 1)
        #expect(abs(out[0] - 0.1) < 0.01)

        setCV(runtime, node: 0, block: 32, 0.99)  // step index 3
        out = renderCollect(runtime, node: 0, block: 34, blocks: 1)
        #expect(abs(out[0] - 0.7) < 0.01)
    }

    /// one_shot stops on the last step; the queue-start jack rearms.
    @Test func sequencerOneShotStopsAndRestartRearms() throws {
        let document = try makeDocument()
        let seq = try #require(document.addModule(typeID: 4, at: .zero))
        document.setOption(seq.id, optionIndex: 0, byte: 1)  // 2 steps
        document.setOption(seq.id, optionIndex: 2, byte: 1)  // restart jack
        document.setOption(seq.id, optionIndex: 3, byte: 1)  // one_shot
        document.setParam(seq.id, paramIndex: 0, fraction: 0.2)
        document.setParam(seq.id, paramIndex: 1, fraction: 0.8)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        var out = renderCollect(runtime, node: 0, block: 34, blocks: 1)
        #expect(abs(out[0] - 0.2) < 0.01, "starts on step 1")
        pulse(runtime, node: 0, block: 32)
        #expect(abs((runtime.nodes[0].cvOut[34] ?? 0) - 0.8) < 0.01)
        pulse(runtime, node: 0, block: 32)
        pulse(runtime, node: 0, block: 32)
        #expect(abs((runtime.nodes[0].cvOut[34] ?? 0) - 0.8) < 0.01,
                "one_shot holds the last step")

        pulse(runtime, node: 0, block: 33)  // queue start
        out = renderCollect(runtime, node: 0, block: 34, blocks: 1)
        #expect(abs(out[0] - 0.2) < 0.01, "restart rewinds to step 1")
        pulse(runtime, node: 0, block: 32)
        #expect(abs((runtime.nodes[0].cvOut[34] ?? 0) - 0.8) < 0.01,
                "restart rearms the gate")
    }

    /// Tracks 2+ exist as outputs; a canvas-authored module has no
    /// saved_data rows for them yet, so they read 0.
    @Test func sequencerExtraTracksOutputZero() throws {
        let document = try makeDocument()
        let seq = try #require(document.addModule(typeID: 4, at: .zero))
        document.setOption(seq.id, optionIndex: 0, byte: 3)  // 4 steps
        document.setOption(seq.id, optionIndex: 1, byte: 2)  // 3 tracks
        document.setParam(seq.id, paramIndex: 0, fraction: 0.4)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        renderCollect(runtime, node: 0, block: 34, blocks: 1)
        #expect(abs((runtime.nodes[0].cvOut[34] ?? 0) - 0.4) < 0.01)
        #expect(runtime.nodes[0].cvOut[35] == 0)
        #expect(runtime.nodes[0].cvOut[36] == 0)
        #expect(runtime.nodes[0].cvOut[37] == nil, "only 3 tracks active")
    }

    /// key_input "increment": each key gate writes the key note into the
    /// next step.
    @Test func sequencerKeyInputWritesSteps() throws {
        let document = try makeDocument()
        let seq = try #require(document.addModule(typeID: 4, at: .zero))
        document.setOption(seq.id, optionIndex: 0, byte: 1)  // 2 steps
        document.setOption(seq.id, optionIndex: 4, byte: 2)  // increment
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        setCV(runtime, node: 0, block: 42, 0.9)
        pulse(runtime, node: 0, block: 43)
        setCV(runtime, node: 0, block: 42, 0.6)
        pulse(runtime, node: 0, block: 43)

        let out = renderCollect(runtime, node: 0, block: 34, blocks: 1)
        #expect(abs(out[0] - 0.9) < 0.01, "step 1 took the first key note")
        pulse(runtime, node: 0, block: 32)
        #expect(abs((runtime.nodes[0].cvOut[34] ?? 0) - 0.6) < 0.01,
                "step 2 took the second key note")
    }

    // MARK: - LFO (5)

    /// linear_cv input: 0…1 maps linearly to 0…25 Hz.
    @Test func lfoLinearCVFrequency() throws {
        let document = try makeDocument()
        let lfo = try #require(document.addModule(typeID: 5, at: .zero))
        document.setOption(lfo.id, optionIndex: 3, byte: 2)  // linear_cv
        document.setParam(lfo.id, paramIndex: 0, fraction: 0.08)  // 2 Hz
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let out = renderCollect(runtime, node: 0, block: 3, blocks: 2250)  // 3 s
        let edges = risingEdges(out)
        #expect((4...7).contains(edges), "2 Hz square over 3 s → \(edges) edges")
    }

    /// tap input: two taps 0.5 s apart lock the LFO to 2 Hz.
    @Test func lfoTapTempoLocksToTapInterval() throws {
        let document = try makeDocument()
        let clock = try #require(document.addModule(typeID: 5, at: .zero))
        let tapped = try #require(document.addModule(typeID: 5, at: .zero))
        document.setOption(clock.id, optionIndex: 3, byte: 2)   // linear_cv
        document.setParam(clock.id, paramIndex: 0, fraction: 0.08)  // 2 Hz taps
        document.setOption(tapped.id, optionIndex: 3, byte: 1)  // tap
        document.connect(
            from: PortRef(module: clock.id, blockPosition: 3, type: .cvOut),
            to: PortRef(module: tapped.id, blockPosition: 1, type: .cvIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        renderCollect(runtime, node: 1, block: 3, blocks: 750)  // settle 1 s
        let out = renderCollect(runtime, node: 1, block: 3, blocks: 2250)  // 3 s
        let edges = risingEdges(out)
        #expect((4...7).contains(edges), "tap-locked 2 Hz → \(edges) edges")
    }

    /// Bipolar sine spans the full -1…1 range.
    @Test func lfoBipolarSineSpansRange() throws {
        let document = try makeDocument()
        let lfo = try #require(document.addModule(typeID: 5, at: .zero))
        document.setOption(lfo.id, optionIndex: 0, byte: 1)  // sine
        document.setOption(lfo.id, optionIndex: 2, byte: 1)  // -1 to 1
        document.setParam(lfo.id, paramIndex: 0, fraction: 0.9)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let out = renderCollect(runtime, node: 0, block: 3, blocks: 750)
        #expect((out.max() ?? 0) > 0.9)
        #expect((out.min() ?? 0) < -0.9)
    }

    /// Phase reset rewinds; phase input offsets the ramp start point.
    @Test func lfoPhaseInputAndReset() throws {
        let document = try makeDocument()
        let lfo = try #require(document.addModule(typeID: 5, at: .zero))
        document.setOption(lfo.id, optionIndex: 0, byte: 4)  // ramp
        document.setOption(lfo.id, optionIndex: 4, byte: 1)  // phase input
        document.setOption(lfo.id, optionIndex: 5, byte: 1)  // phase reset
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        setCV(runtime, node: 0, block: 4, 0.25)  // 90° offset
        renderCollect(runtime, node: 0, block: 3, blocks: 100)
        setCV(runtime, node: 0, block: 5, 1)  // reset edge
        let out = renderCollect(runtime, node: 0, block: 3, blocks: 1)
        #expect(abs(out[0] - 0.25) < 0.02,
                "after reset the ramp restarts at the phase offset, saw \(out[0])")
    }

    /// Swing shifts the square duty cycle off 50 %.
    @Test func lfoSwingSkewsDutyCycle() throws {
        let document = try makeDocument()
        let plain = try #require(document.addModule(typeID: 5, at: .zero))
        let swung = try #require(document.addModule(typeID: 5, at: .zero))
        for id in [plain.id, swung.id] {
            document.setOption(id, optionIndex: 3, byte: 2)  // linear_cv
            document.setParam(id, paramIndex: 0, fraction: 0.3)  // 7.5 Hz
        }
        document.setOption(swung.id, optionIndex: 1, byte: 1)  // swing on
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        setCV(runtime, node: 1, block: 2, 0.5)  // midpoint → 0.725

        var left = [Float](repeating: 0, count: 64)
        var right = left
        var plainOut: [Float] = []
        var swungOut: [Float] = []
        for _ in 0..<2250 {  // 3 s
            runtime.render(frames: 64, outputL: &left, outputR: &right)
            plainOut.append(runtime.nodes[0].cvOut[3] ?? 0)
            swungOut.append(runtime.nodes[1].cvOut[3] ?? 0)
        }
        let dutyPlain = Float(plainOut.filter { $0 >= 0.5 }.count) / Float(plainOut.count)
        let dutySwung = Float(swungOut.filter { $0 >= 0.5 }.count) / Float(swungOut.count)
        #expect(abs(dutyPlain - 0.5) < 0.05, "no swing → 50 % duty, saw \(dutyPlain)")
        #expect(dutySwung > 0.66 && dutySwung < 0.79,
                "swing 0.5 → ~72 % duty, saw \(dutySwung)")
    }

    // MARK: - ADSR (6)

    /// Attack to peak, decay to sustain, release to zero.
    @Test func adsrEnvelopeShape() throws {
        let document = try makeDocument()
        let adsr = try #require(document.addModule(typeID: 6, at: .zero))
        document.setOption(adsr.id, optionIndex: 6, byte: 1)  // linear time
        document.setParam(adsr.id, paramIndex: 1, fraction: 0.005)  // A 50 ms
        document.setParam(adsr.id, paramIndex: 2, fraction: 0.005)  // D 50 ms
        document.setParam(adsr.id, paramIndex: 3, fraction: 0.5)    // S 0.5
        document.setParam(adsr.id, paramIndex: 4, fraction: 0.005)  // R 50 ms
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        setCV(runtime, node: 0, block: 0, 1)  // gate on
        let held = renderCollect(runtime, node: 0, block: 9, blocks: 150)  // 200 ms
        #expect((held.max() ?? 0) > 0.95, "attack reaches the peak")
        #expect(abs(held[149] - 0.5) < 0.02, "settles at sustain, saw \(held[149])")
        #expect(held[10] > 0.05 && held[10] < 0.95, "mid-attack is mid-flight")

        setCV(runtime, node: 0, block: 0, 0)  // gate off
        let released = renderCollect(runtime, node: 0, block: 9, blocks: 110)
        #expect(released[109] < 0.02, "release lands at zero, saw \(released[109])")
    }

    /// Retrigger relaunches the attack during sustain.
    @Test func adsrRetriggerRelaunchesAttack() throws {
        let document = try makeDocument()
        let adsr = try #require(document.addModule(typeID: 6, at: .zero))
        document.setOption(adsr.id, optionIndex: 0, byte: 1)  // retrigger on
        document.setOption(adsr.id, optionIndex: 6, byte: 1)  // linear time
        document.setParam(adsr.id, paramIndex: 2, fraction: 0.005)  // A 50 ms
        document.setParam(adsr.id, paramIndex: 3, fraction: 0.005)  // D 50 ms
        document.setParam(adsr.id, paramIndex: 4, fraction: 0.3)    // S 0.3
        document.setParam(adsr.id, paramIndex: 5, fraction: 0.005)  // R 50 ms
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        setCV(runtime, node: 0, block: 0, 1)
        renderCollect(runtime, node: 0, block: 9, blocks: 150)
        #expect(abs((runtime.nodes[0].cvOut[9] ?? 0) - 0.3) < 0.02, "at sustain")

        setCV(runtime, node: 0, block: 1, 1)  // retrigger edge
        let retriggered = renderCollect(runtime, node: 0, block: 9, blocks: 150)
        #expect((retriggered.max() ?? 0) > 0.95, "attack ran again")
        #expect(abs(retriggered[149] - 0.3) < 0.02, "back at sustain")
    }

    /// str off: no sustain stage — the envelope falls to zero on its own
    /// while the gate is still held.
    @Test func adsrWithoutSustainFallsToZero() throws {
        let document = try makeDocument()
        let adsr = try #require(document.addModule(typeID: 6, at: .zero))
        document.setOption(adsr.id, optionIndex: 3, byte: 1)  // str off
        document.setOption(adsr.id, optionIndex: 6, byte: 1)  // linear time
        document.setParam(adsr.id, paramIndex: 1, fraction: 0.005)  // A 50 ms
        document.setParam(adsr.id, paramIndex: 2, fraction: 0.005)  // D 50 ms
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        setCV(runtime, node: 0, block: 0, 1)  // gate held throughout
        let out = renderCollect(runtime, node: 0, block: 9, blocks: 225)  // 300 ms
        #expect((out.max() ?? 0) > 0.95)
        #expect(out[224] < 0.02, "fell back to zero with gate high, saw \(out[224])")
    }

    /// immediate release ON cuts a short note at its current level;
    /// OFF completes the attack first.
    @Test func adsrImmediateReleaseOption() throws {
        func peakAfterShortGate(immediateRelease: Bool) throws -> Float {
            let document = try makeDocument()
            let adsr = try #require(document.addModule(typeID: 6, at: .zero))
            if !immediateRelease {
                document.setOption(adsr.id, optionIndex: 4, byte: 1)  // off
            }
            document.setOption(adsr.id, optionIndex: 6, byte: 1)  // linear time
            document.setParam(adsr.id, paramIndex: 1, fraction: 0.1)    // A 1 s
            document.setParam(adsr.id, paramIndex: 2, fraction: 0.001)  // D 10 ms
            document.setParam(adsr.id, paramIndex: 3, fraction: 0.8)    // S
            document.setParam(adsr.id, paramIndex: 4, fraction: 0.002)  // R 20 ms
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            setCV(runtime, node: 0, block: 0, 1)
            var out = renderCollect(runtime, node: 0, block: 9, blocks: 37)  // ~50 ms
            setCV(runtime, node: 0, block: 0, 0)
            out += renderCollect(runtime, node: 0, block: 9, blocks: 900)  // 1.2 s
            #expect(out[out.count - 1] < 0.05, "envelope ends at zero")
            return out.max() ?? 0
        }
        let cut = try peakAfterShortGate(immediateRelease: true)
        #expect(cut < 0.5, "immediate release cuts the short note, peak \(cut)")
        let carried = try peakAfterShortGate(immediateRelease: false)
        #expect(carried > 0.95, "attack completes when off, peak \(carried)")
    }

    // MARK: - Rhythm (37)

    /// Records a gate pattern while rec is high, replays it once on play,
    /// and raises done when playback ends.
    @Test func rhythmRecordsAndReplaysPattern() throws {
        let document = try makeDocument()
        let rhythm = try #require(document.addModule(typeID: 37, at: .zero))
        document.setOption(rhythm.id, optionIndex: 0, byte: 1)  // done out
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        let pattern: [Float] = [1, 0, 0, 1]
        setCV(runtime, node: 0, block: 0, 1)  // record
        for v in pattern {
            setCV(runtime, node: 0, block: 1, v)
            renderCollect(runtime, node: 0, block: 4, blocks: 1)
        }
        setCV(runtime, node: 0, block: 0, 0)  // stop recording
        renderCollect(runtime, node: 0, block: 4, blocks: 1)
        #expect(runtime.nodes[0].cvOut[4] == 0, "silent while idle")

        setCV(runtime, node: 0, block: 2, 1)  // play
        var replayed: [Float] = []
        for i in 0..<4 {
            replayed += renderCollect(runtime, node: 0, block: 4, blocks: 1)
            if i < 3 { #expect(runtime.nodes[0].cvOut[3] == 0, "not done yet") }
        }
        #expect(replayed == pattern, "replayed \(replayed)")
        #expect(runtime.nodes[0].cvOut[3] == 1, "done latches after playback")
        renderCollect(runtime, node: 0, block: 4, blocks: 1)
        #expect(runtime.nodes[0].cvOut[4] == 0, "output rests after playback")
    }

    // MARK: - Random (39)

    /// Free-running: fresh value each block, range set by the option.
    @Test func randomFreeRunningAndRange() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 39, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let unipolar = renderCollect(runtime, node: 0, block: 1, blocks: 30)
        #expect(unipolar.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(Set(unipolar).count > 5, "free-running values keep changing")

        let doc2 = try makeDocument()
        let random = try #require(doc2.addModule(typeID: 39, at: .zero))
        doc2.setOption(random.id, optionIndex: 0, byte: 1)  // -1 to 1
        let runtime2 = PatchRuntime(document: doc2, sampleRate: 48000)
        let bipolar = renderCollect(runtime2, node: 0, block: 1, blocks: 60)
        #expect(bipolar.allSatisfy { $0 >= -1 && $0 <= 1 })
        #expect((bipolar.min() ?? 0) < 0, "bipolar range reaches below zero")
    }

    /// new_val_on_trig: holds between triggers, refreshes on the edge.
    @Test func randomHoldsUntilTriggered() throws {
        let document = try makeDocument()
        let random = try #require(document.addModule(typeID: 39, at: .zero))
        document.setOption(random.id, optionIndex: 1, byte: 1)  // trig input
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        let held = renderCollect(runtime, node: 0, block: 1, blocks: 10)
        #expect(Set(held).count == 1, "no trigger → value holds")

        var values: Set<Float> = [held[0]]
        for _ in 0..<5 {
            pulse(runtime, node: 0, block: 0)
            values.insert(runtime.nodes[0].cvOut[1] ?? 0)
        }
        #expect(values.count >= 2, "triggers draw new values")
    }

    // MARK: - CV Loop (47)

    /// Record fall drops into looped playback; restart rewinds; playback
    /// speed halves per the speed CV.
    @Test func cvLoopRecordsLoopsAndRestarts() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 47, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)

        setCV(runtime, node: 0, block: 3, 0.5)  // speed 0.5 → 100 %
        setCV(runtime, node: 0, block: 1, 1)    // record
        for v in [Float(0.1), 0.2, 0.3, 0.4] {
            setCV(runtime, node: 0, block: 0, v)
            renderCollect(runtime, node: 0, block: 7, blocks: 1)
        }
        setCV(runtime, node: 0, block: 1, 0)    // fall → playback
        let looped = renderCollect(runtime, node: 0, block: 7, blocks: 8)
        #expect(looped == [0.1, 0.2, 0.3, 0.4, 0.1, 0.2, 0.3, 0.4],
                "unity-speed loop, saw \(looped)")

        renderCollect(runtime, node: 0, block: 7, blocks: 2)  // into the loop
        setCV(runtime, node: 0, block: 6, 1)  // restart edge
        let restarted = renderCollect(runtime, node: 0, block: 7, blocks: 1)
        #expect(restarted[0] == 0.1, "restart rewinds, saw \(restarted[0])")
        setCV(runtime, node: 0, block: 6, 0)

        setCV(runtime, node: 0, block: 3, 0.25)  // 50 % speed
        setCV(runtime, node: 0, block: 2, 1)     // play edge → start
        let half = renderCollect(runtime, node: 0, block: 7, blocks: 8)
        #expect(half == [0.1, 0.1, 0.2, 0.2, 0.3, 0.3, 0.4, 0.4],
                "half speed doubles each sample, saw \(half)")
    }

    /// length_edit trims the loop from both ends.
    @Test func cvLoopStartStopTrimsPlayback() throws {
        let document = try makeDocument()
        let loop = try #require(document.addModule(typeID: 47, at: .zero))
        document.setOption(loop.id, optionIndex: 1, byte: 1)  // length edit
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let blockDur = Float(64.0 / 48000)

        setCV(runtime, node: 0, block: 3, 0.5)  // unity speed
        setCV(runtime, node: 0, block: 1, 1)    // record 8 values
        for v in [Float(0.1), 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8] {
            setCV(runtime, node: 0, block: 0, v)
            renderCollect(runtime, node: 0, block: 7, blocks: 1)
        }
        setCV(runtime, node: 0, block: 1, 0)
        // Chop 2 blocks at the start and 2 at the end. Offsets sit
        // mid-block so neither the sample index nor the wrap comparison
        // lands on a float knife edge (playhead 2.5→5.5 blocks, loop end
        // at 6.2 blocks).
        setCV(runtime, node: 0, block: 4, 2.5 * blockDur)
        setCV(runtime, node: 0, block: 5, 1.8 * blockDur)
        setCV(runtime, node: 0, block: 2, 1)  // play from start position
        let out = renderCollect(runtime, node: 0, block: 7, blocks: 8)
        #expect(out == [0.3, 0.4, 0.5, 0.6, 0.3, 0.4, 0.5, 0.6],
                "trimmed loop plays the middle only, saw \(out)")
    }

    // MARK: - Tap to CV (85)

    /// A 2 Hz tap clock maps to the middle of a 0…1 s window linearly,
    /// and near the top of it exponentially.
    @Test func tapToCVMapsTapInterval() throws {
        func output(exponential: Bool) throws -> Float {
            let document = try makeDocument()
            let clock = try #require(document.addModule(typeID: 5, at: .zero))
            let tap = try #require(document.addModule(typeID: 85, at: .zero))
            document.setOption(clock.id, optionIndex: 3, byte: 2)  // linear_cv
            document.setParam(clock.id, paramIndex: 0, fraction: 0.08)  // 2 Hz
            document.setOption(tap.id, optionIndex: 0, byte: 1)  // range on
            document.setParam(tap.id, paramIndex: 0, fraction: 0)    // min 0 s
            document.setParam(tap.id, paramIndex: 1, fraction: 0.1)  // max 1 s
            if exponential {
                document.setOption(tap.id, optionIndex: 1, byte: 1)
            }
            document.connect(
                from: PortRef(module: clock.id, blockPosition: 3, type: .cvOut),
                to: PortRef(module: tap.id, blockPosition: 0, type: .cvIn))
            let runtime = PatchRuntime(document: document, sampleRate: 48000)
            renderCollect(runtime, node: 1, block: 3, blocks: 2250)  // 3 s
            return runtime.nodes[1].cvOut[3] ?? 0
        }
        let linear = try output(exponential: false)
        #expect(abs(linear - 0.5) < 0.02, "0.5 s in 0…1 s → 0.5, saw \(linear)")
        let exponential = try output(exponential: true)
        #expect(abs(exponential - 0.8997) < 0.02,
                "log-mapped 0.5 s → ~0.9, saw \(exponential)")
    }
}
