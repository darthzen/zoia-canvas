import AppKit
import SwiftUI
import Testing
@testable import ZoiaCanvas

/// Regression: deleting the inspected module while the inspector is on
/// screen. AppKit controls and lazily re-evaluated rows outlive the
/// deletion by a frame; anything holding a captured array index
/// subscripts past the end of `modules` and dies.
@Suite @MainActor struct InspectorTeardownTests {
    @Test func deletingInspectedModuleDoesNotCrash() throws {
        let document = PatchDocument(catalog: try ModuleCatalog.loadBundled())
        // Sequencer: has options, params, and a text field — every
        // binding shape the inspector builds.
        let module = try #require(document.addModule(typeID: 4, at: .zero))

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(
            rootView: InspectorView(document: document, moduleID: module.id))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        document.removeModule(module.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        window.orderOut(nil)
        #expect(document.modules.isEmpty)
    }
}
