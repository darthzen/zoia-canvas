import Foundation
import Testing
@testable import ZoiaCanvas

/// The pick-up-and-move gesture's model half: unplugging the newest
/// cable from an input hands back its far end with strength intact,
/// and the edited flag tracks everything that reaches the .bin.
@Suite @MainActor struct CableReconnectTests {
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

    @Test func unplugReturnsNewestCableAndKeepsStrength() throws {
        let document = PatchDocument(catalog: try catalog())
        let a = try #require(document.addModule(typeID: 1, at: .zero))
        let b = try #require(document.addModule(typeID: 1, at: .zero))
        let sink = try #require(document.addModule(typeID: 2, at: .zero))
        let dest = try port(sink, in: document, output: false)
        document.connect(from: try port(a, in: document, output: true), to: dest)
        document.connect(from: try port(b, in: document, output: true), to: dest,
                         strengthRaw: 5000)

        let picked = try #require(document.unplugConnection(into: dest))
        #expect(picked.source.module == b.id, "newest cable comes off first")
        #expect(picked.strengthRaw == 5000, "strength travels with the plug")
        #expect(document.connections.count == 1)
        #expect(document.connections[0].sourceModule == a.id)

        // Re-plugging the picked end elsewhere is a plain connect.
        let ruling = document.connect(from: picked.source, to: dest,
                                      strengthRaw: picked.strengthRaw)
        #expect(ruling == .allowed)
    }

    @Test func unplugEmptyOrOutputPortReturnsNil() throws {
        let document = PatchDocument(catalog: try catalog())
        let source = try #require(document.addModule(typeID: 1, at: .zero))
        let sink = try #require(document.addModule(typeID: 2, at: .zero))
        #expect(document.unplugConnection(
            into: try port(sink, in: document, output: false)) == nil)
        #expect(document.unplugConnection(
            into: try port(source, in: document, output: true)) == nil)
    }

    @Test func editedFlagTracksSaveWorthyChanges() throws {
        let document = PatchDocument(catalog: try catalog())
        #expect(!document.isEdited, "a fresh document is clean")

        let module = try #require(document.addModule(typeID: 0, at: .zero))
        #expect(document.isEdited, "structure changes mark it")
        document.markSaved()
        #expect(!document.isEdited)

        document.setGridPosition(module.id, to: 8)
        #expect(document.isEdited, "grid slots reach the .bin")
        document.markSaved()

        document.setCustomName(module.id, to: "flt")
        #expect(document.isEdited, "names reach the .bin")
        document.markSaved()

        document.setColorID(module.id, to: 3)
        #expect(document.isEdited, "colors reach the .bin")
        document.markSaved()

        document.renamePage(0, to: "main")
        #expect(document.isEdited, "page names reach the .bin")
    }

    @Test func openedPatchStartsClean() throws {
        let bundle = Bundle(for: CorpusHook.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        let patch = try ZoiaPatchBinary.decode(try Data(contentsOf:
            root.appendingPathComponent("Factory/023_zoia_Snowfall.bin")))
        let document = PatchDocument(patch: patch, catalog: try catalog())
        #expect(!document.isEdited, "opening a file is not an edit")
    }
}

private final class CorpusHook {}
