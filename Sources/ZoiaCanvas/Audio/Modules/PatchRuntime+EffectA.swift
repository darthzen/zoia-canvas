import Foundation

/// Drive, dynamics and EQ effects — IDs 11 (OD & Distortion),
/// 23 (Compressor), 40 (Gate), 42 (Tone Control), 66 (Fuzz),
/// 68 (Cabinet Sim), 72 (Env Filter), 73 (Ring Modulator).
extension PatchRuntime {
    func renderEffectA(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        default: return false
        }
    }
}
