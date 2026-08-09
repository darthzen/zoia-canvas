import SwiftUI

/// Cross-scene open/export plumbing: the File menu and the Finder/Dock
/// open path both land here, and ContentView reacts via onChange.
@Observable
@MainActor
final class FileRequests {
    /// A patch URL delivered from outside the app (Finder, Dock, `open`).
    var pendingURL: URL?
    /// Bumped by File > Open Patch… (⌘O) to show the open panel.
    var openPanelTicket = 0
    /// Bumped by File > Export Patch… (⌘E) to show the save panel.
    var exportTicket = 0
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var requests: FileRequests?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in requests?.pendingURL = url }
    }
}

@main
struct ZoiaCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var requests = FileRequests()

    var body: some Scene {
        // A single Window scene, not a WindowGroup: opening a patch from
        // Finder must load into the existing (possibly empty) project
        // window, and WindowGroup spawns a new window per open request.
        Window("ZOIA Canvas", id: "main") {
            ContentView(requests: requests)
                .onAppear { delegate.requests = requests }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open Patch…") { requests.openPanelTicket += 1 }
                    .keyboardShortcut("o")
                Button("Export Patch…") { requests.exportTicket += 1 }
                    .keyboardShortcut("e")
            }
        }
    }
}
