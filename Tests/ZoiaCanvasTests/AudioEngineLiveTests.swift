import Foundation
import Testing
@testable import ZoiaCanvas

/// Starts the real AVAudioEngine so CoreAudio's IO thread executes the
/// source-node render closure — the one code path offline rendering never
/// touches. Regression for the 2026-08-09 Play crash: that closure
/// inherited MainActor isolation from the enclosing method and Swift 6's
/// runtime isolation check trapped (SIGTRAP) on the IO thread; with the
/// bug present this test kills the process. Empty document, so nothing
/// is audible.
@Suite @MainActor struct AudioEngineLiveTests {
    @Test func engineSurvivesLiveRenderCallbacks() async throws {
        let engine = AudioEngine()
        let document = PatchDocument(catalog: try ModuleCatalog.loadBundled())
        engine.start(document: document)
        try #require(engine.isRunning, "engine failed to start: \(engine.lastError ?? "no error")")
        try await Task.sleep(for: .seconds(1))
        #expect(engine.isRunning)
        engine.stop()
    }
}
