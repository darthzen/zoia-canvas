import Foundation
import Testing
@testable import ZoiaCanvas

@Suite struct FromScratchExportTests {
    /// Builds a patch entirely from the catalog — never seen by a ZOIA or
    /// zoia_lib — encodes it, and proves it decodes back to what we meant.
    /// The encoded file is also written to the user temp directory so the
    /// Python oracle (zoia_lib) can be run against the identical bytes:
    /// audio input → SV filter → audio output, params at half, 100% cables.
    @Test func fromScratchPatchRoundTrips() throws {
        let catalog = try ModuleCatalog.loadBundled()
        let patch = try Self.makePatch(catalog: catalog)
        let encoded = ZoiaPatchBinary.encode(patch)
        #expect(encoded.count == ZoiaPatchBinary.fileSize)

        let decoded = try ZoiaPatchBinary.decode(encoded)
        #expect(decoded.name == "Oracle Test")
        #expect(decoded.modules.map(\.typeID) == [1, 0, 2])
        #expect(decoded.modules.map(\.paramCount) == patch.modules.map { $0.paramsRaw.count })
        #expect(decoded.connections.count == 2)
        #expect(decoded.connections.map(\.strengthRaw) == [10000, 10000])
        #expect(decoded.colors == [1, 2, 3])
        for module in decoded.modules where module.paramCount > 0 {
            #expect(module.paramsRaw.allSatisfy { $0 == 32768 })
        }

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoiacanvas-oracle-export.bin")
        try encoded.write(to: exportURL)
    }

    private static func makePatch(catalog: ModuleCatalog) throws -> ZoiaPatch {
        // Audio Input (1), SV Filter (0), Audio Output (2).
        let modules = try [1, 0, 2].enumerated().map { index, typeID in
            let spec = try #require(catalog[typeID], "module \(typeID) missing from catalog")
            return ZoiaModuleEntry(
                sizeWords: ZoiaModuleEntry.headerWords + spec.paramCount + ZoiaModuleEntry.nameWords,
                typeID: typeID,
                version: 0,
                pageRaw: 0,
                headerColorID: index + 1,
                position: index * 8,
                paramCount: spec.paramCount,
                savedDataSizeField: 0,
                optionBytes: [UInt8](repeating: 0, count: 8),
                paramsRaw: [Int](repeating: 32768, count: spec.paramCount),
                savedData: Data(),
                nameRaw: Data(count: 16)
            )
        }
        var name = Data("Oracle Test".utf8)
        name.append(Data(count: 16 - name.count))
        return ZoiaPatch(
            declaredSizeWords: 0, // recomputed by the encoder
            nameRaw: name,
            modules: modules,
            connections: [
                ZoiaConnection(sourceModule: 0, sourceBlock: 0, destModule: 1, destBlock: 0, strengthRaw: 10000),
                ZoiaConnection(sourceModule: 1, sourceBlock: 3, destModule: 2, destBlock: 0, strengthRaw: 10000),
            ],
            pageCountRaw: 0,
            pageNamesRaw: [],
            starred: [],
            colors: [1, 2, 3]
        )
    }
}
