import SwiftUI

/// Right-hand panel for the selected module: name, color, every catalog
/// option (changing one re-lays-out the blocks live), and a control per
/// active param block. This is where a sequencer grows past one step —
/// its number_of_steps option sizes both the blocks and the param list.
struct InspectorView: View {
    @Bindable var document: PatchDocument
    let moduleID: UUID
    /// Param value readout: raw 0…1 CV fraction, or the MIDI note the
    /// pitch mapping (fraction × 127) lands on. Persisted across launches.
    @AppStorage("paramDisplayNotes") private var showNoteNames = false

    var body: some View {
        if let index = document.modules.firstIndex(where: { $0.id == moduleID }),
           let spec = document.catalog[document.modules[index].typeID] {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(index: index, spec: spec)
                    optionsSection(index: index, spec: spec)
                    paramsSection(index: index)
                }
                .padding(12)
            }
            .frame(minWidth: 230, maxWidth: 280)
        }
    }

    private func header(index: Int, spec: ModuleSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(spec.name)
                .font(.headline)
            TextField("Custom name", text: Binding(
                get: { document.modules[index].customName },
                set: { document.modules[index].customName = String($0.prefix(16)) }))
                .textFieldStyle(.roundedBorder)
            Picker("Color", selection: Binding(
                get: { document.modules[index].colorID },
                set: { document.modules[index].colorID = $0 })) {
                ForEach(1...15, id: \.self) { code in
                    HStack {
                        Circle().fill(zoiaColor(code)).frame(width: 10, height: 10)
                        Text(zoiaColorName(code))
                    }
                    .tag(code)
                }
            }
            Picker("Page", selection: Binding(
                get: { document.modules[index].page },
                set: { document.moveModule(moduleID, toPage: $0) })) {
                ForEach(0..<document.pageCount, id: \.self) { page in
                    let name = document.pageName(page)
                    Text(name.isEmpty ? "Page \(page + 1)" : "\(page + 1) · \(name)")
                        .tag(page)
                }
            }
            if let doc = spec.doc {
                Text(doc.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func optionsSection(index: Int, spec: ModuleSpec) -> some View {
        if !spec.options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Options").font(.subheadline.bold())
                ForEach(Array(spec.options.enumerated()), id: \.offset) { optIndex, option in
                    Picker(option.key, selection: Binding(
                        get: { Int(document.modules[index].optionBytes[optIndex]) },
                        set: { document.setOption(moduleID, optionIndex: optIndex, byte: UInt8($0)) })) {
                        ForEach(Array(option.values.enumerated()), id: \.offset) { valueIndex, value in
                            Text(value.description).tag(valueIndex)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func paramsSection(index: Int) -> some View {
        let blocks = document.paramBlocks(of: document.modules[index])
        if !blocks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Params").font(.subheadline.bold())
                    Spacer()
                    Picker("", selection: $showNoteNames) {
                        Text("CV").tag(false)
                        Text("Note").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 90)
                    .help("Show values as raw CV or as the MIDI note the pitch mapping lands on")
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { paramIndex, block in
                    HStack(spacing: 6) {
                        Text(block.key)
                            .font(.caption)
                            .frame(width: 90, alignment: .leading)
                            .lineLimit(1)
                        Slider(value: Binding(
                            get: {
                                paramIndex < document.modules[index].paramsRaw.count
                                    ? Double(document.modules[index].paramsRaw[paramIndex]) / 65535
                                    : 0
                            },
                            set: { document.setParam(moduleID, paramIndex: paramIndex, fraction: $0) }))
                        Text(valueLabel(
                            paramIndex < document.modules[index].paramsRaw.count
                                ? Double(document.modules[index].paramsRaw[paramIndex]) / 65535 : 0))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 30)
                    }
                }
            }
        }
    }

    private func valueLabel(_ fraction: Double) -> String {
        guard showNoteNames else { return String(format: "%.2f", fraction) }
        let note = Int((fraction * 127).rounded())
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return names[note % 12] + String(note / 12 - 1)
    }
}

func zoiaColorName(_ code: Int) -> String {
    switch code {
    case 1: "Blue"; case 2: "Green"; case 3: "Red"; case 4: "Yellow"
    case 5: "Aqua"; case 6: "Magenta"; case 7: "White"; case 8: "Orange"
    case 9: "Lima"; case 10: "Surf"; case 11: "Sky"; case 12: "Purple"
    case 13: "Pink"; case 14: "Peach"; case 15: "Mango"
    default: "Gray"
    }
}
