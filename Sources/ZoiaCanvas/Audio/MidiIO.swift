import CoreMIDI
import Foundation

/// CoreMIDI-backed MidiPort exposing two virtual endpoints: "ZoiaCanvas
/// Out" (a source other apps can read) and "ZoiaCanvas In" (a destination
/// they can send to). Incoming events are queued and drained by the
/// render thread.
final class CoreMidiPort: MidiPort, @unchecked Sendable {
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var destination = MIDIEndpointRef()
    private let lock = NSLock()
    private var queue: [MidiEvent] = []

    init?() {
        guard MIDIClientCreateWithBlock("ZoiaCanvas" as CFString, &client, nil) == noErr,
              MIDISourceCreateWithProtocol(client, "ZoiaCanvas Out" as CFString,
                                           ._1_0, &source) == noErr else { return nil }
        let status = MIDIDestinationCreateWithProtocol(
            client, "ZoiaCanvas In" as CFString, ._1_0, &destination
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard status == noErr else { return nil }
    }

    deinit {
        MIDIEndpointDispose(source)
        MIDIEndpointDispose(destination)
        MIDIClientDispose(client)
    }

    // MARK: - Receive

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        var events: [MidiEvent] = []
        var packet = eventList.pointee.packet
        for _ in 0..<eventList.pointee.numPackets {
            let words = withUnsafeBytes(of: packet.words) { raw in
                (0..<Int(packet.wordCount)).map {
                    raw.load(fromByteOffset: $0 * 4, as: UInt32.self)
                }
            }
            for word in words {
                if let event = Self.decode(word) { events.append(event) }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
        if !events.isEmpty {
            lock.lock()
            queue.append(contentsOf: events)
            lock.unlock()
        }
    }

    /// Decodes one UMP word: MIDI 1.0 channel voice (0x2gscd1d2) and
    /// system common/realtime (0x10ssd1d2) messages.
    private static func decode(_ word: UInt32) -> MidiEvent? {
        switch word >> 28 {
        case 0x2:
            let status = (word >> 20) & 0xF
            let channel = Int((word >> 16) & 0xF) + 1
            let d1 = Int((word >> 8) & 0x7F)
            let d2 = Int(word & 0x7F)
            switch status {
            case 0x9 where d2 > 0:
                return MidiEvent(channel: channel, note: d1, kind: .noteOn(velocity: d2))
            case 0x8, 0x9:
                return MidiEvent(channel: channel, note: d1, kind: .noteOff)
            case 0xB:
                return MidiEvent(channel: channel, note: 0,
                                 kind: .controlChange(controller: d1, value: d2))
            case 0xC:
                return MidiEvent(channel: channel, note: 0, kind: .programChange(program: d1))
            case 0xD:
                return MidiEvent(channel: channel, note: 0, kind: .channelPressure(pressure: d1))
            case 0xE:
                return MidiEvent(channel: channel, note: 0,
                                 kind: .pitchBend(value: d2 << 7 | d1))
            default:
                return nil
            }
        case 0x1:
            let status = (word >> 16) & 0xFF
            let d1 = Int((word >> 8) & 0x7F)
            let d2 = Int(word & 0x7F)
            switch status {
            case 0xF8: return MidiEvent(channel: 0, note: 0, kind: .clockTick)
            case 0xFA: return MidiEvent(channel: 0, note: 0, kind: .clockStart)
            case 0xFB: return MidiEvent(channel: 0, note: 0, kind: .clockContinue)
            case 0xFC: return MidiEvent(channel: 0, note: 0, kind: .clockStop)
            case 0xF2:
                return MidiEvent(channel: 0, note: 0,
                                 kind: .songPosition(sixteenths: d2 << 7 | d1))
            default: return nil
            }
        default:
            return nil
        }
    }

    func drainIncoming() -> [MidiEvent] {
        lock.lock()
        defer { queue.removeAll(); lock.unlock() }
        return queue
    }

    // MARK: - Send

    private func sendWord(_ word: UInt32) {
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        _ = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size,
                             packet, 0, 1, [word])
        MIDIReceivedEventList(source, &eventList)
    }

    private func voice(_ status: UInt32, channel: Int, _ d1: Int, _ d2: Int) {
        let channelBits = UInt32(max(0, min(channel - 1, 15)))
        sendWord(0x20000000
            | (status << 20) | (channelBits << 16)
            | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F))
    }

    private func system(_ status: UInt32, _ d1: Int = 0, _ d2: Int = 0) {
        sendWord(0x10000000 | (status << 16)
            | (UInt32(d1 & 0x7F) << 8) | UInt32(d2 & 0x7F))
    }

    func noteOn(channel: Int, note: Int, velocity: Int) {
        voice(0x9, channel: channel, note, velocity)
    }

    func noteOff(channel: Int, note: Int) {
        voice(0x8, channel: channel, note, 0)
    }

    func controlChange(channel: Int, controller: Int, value: Int) {
        voice(0xB, channel: channel, controller, value)
    }

    func programChange(channel: Int, program: Int) {
        voice(0xC, channel: channel, program, 0)
    }

    func pitchBend(channel: Int, value: Int) {
        voice(0xE, channel: channel, value & 0x7F, (value >> 7) & 0x7F)
    }

    func channelPressure(channel: Int, pressure: Int) {
        voice(0xD, channel: channel, pressure, 0)
    }

    func clockTick() { system(0xF8) }
    func clockStart() { system(0xFA) }
    func clockStop() { system(0xFC) }
    func clockContinue() { system(0xFB) }

    func songPosition(sixteenths: Int) {
        system(0xF2, sixteenths & 0x7F, (sixteenths >> 7) & 0x7F)
    }
}
