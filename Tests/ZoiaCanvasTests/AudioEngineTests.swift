import AVFoundation
import Foundation
import Testing
@testable import ZoiaCanvas

/// Ring buffer and input-capture components of the live play-through path.
/// Deliberately no test touches the live microphone or starts the engine:
/// test hosts may lack an input device or mic permission, and engine start
/// can fail headless — the components carry the logic, so they get the tests.
@Suite struct InputRingBufferTests {
    @Test func readOfEmptyRingReturnsSilence() {
        let ring = InputRingBuffer(capacity: 64)
        var left = [Float](repeating: 9, count: 16)
        var right = [Float](repeating: 9, count: 16)
        ring.read(frames: 16, intoLeft: &left, right: &right)
        #expect(left.allSatisfy { $0 == 0 })
        #expect(right.allSatisfy { $0 == 0 })
    }

    @Test func roundTripPreservesOrderAndChannels() {
        let ring = InputRingBuffer(capacity: 64)
        let inLeft = (0..<10).map { Float($0) }
        let inRight = (0..<10).map { Float($0) + 100 }
        ring.write(left: inLeft, right: inRight)
        var left = [Float](repeating: -1, count: 10)
        var right = [Float](repeating: -1, count: 10)
        ring.read(frames: 10, intoLeft: &left, right: &right)
        #expect(left == inLeft)
        #expect(right == inRight)
    }

    @Test func partialUnderrunZeroFillsTail() {
        let ring = InputRingBuffer(capacity: 64)
        ring.write(left: [1, 2, 3, 4], right: [5, 6, 7, 8])
        var left = [Float](repeating: -1, count: 8)
        var right = [Float](repeating: -1, count: 8)
        ring.read(frames: 8, intoLeft: &left, right: &right)
        #expect(left == [1, 2, 3, 4, 0, 0, 0, 0])
        #expect(right == [5, 6, 7, 8, 0, 0, 0, 0])
    }

    @Test func wraparoundAcrossCapacityBoundary() {
        let ring = InputRingBuffer(capacity: 8)
        var left = [Float](repeating: 0, count: 6)
        var right = [Float](repeating: 0, count: 6)
        // First pass fills indices 0..5; second pass wraps through 6,7,0..3.
        ring.write(left: [1, 2, 3, 4, 5, 6], right: [1, 2, 3, 4, 5, 6])
        ring.read(frames: 6, intoLeft: &left, right: &right)
        ring.write(left: [7, 8, 9, 10, 11, 12], right: [7, 8, 9, 10, 11, 12])
        ring.read(frames: 6, intoLeft: &left, right: &right)
        #expect(left == [7, 8, 9, 10, 11, 12])
        #expect(right == [7, 8, 9, 10, 11, 12])
    }

    @Test func overflowDropsOldestFrames() {
        let ring = InputRingBuffer(capacity: 8)
        let input = (1...12).map(Float.init)
        ring.write(left: input, right: input)  // 12 frames into 8 slots
        var left = [Float](repeating: 0, count: 8)
        var right = [Float](repeating: 0, count: 8)
        ring.read(frames: 8, intoLeft: &left, right: &right)
        #expect(left == [5, 6, 7, 8, 9, 10, 11, 12])
        #expect(right == left)
    }

    @Test func oversizedSingleWriteKeepsMostRecentFrames() {
        let ring = InputRingBuffer(capacity: 8)
        let input = (1...20).map(Float.init)
        ring.write(left: input, right: input)
        var left = [Float](repeating: 0, count: 8)
        var right = [Float](repeating: 0, count: 8)
        ring.read(frames: 8, intoLeft: &left, right: &right)
        #expect(left == [13, 14, 15, 16, 17, 18, 19, 20])
    }
}

@Suite struct InputCaptureTests {
    /// 24 kHz mono in, 48 kHz stereo render rate: the converter must resample
    /// and the capture must duplicate mono to both channels.
    @Test func convertsSampleRateAndDuplicatesMono() throws {
        let inputFormat = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        let ring = InputRingBuffer(capacity: 8192)
        let capture = try #require(
            InputCapture(inputFormat: inputFormat, outputSampleRate: 48000, ring: ring))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 240))
        buffer.frameLength = 240
        for i in 0..<240 { buffer.floatChannelData![0][i] = 0.5 }
        capture.process(buffer)

        var left = [Float](repeating: 0, count: 400)
        var right = [Float](repeating: 0, count: 400)
        ring.read(frames: 400, intoLeft: &left, right: &right)
        // Converter priming can soften the first samples; check mid-buffer DC.
        #expect(abs(left[200] - 0.5) < 0.05, "left mid-buffer \(left[200])")
        #expect(abs(right[200] - 0.5) < 0.05, "right mid-buffer \(right[200])")
    }

    @Test func matchingFormatPassesThroughUnchanged() throws {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let ring = InputRingBuffer(capacity: 256)
        let capture = try #require(
            InputCapture(inputFormat: format, outputSampleRate: 48000, ring: ring))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        buffer.frameLength = 16
        for i in 0..<16 {
            buffer.floatChannelData![0][i] = Float(i)
            buffer.floatChannelData![1][i] = Float(i) + 100
        }
        capture.process(buffer)

        var left = [Float](repeating: 0, count: 16)
        var right = [Float](repeating: 0, count: 16)
        ring.read(frames: 16, intoLeft: &left, right: &right)
        #expect(left == (0..<16).map(Float.init))
        #expect(right == (0..<16).map { Float($0) + 100 })
    }
}

/// Offline render-path wiring: Audio Input module → Audio Output module must
/// reproduce injected input buffers through PatchRuntime.render.
@Suite @MainActor struct AudioEnginePlayThroughTests {
    private func makeDocument() throws -> PatchDocument {
        PatchDocument(catalog: try ModuleCatalog.loadBundled())
    }

    @Test func audioInputFeedsThroughToOutput() throws {
        let document = try makeDocument()
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let output = try #require(document.addModule(typeID: 2, at: .zero))
        document.connect(
            from: PortRef(module: input.id, blockPosition: 0, type: .audioOut),
            to: PortRef(module: output.id, blockPosition: 0, type: .audioIn))
        document.connect(
            from: PortRef(module: input.id, blockPosition: 1, type: .audioOut),
            to: PortRef(module: output.id, blockPosition: 1, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let frames = 64
        let inLeft = (0..<frames).map { Float($0) / Float(frames) }
        let inRight = inLeft.map { -$0 }
        var outLeft = [Float](repeating: 0, count: frames)
        var outRight = [Float](repeating: 0, count: frames)
        runtime.render(frames: frames, inputL: inLeft, inputR: inRight,
                       outputL: &outLeft, outputR: &outRight)
        #expect(outLeft == inLeft)
        #expect(outRight == inRight)
    }

    @Test func leftOnlyInputRoutesLeftChannelOnly() throws {
        let document = try makeDocument()
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let output = try #require(document.addModule(typeID: 2, at: .zero))
        document.setOption(input.id, optionIndex: 0, byte: 1)  // channels: left
        document.connect(
            from: PortRef(module: input.id, blockPosition: 0, type: .audioOut),
            to: PortRef(module: output.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let frames = 32
        let inLeft = [Float](repeating: 0.25, count: frames)
        let inRight = [Float](repeating: 0.75, count: frames)
        var outLeft = [Float](repeating: 9, count: frames)
        var outRight = [Float](repeating: 9, count: frames)
        runtime.render(frames: frames, inputL: inLeft, inputR: inRight,
                       outputL: &outLeft, outputR: &outRight)
        #expect(outLeft == inLeft)
        #expect(outRight.allSatisfy { $0 == 0 })
    }

    /// Missing capture (empty input buffers) must render silence, not crash —
    /// the app-level behavior when no input device is present.
    @Test func absentInputBuffersRenderSilence() throws {
        let document = try makeDocument()
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let output = try #require(document.addModule(typeID: 2, at: .zero))
        document.connect(
            from: PortRef(module: input.id, blockPosition: 0, type: .audioOut),
            to: PortRef(module: output.id, blockPosition: 0, type: .audioIn))

        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var outLeft = [Float](repeating: 9, count: 64)
        var outRight = [Float](repeating: 9, count: 64)
        runtime.render(frames: 64, outputL: &outLeft, outputR: &outRight)
        #expect(outLeft.allSatisfy { $0 == 0 })
        #expect(outRight.allSatisfy { $0 == 0 })
    }

    /// Runtime swaps and stop() must be safe without ever starting the
    /// engine — start() is untested by design (headless hosts may have no
    /// input device or mic permission).
    @Test func rebuildAndStopAreSafeWithoutStart() throws {
        let engine = AudioEngine()
        engine.rebuild(document: try makeDocument())
        engine.rebuild(document: try makeDocument())
        engine.stop()
        #expect(engine.isRunning == false)
    }
}
