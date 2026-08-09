import CoreMIDI
import Foundation

/// CoreMIDI-backed MidiPort exposing two virtual endpoints: "ZoiaCanvas
/// Out" (a source other apps can read) and "ZoiaCanvas In" (a destination
/// they can send to). Incoming notes are queued and drained by the render
/// thread.
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
                // MIDI 1.0 channel voice inside UMP: 0x2gssccnnvv.
                guard word >> 28 == 0x2 else { continue }
                let status = (word >> 20) & 0xF
                let channel = Int((word >> 16) & 0xF) + 1
                let note = Int((word >> 8) & 0x7F)
                let velocity = Int(word & 0x7F)
                switch status {
                case 0x9 where velocity > 0:
                    events.append(MidiEvent(channel: channel, note: note,
                                            kind: .noteOn(velocity: velocity)))
                case 0x8, 0x9:
                    events.append(MidiEvent(channel: channel, note: note, kind: .noteOff))
                default:
                    break
                }
            }
            packet = MIDIEventPacketNext(&packet).pointee
        }
        if !events.isEmpty {
            lock.lock()
            queue.append(contentsOf: events)
            lock.unlock()
        }
    }

    func drainIncoming() -> [MidiEvent] {
        lock.lock()
        defer { queue.removeAll(); lock.unlock() }
        return queue
    }

    private func send(status: UInt32, channel: Int, note: Int, velocity: Int) {
        var eventList = MIDIEventList()
        let packet = MIDIEventListInit(&eventList, ._1_0)
        let channelBits = UInt32(max(0, min(channel - 1, 15)))
        let word: UInt32 = 0x20000000
            | (status << 20) | (channelBits << 16)
            | (UInt32(note & 0x7F) << 8) | UInt32(velocity & 0x7F)
        _ = MIDIEventListAdd(&eventList, MemoryLayout<MIDIEventList>.size,
                             packet, 0, 1, [word])
        MIDIReceivedEventList(source, &eventList)
    }

    func noteOn(channel: Int, note: Int, velocity: Int) {
        send(status: 0x9, channel: channel, note: note, velocity: velocity)
    }

    func noteOff(channel: Int, note: Int) {
        send(status: 0x8, channel: channel, note: note, velocity: 0)
    }
}
