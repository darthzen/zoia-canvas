import AVFoundation
import Foundation

/// Owns the AVAudioEngine, the CoreMIDI ports, and the live PatchRuntime.
/// The runtime is swapped atomically when the document changes; render
/// callbacks keep running against the old graph until the swap.
///
/// Live play-through: a tap on `engine.inputNode` captures the input device,
/// `InputCapture` converts it to the output sample rate/format, and the
/// `AVAudioSourceNode` render callback pulls frames out of an
/// `InputRingBuffer` to feed Audio Input modules. Underrun reads silence;
/// the render thread never blocks beyond the ring's short lock.
@MainActor
@Observable
final class AudioEngine {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let midiPort = CoreMidiPort()
    private let runtimeBox = RuntimeBox()
    private let inputRing = InputRingBuffer()
    private var inputCapture: InputCapture?
    private(set) var isRunning = false
    private(set) var lastError: String?
    /// Selected capture device; nil follows the system default input.
    private(set) var inputDeviceID: AudioDeviceID?

    func start(document: PatchDocument) {
        rebuild(document: document)
        guard sourceNode == nil else { resume(); return }

        let format = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let box = runtimeBox
        let ring = inputRing
        // @Sendable keeps the render closure out of MainActor isolation:
        // formed inside this @MainActor method it would otherwise inherit
        // it, and Swift 6's runtime isolation check then traps (SIGTRAP)
        // on the CoreAudio IO thread the first time a device pulls audio.
        let node = AVAudioSourceNode(format: AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2)!) { @Sendable _, _, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            var inLeft = [Float](repeating: 0, count: frames)
            var inRight = [Float](repeating: 0, count: frames)
            ring.read(frames: frames, intoLeft: &inLeft, right: &inRight)
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            box.withRuntime { runtime in
                runtime?.render(frames: frames, inputL: inLeft, inputR: inRight,
                                outputL: &left, outputR: &right)
            }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if buffers.count >= 2 {
                left.withUnsafeBufferPointer {
                    buffers[0].mData?.copyMemory(from: $0.baseAddress!, byteCount: frames * 4)
                }
                right.withUnsafeBufferPointer {
                    buffers[1].mData?.copyMemory(from: $0.baseAddress!, byteCount: frames * 4)
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nil)
        sourceNode = node
        let inputWarning = installInputTap(into: ring, outputSampleRate: sampleRate)
        resume()
        if lastError == nil { lastError = inputWarning }
    }

    // MARK: - Input routing

    struct InputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let name: String
    }

    /// Every CoreAudio device with input channels — the mic, but also
    /// virtual loopbacks (BlackHole, Loopback) and aggregates, which is
    /// how another app's output gets routed into the patch.
    static func availableInputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let name = deviceName(id) else { return nil }
            return InputDevice(id: id, name: name)
        }
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return name as String?
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Points the capture side at a specific input device (nil = system
    /// default). The engine restarts around the switch and the tap is
    /// reinstalled at the new device's format.
    func selectInput(deviceID: AudioDeviceID?) {
        let wasRunning = isRunning
        engine.stop()
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        inputCapture = nil
        do {
            guard let target = deviceID ?? Self.defaultInputDeviceID() else {
                throw NSError(domain: "ZoiaCanvas", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "no input device available"])
            }
            try engine.inputNode.auAudioUnit.setDeviceID(target)
            inputDeviceID = deviceID
        } catch {
            lastError = "Input switch failed: \(error.localizedDescription)"
        }
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let warning = installInputTap(into: inputRing,
                                      outputSampleRate: sampleRate > 0 ? sampleRate : 48000)
        if wasRunning {
            resume()
            if lastError == nil { lastError = warning }
        }
    }

    /// Installs the capture tap on the input node. Returns a warning string
    /// when live input is unavailable — output still renders, Audio Input
    /// modules just read silence.
    private func installInputTap(into ring: InputRingBuffer,
                                 outputSampleRate: Double) -> String? {
        let input = engine.inputNode
        input.removeTap(onBus: 0)  // safe when none; guards double-install
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return "No audio input device — Audio Input modules read silence."
        }
        guard let capture = InputCapture(inputFormat: inputFormat,
                                         outputSampleRate: outputSampleRate,
                                         ring: ring) else {
            return "Unsupported input format (\(inputFormat)) — Audio Input modules read silence."
        }
        // Same @Sendable escape hatch as the render closure: the tap fires
        // on an audio thread and must not carry MainActor isolation.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable buffer, _ in
            capture.process(buffer)
        }
        inputCapture = capture
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            return "Microphone access denied in System Settings — Audio Input modules read silence."
        }
        return nil
    }

    private func resume() {
        do {
            try engine.start()
            isRunning = true
            lastError = nil
        } catch {
            lastError = "Audio engine failed to start: \(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        engine.pause()
        isRunning = false
    }

    /// Peak output level per (module index, block) pair, for the cable
    /// activity lights. One lock round-trip for the whole list; the box
    /// lock also serializes against the render callback, so the node
    /// dictionaries are never read mid-mutation. Entries with a negative
    /// module index (unresolved) read 0.
    func sourceLevels(_ sources: [(module: Int, block: Int)]) -> [Float] {
        var levels = [Float](repeating: 0, count: sources.count)
        guard isRunning else { return levels }
        runtimeBox.withRuntime { runtime in
            guard let runtime else { return }
            for (i, source) in sources.enumerated()
            where source.module >= 0 && source.module < runtime.nodes.count {
                let node = runtime.nodes[source.module]
                if let cv = node.cvOut[source.block] {
                    levels[i] = abs(cv)
                } else if let audio = node.audioOut[source.block] {
                    levels[i] = audio.reduce(0) { max($0, abs($1)) }
                }
            }
        }
        return levels
    }

    /// Rebuilds the runtime from the current document; safe to call while
    /// rendering.
    func rebuild(document: PatchDocument) {
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let runtime = PatchRuntime(document: document,
                                   sampleRate: sampleRate > 0 ? sampleRate : 48000)
        runtime.midi = midiPort
        runtimeBox.replace(runtime)
    }
}

/// Lock-guarded handoff between the main thread (rebuilds) and the audio
/// render thread (reads).
final class RuntimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var runtime: PatchRuntime?

    func replace(_ new: PatchRuntime) {
        lock.lock()
        runtime = new
        lock.unlock()
    }

    func withRuntime(_ body: (PatchRuntime?) -> Void) {
        lock.lock()
        body(runtime)
        lock.unlock()
    }
}

/// Stereo FIFO between the input tap thread (writes) and the render thread
/// (reads), lock-guarded in the same style as RuntimeBox. Overflow drops the
/// oldest frames, which bounds capture-to-render latency to `capacity`
/// frames; underrun zero-fills the tail so the render thread never blocks.
final class InputRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var left: [Float]
    private var right: [Float]
    let capacity: Int
    private var head = 0        // next write index, 0..<capacity
    private var available = 0   // readable frames

    /// 8192 frames ≈ 170 ms at 48 kHz — comfortably above the ~4800-frame
    /// buffers macOS hands input taps regardless of the requested size.
    init(capacity: Int = 8192) {
        self.capacity = max(1, capacity)
        left = [Float](repeating: 0, count: self.capacity)
        right = [Float](repeating: 0, count: self.capacity)
    }

    func write(left inL: UnsafePointer<Float>, right inR: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        if count >= capacity {
            // Oversized write: keep only the most recent `capacity` frames.
            let offset = count - capacity
            for i in 0..<capacity {
                left[i] = inL[offset + i]
                right[i] = inR[offset + i]
            }
            head = 0
            available = capacity
            return
        }
        for i in 0..<count {
            left[head] = inL[i]
            right[head] = inR[i]
            head = (head + 1) % capacity
        }
        available = min(available + count, capacity)
    }

    func write(left inL: [Float], right inR: [Float]) {
        let count = min(inL.count, inR.count)
        guard count > 0 else { return }
        inL.withUnsafeBufferPointer { l in
            inR.withUnsafeBufferPointer { r in
                write(left: l.baseAddress!, right: r.baseAddress!, count: count)
            }
        }
    }

    /// Copies the oldest available frames into the front of outL/outR and
    /// zero-fills the remainder on underrun.
    func read(frames: Int, intoLeft outL: inout [Float], right outR: inout [Float]) {
        let frames = min(frames, outL.count, outR.count)
        lock.lock()
        let n = min(frames, available)
        var tail = (head - available + 2 * capacity) % capacity
        for i in 0..<n {
            outL[i] = left[tail]
            outR[i] = right[tail]
            tail = (tail + 1) % capacity
        }
        available -= n
        lock.unlock()
        for i in n..<frames {
            outL[i] = 0
            outR[i] = 0
        }
    }
}

/// Runs on the input tap thread: converts each captured buffer to the render
/// sample rate/format (AVAudioConverter when they differ) and deposits it in
/// the ring buffer. Mono input is duplicated to both channels; for inputs
/// with more than two channels the converter's default downmix applies.
final class InputCapture: @unchecked Sendable {
    private let ring: InputRingBuffer
    private let converter: AVAudioConverter?
    private let convertedFormat: AVAudioFormat?  // nil = passthrough

    init?(inputFormat: AVAudioFormat, outputSampleRate: Double, ring: InputRingBuffer) {
        self.ring = ring
        if inputFormat.sampleRate == outputSampleRate,
           inputFormat.commonFormat == .pcmFormatFloat32,
           !inputFormat.isInterleaved {
            converter = nil
            convertedFormat = nil
        } else {
            // Convert at the input's own channel count (clamped to stereo) so
            // rate conversion never invents a channel mapping for mono input;
            // duplication to L/R happens deterministically in process().
            let channels = min(inputFormat.channelCount, 2)
            guard let target = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate,
                                             channels: channels),
                  let converter = AVAudioConverter(from: inputFormat, to: target) else {
                return nil
            }
            self.converter = converter
            convertedFormat = target
        }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        let source: AVAudioPCMBuffer
        if let converter, let format = convertedFormat {
            let ratio = format.sampleRate / buffer.format.sampleRate
            let cap = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return }
            var fed = false
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }
            guard status != .error else { return }
            source = out
        } else {
            source = buffer
        }
        guard let data = source.floatChannelData else { return }
        let frames = Int(source.frameLength)
        guard frames > 0 else { return }
        let leftChannel = data[0]
        let rightChannel = source.format.channelCount > 1 ? data[1] : data[0]
        ring.write(left: leftChannel, right: rightChannel, count: frames)
    }
}
