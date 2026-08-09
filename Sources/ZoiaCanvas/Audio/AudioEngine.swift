import AVFoundation
import Foundation

/// Owns the AVAudioEngine, the CoreMIDI ports, and the live PatchRuntime.
/// The runtime is swapped atomically when the document changes; render
/// callbacks keep running against the old graph until the swap.
@MainActor
@Observable
final class AudioEngine {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let midiPort = CoreMidiPort()
    private let runtimeBox = RuntimeBox()
    private(set) var isRunning = false
    private(set) var lastError: String?

    func start(document: PatchDocument) {
        rebuild(document: document)
        guard sourceNode == nil else { resume(); return }

        let format = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        let box = runtimeBox
        let node = AVAudioSourceNode(format: AVAudioFormat(
            standardFormatWithSampleRate: sampleRate, channels: 2)!) { _, _, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            box.withRuntime { runtime in
                runtime?.render(frames: frames, outputL: &left, outputR: &right)
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
        resume()
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
