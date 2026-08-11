import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var router: WindowRouter?

    /// Finder, Dock, and `open` deliveries — routed like any other
    /// open: an empty untitled window adopts the patch, otherwise it
    /// gets a window of its own.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { self.router?.route(url, preferring: nil) }
        }
    }
}

@main
struct ZoiaCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var router = WindowRouter()

    var body: some Scene {
        // One window per patch. The presented URL is the patch a spawn
        // was asked to open; ⌘N and the launch window present nil.
        WindowGroup(id: "patch", for: URL.self) { $url in
            ContentView(router: router, initialURL: url)
                .onAppear { delegate.router = router }
        }
        .commands {
            PatchFileCommands(router: router)
        }
    }
}

/// File menu, acting on the frontmost patch window.
struct PatchFileCommands: Commands {
    let router: WindowRouter
    @FocusedValue(\.patchSession) private var session
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Patch") { openWindow(id: "patch") }
                .keyboardShortcut("n")
            Button("Open Patch…") { session?.showingOpenPanel = true }
                .keyboardShortcut("o")
                .disabled(session == nil)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save Patch") { session?.save() }
                .keyboardShortcut("s")
                .disabled(session == nil)
            Button("Save Patch As…") { session?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(session == nil)
        }
    }
}
