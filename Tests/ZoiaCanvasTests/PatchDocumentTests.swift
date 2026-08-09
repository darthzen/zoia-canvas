import Foundation
import Testing
@testable import ZoiaCanvas

private final class CorpusLocator {}

@Suite @MainActor struct PatchDocumentTests {
    private func catalog() throws -> ModuleCatalog {
        try ModuleCatalog.loadBundled()
    }

    private func corpusData(_ relPath: String) throws -> Data {
        let bundle = Bundle(for: CorpusLocator.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        return try Data(contentsOf: root.appendingPathComponent(relPath))
    }

    @Test func buildsFromScratchAndConnects() throws {
        let document = PatchDocument(catalog: try catalog())
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let svf = try #require(document.addModule(typeID: 0, at: CGPoint(x: 200, y: 0)))
        let inBlocks = input.activeBlocks(in: document.catalog)
        let svfBlocks = svf.activeBlocks(in: document.catalog)
        let out = try #require(inBlocks.first { $0.type.isOutput })
        let dest = try #require(svfBlocks.first { !$0.type.isOutput })

        let ruling = document.connect(
            from: PortRef(module: input.id, blockPosition: out.position ?? 0, type: out.type),
            to: PortRef(module: svf.id, blockPosition: dest.position ?? 0, type: dest.type))
        #expect(ruling == .allowed)
        #expect(document.connections.count == 1)
        #expect(document.dspTotal > 0)
    }

    @Test func directionRuleBlocksInputToInput() throws {
        let document = PatchDocument(catalog: try catalog())
        let a = try #require(document.addModule(typeID: 0, at: .zero))
        let b = try #require(document.addModule(typeID: 0, at: .zero))
        let input = try #require(a.activeBlocks(in: document.catalog).first { !$0.type.isOutput })
        let ruling = document.connect(
            from: PortRef(module: a.id, blockPosition: input.position ?? 0, type: input.type),
            to: PortRef(module: b.id, blockPosition: input.position ?? 0, type: input.type))
        #expect(ruling == .notOutputToInput)
        #expect(document.connections.isEmpty)
    }

    @Test func crossTypeCableIsWarnedNotBlocked() throws {
        let document = PatchDocument(catalog: try catalog())
        // Oscillator audio_out → SV filter frequency (cv in).
        let osc = try #require(document.addModule(typeID: 14, at: .zero))
        let svf = try #require(document.addModule(typeID: 0, at: .zero))
        let audioOut = try #require(osc.activeBlocks(in: document.catalog).first { $0.type == .audioOut })
        let cvIn = try #require(svf.activeBlocks(in: document.catalog).first { $0.type == .cvIn })
        let ruling = document.connect(
            from: PortRef(module: osc.id, blockPosition: audioOut.position ?? 0, type: audioOut.type),
            to: PortRef(module: svf.id, blockPosition: cvIn.position ?? 0, type: cvIn.type))
        #expect(ruling == .allowedTypeMismatch)
        #expect(document.connections.count == 1)
    }

    @Test func removingModuleDropsItsCables() throws {
        let document = PatchDocument(catalog: try catalog())
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let output = try #require(document.addModule(typeID: 2, at: .zero))
        let src = try #require(input.activeBlocks(in: document.catalog).first { $0.type.isOutput })
        let dst = try #require(output.activeBlocks(in: document.catalog).first { !$0.type.isOutput })
        document.connect(
            from: PortRef(module: input.id, blockPosition: src.position ?? 0, type: src.type),
            to: PortRef(module: output.id, blockPosition: dst.position ?? 0, type: dst.type))
        #expect(document.connections.count == 1)
        document.removeModule(input.id)
        #expect(document.connections.isEmpty)
        #expect(document.modules.count == 1)
    }

    @Test func removesSingleConnectionByID() throws {
        let document = PatchDocument(catalog: try catalog())
        let input = try #require(document.addModule(typeID: 1, at: .zero))
        let output = try #require(document.addModule(typeID: 2, at: .zero))
        let src = try #require(input.activeBlocks(in: document.catalog).first { $0.type.isOutput })
        let dst = try #require(output.activeBlocks(in: document.catalog).first { !$0.type.isOutput })
        document.connect(
            from: PortRef(module: input.id, blockPosition: src.position ?? 0, type: src.type),
            to: PortRef(module: output.id, blockPosition: dst.position ?? 0, type: dst.type))
        let cable = try #require(document.connections.first)
        let revision = document.structureRevision

        document.removeConnection(UUID())
        #expect(document.connections.count == 1, "unknown id is a no-op")
        #expect(document.structureRevision == revision, "no-op must not force a graph rebuild")

        document.removeConnection(cable.id)
        #expect(document.connections.isEmpty)
        #expect(document.modules.count == 2, "modules stay")
        #expect(document.structureRevision > revision)
    }

    @Test func pageLifecycle() throws {
        let document = PatchDocument(catalog: try catalog())
        let module = try #require(document.addModule(typeID: 1, at: CGPoint(x: 100, y: 100)))
        #expect(document.pageCount == 1, "a fresh document has one implicit page")

        #expect(document.addPage() == 1)
        document.renamePage(1, to: "drums & synths on page two")
        #expect(document.pageName(1) == "drums & synths o", "clipped to 16 ASCII bytes")

        document.moveModule(module.id, toPage: 1)
        let moved = try #require(document.module(module.id))
        #expect(moved.page == 1)
        #expect(moved.canvasPosition.x == 100 + PatchDocument.pageStride,
                "canvas position follows the page band")

        #expect(!document.removePage(1), "occupied pages stay")
        document.moveModule(module.id, toPage: 0)
        #expect(document.removePage(1))
        #expect(document.pageCount == 1)
        #expect(!document.removePage(0), "the last page stays")

        // Removing an earlier empty page shifts later assignments down.
        #expect(document.addPage() == 1)
        document.moveModule(module.id, toPage: 1)
        document.renamePage(0, to: "empty")
        document.renamePage(1, to: "home")
        #expect(document.removePage(0))
        let shifted = try #require(document.module(module.id))
        #expect(shifted.page == 0)
        #expect(shifted.canvasPosition.x == 100, "band shift undone")
        #expect(document.pageName(0) == "home")

        // Export sizes the page list from names and assignments alike.
        #expect(document.buildPatch().pageCountRaw == 1)
    }

    /// Imported patches pack the canvas: every node inside its page
    /// band, no two nodes overlapping. Density itself is a judgement
    /// call; these are the invariants that keep it legible.
    @Test func importedLayoutPacksWithoutOverlap() throws {
        let patch = try ZoiaPatchBinary.decode(
            try corpusData("Factory/000_zoia_Loop_Forest.bin"))
        let document = PatchDocument(patch: patch, catalog: try catalog())
        let placed = document.modules.map { m -> (page: Int, rect: CGRect) in
            let height = NodeMetrics.height(
                blockCount: m.activeBlocks(in: document.catalog).count)
            return (m.page, CGRect(origin: m.canvasPosition,
                                   size: CGSize(width: NodeMetrics.width, height: height)))
        }
        for (page, rect) in placed {
            let band = CGRect(x: CGFloat(page) * PatchDocument.pageStride, y: 0,
                              width: PatchDocument.pageStride, height: 1_000_000)
            #expect(band.contains(rect), "node escapes its page band")
        }
        for i in placed.indices {
            for j in placed.indices where j > i {
                #expect(!placed[i].rect.intersects(placed[j].rect),
                        "modules \(i) and \(j) overlap")
            }
        }
    }

    /// Loading a factory patch into the document and rebuilding must
    /// preserve everything the device cares about (semantic equality;
    /// byte layout is the encoder tests' job).
    @Test func factoryPatchSurvivesDocumentRoundTrip() throws {
        let original = try ZoiaPatchBinary.decode(
            try corpusData("Factory/000_zoia_Loop_Forest.bin"))
        let document = PatchDocument(patch: original, catalog: try catalog())
        let rebuilt = try ZoiaPatchBinary.decode(document.encodeBin())

        #expect(rebuilt.name == original.name)
        #expect(rebuilt.modules.count == original.modules.count)
        for (a, b) in zip(rebuilt.modules, original.modules) {
            #expect(a.typeID == b.typeID)
            #expect(a.version == b.version)
            #expect(a.pageRaw == b.pageRaw)
            #expect(a.position == b.position)
            #expect(a.optionBytes == b.optionBytes)
            #expect(a.paramsRaw == b.paramsRaw)
            #expect(a.savedData == b.savedData)
            #expect(a.name == b.name)
        }
        #expect(rebuilt.connections.count == original.connections.count)
        for (a, b) in zip(rebuilt.connections, original.connections) {
            #expect(a.sourceModule == b.sourceModule)
            #expect(a.sourceBlock == b.sourceBlock)
            #expect(a.destModule == b.destModule)
            #expect(a.destBlock == b.destBlock)
            #expect(a.strengthRaw == b.strengthRaw)
        }
        #expect(rebuilt.colors == original.colors)
        #expect(rebuilt.starred.map(\.moduleIndex) == original.starred.map(\.moduleIndex))
        #expect(rebuilt.starred.map(\.blockField) == original.starred.map(\.blockField))
    }
}
