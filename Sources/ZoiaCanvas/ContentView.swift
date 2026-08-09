import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var requests = FileRequests()

    @State private var document: PatchDocument?
    @State private var selection: UUID?
    @State private var loadError: String?
    @State private var showingImporter = false
    @State private var engine = AudioEngine()
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
            if let document {
                editor(document)
            } else {
                ProgressView()
                    .task { loadCatalog() }
            }
        }
        .alert("Problem", isPresented: .init(
            get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loadError ?? "")
        }
        .onChange(of: requests.openPanelTicket) { showingImporter = true }
        .onChange(of: requests.exportTicket) {
            if let document { exportBin(document) }
        }
        .onChange(of: requests.pendingURL) {
            if let url = requests.pendingURL {
                openBin(at: url)
                requests.pendingURL = nil
            }
        }
    }

    private func loadCatalog() {
        do {
            document = PatchDocument(catalog: try ModuleCatalog.loadBundled())
        } catch {
            loadError = "Module catalog failed to load: \(error)"
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
        .navigationTitle(document.patchName)
        // Drop a .bin anywhere on the window to open it. The palette's
        // module drags are plain-text payloads, so they never reach this
        // file-URL handler.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in openBin(at: url) }
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
                Button("Open…", systemImage: "square.and.arrow.down") {
                    showingImporter = true
                }
                Button("Export…", systemImage: "square.and.arrow.up") {
                    exportBin(document)
                }
                .disabled(document.modules.isEmpty)
            }
        }
        .onChange(of: document.structureRevision) {
            if engine.isRunning { engine.rebuild(document: document) }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data]) { result in
            if case .success(let url) = result {
                openBin(at: url)
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

    private func openBin(at url: URL) {
        guard let current = document else { return }
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        do {
            let patch = try ZoiaPatchBinary.decode(Data(contentsOf: url))
            let loaded = PatchDocument(patch: patch, catalog: current.catalog)
            if loaded.patchName.isEmpty {
                loaded.patchName = url.deletingPathExtension().lastPathComponent
            }
            document = loaded
            selection = nil
        } catch {
            loadError = "\(url.lastPathComponent): \(error)"
        }
    }

    private func exportBin(_ document: PatchDocument) {
        // buildPatch writes grid positions verbatim; a page over its 40
        // buttons would put modules on top of each other on the pedal.
        let blockers = document.gridExportBlockers
        guard blockers.isEmpty else {
            loadError = "Cannot export.\n" + blockers.joined(separator: "\n")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        panel.nameFieldStringValue = "\(document.patchName.isEmpty ? "patch" : document.patchName).bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.encodeBin().write(to: url)
        } catch {
            loadError = "Export failed: \(error)"
        }
    }
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
    ContentView()
}
