import Foundation
import Testing
@testable import ZoiaCanvas

/// The canvas-layout sidecar and the open-routing rules: arrangements
/// survive reopen, and opens only ever replace an empty untitled
/// window.
@Suite @MainActor struct LayoutPersistenceTests {
    private func catalog() throws -> ModuleCatalog {
        try ModuleCatalog.loadBundled()
    }

    private func scratchStoreDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zoia-layout-tests-\(UUID().uuidString)")
        PatchLayoutStore.directory = dir
        return dir
    }

    @Test func layoutRoundTripsThroughSidecar() throws {
        let dir = scratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let patchURL = dir.appendingPathComponent("some/patch.bin")

        let document = PatchDocument(catalog: try catalog())
        let a = try #require(document.addModule(typeID: 1, at: CGPoint(x: 12, y: 34)))
        _ = try #require(document.addModule(typeID: 2, at: CGPoint(x: 56, y: 78)))
        document.viewportZoom = 1.5
        document.viewportOffset = CGSize(width: -40, height: 25)
        PatchLayoutStore.save(document, for: patchURL)

        // A "reopened" copy: same modules, import-style positions.
        let reopened = PatchDocument(catalog: try catalog())
        _ = try #require(reopened.addModule(typeID: 1, at: .zero))
        _ = try #require(reopened.addModule(typeID: 2, at: .zero))
        let layout = try #require(PatchLayoutStore.load(for: patchURL))
        PatchLayoutStore.apply(layout, to: reopened)

        #expect(reopened.modules[0].canvasPosition == CGPoint(x: 12, y: 34))
        #expect(reopened.modules[1].canvasPosition == CGPoint(x: 56, y: 78))
        #expect(reopened.viewportZoom == 1.5)
        #expect(reopened.viewportOffset == CGSize(width: -40, height: 25))
        _ = a
    }

    @Test func mismatchedModuleCountLeavesLayoutAlone() throws {
        let dir = scratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let patchURL = dir.appendingPathComponent("patch.bin")

        let document = PatchDocument(catalog: try catalog())
        _ = try #require(document.addModule(typeID: 1, at: CGPoint(x: 12, y: 34)))
        PatchLayoutStore.save(document, for: patchURL)

        // The patch grew a module since the layout was stored.
        let reopened = PatchDocument(catalog: try catalog())
        _ = try #require(reopened.addModule(typeID: 1, at: CGPoint(x: 1, y: 2)))
        _ = try #require(reopened.addModule(typeID: 2, at: CGPoint(x: 3, y: 4)))
        let layout = try #require(PatchLayoutStore.load(for: patchURL))
        PatchLayoutStore.apply(layout, to: reopened)

        #expect(reopened.modules[0].canvasPosition == CGPoint(x: 1, y: 2),
                "a stale layout must not scatter a changed patch")
    }

    @Test func routerReplacesOnlyEmptyUntitledWindows() throws {
        let dir = scratchStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = WindowRouter()

        let empty = PatchSession()
        router.register(empty)
        #expect(empty.isEmptyUntitled)

        let busy = PatchSession()
        router.register(busy)
        _ = busy.document.map { _ = $0.addModule(typeID: 1, at: .zero) }
        #expect(!busy.isEmptyUntitled, "content makes a window ineligible")

        // Preferring the busy window still lands in the empty one.
        let url = dir.appendingPathComponent("missing.bin")
        router.route(url, preferring: busy)
        #expect(router.pendingSpawns.isEmpty,
                "an empty window absorbs the open before any spawn")

        // With no empty window left, the patch waits for its own window.
        _ = empty.document.map { _ = $0.addModule(typeID: 1, at: .zero) }
        router.route(url, preferring: busy)
        #expect(router.pendingSpawns == [url])
        #expect(router.takeSpawn() == url)
        #expect(router.takeSpawn() == nil)

        // A fresh empty window adopts a waiting patch on registration.
        router.route(url, preferring: nil)
        let fresh = PatchSession()
        router.register(fresh)
        #expect(router.pendingSpawns.isEmpty, "registration drains the queue")
    }

    @Test func workspaceRestoresEveryWindowWithItsFrame() throws {
        let dir = scratchStoreDirectory()
        defer {
            try? FileManager.default.removeItem(at: dir)
            PatchSession.defaults = .standard
        }
        let suite = "zoia-workspace-test-\(UUID().uuidString)"
        PatchSession.defaults = try #require(UserDefaults(suiteName: suite))
        defer { PatchSession.defaults.removePersistentDomain(forName: suite) }

        // Two real patches on disk, as if two windows were open at quit.
        let bundle = Bundle(for: WorkspaceCorpus.self)
        let corpus = try #require(bundle.resourceURL?
            .appendingPathComponent("Corpus/Factory/023_zoia_Snowfall.bin"))
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let firstURL = dir.appendingPathComponent("first.bin")
        let secondURL = dir.appendingPathComponent("second.bin")
        try FileManager.default.copyItem(at: corpus, to: firstURL)
        try FileManager.default.copyItem(at: corpus, to: secondURL)
        let secondFrame = CGRect(x: 40, y: 50, width: 900, height: 600)
        let entries = try [
            WorkspaceEntry(bookmark: firstURL.bookmarkData(),
                           x: 10, y: 20, width: 800, height: 500),
            WorkspaceEntry(bookmark: secondURL.bookmarkData(),
                           x: secondFrame.origin.x, y: secondFrame.origin.y,
                           width: secondFrame.width, height: secondFrame.height),
        ]
        PatchSession.defaults.set(try JSONEncoder().encode(entries),
                                  forKey: "workspaceV1")

        let router = WindowRouter()
        let launchWindow = PatchSession()
        router.register(launchWindow)
        router.launchRestore(into: launchWindow)

        #expect(launchWindow.fileURL?.standardizedFileURL
            == firstURL.standardizedFileURL,
                "the launch window takes the first workspace patch")
        #expect(router.pendingSpawns.map(\.standardizedFileURL)
            == [secondURL.standardizedFileURL],
                "the rest wait for windows of their own")
        #expect(router.claimFrame(for: secondURL) == secondFrame)
        #expect(router.claimFrame(for: secondURL) == nil, "frames claim once")

        // A second launchRestore (⌘N window) must not restore again.
        let extra = PatchSession()
        _ = router.takeSpawn()
        router.launchRestore(into: extra)
        #expect(extra.isEmptyUntitled, "only the first window restores")
    }
}

private final class WorkspaceCorpus {}
