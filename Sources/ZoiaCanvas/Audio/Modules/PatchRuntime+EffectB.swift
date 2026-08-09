import Foundation

/// Modulation, time-based effects and reverbs — IDs 25 (Plate Reverb),
/// 29 (Phaser), 41 (Tremolo), 43 (Delay w/Mod), 67 (Ghostverb),
/// 69 (Flanger), 70 (Chorus), 71 (Vibrato), 74 (Hall Reverb),
/// 75 (Ping Pong Delay), 79 (Reverb Lite), 80 (Room Reverb),
/// 106 (Reverse Delay), 107 (Univibe).
extension PatchRuntime {
    func renderEffectB(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        default: return false
        }
    }
}
