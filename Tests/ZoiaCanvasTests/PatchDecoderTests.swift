import Foundation
import Testing
@testable import ZoiaCanvas

/// Ground truth produced by zoia_lib's Python parser over the same corpus
/// (Tests/ZoiaCanvasTests/Corpus/manifest.json). Files the Python parser
/// itself fails on are absent from the manifest.
private struct OracleEntry: Decodable {
    let name: String
    let size: Int
    let n_modules: Int
    let n_connections: Int
    let n_starred: Int
    let module_ids: [Int]
}

/// Corpus files that are not device-format patches:
/// - `_zoia_.bin` and `Factory/062_zoia_.bin` are 32768 zero bytes — empty
///   slot placeholders, rejected by zoia_lib's parser too.
/// - `input_test.bin` is a synthetic zoia_lib fixture whose module entries
///   claim a size of 1 word; a real entry is at least 14. zoia_lib's parser
///   is lenient enough to read garbage from it, ours is not.
private let nonPatchFiles: Set<String> = [
    "_zoia_.bin",
    "Factory/062_zoia_.bin",
    "input_test.bin",
]

private final class CorpusLocator {}

private func corpusRoot() throws -> URL {
    let bundle = Bundle(for: CorpusLocator.self)
    return try #require(bundle.resourceURL?.appendingPathComponent("Corpus"),
                        "Corpus folder missing from test bundle")
}

/// All corpus .bin files as (path relative to Corpus, URL), sorted.
private func corpusFiles() throws -> [(relPath: String, url: URL)] {
    let root = try corpusRoot()
    let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "bin" } ?? []
    return all
        .map { url in
            // Path components after "Corpus" — immune to /tmp vs /private/tmp
            // symlink differences between the enumerator and resourceURL.
            let components = url.pathComponents.drop { $0 != "Corpus" }.dropFirst()
            return (components.joined(separator: "/"), url)
        }
        .sorted { $0.0 < $1.0 }
}

private func devicePatchFiles() throws -> [(relPath: String, url: URL)] {
    try corpusFiles().filter { !nonPatchFiles.contains($0.relPath) }
}

@Suite struct PatchDecoderTests {
    @Test func corpusIsComplete() throws {
        // 64 ZOIA factory + 64 Euroburo factory + input_test + blank template.
        #expect(try corpusFiles().count == 130)
        #expect(try devicePatchFiles().count == 127)
    }

    @Test func decodesEveryDevicePatch() throws {
        for (relPath, url) in try devicePatchFiles() {
            let data = try Data(contentsOf: url)
            do {
                _ = try ZoiaPatchBinary.decode(data)
            } catch {
                Issue.record("\(relPath): \(error)")
            }
        }
    }

    @Test func rejectsNonPatches() throws {
        let root = try corpusRoot()
        for relPath in ["_zoia_.bin", "Factory/062_zoia_.bin"] {
            let data = try Data(contentsOf: root.appendingPathComponent(relPath))
            #expect(throws: PatchDecodeError.declaredSizeOutOfRange(words: 0, fileWords: 8192)) {
                try ZoiaPatchBinary.decode(data)
            }
        }
        let fixture = try Data(contentsOf: root.appendingPathComponent("input_test.bin"))
        #expect(throws: PatchDecodeError.badModuleSize(moduleIndex: 0, sizeWords: 1, paramCount: 0)) {
            try ZoiaPatchBinary.decode(fixture)
        }
    }

    @Test func matchesPythonOracle() throws {
        let manifestURL = try corpusRoot().appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(
            [String: OracleEntry].self, from: Data(contentsOf: manifestURL))
        #expect(manifest.count == 125)

        let root = try corpusRoot()
        var compared = 0
        for (relPath, oracle) in manifest.sorted(by: { $0.key < $1.key }) {
            if nonPatchFiles.contains(relPath) { continue }
            let data = try Data(contentsOf: root.appendingPathComponent(relPath))
            let patch = try ZoiaPatchBinary.decode(data)
            #expect(patch.name == oracle.name, "\(relPath) name")
            #expect(patch.declaredSizeWords == oracle.size, "\(relPath) size")
            #expect(patch.modules.count == oracle.n_modules, "\(relPath) modules")
            #expect(patch.connections.count == oracle.n_connections, "\(relPath) connections")
            #expect(patch.starred.count == oracle.n_starred, "\(relPath) starred")
            #expect(patch.modules.map(\.typeID) == oracle.module_ids, "\(relPath) module ids")
            compared += 1
        }
        #expect(compared == 124)
    }

    @Test func moduleTypesAllInCatalog() throws {
        let catalog = try ModuleCatalog.loadBundled()
        for (relPath, url) in try devicePatchFiles() {
            let patch = try ZoiaPatchBinary.decode(Data(contentsOf: url))
            for module in patch.modules {
                #expect(catalog[module.typeID] != nil,
                        "\(relPath): unknown module type \(module.typeID)")
            }
        }
    }

    @Test func paramsFitSixteenBits() throws {
        for (relPath, url) in try devicePatchFiles() {
            let patch = try ZoiaPatchBinary.decode(Data(contentsOf: url))
            for module in patch.modules {
                for value in module.paramsRaw {
                    #expect((0...65535).contains(value),
                            "\(relPath) module \(module.name): param \(value)")
                }
            }
        }
    }

    @Test func moduleSizesAreConsistent() throws {
        for (relPath, url) in try devicePatchFiles() {
            let patch = try ZoiaPatchBinary.decode(Data(contentsOf: url))
            for module in patch.modules {
                let expected = ZoiaModuleEntry.headerWords + module.paramCount
                    + module.savedData.count / 4 + ZoiaModuleEntry.nameWords
                #expect(module.sizeWords == expected, "\(relPath) \(module.name)")
            }
        }
    }

    @Test func colorsMatchModuleCount() throws {
        for (relPath, url) in try devicePatchFiles() {
            let patch = try ZoiaPatchBinary.decode(Data(contentsOf: url))
            if !patch.colors.isEmpty {
                #expect(patch.colors.count == patch.modules.count, "\(relPath)")
            }
        }
    }

    /// Factory/060_zoia_.bin is a valid patch with zero modules — the
    /// smallest device-format file in the corpus (9 words).
    @Test func emptyPatchDecodes() throws {
        let url = try corpusRoot().appendingPathComponent("Factory/060_zoia_.bin")
        let patch = try ZoiaPatchBinary.decode(Data(contentsOf: url))
        #expect(patch.declaredSizeWords == 9)
        #expect(patch.name.isEmpty)
        #expect(patch.modules.isEmpty)
        #expect(patch.connections.isEmpty)
        #expect(patch.starred.isEmpty)
        #expect(patch.colors.isEmpty)
    }
}
