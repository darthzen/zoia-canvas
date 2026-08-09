import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var document: PatchDocument?
    @State private var selection: UUID?
    @State private var loadError: String?
    @State private var showingImporter = false

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
            PatchEditorView(document: document, selection: $selection)
                .coordinateSpace(name: "editor")
                .frame(minWidth: 500, maxWidth: .infinity,
                       minHeight: 400, maxHeight: .infinity)
        }
        .navigationTitle(document.patchName)
        .toolbar {
            ToolbarItemGroup {
                DSPMeter(total: document.dspTotal)
                Button("Open…", systemImage: "square.and.arrow.down") {
                    showingImporter = true
                }
                Button("Export…", systemImage: "square.and.arrow.up") {
                    exportBin(document)
                }
                .disabled(document.modules.isEmpty)
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data]) { result in
            if case .success(let url) = result {
                openBin(at: url)
            }
        }
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
