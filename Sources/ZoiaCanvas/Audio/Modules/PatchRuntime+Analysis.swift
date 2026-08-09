import Foundation

/// Analysis modules — IDs 12 (Env Follower), 36 (Onset Detector),
/// 58 (Pitch Detector).
extension PatchRuntime {
    func renderAnalysis(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        default: return false
        }
    }
}
