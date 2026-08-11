import CoreGraphics
import Foundation
import Testing
@testable import ZoiaCanvas

/// The signal taps behind the Bespoke-ported cable and module
/// animations: gate-event history, recent-change smoothing, the audio
/// viz ring, the highlight formulas, and the arc-length path sampler.
@Suite struct SignalTapTests {
    // MARK: - Gate history

    @Test func gateEdgesRecordEvents() {
        let tap = SignalTap()
        tap.updateCV(0, time: 0.0, blocksPerSecond: 750)
        tap.updateCV(1, time: 0.1, blocksPerSecond: 750)   // rising edge
        tap.updateCV(1, time: 0.11, blocksPerSecond: 750)  // held: no event
        tap.updateCV(0, time: 0.2, blocksPerSecond: 750)   // falling edge

        let events = tap.recentEvents(now: 0.21)
        #expect(events.count == 2)
        #expect(events[0].on == false && events[0].time == 0.2)
        #expect(events[1].on == true && events[1].time == 0.1)
        #expect(tap.lastOnEventTime == 0.1)
    }

    @Test func recentEventsStopAtTravelWindow() {
        let tap = SignalTap()
        for i in 0..<20 {
            tap.updateCV(i % 2 == 0 ? 1 : 0, time: Double(i) * 0.1,
                         blocksPerSecond: 750)
        }
        // At now = 2.0 the events at 1.9 and 1.8 are inside the 250 ms
        // window; 1.7 is the terminator the draw loop needs.
        let events = tap.recentEvents(now: 2.0)
        #expect(events.count == 3)
        #expect(abs((events.last?.time ?? 0) - 1.7) < 1e-9)
    }

    @Test func gateThresholdMatchesRuntimeSemantics() {
        let tap = SignalTap()
        tap.updateCV(0.49, time: 0.0, blocksPerSecond: 750)
        #expect(tap.recentEvents(now: 0.01).isEmpty)
        tap.updateCV(0.5, time: 0.1, blocksPerSecond: 750)
        #expect(tap.recentEvents(now: 0.11).count == 1)
    }

    // MARK: - Recent change (modulation overlay)

    @Test func recentChangeFlaresThenDecays() {
        let tap = SignalTap()
        // Bespoke's exp2 blend settles over a couple of seconds of
        // control blocks (750/s), so give it 2000 blocks to converge.
        for _ in 0..<2000 { tap.updateCV(0.2, time: 0, blocksPerSecond: 750) }
        let settled = abs(tap.recentChange)
        tap.updateCV(0.8, time: 0.1, blocksPerSecond: 750)
        let flared = tap.recentChange
        #expect(settled < 0.01)
        #expect(flared > 0.3)
        for _ in 0..<5000 { tap.updateCV(0.8, time: 0.2, blocksPerSecond: 750) }
        #expect(abs(tap.recentChange) < 0.01)
    }

    @Test func recentChangeSignFollowsDirection() {
        let tap = SignalTap()
        for _ in 0..<2000 { tap.updateCV(0.8, time: 0, blocksPerSecond: 750) }
        tap.updateCV(0.1, time: 0.1, blocksPerSecond: 750)
        #expect(tap.recentChange < -0.3)
    }

    // MARK: - Audio viz ring

    @Test func vizSnapshotIsNewestFirst() {
        let tap = SignalTap()
        tap.updateAudio([Float](repeating: 0, count: SignalTap.vizSize))
        tap.updateAudio([0.1, 0.2, 0.3])
        let snapshot = tap.vizSnapshot()
        #expect(tap.isAudio)
        #expect(snapshot[0] == 0.3)
        #expect(snapshot[1] == 0.2)
        #expect(snapshot[2] == 0.1)
        #expect(snapshot[3] == 0)
    }

    // MARK: - Highlight formulas (Bespoke DrawFrame)

    @Test func audioHighlightTracksLevel() {
        let silent = SignalTap()
        silent.updateAudio([Float](repeating: 0, count: 600))
        #expect(silent.audioHighlight() == 0)

        let loud = SignalTap()
        loud.updateAudio([Float](repeating: 0.5, count: 600))
        // Mean square 0.25 → fourth root ~0.707 → ×3 clamps to 1 → 0.15.
        #expect(abs(loud.audioHighlight() - 0.15) < 0.001)

        let quiet = SignalTap()
        quiet.updateAudio([Float](repeating: 0.01, count: 600))
        let h = quiet.audioHighlight()
        #expect(h > 0.04 && h < 0.15)   // fourth root: sensitive when quiet
    }

    @Test func noteHighlightDecaysOver250ms() {
        let tap = SignalTap()
        tap.updateCV(1, time: 1.0, blocksPerSecond: 750)
        #expect(abs(tap.noteHighlight(now: 1.0) - 0.15) < 0.001)
        #expect(abs(tap.noteHighlight(now: 1.125) - 0.075) < 0.001)
        #expect(tap.noteHighlight(now: 1.3) == 0)
    }

    // MARK: - Cable animation math

    @Test func litWidthStartsThickAndDecays() {
        // At elapsed 0 the pulse head is ~3.5× wide (2 + 1.5 ± 0.15
        // shimmer); by elapsed 1.43 the decay term is gone (2 ± 0.15).
        let head = CableAnimation.litWidth(elapsed: 0, sinceEvent: 0)
        #expect(abs(head - 3.5) <= 0.16)
        let tail = CableAnimation.litWidth(elapsed: 1.5, sinceEvent: 1.5 * 0.25)
        #expect(abs(tail - 2) <= 0.16)
    }

    @Test func compressIsSignedSqrt() {
        #expect(CableAnimation.compress(0.25) == 0.5)
        #expect(CableAnimation.compress(-0.25) == -0.5)
        #expect(CableAnimation.compress(4) == 1)   // clamped
        #expect(CableAnimation.compress(0) == 0)
    }

    @Test func modulationAlphaFadesAtRest() {
        #expect(CableAnimation.modulationAlpha(0) == 0)
        #expect(CableAnimation.modulationAlpha(1) > 0.5)
        #expect(CableAnimation.modulationAlpha(-1) > 0.5)
    }

    // MARK: - Path sampler

    @Test func samplerParameterizesByArcLength() {
        // L-shaped polyline, 100 + 100 long: the halfway fraction lands
        // exactly on the corner, three quarters halfway down the leg.
        let sampler = PathSampler(polyline: [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100),
        ])
        #expect(abs(sampler.length - 200) < 0.001)
        let corner = sampler.point(at: 0.5)
        #expect(abs(corner.x - 100) < 0.001 && abs(corner.y) < 0.001)
        let leg = sampler.point(at: 0.75)
        #expect(abs(leg.x - 100) < 0.001 && abs(leg.y - 50) < 0.001)
    }

    @Test func samplerPerpendicularIsUnitNormal() {
        let sampler = PathSampler(polyline: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)])
        let normal = sampler.perpendicular(at: 0.5)
        #expect(abs(normal.x) < 0.001 && abs(abs(normal.y) - 1) < 0.001)
    }

    @Test func bezierSamplerHitsEndpoints() {
        let sampler = PathSampler(
            from: CGPoint(x: 0, y: 0), control1: CGPoint(x: 50, y: 0),
            control2: CGPoint(x: 50, y: 100), to: CGPoint(x: 100, y: 100))
        let start = sampler.point(at: 0)
        let end = sampler.point(at: 1)
        #expect(abs(start.x) < 0.001 && abs(start.y) < 0.001)
        #expect(abs(end.x - 100) < 0.001 && abs(end.y - 100) < 0.001)
    }
}

/// End-to-end: rendering a patch populates the runtime's taps.
@Suite @MainActor struct RuntimeSignalTapTests {
    @Test func renderPopulatesTapsForOutputs() throws {
        let document = PatchDocument(catalog: try ModuleCatalog.loadBundled())
        // LFO (5) and Oscillator (14): one CV producer, one audio
        // producer, both tapped after a render pass.
        _ = try #require(document.addModule(typeID: 5, at: .zero))
        _ = try #require(document.addModule(typeID: 14, at: CGPoint(x: 300, y: 0)))
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        var left = [Float](repeating: 0, count: 64)
        var right = left
        for block in 0..<200 {
            runtime.render(frames: 64, outputL: &left, outputR: &right,
                           now: Double(block) / 750)
        }
        let cvTapped = runtime.taps.contains { !$0.value.isAudio }
        let audioTapped = runtime.taps.contains { $0.value.isAudio }
        #expect(cvTapped, "LFO cv output should have a tap")
        #expect(audioTapped, "oscillator audio output should have a tap")
        // The oscillator runs at audible level, so its module highlight
        // is pinned at the 0.15 ceiling.
        let audioTap = runtime.taps.first { $0.value.isAudio }!.value
        #expect(audioTap.audioHighlight() > 0.1)
    }
}
