import Foundation

/// CV utility modules — IDs 10 (Sample and Hold), 17 (CV Invert),
/// 18 (Steps), 19 (Slew Limiter), 22 (Multiplier), 28 (Quantizer),
/// 31 (In Switch), 32 (Out Switch), 45 (Value), 46 (CV Delay),
/// 48 (CV Filter), 49 (Clock Divider), 50 (Comparator), 51 (CV Rectify),
/// 52 (Trigger), 77 (CV Flip Flop), 104 (CV Mixer), 105 (Logic Gate).
extension PatchRuntime {
    func renderCVUtilities(_ index: Int, _ node: Node, _ ctx: inout RenderContext) -> Bool {
        switch node.typeID {
        default: return false
        }
    }
}
