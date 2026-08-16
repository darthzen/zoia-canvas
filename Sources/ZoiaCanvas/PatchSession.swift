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
        reflectEditedState(document?.isEdited ?? false)
        applyPendingFrame()
    }

    /// Unsaved state shows as the standard dot in the close button; the
    /// title bar is spoken for by the editable patch name.
    func reflectEditedState(_ edited: Bool) {
        window?.isDocumentEdited = edited
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
            // Blank header name (factory patches ship a few): fall back
            // to the filename, which carries the same name by convention.
            if loaded.patchName.isEmpty {
                loaded.adoptPatchName(
                    ZoiaPatchNaming.patchName(fromFileName: url.lastPathComponent))
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

    // MARK: - Rename

    private enum RenameChoice {
        case renameFile, saveAsNew, cancel
    }

    /// Renaming from the title bar. An unsaved patch just takes the new
    /// name; a patch that already has a file on disk raises the question
    /// the user is actually asking — is this the same patch under a new
    /// name, or a new patch? Nothing is changed until they answer.
    func rename(to name: String) {
        guard let document else { return }
        let clamped = ZoiaPatchNaming.clamp(name)
        guard clamped != document.patchName else { return }
        guard let fileURL else { return document.setPatchName(clamped) }

        switch Self.confirmRename(from: document.patchName, to: clamped, file: fileURL) {
        case .cancel:
            return
        case .saveAsNew:
            document.setPatchName(clamped)
            saveAs()
        case .renameFile:
            document.setPatchName(clamped)
            renameOnDisk(document, from: fileURL, to: clamped)
        }
    }

    private static func confirmRename(from oldName: String, to newName: String,
                                      file: URL) -> RenameChoice {
        let alert = NSAlert()
        alert.messageText = "Rename “\(oldName)” to “\(newName)”?"
        // The name is bytes inside the patch, not just a label on the
        // file, so either answer rewrites the file — worth saying plainly.
        alert.informativeText = """
            The ZOIA reads the name from inside the patch, so \
            \(file.lastPathComponent) has to be written out again either way. \
            Renaming replaces it; saving as a new patch leaves it as it is.
            """
        alert.addButton(withTitle: "Rename File")
        alert.addButton(withTitle: "Save as New Patch…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .renameFile
        case .alertSecondButtonReturn: return .saveAsNew
        default: return .cancel
        }
    }

    /// Writes the patch out under its new name and clears the old file.
    /// The slot prefix is kept so the patch holds its place on the card.
    private func renameOnDisk(_ document: PatchDocument, from oldURL: URL,
                              to name: String) {
        let slot = ZoiaPatchNaming.slot(fromFileName: oldURL.lastPathComponent)
            ?? ZoiaPatchNaming.defaultSlot
        let newURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(ZoiaPatchNaming.fileName(for: name, slot: slot))
        // Some other patch already holds that name. The save panel owns
        // that conversation, overwrite warning and all.
        guard newURL == oldURL
                || !FileManager.default.fileExists(atPath: newURL.path) else {
            return saveAs()
        }
        writeBin(document, to: newURL)
        // Only once the new file is really there and adopted.
        guard newURL != oldURL, fileURL == newURL else { return }
        try? FileManager.default.removeItem(at: oldURL)
        PatchLayoutStore.discard(for: oldURL)
    }

    // MARK: - Save

    /// ⌘S: write back to the open file. A patch that has never been
    /// saved goes the long way round, because the name the device will
    /// show has to be settled before anything reaches disk.
    func save() {
        guard let document else { return }
        guard let fileURL else { return saveAs() }
        writeBin(document, to: fileURL)
    }

    /// ⇧⌘S: name the patch, write it to a new home, keep working there.
    func saveAs() {
        guard let document, let choice = Self.runSavePanel(document) else { return }
        writeBin(document, to: choice.url, patchName: choice.patchName)
    }

    private func writeBin(_ document: PatchDocument, to url: URL,
                          patchName: String? = nil) {
        let blockers = document.gridExportBlockers
        guard blockers.isEmpty else {
            loadError = "Cannot save.\n" + blockers.joined(separator: "\n")
            return
        }
        // The name is part of the bytes, so it is adopted before the
        // encode rather than after the write.
        if let patchName { document.adoptPatchName(patchName) }
        do {
            try document.encodeBin().write(to: url)
            fileURL = url
            document.markSaved()
            Self.rememberLastPatch(url)
            persistLayout()
        } catch {
            loadError = "Save failed: \(error)"
        }
    }

    /// The panel carries the ZOIA name as well as the filename: the name
    /// is what the device's patch menu reads, and the filename follows
    /// it as `NNN_zoia_Name.bin` until the user types over it.
    private static func runSavePanel(_ document: PatchDocument) -> (url: URL, patchName: String)? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        let naming = SavePanelNaming(panel: panel, patchName: document.patchName)
        panel.accessoryView = naming.accessoryView
        naming.syncFileName()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, naming.patchName)
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

/// The save panel's "ZOIA patch name" field. Owns the rule that the
/// filename trails the name, and holds the name to the 16 bytes the
/// header stores so what the panel shows is what the device will show.
@MainActor
private final class SavePanelNaming: NSObject, NSTextFieldDelegate {
    private weak var panel: NSSavePanel?
    private let field: NSTextField

    init(panel: NSSavePanel, patchName: String) {
        self.panel = panel
        field = NSTextField(string: ZoiaPatchNaming.clamp(patchName))
        super.init()
        field.delegate = self
        field.placeholderString = "Shown in the ZOIA's patch menu"
    }

    var patchName: String { ZoiaPatchNaming.clamp(field.stringValue) }

    lazy var accessoryView: NSView = {
        let stack = NSStackView(views: [
            NSTextField(labelWithString: "ZOIA patch name:"), field,
        ])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 4, right: 20)
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        return stack
    }()

    func syncFileName() {
        panel?.nameFieldStringValue = ZoiaPatchNaming.fileName(for: patchName)
    }

    func controlTextDidChange(_ notification: Notification) {
        // Typing past 16 bytes would silently vanish at encode time, so
        // the field refuses the extra characters instead.
        let clamped = patchName
        if field.stringValue != clamped { field.stringValue = clamped }
        syncFileName()
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
