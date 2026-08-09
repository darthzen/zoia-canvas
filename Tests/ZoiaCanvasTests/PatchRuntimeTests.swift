import Foundation
import Testing
@testable import ZoiaCanvas

/// Records outgoing MIDI and feeds queued incoming events.
private final class MidiRecorder: MidiPort {
    var sent: [(String, Int, Int)] = []
    var incoming: [MidiEvent] = []

    func noteOn(channel: Int, note: Int, velocity: Int) { sent.append(("on", note, velocity)) }
    func noteOff(channel: Int, note: Int) { sent.append(("off", note, 0)) }
    func drainIncoming() -> [MidiEvent] {
        defer { incoming = [] }
        return incoming
    }
}

@Suite @MainActor struct PatchRuntimeTests {
    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// Manually clocked 4-step sequencer: gate wired from an LFO square.
    /// Rendering enough blocks must cycle track 1 through the step values.
    @Test func sequencerAdvancesThroughSteps() throws {
        let document = try makeDocument()
        let lfo = try #require(document.addModule(typeID: 5, at: .zero))
        let seq = try #require(document.addModule(typeID: 4, at: .zero))
        // 4 steps (option byte 3 → value 4), 1 track.
        document.setOption(seq.id, optionIndex: 0, byte: 3)
        let stepValues: [Double] = [0.1, 0.3, 0.5, 0.7]
        for (i, v) in stepValues.enumerated() {
            document.setParam(seq.id, paramIndex: i, fraction: v)
        }
        // LFO fast square into the sequencer gate (position 32).
        document.setParam(lfo.id, paramIndex: 0, fraction: 0.9)
        document.connect(
            from: PortRef(module: lfo.id, blockPosition: 3, type: .cvOut),
            to: PortRef(module: seq.id, blockPosition: 32, type: .cvIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var left = [Float](repeating: 0, count: 64)
        var right = left
        var seen: [Float] = []
        for _ in 0..<4000 {
            runtime.render(frames: 64, outputL: &left, outputR: &right)
            let value = runtime.nodes[1].cvOut[36] ?? -1
            if seen.last != value { seen.append(value) }
        }
        // The sequencer must have visited all four step values in order.
        let rounded = seen.map { (($0 * 10).rounded()) / 10 }
        #expect(Set(rounded).isSuperset(of: [0.1, 0.3, 0.5, 0.7]),
                "saw \(rounded)")
        // Order check: 0.3 follows 0.1, 0.5 follows 0.3 somewhere.
        if let first = rounded.firstIndex(of: 0.1), first + 2 < rounded.count {
            #expect(rounded[first + 1] == 0.3)
            #expect(rounded[first + 2] == 0.5)
        }
    }

    /// A4 (MIDI 69 → cv 69/127) must render ≈440 Hz from the oscillator.
    @Test func oscillatorPitchIsCalibrated() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let out = try #require(document.addModule(typeID: 2, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 69.0 / 127.0)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: out.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var left = [Float](repeating: 0, count: 480)
        var right = left
        var crossings = 0
        var last: Float = 0
        for _ in 0..<100 {  // 1 second total
            runtime.render(frames: 480, outputL: &left, outputR: &right)
            for sample in left {
                if last < 0, sample >= 0 { crossings += 1 }
                last = sample
            }
        }
        #expect(abs(crossings - 440) <= 2, "\(crossings) rising zero crossings")
    }

    @Test func vcaScalesAudio() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let vca = try #require(document.addModule(typeID: 7, at: .zero))
        let out = try #require(document.addModule(typeID: 2, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 0.5)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: vca.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: vca.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: out.id, blockPosition: 0, type: .audioIn))
        document.setParam(vca.id, paramIndex: 0, fraction: 0.5)

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var left = [Float](repeating: 0, count: 512)
        var right = left
        for _ in 0..<10 { runtime.render(frames: 512, outputL: &left, outputR: &right) }
        let peak = left.map(abs).max() ?? 0
        #expect(peak > 0.4 && peak < 0.6, "peak \(peak) with level 0.5")
    }

    /// Sequencer → Midi Note Out: each gate edge sends noteOn for the
    /// current step's pitch, and noteOff before the next noteOn.
    @Test func sequencerDrivesMidiNoteOut() throws {
        let document = try makeDocument()
        let lfo = try #require(document.addModule(typeID: 5, at: .zero))
        let seq = try #require(document.addModule(typeID: 4, at: .zero))
        let midiOut = try #require(document.addModule(typeID: 60, at: .zero))
        document.setOption(seq.id, optionIndex: 0, byte: 1)  // 2 steps
        document.setParam(seq.id, paramIndex: 0, fraction: 60.0 / 127.0)
        document.setParam(seq.id, paramIndex: 1, fraction: 67.0 / 127.0)
        document.setParam(lfo.id, paramIndex: 0, fraction: 0.9)
        document.connect(
            from: PortRef(module: lfo.id, blockPosition: 3, type: .cvOut),
            to: PortRef(module: seq.id, blockPosition: 32, type: .cvIn))
        document.connect(
            from: PortRef(module: seq.id, blockPosition: 36, type: .cvOut),
            to: PortRef(module: midiOut.id, blockPosition: 0, type: .cvIn))
        document.connect(
            from: PortRef(module: lfo.id, blockPosition: 3, type: .cvOut),
            to: PortRef(module: midiOut.id, blockPosition: 1, type: .cvIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = MidiRecorder()
        runtime.midi = recorder
        var left = [Float](repeating: 0, count: 64)
        var right = left
        for _ in 0..<4000 { runtime.render(frames: 64, outputL: &left, outputR: &right) }

        let notesOn = recorder.sent.filter { $0.0 == "on" }.map(\.1)
        #expect(notesOn.count >= 4, "\(recorder.sent.count) events")
        #expect(Set(notesOn).isSuperset(of: [60, 67]), "notes \(Set(notesOn))")
        let offs = recorder.sent.filter { $0.0 == "off" }
        #expect(!offs.isEmpty)
    }

    /// Midi Notes In: a held note surfaces as pitch cv + gate on voice 1.
    @Test func midiNotesInProducesGateAndPitch() throws {
        let document = try makeDocument()
        let midiIn = try #require(document.addModule(typeID: 20, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = MidiRecorder()
        recorder.incoming = [MidiEvent(channel: 1, note: 64, kind: .noteOn(velocity: 90))]
        runtime.midi = recorder
        var left = [Float](repeating: 0, count: 64)
        var right = left
        runtime.render(frames: 64, outputL: &left, outputR: &right)
        _ = midiIn
        #expect(runtime.nodes[0].cvOut[1] == 1)
        #expect(abs((runtime.nodes[0].cvOut[0] ?? 0) - 64.0 / 127.0) < 0.001)

        recorder.incoming = [MidiEvent(channel: 1, note: 64, kind: .noteOff)]
        runtime.render(frames: 64, outputL: &left, outputR: &right)
        #expect(runtime.nodes[0].cvOut[1] == 0)
    }

    /// Options resize the param list: a sequencer at 8 steps carries
    /// 8 step params + gate, and shrinking to 2 truncates.
    @Test func optionChangeResizesParams() throws {
        let document = try makeDocument()
        let seq = try #require(document.addModule(typeID: 4, at: .zero))
        #expect(document.modules[0].paramsRaw.count == 2)  // 1 step + gate
        document.setOption(seq.id, optionIndex: 0, byte: 7)  // 8 steps
        #expect(document.modules[0].paramsRaw.count == 9)
        document.setOption(seq.id, optionIndex: 0, byte: 1)  // 2 steps
        #expect(document.modules[0].paramsRaw.count == 3)
    }
}
