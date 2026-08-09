import Foundation
import Testing
@testable import ZoiaCanvas

/// Coverage for the sequencer saved_data step matrix — the format-level
/// decode against known factory patches, the corpus-wide structural
/// invariants the layout rests on, and the runtime playing tracks 2+.
private final class CorpusLocator {}

private func corpusURL(_ relPath: String) throws -> URL {
    let bundle = Bundle(for: CorpusLocator.self)
    let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"),
                            "Corpus folder missing from test bundle")
    return root.appendingPathComponent(relPath)
}

private func sequencerEntries(_ relPath: String) throws -> [ZoiaModuleEntry] {
    let patch = try ZoiaPatchBinary.decode(Data(contentsOf: corpusURL(relPath)))
    return patch.modules.filter { $0.typeID == 4 }
}

@Suite struct SequencerSavedDataTests {
    /// Fake Beard's sequencer is a 4-step, 4-track diagonal: track n
    /// fires only on step n−1 (track 1 in params, tracks 2–4 in the
    /// matrix). The cleanest structural witness in the corpus.
    @Test func decodesFakeBeardDiagonal() throws {
        let seq = try #require(try sequencerEntries("Factory/019_zoia_Fake_Beard.bin").first)
        #expect(seq.optionBytes[0] == 3 && seq.optionBytes[1] == 3, "4 steps, 4 tracks")
        for track in 1...3 {
            for step in 0...3 {
                let value = try #require(SequencerSavedData.step(seq.savedData, track: track, step: step))
                let expected: Float = step == track ? 1 : 0
                #expect(abs(value - expected) < 0.001,
                        "track \(track + 1) step \(step + 1): \(value)")
            }
        }
    }

    /// Duck Friends: 14 steps, 6 tracks; tracks 1, 3, 4, 5 hold melodic
    /// values, tracks 2 and 6 are programmed all-zero. Spot-checks that
    /// rows sit at the 32-step stride and values use the ×65535 encoding.
    @Test func decodesDuckFriendsRows() throws {
        let seq = try #require(try sequencerEntries("Factory/035_zoia_Duck_Friends.bin").first)
        #expect(seq.optionBytes[0] == 13 && seq.optionBytes[1] == 5, "14 steps, 6 tracks")
        for track in [2, 3, 4] {
            let step0 = try #require(SequencerSavedData.step(seq.savedData, track: track, step: 0))
            #expect(step0 > 0, "track \(track + 1) is a programmed melody row")
        }
        for track in [1, 5] {
            for step in 0..<14 {
                let value = try #require(SequencerSavedData.step(seq.savedData, track: track, step: step))
                #expect(value == 0, "track \(track + 1) step \(step + 1) programmed silent")
            }
        }
    }

    /// The layout's structural invariants, asserted over every sequencer
    /// in the corpus: the blob is one of the two fixed sizes, and the
    /// 4156-byte variant is the 572-byte layout plus an all-zero tail.
    @Test func corpusBlobsMatchKnownLayouts() throws {
        let bundle = Bundle(for: CorpusLocator.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "bin" } ?? []
        var seen = 0
        for url in files {
            guard let patch = try? ZoiaPatchBinary.decode(Data(contentsOf: url)) else { continue }
            for seq in patch.modules where seq.typeID == 4 {
                seen += 1
                #expect(seq.savedData.count == 572 || seq.savedData.count == 4156,
                        "\(url.lastPathComponent): saved_data \(seq.savedData.count) bytes")
                if seq.savedData.count == 4156 {
                    #expect(seq.savedData.dropFirst(572).allSatisfy { $0 == 0 },
                            "\(url.lastPathComponent): non-zero tail past byte 572")
                }
            }
        }
        #expect(seen == 77, "corpus holds 77 sequencer instances, saw \(seen)")
    }

    /// Out-of-range coordinates and empty blobs (canvas-authored modules)
    /// decode to nil, never trap.
    @Test func stepBoundsAndEmptyBlob() {
        var matrix = Data(count: SequencerSavedData.stepMatrixBytes)
        matrix[2 * 32 * 2] = 0xFF  // track 3, step 0, low byte
        matrix[2 * 32 * 2 + 1] = 0xFF
        #expect(SequencerSavedData.step(matrix, track: 2, step: 0) == 1)
        #expect(SequencerSavedData.step(matrix, track: 2, step: 1) == 0)
        #expect(SequencerSavedData.step(matrix, track: 8, step: 0) == nil)
        #expect(SequencerSavedData.step(matrix, track: 0, step: 32) == nil)
        #expect(SequencerSavedData.step(Data(), track: 0, step: 0) == nil)
    }
}

@Suite @MainActor struct RuntimeSequencerTracksTests {
    /// Plays Fake Beard's sequencer standalone and steps it through one
    /// full cycle: each gate edge must light exactly the diagonal track.
    @Test func tracksTwoPlusPlayFromSavedData() throws {
        let entry = try #require(try sequencerEntries("Factory/019_zoia_Fake_Beard.bin").first)
        let patch = ZoiaPatch(declaredSizeWords: 0, nameRaw: Data(), modules: [entry],
                              connections: [], pageCountRaw: 0, pageNamesRaw: [],
                              starred: [], colors: [])
        let document = PatchDocument(patch: patch, catalog: try ModuleCatalog.loadBundled())
        let runtime = PatchRuntime(document: document, sampleRate: 48000)
        let node = runtime.nodes[0]
        let gate = try #require(node.paramIndexByPosition[32])
        var left = [Float](repeating: 0, count: 64)
        var right = left

        func render() { runtime.render(frames: 64, outputL: &left, outputR: &right) }
        func pulseGate() {
            node.params[gate] = 1; render()
            node.params[gate] = 0; render()
        }
        func outputs() -> [Float] { (0...3).map { node.cvOut[36 + $0] ?? 0 } }

        render()
        #expect(outputs().map { $0 > 0.5 } == [true, false, false, false], "step 1: track 1")
        pulseGate()
        #expect(outputs().map { $0 > 0.5 } == [false, true, false, false], "step 2: track 2")
        pulseGate()
        #expect(outputs().map { $0 > 0.5 } == [false, false, true, false], "step 3: track 3")
        pulseGate()
        #expect(outputs().map { $0 > 0.5 } == [false, false, false, true], "step 4: track 4")
        pulseGate()
        #expect(outputs().map { $0 > 0.5 } == [true, false, false, false], "loops to step 1")
    }
}
