import Foundation
import Testing
@testable import ZoiaCanvas

private final class CorpusLocator {}

/// The live pedal-grid reflow: canvas-authored modules always hold
/// real, disjoint button runs; pinned placements survive; full pages
/// report overflow and block export; imported layouts never move.
@Suite @MainActor struct GridPlacementTests {
    private func catalog() throws -> ModuleCatalog {
        try ModuleCatalog.loadBundled()
    }

    private func port(_ module: CanvasModule, in document: PatchDocument,
                      output: Bool) throws -> PortRef {
        let block = try #require(module.activeBlocks(in: document.catalog)
            .first { $0.type.isOutput == output })
        return PortRef(module: module.id,
                       blockPosition: block.position ?? 0, type: block.type)
    }

    private func expectDisjointRuns(_ document: PatchDocument) {
        for page in 0..<document.pageCount {
            var seen = Set<Int>()
            for m in document.modules(onPage: page) {
                for b in m.gridPosition..<(m.gridPosition + document.buttonSpan(m)) {
                    #expect(!seen.contains(b),
                            "page \(page): button \(b) assigned twice")
                    seen.insert(b)
                }
            }
        }
    }

    @Test func autoPlacementFollowsSignalFlow() throws {
        let document = PatchDocument(catalog: try catalog())
        // Audio input (1) → SV filter (0) → audio output (2).
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let filter = try #require(document.addModule(typeID: 0, at: .zero))
        let output = try #require(document.addModule(typeID: 2, at: .zero))
        document.connect(from: try port(input, in: document, output: true),
                         to: try port(filter, in: document, output: false))
        document.connect(from: try port(filter, in: document, output: true),
                         to: try port(output, in: document, output: false))

        let byID = Dictionary(uniqueKeysWithValues: document.modules.map { ($0.id, $0) })
        let inputPos = try #require(byID[input.id]).gridPosition
        let filterPos = try #require(byID[filter.id]).gridPosition
        let outputPos = try #require(byID[output.id]).gridPosition
        #expect(inputPos < filterPos, "signal flow orders the grid")
        #expect(filterPos < outputPos, "signal flow orders the grid")
        expectDisjointRuns(document)
        #expect(document.gridOverflow.isEmpty)
        #expect(document.gridExportBlockers.isEmpty)
    }

    @Test func pinnedPlacementSurvivesReflow() throws {
        let document = PatchDocument(catalog: try catalog())
        let pinned = try #require(document.addModule(typeID: 0, at: .zero))
        document.setGridPosition(pinned.id, to: 10)
        _ = try #require(document.addModule(typeID: 1, at: .zero))
        _ = try #require(document.addModule(typeID: 2, at: .zero))

        let after = try #require(document.module(pinned.id))
        #expect(after.gridPinned)
        #expect(after.gridPosition == 10, "pin holds through reflow")
        expectDisjointRuns(document)

        document.unpinGridPosition(pinned.id)
        let unpinned = try #require(document.module(pinned.id))
        #expect(unpinned.gridPinned == false)
        expectDisjointRuns(document)
    }

    @Test func overflowBlocksExport() throws {
        let document = PatchDocument(catalog: try catalog())
        var added = 0
        while document.gridOverflow.isEmpty && added < 60 {
            _ = try #require(document.addModule(typeID: 1, at: .zero))
            added += 1
        }
        #expect(!document.gridOverflow.isEmpty, "page 0 eventually fills")
        #expect(!document.gridExportBlockers.isEmpty)
        // Parked modules sit past the last button but still on distinct
        // runs, so nothing silently stacks.
        expectDisjointRuns(document)
        #expect(document.modules.contains {
            $0.gridPosition >= PatchDocument.pageButtonCount
        })
    }

    @Test func importPinsAuthoredPlacement() throws {
        let bundle = Bundle(for: CorpusLocator.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        let patch = try ZoiaPatchBinary.decode(try Data(contentsOf:
            root.appendingPathComponent("Factory/023_zoia_Snowfall.bin")))
        let document = PatchDocument(patch: patch, catalog: try catalog())
        let allPinned = document.modules.allSatisfy { $0.gridPinned }
        #expect(allPinned)
        #expect(document.modules.map(\.gridPosition) == patch.modules.map(\.position),
                "imported placement is authored data — reflow must not touch it")
    }
}
