import Foundation

/// Audio routing, delay and sampling modules — IDs 13 (Delay Line),
/// 26 (Buffer Delay), 30 (Looper), 33 (Audio In Switch),
/// 34 (Audio Out Switch), 53 (Stereo Spread), 57 (Audio Panner),
/// 59 (Pitch Shifter), 64 (Audio Balance), 76 (Audio Mixer),
/// 78 (Diffuser), 83 (Granular), 102 (Sampler).
extension PatchRuntime {
    func renderAudioB(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        default: return false
        }
    }
}
