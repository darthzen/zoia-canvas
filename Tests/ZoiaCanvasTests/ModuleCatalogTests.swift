import Testing
@testable import ZoiaCanvas

@Suite struct ModuleCatalogTests {
    @Test func loadsAllModules() throws {
        let catalog = try ModuleCatalog.loadBundled()
        #expect(catalog.modules.count == 108)
    }

    @Test func oscillatorSpec() throws {
        let catalog = try ModuleCatalog.loadBundled()
        let osc = try #require(catalog[14])
        #expect(osc.name == "Oscillator")
        #expect(osc.category == "Audio")
        #expect(osc.blocks.map(\.key) == ["frequency", "fm_input", "duty_cycle", "audio_out"])
        // Option order is binary truth — the byte order in the patch file.
        #expect(osc.options.map(\.key) == ["waveform", "fm_in", "duty_cycle", "upsampling"])
        #expect(osc.options[0].values.map(\.description) == ["sine", "square", "triangle", "sawtooth"])
        #expect(osc.blocks.last?.type == .audioOut)
        #expect(osc.doc != nil)
    }

    @Test func svFilterSpec() throws {
        let catalog = try ModuleCatalog.loadBundled()
        let svf = try #require(catalog[0])
        #expect(svf.name == "SV Filter")
        #expect(svf.paramCount == 2)
        #expect(svf.maxBlocks == 6)
    }

    @Test func allBlocksTyped() throws {
        let catalog = try ModuleCatalog.loadBundled()
        for module in catalog.modules {
            #expect(!module.blocks.isEmpty, "\(module.name) has no blocks")
        }
    }
}
