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
    private var inputCapture: InputCapture?
    private(set) var isRunning = false
    private(set) var lastError: String?

    func start(document: PatchDocument) {
        rebuild(document: document)
        guard sourceNode == nil else { resume(); return }

        let format = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let box = runtimeBox
        let ring = InputRingBuffer()
        let node = AVAudioSourceNode(format: AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2)!) { _, _, frameCount, audioBufferList -> OSStatus in
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

    /// Installs the capture tap on the input node. Returns a warning string
    /// when live input is unavailable — output still renders, Audio Input
    /// modules just read silence.
    private func installInputTap(into ring: InputRingBuffer,
                                 outputSampleRate: Double) -> String? {
        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            return "No audio input device — Audio Input modules read silence."
        }
        guard let capture = InputCapture(inputFormat: inputFormat,
                                         outputSampleRate: outputSampleRate,
                                         ring: ring) else {
            return "Unsupported input format (\(inputFormat)) — Audio Input modules read silence."
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
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
