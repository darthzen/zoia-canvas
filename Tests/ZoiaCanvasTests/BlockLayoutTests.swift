import Foundation
import Testing
@testable import ZoiaCanvas

private final class CorpusLocator {}

@Suite struct BlockLayoutTests {
    /// Ground truth: zoia_lib's `_calc_blocks` output (ordered active block
    /// names per module) for every corpus patch its parser can handle,
    /// generated into Corpus/blocks-manifest.json.
    @Test func matchesPythonOracleAcrossCorpus() throws {
        let bundle = Bundle(for: CorpusLocator.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        let manifest = try JSONDecoder().decode(
            [String: [[String]]].self,
            from: Data(contentsOf: root.appendingPathComponent("blocks-manifest.json")))
        // input_test.bin is in the manifest (Python parses it leniently)
        // but is not a device-format patch; see PatchDecoderTests.
        let skip: Set<String> = ["input_test.bin"]
        let catalog = try ModuleCatalog.loadBundled()
        // Our catalog uses Empress firmware-5 block names where zoia_lib's
        // ModuleIndex kept pre-fw5 ones; the oracle speaks ModuleIndex.
        let fw5Renames: [Int: [String: String]] = [
            3: ["#_of_samples": "alias_amount"],  // Aliaser
            6: ["cv_input": "gate_input"],        // ADSR
            60: ["velocity_in": "velocity_out"],  // Midi Note Out
        ]

        var patchesChecked = 0
        var modulesChecked = 0
        for (relPath, oracleBlocks) in manifest.sorted(by: { $0.key < $1.key }) {
            if skip.contains(relPath) { continue }
            let patch = try ZoiaPatchBinary.decode(
                Data(contentsOf: root.appendingPathComponent(relPath)))
            #expect(patch.modules.count == oracleBlocks.count, "\(relPath) module count")
            for (module, oracleKeys) in zip(patch.modules, oracleBlocks) {
                let spec = try #require(catalog[module.typeID])
                let active = try BlockLayout.activeBlocks(
                    spec: spec, optionBytes: module.optionBytes, version: module.version)
                let renames = fw5Renames[module.typeID] ?? [:]
                let normalized = active.map { renames[$0.key] ?? $0.key }
                #expect(normalized == oracleKeys,
                        "\(relPath) \(spec.name) v\(module.version) options \(module.optionBytes)")
                modulesChecked += 1
            }
            patchesChecked += 1
        }
        #expect(patchesChecked == 124)
        #expect(modulesChecked > 2000)
    }

    /// The three Euroburo patches upstream rejects ("Block count cannot be
    /// below the minimum") must still produce a layout here — device-written
    /// patches are truth, upstream's minimum check is not.
    @Test func layoutsUpstreamRejects() throws {
        let bundle = Bundle(for: CorpusLocator.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        let catalog = try ModuleCatalog.loadBundled()
        for relPath in ["FactoryEuroburo/040_zoia_3011.bin",
                        "FactoryEuroburo/041_zoia_Spin_Cycle.bin",
                        "FactoryEuroburo/049_zoia_Not_My_Tempo.bin"] {
            let patch = try ZoiaPatchBinary.decode(
                Data(contentsOf: root.appendingPathComponent(relPath)))
            for module in patch.modules {
                let spec = try #require(catalog[module.typeID])
                let active = try BlockLayout.activeBlocks(
                    spec: spec, optionBytes: module.optionBytes, version: module.version)
                #expect(!active.isEmpty || spec.blocks.isEmpty, "\(relPath) \(spec.name)")
            }
        }
    }

    @Test func oscillatorOptionsSelectBlocks() throws {
        let catalog = try ModuleCatalog.loadBundled()
        let osc = try #require(catalog[14])
        // All options at byte 0: fm and duty-cycle inputs off.
        let minimal = try BlockLayout.activeBlocks(spec: osc, optionBytes: [0, 0, 0, 0, 0, 0, 0, 0], version: 0)
        #expect(minimal.map(\.key) == ["frequency", "audio_out"])
        // fm_in on (option 1 → value index 1), duty_cycle on (option 2).
        let full = try BlockLayout.activeBlocks(spec: osc, optionBytes: [0, 1, 1, 0, 0, 0, 0, 0], version: 0)
        #expect(full.map(\.key) == ["frequency", "fm_input", "duty_cycle", "audio_out"])
    }
}
