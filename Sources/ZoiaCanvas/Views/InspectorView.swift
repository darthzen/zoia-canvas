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
    /// Live grid-drag state: the page's slots before the drag started,
    /// which button of the module was grabbed, and the last previewed
    /// target (to skip redundant re-settles).
    @State private var dragSnapshot: [UUID: Int]?
    @State private var dragGrabOffset = 0
    @State private var dragPreviewCell: Int?

    /// The module's index re-resolved at access time. Binding closures
    /// escape and outlive a deletion by a frame — AppKit controls query
    /// them while the panel tears down, so a captured index would
    /// subscript past the end of `modules`.
    private var liveIndex: Int? {
        document.modules.firstIndex { $0.id == moduleID }
    }

    var body: some View {
        if let index = document.modules.firstIndex(where: { $0.id == moduleID }),
           let spec = document.catalog[document.modules[index].typeID] {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(index: index, spec: spec)
                    gridSection(index: index)
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
                get: { liveIndex.map { document.modules[$0].customName } ?? "" },
                set: { document.setCustomName(moduleID, to: $0) }))
                .textFieldStyle(.roundedBorder)
            Picker("Color", selection: Binding(
                get: { liveIndex.map { document.modules[$0].colorID } ?? 1 },
                set: { document.setColorID(moduleID, to: $0) })) {
                ForEach(1...15, id: \.self) { code in
                    HStack {
                        Circle().fill(zoiaColor(code)).frame(width: 10, height: 10)
                        Text(zoiaColorName(code))
                    }
                    .tag(code)
                }
            }
            Picker("Page", selection: Binding(
                get: { liveIndex.map { document.modules[$0].page } ?? 0 },
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

    /// The module's page as the pedal shows it: 8×5 buttons, every
    /// module in its live grid slot. Drag (or click) to place this
    /// module; whatever the drop lands on steps aside, and placement
    /// is sticky — nothing else moves.
    private func gridSection(index: Int) -> some View {
        let module = document.modules[index]
        let span = document.buttonSpan(module)
        let occupants = document.modules(onPage: module.page)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Grid").font(.subheadline.bold())
                Spacer()
                Text("\(span) button\(span == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            gridButtons(module: module, span: span, occupants: occupants)
            if document.gridOverflow[module.page] != nil {
                Text("Page over 40 buttons — export is blocked")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
    }

    private func gridButtons(module: CanvasModule, span: Int,
                             occupants: [CanvasModule]) -> some View {
        let colorAt: [Int: Color] = occupants.reduce(into: [:]) { map, m in
            let mSpan = document.buttonSpan(m)
            for b in m.gridPosition..<(m.gridPosition + mSpan)
            where b < PatchDocument.pageButtonCount {
                map[b] = zoiaColor(m.colorID).opacity(m.id == module.id ? 1 : 0.35)
            }
        }
        let mine = Set(module.gridPosition..<(module.gridPosition + span))
        return Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0..<5, id: \.self) { row in
                GridRow {
                    ForEach(0..<8, id: \.self) { col in
                        let cell = row * 8 + col
                        RoundedRectangle(cornerRadius: 3)
                            .fill(colorAt[cell] ?? Color.primary.opacity(0.08))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(mine.contains(cell) ? Color.accentColor : .clear,
                                              lineWidth: 1.5))
                            .frame(width: 22, height: 16)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(gridDragGesture(module: module, span: span))
        .help("Drag \(module.customName.isEmpty ? "this module" : module.customName) to a button; whatever it lands on steps aside")
    }

    /// The button under a point, mirroring the Grid above: 22×16 cells
    /// on 3pt spacing.
    private func gridCell(at point: CGPoint) -> Int {
        let col = min(max(Int(point.x / 25), 0), 7)
        let row = min(max(Int(point.y / 19), 0), 4)
        return row * 8 + col
    }

    /// Drag (a click is the zero-distance case) to place the module.
    /// Every step rewinds to the pre-drag snapshot before re-placing,
    /// so a neighbor pushed aside returns the moment the drag moves
    /// elsewhere; release keeps whatever the preview shows.
    private func gridDragGesture(module: CanvasModule, span: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragSnapshot == nil {
                    dragSnapshot = document.gridSnapshot(page: module.page)
                    // Grabbing one of the module's own buttons drags by
                    // that button, not by its first block.
                    let start = gridCell(at: value.startLocation)
                    let run = module.gridPosition..<(module.gridPosition + span)
                    dragGrabOffset = run.contains(start) ? start - module.gridPosition : 0
                }
                let target = min(max(gridCell(at: value.location) - dragGrabOffset, 0),
                                 max(PatchDocument.pageButtonCount - span, 0))
                guard target != dragPreviewCell else { return }
                if let snapshot = dragSnapshot {
                    document.restoreGridPositions(snapshot)
                }
                document.setGridPosition(moduleID, to: target)
                dragPreviewCell = target
            }
            .onEnded { _ in
                dragSnapshot = nil
                dragPreviewCell = nil
                dragGrabOffset = 0
            }
    }

    @ViewBuilder
    private func optionsSection(index: Int, spec: ModuleSpec) -> some View {
        if !spec.options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Options").font(.subheadline.bold())
                ForEach(Array(spec.options.enumerated()), id: \.offset) { optIndex, option in
                    Picker(option.key, selection: Binding(
                        get: {
                            liveIndex.map { Int(document.modules[$0].optionBytes[optIndex]) } ?? 0
                        },
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
            VStack(alignment: .leading, spacing: 10) {
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
                    ParamRow(key: block.key,
                             fraction: paramFraction(paramIndex),
                             showNoteNames: showNoteNames) { fraction in
                        document.setParam(moduleID, paramIndex: paramIndex, fraction: fraction)
                    }
                }
            }
        }
    }

    /// Param read that survives the module's deletion — the ForEach row
    /// re-evaluates lazily and its captured index dies with the module;
    /// see `liveIndex`.
    private func paramFraction(_ paramIndex: Int) -> Double {
        guard let i = liveIndex, paramIndex < document.modules[i].paramsRaw.count
        else { return 0 }
        return Double(document.modules[i].paramsRaw[paramIndex]) / 65535
    }
}

/// One param block: a full-width slider with the value in a field you can
/// type into. In Note mode the slider steps by whole semitones — 127
/// notes across a panel-width track is otherwise too fine to land on the
/// note you want — and the field takes note names ("C4", "F#3", "Bb2") or
/// a bare MIDI note number.
private struct ParamRow: View {
    let key: String
    let fraction: Double
    let showNoteNames: Bool
    let commit: (Double) -> Void

    @State private var text = ""
    @FocusState private var editing: Bool

    private static let noteNames = ["C", "C#", "D", "D#", "E", "F",
                                    "F#", "G", "G#", "A", "A#", "B"]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(key)
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 4)
                TextField("", text: $text)
                    .font(.system(size: 10, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 58)
                    .focused($editing)
                    .onSubmit { commitText() }
                    .help(showNoteNames
                          ? "Type a note name (C4, F#3, Bb2) or a MIDI note number 0–127"
                          : "Type a CV value from 0 to 1")
            }
            slider
        }
        .onAppear { text = Self.label(fraction, notes: showNoteNames) }
        // While the field has focus the value it drives is not allowed to
        // overwrite what is being typed.
        .onChange(of: fraction) { if !editing { text = Self.label(fraction, notes: showNoteNames) } }
        .onChange(of: showNoteNames) { text = Self.label(fraction, notes: showNoteNames) }
        .onChange(of: editing) { _, focused in if !focused { commitText() } }
    }

    @ViewBuilder
    private var slider: some View {
        if showNoteNames {
            Slider(value: Binding(
                get: { (fraction * 127).rounded() },
                set: { commit($0 / 127) }), in: 0...127, step: 1)
        } else {
            Slider(value: Binding(get: { fraction }, set: { commit($0) }))
        }
    }

    /// Commit the typed text, then restate the field from the value that
    /// was actually stored — `fraction` still holds the pre-commit value
    /// on this pass, so the label is built from the parsed number.
    private func commitText() {
        guard let parsed = parse(text) else {
            text = Self.label(fraction, notes: showNoteNames)
            return
        }
        commit(parsed)
        text = Self.label(parsed, notes: showNoteNames)
    }

    private func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard showNoteNames else {
            guard let value = Double(trimmed) else { return nil }
            return min(max(value, 0), 1)
        }
        if let note = Int(trimmed) {
            return Double(min(max(note, 0), 127)) / 127
        }
        return Self.midiNote(from: trimmed).map { Double($0) / 127 }
    }

    private static func label(_ fraction: Double, notes: Bool) -> String {
        guard notes else { return String(format: "%.2f", fraction) }
        let note = min(max(Int((fraction * 127).rounded()), 0), 127)
        return noteNames[note % 12] + String(note / 12 - 1)
    }

    /// "C4", "F#3", "Bb2", "Eb-1" → MIDI note, with C-1 as note 0 to
    /// match the readout.
    private static func midiNote(from text: String) -> Int? {
        var chars = Array(text.uppercased())
        let steps: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5,
                                       "G": 7, "A": 9, "B": 11]
        guard let letter = chars.first, let base = steps[letter] else { return nil }
        chars.removeFirst()
        var semitone = base
        while let accidental = chars.first,
              accidental == "#" || accidental == "♯"
              || accidental == "B" || accidental == "♭" {
            semitone += (accidental == "#" || accidental == "♯") ? 1 : -1
            chars.removeFirst()
        }
        guard let octave = Int(String(chars)) else { return nil }
        let note = (octave + 1) * 12 + semitone
        return (0...127).contains(note) ? note : nil
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
