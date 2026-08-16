import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let router: WindowRouter
    let initialURL: URL?

    @State private var session = PatchSession()
    @State private var selection: UUID?
    @State private var engine = AudioEngine()
    @Environment(\.openWindow) private var openWindow
    @AppStorage("cableStyle") private var cableStyleRaw = CableStyle.curved.rawValue

    /// Curved (parenthesis) vs angular (curly-bracket) cable rendering.
    private var cableStylePicker: some View {
        Picker("Cable style", selection: $cableStyleRaw) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .help("Curved cables")
                .tag(CableStyle.curved.rawValue)
            Image(systemName: "arrow.turn.right.down")
                .help("Angular cables")
                .tag(CableStyle.angular.rawValue)
        }
        .pickerStyle(.segmented)
        .help("Cable style")
    }

    var body: some View {
        Group {
            if let document = session.document {
                editor(document)
            } else {
                ProgressView()
            }
        }
        .focusedSceneValue(\.patchSession, session)
        .alert("Problem", isPresented: .init(
            get: { session.loadError != nil },
            set: { if !$0 { session.loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.loadError ?? "")
        }
        .background(WindowAccessor { session.adoptWindow($0) })
        .onAppear {
            router.register(session)
            if let initialURL {
                session.schedule(frame: router.claimFrame(for: initialURL))
                session.openBin(at: initialURL)
            } else {
                router.launchRestore(into: session)
            }
            consumeSpawn()
        }
        .onDisappear {
            session.persistLayout()
            router.unregister(session)
        }
        // A patch that needs its own window (every window busy) waits in
        // the router; any live window spawns it.
        .onChange(of: router.pendingSpawns) { consumeSpawn() }
        // A new document means a new module set; stale selection would
        // point the inspector at a ghost.
        .onChange(of: session.document.map(ObjectIdentifier.init)) { selection = nil }
    }

    private func consumeSpawn() {
        if let url = router.takeSpawn() {
            openWindow(id: "patch", value: url)
        }
    }

    private func editor(_ document: PatchDocument) -> some View {
        HSplitView {
            PaletteView(catalog: document.catalog) { typeID in
                let stagger = CGFloat(document.modules.count % 6) * 30
                document.addModule(typeID: typeID,
                                   at: CGPoint(x: 320 + stagger, y: 120 + stagger))
            }
            PatchEditorView(document: document, selection: $selection,
                            engine: engine)
                .coordinateSpace(name: "editor")
                .frame(minWidth: 500, maxWidth: .infinity,
                       minHeight: 400, maxHeight: .infinity)
            if let selected = selection {
                InspectorView(document: document, moduleID: selected)
            }
        }
        // Editable in place. This is the name the ZOIA's patch menu
        // shows, and the save panel derives the filename from it, so
        // the title bar is the one place a patch gets named.
        .navigationTitle(Binding(
            get: { document.patchName },
            set: { session.rename(to: $0) }))
        // The title now belongs to the name, so unsaved state moves to
        // the dot macOS puts in the close button.
        .onChange(of: document.isEdited, initial: true) {
            session.reflectEditedState(document.isEdited)
        }
        // Drop a .bin anywhere on the window to open it. The palette's
        // module drags are plain-text payloads, so they never reach this
        // file-URL handler.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in router.route(url, preferring: session) }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                DSPMeter(total: document.dspTotal)
                cableStylePicker
                // Expanded layout re-packs the canvas with room for every
                // connector card; toggling back restores the arrangement.
                Toggle(isOn: .init(
                    get: { document.isCardLayoutExpanded },
                    set: { $0 ? document.applyExpandedCardLayout()
                              : document.restoreCollapsedCardLayout() })) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .help("Expand all connector cards")
                }
                .toggleStyle(.button)
                inputSourceMenu
                Button(engine.isRunning ? "Stop" : "Play",
                       systemImage: engine.isRunning ? "stop.fill" : "play.fill") {
                    if engine.isRunning {
                        engine.stop()
                    } else {
                        engine.start(document: document)
                    }
                }
                Button("Open…", systemImage: "folder") {
                    session.showingOpenPanel = true
                }
                Button("Save", systemImage: "square.and.arrow.down") {
                    session.save()
                }
                .disabled(!document.isEdited)
                .help(document.isEdited ? "Save changes (⌘S)" : "No unsaved changes")
            }
        }
        .onChange(of: document.structureRevision) {
            if engine.isRunning { engine.rebuild(document: document) }
        }
        .fileImporter(isPresented: .init(
            get: { session.showingOpenPanel },
            set: { session.showingOpenPanel = $0 }),
                      allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data]) { result in
            if case .success(let url) = result {
                router.route(url, preferring: session)
            }
        }
    }

    /// Capture-source picker: the mic, but also virtual loopback devices
    /// (BlackHole, Loopback, aggregates), which is how another app's
    /// audio gets played into the patch.
    private var inputSourceMenu: some View {
        Menu {
            Button {
                engine.selectInput(deviceID: nil)
            } label: {
                if engine.inputDeviceID == nil { Image(systemName: "checkmark") }
                Text("System Default")
            }
            Divider()
            ForEach(AudioEngine.availableInputDevices()) { device in
                Button {
                    engine.selectInput(deviceID: device.id)
                } label: {
                    if engine.inputDeviceID == device.id { Image(systemName: "checkmark") }
                    Text(device.name)
                }
            }
        } label: {
            Label("Input", systemImage: "waveform.badge.mic")
        }
        .help("Audio input source — pick a loopback device (e.g. BlackHole) to route another app in")
    }
}

/// Hands the hosting NSWindow to the session, for workspace frame
/// save/restore.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            Task { @MainActor in self.onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = onWindow
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// The ZOIA's DSP budget is 100%; estimates come from the module catalog
/// like the on-device meter.
struct DSPMeter: View {
    let total: Double

    var body: some View {
        HStack(spacing: 6) {
            Gauge(value: min(total, 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(total > 85 ? .red : total > 65 ? .yellow : .green)
                .frame(width: 90)
            Text(String(format: "DSP %.1f%%", total))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(total > 100 ? .red : .secondary)
        }
        .help("Estimated DSP load (catalog averages; the device meter is truth)")
    }
}

#Preview {
    ContentView(router: WindowRouter(), initialURL: nil)
}
