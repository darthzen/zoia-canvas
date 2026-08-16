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

/// The name the device's patch menu shows lives in two places at once:
/// the 16-byte header field, and the SD-card filename, which repeats it
/// behind an `NNN_zoia_` slot prefix with every non-alphanumeric
/// character written as an underscore. All 128 factory patches in the
/// test corpus agree on that, character for character — including
/// `017_zoia_V_Sync.bin`, whose header name is "V-Sync". The filename is
/// therefore derived from the name, never the reverse: the header keeps
/// the punctuation the filename throws away.
enum ZoiaPatchNaming {
    /// The header field is 16 bytes, so that is the whole name budget.
    static let maxNameBytes = 16

    /// Holds a name to what the header can store, without splitting a
    /// character across the boundary.
    static func clamp(_ name: String) -> String {
        var result = ""
        for character in name {
            guard result.utf8.count + String(character).utf8.count <= maxNameBytes
            else { break }
            result.append(character)
        }
        return result
    }

    /// Where a patch lands on the card when the user has not said
    /// otherwise. Slot 0 is the one the device boots into, so a new
    /// patch takes the next one rather than displacing it.
    static let defaultSlot = 1

    /// "Grains de folie" → "001_zoia_Grains_de_folie.bin". The slot is a
    /// starting point; the save panel leaves the filename editable.
    static func fileName(for patchName: String, slot: Int = defaultSlot) -> String {
        // ASCII alphanumerics survive; the device writes everything else
        // — spaces, hyphens — as an underscore.
        let stem = String(clamp(patchName).map {
            $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_"
        })
        return String(format: "%03d_zoia_%@.bin", slot, stem)
    }

    /// A best guess at the name behind a filename, for the one case that
    /// needs it: a patch whose header name is blank. Lossy on purpose —
    /// the filename cannot say whether an underscore was a space or a
    /// hyphen — so it is never used to overwrite a name the header has.
    static func patchName(fromFileName fileName: String) -> String {
        var stem = (fileName as NSString).deletingPathExtension
        if let separator = stem.range(of: "_zoia_") {
            stem = String(stem[separator.upperBound...])
        }
        return clamp(stem.replacingOccurrences(of: "_", with: " "))
    }

    /// The slot a file already claims, so a rename keeps its place on
    /// the card. Nil when the filename does not follow the convention.
    static func slot(fromFileName fileName: String) -> Int? {
        let stem = (fileName as NSString).deletingPathExtension
        guard let separator = stem.range(of: "_zoia_") else { return nil }
        return Int(stem[stem.startIndex..<separator.lowerBound])
    }
}
