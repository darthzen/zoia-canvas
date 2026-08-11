import SwiftUI
import UniformTypeIdentifiers

/// One window's document and file plumbing. A class rather than view
/// state so menu commands, the window router, and AppKit callbacks
/// always reach the live document — closures capturing view structs
/// went stale once already (the delete-monitor bug).
@Observable
@MainActor
final class PatchSession: Identifiable {
    /// Backing store for the last-patch bookmark and the workspace —
    /// overridable so tests never touch the app's real defaults.
    static var defaults: UserDefaults = .standard

    let id = UUID()
    private(set) var document: PatchDocument?
    private(set) var fileURL: URL?
    var loadError: String?
    /// Drives the window's file importer (the Open… command and button).
    var showingOpenPanel = false
    /// The hosting window, handed over by WindowAccessor — for reading
    /// the frame into the workspace at quit and restoring it at launch.
    @ObservationIgnored private(set) weak var window: NSWindow?
    /// A workspace-restore frame waiting for the window to exist.
    @ObservationIgnored private var pendingFrame: CGRect?

    func adoptWindow(_ window: NSWindow?) {
        self.window = window
        applyPendingFrame()
    }

    /// Schedules a frame from the stored workspace; applied as soon as
    /// the window exists (either order works).
    func schedule(frame: CGRect?) {
        pendingFrame = frame
        applyPendingFrame()
    }

    private func applyPendingFrame() {
        guard let window, let frame = pendingFrame,
              frame.width > 100, frame.height > 100 else { return }
        window.setFrame(frame, display: true)
        pendingFrame = nil
    }

    /// An open lands in this window only while there is nothing to
    /// lose here; otherwise the router gives the patch its own window.
    var isEmptyUntitled: Bool {
        fileURL == nil && (document.map { $0.modules.isEmpty && !$0.isEdited } ?? true)
    }

    init() {
        do {
            document = PatchDocument(catalog: try ModuleCatalog.loadBundled())
        } catch {
            loadError = "Module catalog failed to load: \(error)"
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistLayout() }
        }
    }

    // MARK: - Open

    func openBin(at url: URL) {
        guard let current = document else { return }
        persistLayout()   // the outgoing patch keeps its arrangement
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let patch = try ZoiaPatchBinary.decode(Data(contentsOf: url))
            let loaded = PatchDocument(patch: patch, catalog: current.catalog)
            if loaded.patchName.isEmpty {
                loaded.patchName = url.deletingPathExtension().lastPathComponent
            }
            if let layout = PatchLayoutStore.load(for: url) {
                PatchLayoutStore.apply(layout, to: loaded)
            }
            document = loaded
            fileURL = url
            Self.rememberLastPatch(url)
        } catch {
            loadError = "\(url.lastPathComponent): \(error)"
        }
    }

    // MARK: - Save

    /// ⌘S: write back to the open file; an untitled patch picks its
    /// home through the save panel once and saves silently after.
    func save() {
        guard let document else { return }
        writeBin(document, to: fileURL ?? Self.runSavePanel(document), adopt: true)
    }

    /// ⇧⌘S: write to a new home and keep working there.
    func saveAs() {
        guard let document else { return }
        writeBin(document, to: Self.runSavePanel(document), adopt: true)
    }

    private func writeBin(_ document: PatchDocument, to url: URL?, adopt: Bool) {
        let blockers = document.gridExportBlockers
        guard blockers.isEmpty else {
            loadError = "Cannot save.\n" + blockers.joined(separator: "\n")
            return
        }
        guard let url else { return }
        do {
            try document.encodeBin().write(to: url)
            if adopt {
                if document.patchName.isEmpty {
                    document.patchName = url.deletingPathExtension().lastPathComponent
                }
                fileURL = url
                document.markSaved()
                Self.rememberLastPatch(url)
                persistLayout()
            }
        } catch {
            loadError = "Save failed: \(error)"
        }
    }

    private static func runSavePanel(_ document: PatchDocument) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.nameFieldStringValue =
            "\(document.patchName.isEmpty ? "patch" : document.patchName).bin"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Canvas layout sidecar

    /// Called on save, on open (for the outgoing patch), when the
    /// window closes, and at quit — the arrangement survives without
    /// the user ever thinking about it.
    func persistLayout() {
        guard let document, let fileURL else { return }
        PatchLayoutStore.save(document, for: fileURL)
    }

    // MARK: - Last-patch bookmark

    private static let lastPatchKey = "lastOpenedPatch"

    /// A bookmark (not a path) so the file is found again after a move;
    /// the app is unsandboxed, so no security scope is involved.
    static func rememberLastPatch(_ url: URL) {
        if let data = try? url.bookmarkData() {
            defaults.set(data, forKey: lastPatchKey)
        }
    }

    /// The launch window reopens the last patch that was open.
    func restoreLastPatch() {
        guard let data = Self.defaults.data(forKey: Self.lastPatchKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else {
            // The file is gone; forget it quietly rather than alerting
            // on every launch until something else is opened.
            Self.defaults.removeObject(forKey: Self.lastPatchKey)
            return
        }
        openBin(at: url)
        if stale { Self.rememberLastPatch(url) }
    }
}

/// One window's worth of stored workspace: which patch, and where the
/// window sat.
struct WorkspaceEntry: Codable {
    var bookmark: Data
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

/// Decides where an open lands: the window that asked (if it has
/// nothing to lose), any other empty untitled window, or a fresh
/// window — patches open side by side for comparison, and only an
/// empty untitled window ever gets replaced. Also owns the workspace:
/// the set of open patch windows, persisted at quit and reopened in
/// full at launch.
@Observable
@MainActor
final class WindowRouter {
    private(set) var sessions: [PatchSession] = []
    /// URLs waiting for a window of their own; any live window's
    /// coordinator consumes one and calls openWindow with it.
    private(set) var pendingSpawns: [URL] = []
    /// Workspace frames waiting for their patch's window, by
    /// standardized file path.
    private var pendingFrames: [String: CGRect] = [:]
    private var launchRestoreClaimed = false

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil,
            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveWorkspace() }
        }
    }

    func register(_ session: PatchSession) {
        sessions.append(session)
        // A window born empty adopts a waiting patch (covers "app had
        // no windows and Finder opened one").
        if session.isEmptyUntitled, !pendingSpawns.isEmpty {
            let url = pendingSpawns.removeFirst()
            session.schedule(frame: claimFrame(for: url))
            session.openBin(at: url)
        }
    }

    func unregister(_ session: PatchSession) {
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: - Workspace

    private static let workspaceKey = "workspaceV1"

    /// Every open window that has a file, with its frame — written at
    /// quit, reopened wholesale by `launchRestore`. Untitled windows
    /// have nothing on disk to reopen and are skipped.
    private func saveWorkspace() {
        let entries = sessions.compactMap { session -> WorkspaceEntry? in
            guard let url = session.fileURL,
                  let bookmark = try? url.bookmarkData() else { return nil }
            let frame = session.window?.frame ?? .zero
            return WorkspaceEntry(bookmark: bookmark,
                                  x: frame.origin.x, y: frame.origin.y,
                                  width: frame.width, height: frame.height)
        }
        PatchSession.defaults.set(
            try? JSONEncoder().encode(entries), forKey: Self.workspaceKey)
    }

    static func loadWorkspace() -> [(url: URL, frame: CGRect)] {
        guard let data = PatchSession.defaults.data(forKey: workspaceKey),
              let entries = try? JSONDecoder().decode([WorkspaceEntry].self, from: data)
        else { return [] }
        return entries.compactMap { entry in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: entry.bookmark,
                                     bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return (url, CGRect(x: entry.x, y: entry.y,
                                width: entry.width, height: entry.height))
        }
    }

    /// The first launch window triggers this exactly once: it takes
    /// the workspace's first patch itself and queues the rest, each
    /// with its remembered frame. No stored workspace falls back to
    /// reopening the last patch; ⌘N windows never restore anything.
    func launchRestore(into session: PatchSession) {
        guard !launchRestoreClaimed else { return }
        launchRestoreClaimed = true
        guard session.isEmptyUntitled else { return }
        let workspace = Self.loadWorkspace()
        guard let first = workspace.first else {
            session.restoreLastPatch()
            return
        }
        session.schedule(frame: first.frame)
        session.openBin(at: first.url)
        for entry in workspace.dropFirst() {
            pendingFrames[entry.url.standardizedFileURL.path] = entry.frame
            pendingSpawns.append(entry.url)
        }
    }

    func claimFrame(for url: URL) -> CGRect? {
        pendingFrames.removeValue(forKey: url.standardizedFileURL.path)
    }

    func route(_ url: URL, preferring session: PatchSession?) {
        if let session, session.isEmptyUntitled {
            session.openBin(at: url)
        } else if let empty = sessions.first(where: \.isEmptyUntitled) {
            empty.openBin(at: url)
        } else {
            pendingSpawns.append(url)
        }
    }

    func takeSpawn() -> URL? {
        pendingSpawns.isEmpty ? nil : pendingSpawns.removeFirst()
    }
}

extension FocusedValues {
    /// The frontmost window's session, for the File menu commands.
    @Entry var patchSession: PatchSession?
}
