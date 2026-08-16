import Foundation
import Testing
@testable import ZoiaCanvas

private final class NamingCorpusLocator {}

/// Every `.bin` in the corpus, with its filename.
private func corpusFiles() throws -> [(fileName: String, data: Data)] {
    let bundle = Bundle(for: NamingCorpusLocator.self)
    let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
    let all = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "bin" } ?? []
    return try all
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
}

@Suite @MainActor struct PatchNamingTests {
    /// The rule the whole feature rests on: the device patches state
    /// their name twice — in the header and in the filename — and the
    /// filename is always the header name with every non-alphanumeric
    /// character written as an underscore. If a device patch ever
    /// disagrees, deriving the filename from the name is wrong.
    @Test func factoryFilenamesMatchTheirHeaderNames() throws {
        var checked = 0
        for (fileName, data) in try corpusFiles() {
            // Only card-convention filenames make the claim, and an
            // empty slot (declared size 0, e.g. Factory/062_zoia_.bin)
            // is a placeholder on the card with no patch to name.
            guard let slot = ZoiaPatchNaming.slot(fromFileName: fileName),
                  data.prefix(4) != Data(count: 4) else { continue }
            let patch = try ZoiaPatchBinary.decode(data)
            #expect(ZoiaPatchNaming.fileName(for: patch.name, slot: slot) == fileName,
                    "\(fileName) header name is “\(patch.name)”")
            checked += 1
        }
        #expect(checked >= 127, "expected both factory sets, saw \(checked) files")
    }

    @Test func fileNameCarriesSlotAndUnderscores() {
        #expect(ZoiaPatchNaming.fileName(for: "Grains de folie", slot: 11)
                == "011_zoia_Grains_de_folie.bin")
        // Punctuation goes the same way a space does — the corpus's
        // "V-Sync" is stored as 017_zoia_V_Sync.bin.
        #expect(ZoiaPatchNaming.fileName(for: "V-Sync", slot: 17)
                == "017_zoia_V_Sync.bin")
        // A new patch lands one past the boot slot unless told otherwise.
        #expect(ZoiaPatchNaming.fileName(for: "SWARM") == "001_zoia_SWARM.bin")
    }

    @Test func patchNameReadsBackThroughTheFilename() {
        #expect(ZoiaPatchNaming.patchName(fromFileName: "011_zoia_Grains_de_folie.bin")
                == "Grains de folie")
        // An empty name is a real state: 062_zoia_.bin ships that way.
        #expect(ZoiaPatchNaming.patchName(fromFileName: "062_zoia_.bin") == "")
        // No convention in the name, no slot to keep.
        #expect(ZoiaPatchNaming.slot(fromFileName: "my_patch.bin") == nil)
        #expect(ZoiaPatchNaming.slot(fromFileName: "007_zoia_Space4rent.bin") == 7)
    }

    /// The header field is 16 bytes with no length elsewhere, so a
    /// longer name would be silently cut at export. It is cut on the
    /// way in instead, where the user can see it happen.
    @Test func namesAreClampedToTheHeaderField() {
        #expect(ZoiaPatchNaming.clamp("0123456789abcdefGHIJ") == "0123456789abcdef")
        #expect(ZoiaPatchNaming.clamp("Phase drag") == "Phase drag")
        // Multi-byte characters are dropped whole, never split.
        let emoji = ZoiaPatchNaming.clamp("123456789012345🎛")
        #expect(emoji == "123456789012345")
        #expect(emoji.utf8.count <= ZoiaPatchNaming.maxNameBytes)
    }

    /// What the encoder writes is what the title bar showed.
    @Test func renamingSurvivesAnExportRoundTrip() throws {
        let document = PatchDocument(catalog: try ModuleCatalog.loadBundled())
        document.setPatchName("Tape Return")
        #expect(document.isEdited)

        let reloaded = try ZoiaPatchBinary.decode(document.encodeBin())
        #expect(reloaded.name == "Tape Return")
    }

    @Test func overlongRenamesNeverReachTheFile() throws {
        let document = PatchDocument(catalog: try ModuleCatalog.loadBundled())
        document.setPatchName("this name is far too long for the header")
        #expect(document.patchName == "this name is far")

        let reloaded = try ZoiaPatchBinary.decode(document.encodeBin())
        #expect(reloaded.name == document.patchName)
    }
}
