import Foundation
import Testing
@testable import ZoiaCanvas

/// Records every outgoing MIDI message and feeds queued incoming events.
private final class InterfaceMidiRecorder: MidiPort {
    enum Sent: Equatable {
        case noteOn(Int, Int, Int), noteOff(Int, Int)
        case cc(Int, Int, Int), pc(Int, Int)
        case bend(Int, Int), pressure(Int, Int)
        case tick, start, stop, cont, spp(Int)
    }
    var sent: [Sent] = []
    var incoming: [MidiEvent] = []

    func noteOn(channel: Int, note: Int, velocity: Int) { sent.append(.noteOn(channel, note, velocity)) }
    func noteOff(channel: Int, note: Int) { sent.append(.noteOff(channel, note)) }
    func controlChange(channel: Int, controller: Int, value: Int) { sent.append(.cc(channel, controller, value)) }
    func programChange(channel: Int, program: Int) { sent.append(.pc(channel, program)) }
    func pitchBend(channel: Int, value: Int) { sent.append(.bend(channel, value)) }
    func channelPressure(channel: Int, pressure: Int) { sent.append(.pressure(channel, pressure)) }
    func clockTick() { sent.append(.tick) }
    func clockStart() { sent.append(.start) }
    func clockStop() { sent.append(.stop) }
    func clockContinue() { sent.append(.cont) }
    func songPosition(sixteenths: Int) { sent.append(.spp(sixteenths)) }
    func drainIncoming() -> [MidiEvent] {
        defer { incoming = [] }
        return incoming
    }
}

@Suite @MainActor struct RuntimeInterfaceTests {
    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    /// Renders `times` control blocks and returns the last L/R mix.
    @discardableResult
    private func render(_ runtime: PatchRuntime, frames: Int = 64, times: Int = 1,
                        inputL: [Float] = [], inputR: [Float] = []) -> ([Float], [Float]) {
        var left = [Float](repeating: 0, count: frames)
        var right = left
        for _ in 0..<times {
            runtime.render(frames: frames, inputL: inputL, inputR: inputR,
                           outputL: &left, outputR: &right)
        }
        return (left, right)
    }

    // MARK: Buttons

    @Test func pushbuttonMomentaryRespectsNormally() throws {
        let document = try makeDocument()
        let normal = try #require(document.addModule(typeID: 15, at: .zero))
        let inverted = try #require(document.addModule(typeID: 15, at: .zero))
        document.setOption(inverted.id, optionIndex: 1, byte: 1)  // normally one
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime)
        #expect(runtime.nodes[0].cvOut[1] == 0)
        #expect(runtime.nodes[1].cvOut[1] == 1)
        runtime.nodes[0].state(ButtonState()).pressed = true
        runtime.nodes[1].state(ButtonState()).pressed = true
        render(runtime)
        #expect(runtime.nodes[0].cvOut[1] == 1)
        #expect(runtime.nodes[1].cvOut[1] == 0)
        runtime.nodes[0].state(ButtonState()).pressed = false
        render(runtime)
        #expect(runtime.nodes[0].cvOut[1] == 0)
    }

    @Test func pushbuttonLatches() throws {
        let document = try makeDocument()
        let button = try #require(document.addModule(typeID: 15, at: .zero))
        document.setOption(button.id, optionIndex: 0, byte: 1)  // latching
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let state = runtime.nodes[0].state(ButtonState())
        state.pressed = true
        render(runtime)
        state.pressed = false
        render(runtime)
        #expect(runtime.nodes[0].cvOut[1] == 1, "stays engaged after release")
        state.pressed = true
        render(runtime)
        state.pressed = false
        render(runtime)
        #expect(runtime.nodes[0].cvOut[1] == 0, "second press unlatches")
    }

    /// A CV wired into a stompswitch's block acts as the finger; euro
    /// pushbutton shares the pushbutton path.
    @Test func stompswitchFollowsWiredCV() throws {
        let document = try makeDocument()
        let button = try #require(document.addModule(typeID: 15, at: .zero))
        let stomp = try #require(document.addModule(typeID: 44, at: .zero))
        let euro = try #require(document.addModule(typeID: 97, at: .zero))
        document.connect(
            from: PortRef(module: button.id, blockPosition: 1, type: .cvOut),
            to: PortRef(module: stomp.id, blockPosition: 0, type: .cvIn))
        document.connect(
            from: PortRef(module: button.id, blockPosition: 1, type: .cvOut),
            to: PortRef(module: euro.id, blockPosition: 0, type: .cvIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime)
        #expect(runtime.nodes[1].cvOut[0] == 0)
        runtime.nodes[0].state(ButtonState()).pressed = true
        render(runtime)
        #expect(runtime.nodes[1].cvOut[0] == 1)
        #expect(runtime.nodes[2].cvOut[1] == 1)
    }

    @Test func uiButtonOutputsWhenDriven() throws {
        let document = try makeDocument()
        let button = try #require(document.addModule(typeID: 56, at: .zero))
        document.setOption(button.id, optionIndex: 0, byte: 1)  // cv output enabled
        document.setParam(button.id, paramIndex: 0, fraction: 0.8)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime)
        #expect(runtime.nodes[0].cvOut[1] == 1)
        #expect(abs(runtime.nodes[0].state(ButtonState()).display - 0.8) < 0.001)
        runtime.nodes[0].params[0] = 0.2
        render(runtime)
        #expect(runtime.nodes[0].cvOut[1] == 0)
    }

    // MARK: Keyboard

    @Test func keyboardPlaysPressedKey() throws {
        let document = try makeDocument()
        let keyboard = try #require(document.addModule(typeID: 16, at: .zero))
        document.setOption(keyboard.id, optionIndex: 0, byte: 2)  // 3 notes
        document.setParam(keyboard.id, paramIndex: 0, fraction: 0.2)
        document.setParam(keyboard.id, paramIndex: 1, fraction: 0.4)
        document.setParam(keyboard.id, paramIndex: 2, fraction: 0.6)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let state = runtime.nodes[0].state(KeyboardState())
        state.pressedKey = 1
        render(runtime)
        #expect(abs((runtime.nodes[0].cvOut[25] ?? 0) - 0.4) < 0.001)
        #expect(runtime.nodes[0].cvOut[26] == 1)
        #expect(runtime.nodes[0].cvOut[27] == 1, "trigger pulses on press")
        render(runtime)
        #expect(runtime.nodes[0].cvOut[27] == 0, "trigger is a single pulse")
        state.pressedKey = -1
        render(runtime)
        #expect(runtime.nodes[0].cvOut[26] == 0)
        #expect(abs((runtime.nodes[0].cvOut[25] ?? 0) - 0.4) < 0.001, "note holds")
    }

    // MARK: Midi Notes In

    @Test func midiNotesInAllocatesPolyphonicVoices() throws {
        let document = try makeDocument()
        let notesIn = try #require(document.addModule(typeID: 20, at: .zero))
        document.setOption(notesIn.id, optionIndex: 1, byte: 3)  // 4 voices
        document.setOption(notesIn.id, optionIndex: 4, byte: 1)  // velocity out
        document.setOption(notesIn.id, optionIndex: 7, byte: 1)  // trigger out
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        recorder.incoming = [
            MidiEvent(channel: 1, note: 60, kind: .noteOn(velocity: 100)),
            MidiEvent(channel: 1, note: 64, kind: .noteOn(velocity: 110)),
            MidiEvent(channel: 1, note: 67, kind: .noteOn(velocity: 120)),
        ]
        render(runtime)
        let node = runtime.nodes[0]
        #expect(abs((node.cvOut[0] ?? 0) - 60.0 / 127) < 0.001)
        #expect(abs((node.cvOut[4] ?? 0) - 64.0 / 127) < 0.001)
        #expect(abs((node.cvOut[8] ?? 0) - 67.0 / 127) < 0.001)
        #expect(node.cvOut[1] == 1 && node.cvOut[5] == 1 && node.cvOut[9] == 1)
        #expect(node.cvOut[13] == 0, "voice 4 stays idle")
        #expect(abs((node.cvOut[6] ?? 0) - 110.0 / 127) < 0.001, "velocity per voice")
        #expect(node.cvOut[3] == 1 && node.cvOut[7] == 1, "triggers on assignment")
        render(runtime)
        #expect(node.cvOut[3] == 0, "trigger is a single pulse")
        recorder.incoming = [MidiEvent(channel: 1, note: 64, kind: .noteOff)]
        render(runtime)
        #expect(node.cvOut[5] == 0, "released voice gates off")
        #expect(abs((node.cvOut[4] ?? 0) - 64.0 / 127) < 0.001, "note value holds")
        #expect(node.cvOut[1] == 1 && node.cvOut[9] == 1, "other voices keep sounding")
    }

    @Test func midiNotesInPriorityAndNoteRange() throws {
        let document = try makeDocument()
        let notesIn = try #require(document.addModule(typeID: 20, at: .zero))
        document.setOption(notesIn.id, optionIndex: 1, byte: 1)  // 2 voices
        document.setOption(notesIn.id, optionIndex: 2, byte: 3)  // priority lowest
        document.setOption(notesIn.id, optionIndex: 5, byte: 20)  // low note 20
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        recorder.incoming = [
            MidiEvent(channel: 1, note: 10, kind: .noteOn(velocity: 90)),  // below range
            MidiEvent(channel: 1, note: 60, kind: .noteOn(velocity: 90)),
            MidiEvent(channel: 1, note: 64, kind: .noteOn(velocity: 90)),
            MidiEvent(channel: 1, note: 67, kind: .noteOn(velocity: 90)),
        ]
        render(runtime)
        let node = runtime.nodes[0]
        let gatedNotes = Set([0, 4].compactMap { base -> Int? in
            node.cvOut[base + 1] == 1 ? Int(((node.cvOut[base] ?? 0) * 127).rounded()) : nil
        })
        #expect(gatedNotes == [60, 64], "two lowest in-range notes sound: \(gatedNotes)")
    }

    @Test func midiNotesInRoundRobinSteals() throws {
        let document = try makeDocument()
        let notesIn = try #require(document.addModule(typeID: 20, at: .zero))
        document.setOption(notesIn.id, optionIndex: 1, byte: 1)  // 2 voices
        document.setOption(notesIn.id, optionIndex: 2, byte: 4)  // RoundRobin
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        for note in [60, 64, 67] {
            recorder.incoming = [MidiEvent(channel: 1, note: note, kind: .noteOn(velocity: 90))]
            render(runtime)
        }
        let node = runtime.nodes[0]
        #expect(abs((node.cvOut[0] ?? 0) - 67.0 / 127) < 0.001, "third note steals voice 1")
        #expect(abs((node.cvOut[4] ?? 0) - 64.0 / 127) < 0.001)
        #expect(node.cvOut[1] == 1 && node.cvOut[5] == 1)
    }

    // MARK: Midi CC / Pressure / Pitch Bend In

    @Test func midiCCInScalesAndFiltersController() throws {
        let document = try makeDocument()
        let unipolar = try #require(document.addModule(typeID: 21, at: .zero))
        document.setOption(unipolar.id, optionIndex: 1, byte: 74)  // controller 74
        let bipolar = try #require(document.addModule(typeID: 21, at: .zero))
        document.setOption(bipolar.id, optionIndex: 1, byte: 74)
        document.setOption(bipolar.id, optionIndex: 2, byte: 1)  // -1 to 1
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        recorder.incoming = [
            MidiEvent(channel: 1, note: 0, kind: .controlChange(controller: 7, value: 127)),
            MidiEvent(channel: 1, note: 0, kind: .controlChange(controller: 74, value: 64)),
        ]
        render(runtime)
        #expect(abs((runtime.nodes[0].cvOut[0] ?? 0) - 64.0 / 127) < 0.001)
        #expect(abs((runtime.nodes[1].cvOut[0] ?? 0) - (2 * 64.0 / 127 - 1)) < 0.001)
        render(runtime)
        #expect(abs((runtime.nodes[0].cvOut[0] ?? 0) - 64.0 / 127) < 0.001, "value latches")
    }

    @Test func midiPressureAndPitchBendIn() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 35, at: .zero))
        _ = try #require(document.addModule(typeID: 86, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        recorder.incoming = [
            MidiEvent(channel: 1, note: 0, kind: .channelPressure(pressure: 100)),
            MidiEvent(channel: 1, note: 0, kind: .pitchBend(value: 16383)),
        ]
        render(runtime)
        #expect(abs((runtime.nodes[0].cvOut[0] ?? 0) - 100.0 / 127) < 0.001)
        #expect((runtime.nodes[1].cvOut[0] ?? 0) > 0.99)
        recorder.incoming = [MidiEvent(channel: 1, note: 0, kind: .pitchBend(value: 0))]
        render(runtime)
        #expect(abs((runtime.nodes[1].cvOut[0] ?? 0) + 1) < 0.001)
    }

    // MARK: Midi CC / PC Out

    @Test func midiCCOutSendsOnChangeOnly() throws {
        let document = try makeDocument()
        let ccOut = try #require(document.addModule(typeID: 61, at: .zero))
        document.setOption(ccOut.id, optionIndex: 0, byte: 2)  // channel 3
        document.setOption(ccOut.id, optionIndex: 1, byte: 7)  // controller 7
        document.setParam(ccOut.id, paramIndex: 0, fraction: 0.5)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        render(runtime, times: 5)
        #expect(recorder.sent == [.cc(3, 7, 64)], "one send despite five renders")
        runtime.nodes[0].params[0] = 1
        render(runtime)
        #expect(recorder.sent == [.cc(3, 7, 64), .cc(3, 7, 127)])
    }

    @Test func midiPCOutSendsOnTrigger() throws {
        let document = try makeDocument()
        let button = try #require(document.addModule(typeID: 15, at: .zero))
        let pcOut = try #require(document.addModule(typeID: 62, at: .zero))
        document.setParam(pcOut.id, paramIndex: 0, fraction: 0.5)
        document.connect(
            from: PortRef(module: button.id, blockPosition: 1, type: .cvOut),
            to: PortRef(module: pcOut.id, blockPosition: 1, type: .cvIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        render(runtime, times: 2)
        #expect(recorder.sent.isEmpty)
        runtime.nodes[0].state(ButtonState()).pressed = true
        render(runtime, times: 3)
        #expect(recorder.sent == [.pc(1, 64)], "one message per rising edge")
        runtime.nodes[0].state(ButtonState()).pressed = false
        render(runtime)
        runtime.nodes[0].state(ButtonState()).pressed = true
        render(runtime)
        #expect(recorder.sent == [.pc(1, 64), .pc(1, 64)])
    }

    // MARK: Midi Clock

    @Test func midiClockInDerivesTempo() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 82, at: .zero))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        // 48-frame blocks = 1 ms; a tick every 10 renders = 24 ppqn at
        // 250 BPM → quarter period 240 ms.
        func feed(_ renders: Int, onTick: (Int) -> Bool) -> Int {
            var edges = 0
            var last: Float = 1
            for i in 0..<renders {
                if onTick(i) {
                    recorder.incoming = [MidiEvent(channel: 0, note: 0, kind: .clockTick)]
                }
                render(runtime, frames: 48)
                let value = runtime.nodes[0].cvOut[0] ?? 0
                if last < 0.5, value >= 0.5 { edges += 1 }
                last = value
            }
            return edges
        }
        _ = feed(100) { $0 % 10 == 0 }  // settle
        #expect(runtime.nodes[0].cvOut[3] == 1, "run out high while clocked")
        let edges = feed(2400) { $0 % 10 == 0 }
        #expect((8...12).contains(edges), "≈10 quarters in 2.4 s, saw \(edges)")
        // Song position 0 pulses reset out for one block.
        recorder.incoming = [MidiEvent(channel: 0, note: 0, kind: .songPosition(sixteenths: 0)),
                             MidiEvent(channel: 0, note: 0, kind: .clockTick)]
        render(runtime, frames: 48)
        #expect(runtime.nodes[0].cvOut[2] == 1)
        render(runtime, frames: 48)
        #expect(runtime.nodes[0].cvOut[2] == 0)
        // Clock loss drops run out.
        _ = feed(1500) { _ in false }
        #expect(runtime.nodes[0].cvOut[3] == 0, "run out low after clock loss")
    }

    @Test func midiClockOutSendsTicksAndTransport() throws {
        let document = try makeDocument()
        let clockOut = try #require(document.addModule(typeID: 84, at: .zero))
        document.setOption(clockOut.id, optionIndex: 0, byte: 1)  // cv_control
        document.setParam(clockOut.id, paramIndex: 0, fraction: 0.5)  // 120 BPM
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let recorder = InterfaceMidiRecorder()
        runtime.midi = recorder
        render(runtime, frames: 48, times: 1000)  // exactly 1 s
        let ticks = recorder.sent.filter { $0 == .tick }.count
        #expect(abs(ticks - 48) <= 2, "120 BPM → 48 ticks/s, saw \(ticks)")
        // Reset input sends stop / SPP 0 / start once per rising edge.
        let node = runtime.nodes[0]
        let resetParam = try #require(node.paramIndexByPosition[2])
        node.params[resetParam] = 1
        render(runtime, frames: 48, times: 2)
        let transport = recorder.sent.filter { $0 == .stop || $0 == .spp(0) || $0 == .start }
        #expect(transport == [.stop, .spp(0), .start])
    }

    // MARK: CPort and Euro CV stubs

    @Test func cportStubsHonorRanges() throws {
        let document = try makeDocument()
        let expIn = try #require(document.addModule(typeID: 54, at: .zero))
        document.setOption(expIn.id, optionIndex: 0, byte: 1)  // -1 to 1
        let cvOut = try #require(document.addModule(typeID: 55, at: .zero))
        document.setParam(cvOut.id, paramIndex: 0, fraction: 0.6)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        runtime.nodes[0].state(ExternalCVState()).value = 0.5
        render(runtime)
        #expect(abs(runtime.nodes[0].cvOut[0] ?? 1) < 0.001, "0.5 travel → 0 bipolar")
        #expect(abs(runtime.nodes[1].state(ExternalCVState()).volts - 3.0) < 0.01,
                "0.6 → 3 V of the 0–5 V jack")
    }

    @Test func euroCVRangesAndTranspose() throws {
        let document = try makeDocument()
        _ = try #require(document.addModule(typeID: 88, at: .zero))
        let euroOut = try #require(document.addModule(typeID: 99, at: .zero))
        document.setOption(euroOut.id, optionIndex: 2, byte: 1)  // transpose C
        document.setParam(euroOut.id, paramIndex: 0, fraction: 0.5)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        runtime.nodes[0].state(EuroCVInState()).volts = 5  // of default 0–10 V
        render(runtime)
        #expect(abs((runtime.nodes[0].cvOut[0] ?? 0) - 0.5) < 0.001)
        #expect(abs(runtime.nodes[1].state(ExternalCVState()).volts - 4.75) < 0.01,
                "0.5 → 5 V minus 0.25 V C-transpose")
    }

    @Test func euroCVInClockFilterIsSchmitt() throws {
        let document = try makeDocument()
        let euroIn = try #require(document.addModule(typeID: 88, at: .zero))
        document.setOption(euroIn.id, optionIndex: 2, byte: 1)  // 2,8 thresholds
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let state = runtime.nodes[0].state(EuroCVInState())
        state.volts = 5  // 0.5 of range: between thresholds → holds low
        render(runtime)
        #expect(runtime.nodes[0].cvOut[0] == 0)
        state.volts = 9
        render(runtime)
        #expect(runtime.nodes[0].cvOut[0] == 1)
        state.volts = 5  // back between thresholds → holds high
        render(runtime)
        #expect(runtime.nodes[0].cvOut[0] == 1)
        state.volts = 1
        render(runtime)
        #expect(runtime.nodes[0].cvOut[0] == 0)
    }

    // MARK: Euro audio and headphone amp

    @Test func euroAudioAliasesMainChannels() throws {
        let document = try makeDocument()
        let euroIn = try #require(document.addModule(typeID: 93, at: .zero))
        document.setOption(euroIn.id, optionIndex: 0, byte: 2)  // no pad
        let padded = try #require(document.addModule(typeID: 93, at: .zero))  // 6 dB pad
        let euroOut = try #require(document.addModule(typeID: 96, at: .zero))  // right
        document.connect(
            from: PortRef(module: euroIn.id, blockPosition: 0, type: .audioOut),
            to: PortRef(module: euroOut.id, blockPosition: 0, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let ones = [Float](repeating: 1, count: 64)
        let (left, right) = render(runtime, inputL: ones)
        #expect(abs(right[10] - 1) < 0.001, "input 1 → output 2 wire passes through")
        #expect(left[10] == 0)
        let paddedPeak = runtime.nodes[1].audioOut[0]?[10] ?? 0
        #expect(abs(paddedPeak - pow(10, -6.0 / 20)) < 0.01, "default 6 dB pad")
    }

    @Test func euroHeadphoneAmpScalesMix() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let out = try #require(document.addModule(typeID: 2, at: .zero))
        let amp = try #require(document.addModule(typeID: 92, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 0.5)
        document.setParam(amp.id, paramIndex: 0, fraction: 0.5)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: out.id, blockPosition: 0, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let (left, _) = render(runtime, frames: 512, times: 10)
        let peak = left.map(abs).max() ?? 0
        #expect(peak > 0.4 && peak < 0.6, "level 0.5 halves the mix, peak \(peak)")
    }

    @Test func audioOutputGainOptionIsDecibels() throws {
        let document = try makeDocument()
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let out = try #require(document.addModule(typeID: 2, at: .zero))
        document.setOption(out.id, optionIndex: 0, byte: 1)  // gain control
        document.setParam(osc.id, paramIndex: 0, fraction: 0.5)
        document.setParam(out.id, paramIndex: 0, fraction: 5.0 / 6.0)  // 0 dB
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: out.id, blockPosition: 0, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let (left, _) = render(runtime, frames: 512, times: 10)
        let peak = left.map(abs).max() ?? 0
        #expect(peak > 0.9 && peak < 1.1, "cv 5/6 = 0 dB (unity), peak \(peak)")
        runtime.nodes[1].params[0] = 0.5  // -40 dB
        let (quiet, _) = render(runtime, frames: 512, times: 10)
        let quietPeak = quiet.map(abs).max() ?? 0
        #expect(quietPeak < 0.02, "cv 0.5 = -40 dB, peak \(quietPeak)")
    }

    // MARK: Pixel and Device Control

    @Test func pixelStoresDisplayLevel() throws {
        let document = try makeDocument()
        let pixel = try #require(document.addModule(typeID: 81, at: .zero))
        document.setParam(pixel.id, paramIndex: 0, fraction: 0.7)
        let audioPixel = try #require(document.addModule(typeID: 81, at: .zero))
        document.setOption(audioPixel.id, optionIndex: 0, byte: 1)  // audio
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        document.setParam(osc.id, paramIndex: 0, fraction: 0.5)
        document.connect(
            from: PortRef(module: osc.id, blockPosition: 3, type: .audioOut),
            to: PortRef(module: audioPixel.id, blockPosition: 1, type: .audioIn))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime, frames: 512, times: 4)
        #expect(abs((runtime.nodes[0].cvOut[0] ?? 0) - 0.7) < 0.001)
        #expect((runtime.nodes[1].cvOut[1] ?? 0) > 0.5, "audio pixel tracks signal peak")
    }

    @Test func deviceControlTracksState() throws {
        let document = try makeDocument()
        let control = try #require(document.addModule(typeID: 103, at: .zero))
        document.setOption(control.id, optionIndex: 0, byte: 2)  // perform
        document.setParam(control.id, paramIndex: 0, fraction: 1)
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        render(runtime)
        #expect(runtime.nodes[0].state(DeviceControlState()).engaged)
        runtime.nodes[0].params[0] = 0
        render(runtime)
        #expect(!runtime.nodes[0].state(DeviceControlState()).engaged)
    }
}
