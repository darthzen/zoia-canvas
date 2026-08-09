import Foundation

/// A decoded ZOIA patch. Every field the binary stores is kept raw so a
/// re-encode can reproduce the original bytes exactly; human-readable
/// values are derived, never stored back.
struct ZoiaPatch: Sendable {
    /// Payload size in 4-byte words, counting the size word itself.
    var declaredSizeWords: Int
    /// Patch name, 16 bytes, ASCII, null-padded.
    var nameRaw: Data
    var modules: [ZoiaModuleEntry]
    var connections: [ZoiaConnection]
    /// Page count as stored in the file — may exceed the number of pages
    /// actually in use, and is preserved for byte-exact re-encoding.
    var pageCountRaw: Int
    /// One 16-byte blob per stored page name.
    var pageNamesRaw: [Data]
    var starred: [ZoiaStarredParam]
    /// Trailing per-module color codes (1–15), same order as `modules`.
    /// Empty when the file predates the color block.
    var colors: [Int]

    var name: String { ZoiaText.decode(nameRaw) }
    var pageNames: [String] { pageNamesRaw.map(ZoiaText.decode) }
}

/// One module entry as laid out in the binary.
struct ZoiaModuleEntry: Sendable {
    /// Entry size in words: 10 header + paramCount + saved-data words + 4 name.
    var sizeWords: Int
    /// Module type ID — the catalog `id`.
    var typeID: Int
    var version: Int
    /// Page number as stored; may be out of range in the wild.
    var pageRaw: Int
    /// Old-style color stored in the module header.
    var headerColorID: Int
    /// Grid position of the first block, 0–39 within the page.
    var position: Int
    var paramCount: Int
    /// The header's saved-data size field, kept verbatim (the structural
    /// saved-data length is `savedData.count`).
    var savedDataSizeField: Int
    /// Eight option bytes, one per catalog option in catalog order; each is
    /// an index into that option's values array. Unused slots are zero.
    var optionBytes: [UInt8]
    /// One word per param; the ZOIA writes the fraction × 65535 in the low
    /// 16 bits. Full words preserved.
    var paramsRaw: [Int]
    /// Module-specific state (e.g. sequencer contents), passed through raw.
    var savedData: Data
    /// Module name, 16 bytes, null-padded.
    var nameRaw: Data

    static let headerWords = 10
    static let nameWords = 4

    var name: String { ZoiaText.decode(nameRaw) }
    var page: Int { (0..<ZoiaPatchBinary.maxPages).contains(pageRaw) ? pageRaw : 0 }

    /// Param value as the 0…1 fraction the UI shows.
    func paramFraction(_ index: Int) -> Double {
        Double(paramsRaw[index]) / 65535
    }
}

/// One patch cable. Block indices are on-device block numbers within the
/// source and destination modules.
struct ZoiaConnection: Sendable {
    var sourceModule: Int
    var sourceBlock: Int
    var destModule: Int
    var destBlock: Int
    /// Strength × 100 as stored (10000 = 100%).
    var strengthRaw: Int

    var strengthPercent: Double { Double(strengthRaw) / 100 }
}

/// A starred parameter: one word holding two little-endian int16s.
struct ZoiaStarredParam: Sendable {
    /// Low int16: module index.
    var moduleIndex: Int
    /// High int16: block index, or 128×(cc+1)+block when a MIDI CC is
    /// assigned.
    var blockField: Int

    var block: Int { blockField % 128 }
    var midiCC: Int? { blockField >= 128 ? (blockField - block) / 128 - 1 : nil }
}

/// Shared 16-byte fixed-field text handling.
enum ZoiaText {
    /// Text is ASCII, left-aligned, null-padded; stop at the first NUL.
    static func decode(_ raw: Data) -> String {
        let prefix = raw.prefix { $0 != 0 }
        return String(decoding: prefix, as: UTF8.self)
    }
}
