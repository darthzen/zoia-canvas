import Foundation

enum BlockLayoutError: Error, CustomStringConvertible {
    case optionByteOutOfRange(module: String, option: String, byte: Int, valueCount: Int)
    case blockIndexOutOfRange(module: String, index: Int, blockCount: Int)

    var description: String {
        switch self {
        case .optionByteOutOfRange(let module, let option, let byte, let count):
            return "\(module).\(option): option byte \(byte) outside \(count) values"
        case .blockIndexOutOfRange(let module, let index, let count):
            return "\(module): block index \(index) outside \(count) blocks"
        }
    }
}

/// Which of a module's catalog blocks are active for a given option
/// selection — ported case-by-case from zoia_lib `patch_binary.py`
/// `_calc_blocks`. Unlike upstream, no min/max block-count error is
/// raised: device-written patches are truth, and three factory Euroburo
/// patches fail upstream's minimum check.
enum BlockLayout {
    /// Resolves the module's option bytes to selected values, in catalog
    /// option order (the byte order in the binary).
    static func selectedOptions(spec: ModuleSpec, optionBytes: [UInt8]) throws -> [OptionValue] {
        var selected: [OptionValue] = []
        var byteIndex = 0
        for option in spec.options where !option.key.isEmpty {
            let byte = byteIndex < optionBytes.count ? Int(optionBytes[byteIndex]) : 0
            guard byte < option.values.count else {
                throw BlockLayoutError.optionByteOutOfRange(
                    module: spec.name, option: option.key, byte: byte,
                    valueCount: option.values.count)
            }
            selected.append(option.values[byte])
            byteIndex += 1
        }
        return selected
    }

    static func activeBlocks(spec: ModuleSpec, optionBytes: [UInt8], version: Int) throws -> [BlockSpec] {
        let opt = try selectedOptions(spec: spec, optionBytes: optionBytes)
        return try activeBlocks(spec: spec, options: opt, version: version)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func activeBlocks(spec: ModuleSpec, options opt: [OptionValue], version: Int) throws -> [BlockSpec] {
        let d = spec.blocks
        var blocks: [BlockSpec] = []

        // Selected option value as text ("" when absent) or int (0 when
        // absent or non-numeric) — mirrors Python string/int comparisons.
        func s(_ i: Int) -> String {
            guard i < opt.count, case .text(let t) = opt[i] else { return "" }
            return t
        }
        func n(_ i: Int) -> Int {
            guard i < opt.count, case .number(let v) = opt[i] else { return 0 }
            return Int(v)
        }
        func add(_ index: Int) throws {
            guard index >= 0, index < d.count else {
                throw BlockLayoutError.blockIndexOutOfRange(
                    module: spec.name, index: index, blockCount: d.count)
            }
            blocks.append(d[index])
        }
        func addAll(_ indices: [Int]) throws { for i in indices { try add(i) } }
        func count(_ n: Int, _ body: (Int) throws -> Void) rethrows {
            var i = 1
            while i <= n { try body(i); i += 1 }
        }

        switch spec.id {
        case 0: // sv_filter
            try addAll([0, 1, 2])
            for (optIndex, blockIndex) in zip(opt.indices, 3..<6) where s(optIndex) == "on" {
                try add(blockIndex)
            }
        case 1: // audio_input
            switch s(0) {
            case "left": try add(0)
            case "right": try add(1)
            default: try addAll([0, 1])
            }
        case 2: // audio_output
            switch s(1) {
            case "left": try add(0)
            case "right": try add(1)
            default: try addAll([0, 1])
            }
            if s(0) == "on" { try add(2) }
        case 4: // sequencer
            try count(n(0)) { try add($0 - 1) }
            try add(32)
            if s(2) == "on" { try add(33) }
            if s(4) != "off" { try addAll([34, 35]) }
            try count(n(1)) { try add($0 + 35) }
        case 5: // lfo
            try add(s(3) != "tap" ? 0 : 1)
            if s(1) == "on" { try add(2) }
            if s(4) == "on" { try add(3) }
            if s(5) == "on" { try add(4) }
            try add(5)
        case 6: // adsr
            try add(0)
            if s(0) == "on" { try add(1) }
            if s(1) == "on" { try add(2) }
            try add(3)
            if s(2) == "on" { try add(4) }
            try add(5)
            if s(3) == "on" { try add(6) }
            if s(5) == "on" { try add(7) }
            if s(3) == "on" { try add(8) }
            try add(9)
        case 7: // vca
            try add(0)
            if s(0) == "stereo" { try add(1) }
            try addAll([2, 3])
            if s(0) == "stereo" { try add(4) }
        case 12: // keyboard
            try add(0)
            if s(0) == "on" { try addAll([1, 2]) }
            try add(3)
        case 13: // cv_invert
            try add(0)
            if s(1) == "yes" { try addAll([2, 3]) } else { try add(1) }
            try add(4)
        case 14: // oscillator
            try add(0)
            if s(1) == "on" { try add(1) }
            if s(2) == "on" { try add(2) }
            try add(3)
        case 16: // multiplier
            try count(n(0)) { try add($0 - 1) }
            try addAll([40, 41, 42])
        case 19: // delay_line
            try add(0)
            if s(0) == "linked" { try add(1) } else { try addAll([2, 3]) }
            try add(4)
        case 20: // sampler? (per upstream)
            try count(n(1)) { i in
                try add(4 * (i - 1))
                try add(4 * (i - 1) + 1)
                if s(4) == "on" { try add(4 * (i - 1) + 2) }
                if s(7) == "on" { try add(4 * (i - 1) + 3) }
            }
        case 22: // cv_mixer
            try add(0)
            var i = 2
            while i <= n(0) { try add(i - 1); i += 1 }
            try add(8)
        case 23: // plate_reverb-ish (per upstream)
            try add(0)
            if s(3) == "stereo" { try add(1) }
            try add(2)
            if s(0) == "on" { try add(3) }
            if s(1) == "on" { try add(4) }
            if s(2) == "on" { try add(5) }
            if s(4) == "external" { try add(6) }
            try add(7)
            if s(3) == "stereo" { try add(8) }
        case 24: // eq filter
            try add(0)
            if ["bell", "hi_shelf", "low_shelf"].contains(s(0)) { try add(1) }
            try addAll([2, 3, 4])
        case 28: // value
            try add(0)
            if s(0) == "yes" { try addAll([1, 2]) }
            try add(3)
        case 29:
            try add(0)
            if s(0) == "2in->2out" { try add(1) }
            switch s(1) {
            case "rate": try add(2)
            case "tap_tempo": try add(3)
            default: try add(4)
            }
            try addAll([5, 6, 7, 8])
            if s(0) != "1in->1out" { try add(9) }
        case 30:
            try addAll([0, 1, 2])
            if s(7) == "yes" { try add(3) }
            try add(4)
            if s(1) == "on" { try addAll([5, 6]) }
            if s(5) == "yes" { try add(7) }
            if s(6) == "yes" { try add(8) }
            try add(9)
        case 31, 33: // audio mixers
            try count(n(0)) { try add($0 - 1) }
            try addAll([16, 17])
        case 32, 34:
            try addAll([0, 1])
            try count(n(0)) { try add($0 + 1) }
        case 36:
            try add(0)
            if s(0) == "on" { try add(1) }
            try add(2)
        case 37:
            try addAll([0, 1, 2])
            if s(0) == "on" { try add(3) }
            try add(4)
        case 39:
            if s(1) == "on" { try add(0) }
            try add(1)
        case 40:
            try add(0)
            if s(2) == "stereo" { try add(1) }
            try add(2)
            if s(0) == "on" { try add(3) }
            if s(1) == "on" { try add(4) }
            if s(3) == "external" { try add(5) }
            try add(6)
            if s(2) == "stereo" { try add(7) }
        case 41:
            try add(0)
            if s(0) == "2in->2out" { try add(1) }
            switch s(1) {
            case "rate": try add(2)
            case "tap_tempo": try add(3)
            default: try add(4)
            }
            try addAll([5, 6])
            if s(0) != "1in->1out" { try add(7) }
        case 42:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            try addAll([2, 3, 4])
            if n(1) == 2 { try addAll([5, 6]) }
            try addAll([7, 8])
            if s(0) == "stereo" { try add(9) }
        case 43:
            try add(0)
            if s(0) == "2in->2out" { try add(1) }
            try add(s(1) == "rate" ? 2 : 3)
            try addAll([4, 5, 6, 7, 8])
            if s(0) != "1in->1out" { try add(9) }
        case 47:
            try addAll([0, 1, 2, 3])
            if s(1) == "on" { try addAll([4, 5]) }
            try addAll([6, 7])
        case 48:
            try add(0)
            if s(0) == "linked" { try add(1) } else { try addAll([2, 3]) }
            try add(4)
        case 49:
            try addAll(version >= 1 ? [0, 1, 3, 4, 5] : [0, 1, 2, 5])
        case 53:
            try addAll(s(0) == "haas" ? [0, 3, 4, 5] : [0, 1, 2, 4, 5])
        case 56:
            try add(0)
            if s(0) == "enabled" { try add(1) }
        case 57:
            try add(0)
            if s(0) == "2in->2out" { try add(1) }
            try addAll([2, 3, 4])
        case 60:
            try addAll([0, 1])
            if s(1) == "on" { try add(2) }
        case 64:
            if s(0) == "mono" { try addAll([0, 2, 4, 5]) } else { blocks = d }
        case 67:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            try addAll([2, 3, 4, 5, 6])
            if s(0) != "1in->1out" { try add(7) }
        case 68:
            if s(0) == "mono" { try addAll([0, 2]) } else { blocks = d }
        case 69:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            switch s(1) {
            case "rate": try add(2)
            case "tap_tempo": try add(3)
            default: try add(4)
            }
            try addAll([5, 6, 7, 8, 9])
            if s(0) != "1in->1out" { try add(10) }
        case 70:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            switch s(1) {
            case "rate": try add(2)
            case "tap_tempo": try add(3)
            default: try add(4)
            }
            try addAll([5, 6, 7, 8])
            if s(0) != "1in->1out" { try add(9) }
        case 71:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            switch s(1) {
            case "rate": try add(2)
            case "tap_tempo": try add(3)
            default: try add(4)
            }
            try addAll([5, 6])
            if s(0) != "1in->1out" { try add(7) }
        case 72:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            try addAll([2, 3, 4, 5, 6])
            if s(0) != "1in->1out" { try add(7) }
        case 73:
            try add(0)
            try add(s(1) == "off" ? 1 : 2)
            if s(2) == "on" { try add(3) }
            try addAll([4, 5])
        case 75:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            try add(s(1) == "rate" ? 2 : 3)
            try addAll([4, 5, 6, 7, 8, 9])
        case 76: // granular
            try count(n(0)) { i in
                try add(2 * (i - 1))
                if s(1) == "stereo" { try add(2 * (i - 1) + 1) }
            }
            try count(n(0)) { try add($0 + 15) }
            if s(2) == "on" {
                try count(n(0)) { try add($0 + 23) }
            }
            try add(32)
            if s(1) == "stereo" { try add(33) }
        case 79:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            try addAll([2, 3, 4])
            if s(0) != "1in->1out" { try add(5) }
        case 81:
            try add(s(0) == "cv" ? 0 : 1)
        case 82:
            try add(0)
            if s(0) == "enabled" { try add(1) }
            if s(1) == "enabled" { try add(2) }
            if s(2) == "enabled" { try add(3) }
        case 83:
            // Upstream compares the option NAME, not its value
            // (`opt[1][0] == "mono"`), so the mono branch never fires and
            // every block stays active. Preserved bug-for-bug for oracle
            // parity; revisit against a real device patch.
            blocks = d
        case 84:
            try add(0)
            if s(1) == "enabled" { try add(1) }
            if s(2) == "enabled" { try add(2) }
            if s(3) == "enabled" { try addAll([3, 4]) }
        case 85:
            try add(0)
            if s(0) == "on" { try addAll([1, 2]) }
            try add(3)
        case 102: // looper
            if s(0) != "disabled" { try addAll([0, 1, 2]) }
            try addAll([3, 4])
            if s(2) == "on" { try add(5) }
            try addAll([6, 7])
            if s(3) == "on" { try addAll([8, 9]) }
            try addAll([10, 11])
        case 103:
            switch s(0) {
            case "bypass": try add(0)
            case "stomp aux": try add(1)
            default: try add(2)
            }
        case 104:
            try count(n(0)) { try add($0 - 1) }
            try count(n(0)) { try add($0 + 7) }
            try add(16)
        case 105: // logic gate
            try add(0)
            if s(0) != "NOT" {
                var i = 2
                while i <= n(1) { try add(i - 1); i += 1 }
            }
            if s(2) == "on" { try add(38) }
            try add(39)
        case 106:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            if s(1) == "rate" { try add(2) } else { try addAll([3, 4]) }
            try addAll([5, 6, 7, 8])
            if s(0) == "stereo" { try add(9) }
        case 107:
            try add(0)
            if s(0) == "stereo" { try add(1) }
            switch s(1) {
            case "rate": try add(2)
            case "tap_tempo": try add(3)
            default: try add(4)
            }
            try addAll([5, 6, 7, 8])
            if s(0) != "1in->1out" { try add(9) }
        default:
            blocks = d
        }

        return blocks
    }
}
