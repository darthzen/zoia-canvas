import CryptoKit
import Foundation

/// A patch's canvas arrangement — node positions plus the editor
/// viewport. None of it exists in the `.bin`, so it lives in a sidecar
/// under Application Support, keyed by the patch file's path: arrange a
/// patch once and it reopens the way you left it.
struct PatchCanvasLayout: Codable {
    var moduleCount: Int
    /// [x, y] per module, in canvas (= wire-format) order.
    var positions: [[Double]]
    var zoom: Double
    var offsetWidth: Double
    var offsetHeight: Double
}

@MainActor
enum PatchLayoutStore {
    /// Overridable so tests write to a scratch directory.
    static var directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ZoiaCanvas/Layouts", isDirectory: true)

    private static func file(for patch: URL) -> URL {
        let digest = SHA256.hash(
            data: Data(patch.standardizedFileURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    static func load(for patch: URL) -> PatchCanvasLayout? {
        guard let data = try? Data(contentsOf: file(for: patch)) else { return nil }
        return try? JSONDecoder().decode(PatchCanvasLayout.self, from: data)
    }

    static func save(_ document: PatchDocument, for patch: URL) {
        let layout = PatchCanvasLayout(
            moduleCount: document.modules.count,
            positions: document.modules.map {
                [Double($0.canvasPosition.x), Double($0.canvasPosition.y)]
            },
            zoom: Double(document.viewportZoom),
            offsetWidth: Double(document.viewportOffset.width),
            offsetHeight: Double(document.viewportOffset.height))
        guard let data = try? JSONEncoder().encode(layout) else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try? data.write(to: file(for: patch))
    }

    /// Drops the sidecar for a path that no longer holds the patch —
    /// after a rename, the arrangement has already been rewritten under
    /// the new path and the old key would linger forever.
    static func discard(for patch: URL) {
        try? FileManager.default.removeItem(at: file(for: patch))
    }

    /// Reapplies a stored arrangement. The module count is the sanity
    /// check: a patch edited elsewhere no longer matches, and the
    /// import layout takes over rather than scattering wrong positions.
    static func apply(_ layout: PatchCanvasLayout, to document: PatchDocument) {
        guard layout.moduleCount == document.modules.count,
              layout.positions.count == document.modules.count else { return }
        for (index, xy) in layout.positions.enumerated() where xy.count == 2 {
            document.modules[index].canvasPosition = CGPoint(x: xy[0], y: xy[1])
        }
        document.viewportZoom = CGFloat(layout.zoom)
        document.viewportOffset = CGSize(width: layout.offsetWidth,
                                         height: layout.offsetHeight)
        document.resolvePageBoundaries()
    }
}
