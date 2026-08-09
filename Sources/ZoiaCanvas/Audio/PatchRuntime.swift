import Foundation

/// Offline-renderable evaluation of a patch graph.
///
/// Semantics mirror the device where they are known and are documented
/// assumptions where they are not:
/// - Modules evaluate in list order per control block; a wire from a
///   later module reads its previous block's output (one-block delay),
///   which is how the pedal behaves for backward connections.
/// - CV inputs sum the incoming wires (× strength) on top of the param
///   value, clamped to 0…1. (Assumption: device sums rather than
///   replaces; calibrate against hardware later.)
/// - Pitch CV: fraction × 127 = MIDI note; Hz = 440 × 2^((n−69)/12).
///   (Assumption: matches the community 0…1 ≙ 0…127 mapping.)
/// - Sequencer: track 1 reads step values from params (verified against
///   factory patches); tracks 2+ read the saved_data step matrix — see
///   SequencerSavedData for the decoded layout and its evidence.
///
/// Module implementations live in per-group extension files
/// (PatchRuntime+Interface, +CVA, +CVB, +AudioA, +AudioB, +Analysis,
/// +EffectA, +EffectB); this file owns the graph, the input helpers, and
/// the render loop.
final class PatchRuntime {
    struct Wire {
        var sourceNode: Int
        var sourceBlock: Int
        var destNode: Int
        var destBlock: Int
        var gain: Float
    }

    /// Per-call state handed to every render group: capture buffers in,
    /// mix buffers out, and the MIDI drained at the top of the block.
    struct RenderContext {
        let frames: Int
        let inputL: [Float]
        let inputR: [Float]
        let incoming: [MidiEvent]
        var outputL: [Float]
        var outputR: [Float]
    }

    final class Node {
        let typeID: Int
        let options: [OptionValue]
        var params: [Float]
        /// Param block position → param array index.
        let paramIndexByPosition: [Int: Int]
        /// Module-specific stored state, raw as decoded from the file
        /// (sequencer step matrix, sampler buffers …).
        let savedData: Data
        var cvOut: [Int: Float] = [:]
        var audioOut: [Int: [Float]] = [:]

        // Lightweight shared state used by several small modules.
        var phase: Double = 0
        var step: Int = 0
        var lastGate: Float = 0
        var lastRestart: Float = 0
        var finished = false
        var activeNote: Int = -1
        var heldNotes: [Int: Int] = [:]  // note → velocity, for midi in

        /// Typed per-module state for implementations that need more than
        /// the shared fields (delay lines, filter memory, envelopes …).
        /// Each group file defines its own state class; created on first
        /// access and kept for the node's lifetime.
        private var stateBox: AnyObject?
        func state<T: AnyObject>(_ create: @autoclosure () -> T) -> T {
            if let existing = stateBox as? T { return existing }
            let fresh = create()
            stateBox = fresh
            return fresh
        }

        init(typeID: Int, options: [OptionValue], params: [Float],
             paramIndexByPosition: [Int: Int], savedData: Data) {
            self.typeID = typeID
            self.options = options
            self.params = params
            self.paramIndexByPosition = paramIndexByPosition
            self.savedData = savedData
        }

        func optionText(_ index: Int) -> String {
            guard index < options.count, case .text(let t) = options[index] else { return "" }
            return t
        }
        func optionInt(_ index: Int) -> Int {
            guard index < options.count, case .number(let n) = options[index] else { return 0 }
            return Int(n)
        }
    }

    let sampleRate: Double
    private(set) var nodes: [Node] = []
    private var wires: [Wire] = []
    /// Wires grouped by (destNode, destBlock) for fast summing.
    private var wiresInto: [Int: [Wire]] = [:]
    weak var midi: MidiPort?

    @MainActor
    init(document: PatchDocument, sampleRate: Double) {
        self.sampleRate = sampleRate
        var indexOf: [UUID: Int] = [:]
        for (i, module) in document.modules.enumerated() {
            indexOf[module.id] = i
            let spec = document.catalog[module.typeID]
            let options = (try? spec.map {
                try BlockLayout.selectedOptions(spec: $0, optionBytes: module.optionBytes)
            }) ?? nil
            let paramBlocks = document.paramBlocks(of: module)
            var paramIndex: [Int: Int] = [:]
            for (i, block) in paramBlocks.enumerated() {
                if let position = block.position { paramIndex[position] = i }
            }
            nodes.append(Node(
                typeID: module.typeID,
                options: options ?? [],
                params: module.paramsRaw.map { Float($0) / 65535 },
                paramIndexByPosition: paramIndex,
                savedData: module.savedData))
        }
        for c in document.connections {
            guard let s = indexOf[c.sourceModule], let d = indexOf[c.destModule] else { continue }
            let wire = Wire(sourceNode: s, sourceBlock: c.sourceBlock,
                            destNode: d, destBlock: c.destBlock,
                            gain: Float(c.strengthRaw) / 10000)
            wires.append(wire)
            wiresInto[d << 8 | (c.destBlock & 0xFF), default: []].append(wire)
        }
    }

    // MARK: - Input helpers (used by the render group extensions)

    func cvIn(node: Int, block: Int) -> Float {
        var value = nodes[node].paramIndexByPosition[block]
            .map { nodes[node].params[$0] } ?? 0
        for wire in wiresInto[node << 8 | (block & 0xFF)] ?? [] {
            value += (nodes[wire.sourceNode].cvOut[wire.sourceBlock] ?? 0) * wire.gain
        }
        return min(max(value, -1), 1)
    }

    func audioIn(node: Int, block: Int, frames: Int) -> [Float] {
        var mix = [Float](repeating: 0, count: frames)
        for wire in wiresInto[node << 8 | (block & 0xFF)] ?? [] {
            guard let source = nodes[wire.sourceNode].audioOut[wire.sourceBlock] else { continue }
            for i in 0..<min(frames, source.count) {
                mix[i] += source[i] * wire.gain
            }
        }
        return mix
    }

    /// Whether any cable feeds this block — distinguishes "input wired"
    /// from "param at rest", where a module treats those differently.
    func hasWire(node: Int, block: Int) -> Bool {
        !(wiresInto[node << 8 | (block & 0xFF)] ?? []).isEmpty
    }

    static func pitchHz(_ cv: Float) -> Double {
        440 * pow(2, (Double(cv) * 127 - 69) / 12)
    }

    /// Filter-cutoff dial: the frequency marks printed in the module index
    /// (27.5 / 155.56 / 880 / 4978 / 23999 Hz) fit 27.5 × 2^(10·cv)
    /// exactly; negative cv extends down to 0.03 Hz. Distinct from
    /// pitchHz, which is the note-CV mapping for oscillators.
    static func filterHz(_ cv: Float) -> Double {
        min(max(27.5 * pow(2, Double(cv) * 10), 0.03), 23999)
    }

    // MARK: - Render

    /// Renders one control block. `input` carries L/R capture buffers for
    /// Audio Input modules (may be empty), `output` receives the L/R mix.
    func render(frames: Int,
                inputL: [Float] = [], inputR: [Float] = [],
                outputL: inout [Float], outputR: inout [Float]) {
        var ctx = RenderContext(
            frames: frames, inputL: inputL, inputR: inputR,
            incoming: midi?.drainIncoming() ?? [],
            outputL: [Float](repeating: 0, count: frames),
            outputR: [Float](repeating: 0, count: frames))

        for index in nodes.indices {
            let node = nodes[index]
            // Exactly one group owns each type ID; the rest decline.
            // Unimplemented modules are silent; cables read 0.
            _ = renderInterface(index, node, &ctx)
                || renderCVGenerators(index, node, &ctx)
                || renderCVUtilities(index, node, &ctx)
                || renderAudioA(index, node, &ctx)
                || renderAudioB(index, node, &ctx)
                || renderAnalysis(index, node, &ctx)
                || renderEffectA(index, node, &ctx)
                || renderEffectB(index, node, &ctx)
        }
        outputL = ctx.outputL
        outputR = ctx.outputR
    }
}
