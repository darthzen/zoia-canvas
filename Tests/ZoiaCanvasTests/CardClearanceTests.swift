import Foundation
import Testing
@testable import ZoiaCanvas

private final class CorpusLocator {}

/// Off-page connector cards occupy real canvas space, and the import
/// layout reserves corridors and tier clearance for them. Checked
/// across the whole corpus so a layout change cannot quietly put
/// modules back underneath cards.
@Suite @MainActor struct CardClearanceTests {
    /// Corpus entries with no modules or synthetic placement data,
    /// mirroring the decoder tests' skip list.
    private static let skip: Set<String> = [
        "_zoia_.bin",
        "Factory/062_zoia_.bin",
        "input_test.bin",
    ]

    @Test func expandedLayoutClearsConnectorCards() throws {
        let bundle = Bundle(for: CorpusLocator.self)
        let root = try #require(bundle.resourceURL?.appendingPathComponent("Corpus"))
        let files = try FileManager.default
            .subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".bin") && !Self.skip.contains($0) }
            .sorted()
        let catalog = try ModuleCatalog.loadBundled()
        for relPath in files {
            let patch = try ZoiaPatchBinary.decode(
                try Data(contentsOf: root.appendingPathComponent(relPath)))
            let document = PatchDocument(patch: patch, catalog: catalog)
            document.applyExpandedCardLayout()
            let rects = document.modules.map { m in
                CGRect(origin: m.canvasPosition,
                       size: CGSize(width: NodeMetrics.width,
                                    height: NodeMetrics.height(
                                        blockCount: m.activeBlocks(in: catalog).count)))
            }
            for card in CableLayer.resolvedStubs(in: document, offsets: [:]) {
                for (i, rect) in rects.enumerated() where card.card.intersects(rect) {
                    Issue.record("\(relPath): module \(i) under a connector card")
                }
            }
            for i in rects.indices {
                for j in rects.indices where j > i && rects[i].intersects(rects[j]) {
                    Issue.record("\(relPath): modules \(i) and \(j) overlap after relaxation")
                }
            }
        }
    }
}
