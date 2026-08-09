import Foundation

/// Interface modules: audio/CV/MIDI to and from the outside world.
/// Owned by the interface group — IDs 1, 2, 15, 16, 20, 21, 35, 44,
/// 54–56, 60–62, 81, 82, 84, 86–101, 103.
extension PatchRuntime {
    func renderInterface(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        case 1: renderAudioInput(node, ctx)
        case 2: renderAudioOutput(index, node, &ctx)
        case 20: renderMidiNotesIn(node, events: ctx.incoming)
        case 60: renderMidiNoteOut(index, node)
        default: return false
        }
        return true
    }

    private func renderAudioInput(_ node: Node, _ ctx: RenderContext) {
        let silence = [Float](repeating: 0, count: ctx.frames)
        switch node.optionText(0) {
        case "left":
            node.audioOut[0] = ctx.inputL.count == ctx.frames ? ctx.inputL : silence
        case "right":
            node.audioOut[1] = ctx.inputR.count == ctx.frames ? ctx.inputR : silence
        default:
            node.audioOut[0] = ctx.inputL.count == ctx.frames ? ctx.inputL : silence
            node.audioOut[1] = ctx.inputR.count == ctx.frames ? ctx.inputR : silence
        }
    }

    private func renderAudioOutput(_ index: Int, _ node: Node, _ ctx: inout RenderContext) {
        // gain_control option adds a gain cv block at position 2.
        let gain: Float = node.optionText(0) == "on" ? cvIn(node: index, block: 2) : 1
        let left = audioIn(node: index, block: 0, frames: ctx.frames)
        let right = audioIn(node: index, block: 1, frames: ctx.frames)
        switch node.optionText(1) {
        case "left":
            for i in 0..<ctx.frames { ctx.outputL[i] += left[i] * gain }
        case "right":
            for i in 0..<ctx.frames { ctx.outputR[i] += right[i] * gain }
        default:
            for i in 0..<ctx.frames {
                ctx.outputL[i] += left[i] * gain
                ctx.outputR[i] += right[i] * gain
            }
        }
    }

    private func renderMidiNotesIn(_ node: Node, events: [MidiEvent]) {
        let channel = node.optionInt(0)
        for event in events where event.channel == channel {
            switch event.kind {
            case .noteOn(let velocity) where velocity > 0:
                node.heldNotes[event.note] = velocity
                node.activeNote = event.note
            default:
                node.heldNotes[event.note] = nil
                if event.note == node.activeNote {
                    node.activeNote = node.heldNotes.keys.max() ?? -1
                }
            }
        }
        // Voice 1 blocks: note_out at position 0, gate_out at 1.
        if node.activeNote >= 0 {
            node.cvOut[0] = Float(node.activeNote) / 127
            node.cvOut[1] = 1
        } else {
            node.cvOut[1] = 0
        }
    }

    private func renderMidiNoteOut(_ index: Int, _ node: Node) {
        let channel = node.optionInt(0)
        let gate = cvIn(node: index, block: 1)
        if gate >= 0.5, node.lastGate < 0.5 {
            let note = Int((cvIn(node: index, block: 0) * 127).rounded())
            let velocity = node.optionText(1) == "on"
                ? max(Int((cvIn(node: index, block: 2) * 127).rounded()), 1)
                : 100
            if node.activeNote >= 0 { midi?.noteOff(channel: channel, note: node.activeNote) }
            midi?.noteOn(channel: channel, note: note, velocity: velocity)
            node.activeNote = note
        } else if gate < 0.5, node.lastGate >= 0.5, node.activeNote >= 0 {
            midi?.noteOff(channel: channel, note: node.activeNote)
            node.activeNote = -1
        }
        node.lastGate = gate
    }
}
