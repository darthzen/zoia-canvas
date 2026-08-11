import Foundation
import Testing
@testable import ZoiaCanvas

private final class CorpusLocator {}

/// Sticky pedal-grid placement: a slot is assigned once and held; only
/// a drop or a growing neighbor moves a module, and only the modules
/// that run actually covers; full pages report overflow and block
/// export; imported layouts never move.
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

    @Test func newModulesPackWithoutMovingAnyone() throws {
        let document = PatchDocument(catalog: try catalog())
        // Audio input (1) → SV filter (0) → audio output (2).
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let filter = try #require(document.addModule(typeID: 0, at: .zero))
        let output = try #require(document.addModule(typeID: 2, at: .zero))
        expectDisjointRuns(document)
        #expect(document.gridOverflow.isEmpty)

        // Cables never move placement — slots are sticky.
        let before = document.modules.map(\.gridPosition)
        document.connect(from: try port(input, in: document, output: true),
                         to: try port(filter, in: document, output: false))
        document.connect(from: try port(filter, in: document, output: true),
                         to: try port(output, in: document, output: false))
        #expect(document.modules.map(\.gridPosition) == before)
    }

    @Test func manualPlacementSticks() throws {
        let document = PatchDocument(catalog: try catalog())
        let placed = try #require(document.addModule(typeID: 0, at: .zero))
        document.setGridPosition(placed.id, to: 10)
        _ = try #require(document.addModule(typeID: 1, at: .zero))
        _ = try #require(document.addModule(typeID: 2, at: .zero))

        let after = try #require(document.module(placed.id))
        #expect(after.gridPosition == 10, "new modules flow around a placed one")
        expectDisjointRuns(document)
    }

    @Test func dropDisplacesOnlyWhatItHits() throws {
        let document = PatchDocument(catalog: try catalog())
        let a = try #require(document.addModule(typeID: 1, at: .zero))
        let b = try #require(document.addModule(typeID: 1, at: .zero))
        let c = try #require(document.addModule(typeID: 1, at: .zero))
        let aPos = try #require(document.module(a.id)).gridPosition
        let cPos = try #require(document.module(c.id)).gridPosition

        document.setGridPosition(b.id, to: aPos)
        #expect(try #require(document.module(b.id)).gridPosition == aPos,
                "the drop wins the contested run")
        #expect(try #require(document.module(a.id)).gridPosition != aPos,
                "the module underneath steps aside")
        #expect(try #require(document.module(c.id)).gridPosition == cPos,
                "an untouched module never moves")
        expectDisjointRuns(document)
    }

    @Test func dragSnapshotRestores() throws {
        let document = PatchDocument(catalog: try catalog())
        let a = try #require(document.addModule(typeID: 1, at: .zero))
        let b = try #require(document.addModule(typeID: 1, at: .zero))
        let snapshot = document.gridSnapshot(page: 0)
        let aPos = try #require(document.module(a.id)).gridPosition

        // Preview a displacing drop, then rewind — the inspector drag
        // does this every step, so nudged neighbors return.
        document.setGridPosition(b.id, to: aPos)
        document.restoreGridPositions(snapshot)
        #expect(document.gridSnapshot(page: 0) == snapshot)
        expectDisjointRuns(document)
    }

    @Test func growingModuleDisplacesItsNeighbor() throws {
        let document = PatchDocument(catalog: try catalog())
        // Sequencer (4): number_of_steps is option 0 and adds a block
        // per step.
        let sequencer = try #require(document.addModule(typeID: 4, at: .zero))
        let neighbor = try #require(document.addModule(typeID: 1, at: .zero))
        let seqPos = try #require(document.module(sequencer.id)).gridPosition
        let neighborPos = try #require(document.module(neighbor.id)).gridPosition
        let grown = document.buttonSpan(try #require(document.module(sequencer.id))) + 7
        document.setOption(sequencer.id, optionIndex: 0, byte: 7)   // 8 steps

        let seqAfter = try #require(document.module(sequencer.id))
        #expect(document.buttonSpan(seqAfter) >= grown - 1,
                "steps grew the span")
        #expect(seqAfter.gridPosition == seqPos, "the grown module holds its slot")
        #expect(try #require(document.module(neighbor.id)).gridPosition != neighborPos,
                "the covered neighbor steps aside")
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

    @Test func deletionRecallsParkedModules() throws {
        let document = PatchDocument(catalog: try catalog())
        var first: CanvasModule?
        var added = 0
        while document.gridOverflow.isEmpty && added < 60 {
            let module = try #require(document.addModule(typeID: 1, at: .zero))
            if first == nil { first = module }
            added += 1
        }
        #expect(!document.gridOverflow.isEmpty)

        document.removeModule(try #require(first).id)
        #expect(document.gridOverflow.isEmpty,
                "freed buttons recall the parked module")
        expectDisjointRuns(document)
    }

    @Test func importKeepsAuthoredPlacement() throws {
        let bundle = Bundle(for: CorpusLocator.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        let patch = try ZoiaPatchBinary.decode(try Data(contentsOf:
            root.appendingPathComponent("Factory/023_zoia_Snowfall.bin")))
        let document = PatchDocument(patch: patch, catalog: try catalog())
        #expect(document.modules.map(\.gridPosition) == patch.modules.map(\.position),
                "imported placement is authored data — nothing may touch it")
        #expect(document.gridExportBlockers.isEmpty,
                "what the device produced must round-trip")
    }
}
