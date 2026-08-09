import Foundation

/// Decoding errors carry the word offset where parsing stopped so a bad
/// file can be diffed against the spec directly.
enum PatchDecodeError: Error, Equatable, CustomStringConvertible {
    case fileTooSmall(bytes: Int)
    case declaredSizeOutOfRange(words: Int, fileWords: Int)
    case truncated(context: String, wordOffset: Int)
    case badModuleSize(moduleIndex: Int, sizeWords: Int, paramCount: Int)
    case badCount(context: String, count: Int, wordOffset: Int)
    case trailingSizeMismatch(declaredWords: Int, parsedWords: Int)

    var description: String {
        switch self {
        case .fileTooSmall(let bytes):
            return "file is \(bytes) bytes; a patch needs at least 24"
        case .declaredSizeOutOfRange(let words, let fileWords):
            return "declared size \(words) words outside file of \(fileWords) words"
        case .truncated(let context, let wordOffset):
            return "\(context) runs past the declared size at word \(wordOffset)"
        case .badModuleSize(let index, let size, let params):
            return "module \(index): size \(size) words cannot hold \(params) params"
        case .badCount(let context, let count, let wordOffset):
            return "implausible \(context) count \(count) at word \(wordOffset)"
        case .trailingSizeMismatch(let declared, let parsed):
            return "parsed \(parsed) words but header declares \(declared)"
        }
    }
}

/// Decoder for the ZOIA `.bin` patch format, ported line-by-line from
/// zoia_lib's `patch_binary.py`. Layout: size word, 16-byte name, module
/// count, module entries, connections, pages, starred params, colors —
/// all little-endian 4-byte words, zero-padded to 32768 bytes.
enum ZoiaPatchBinary {
    static let fileSize = 32768
    static let maxPages = 64

    static func decode(_ data: Data) throws -> ZoiaPatch {
        guard data.count >= 24 else { throw PatchDecodeError.fileTooSmall(bytes: data.count) }
        var reader = WordReader(data: data)

        let declaredSizeWords = try reader.word(context: "size header")
        guard declaredSizeWords >= 6, declaredSizeWords <= data.count / 4 else {
            throw PatchDecodeError.declaredSizeOutOfRange(words: declaredSizeWords, fileWords: data.count / 4)
        }
        reader.limitWords = declaredSizeWords

        let nameRaw = try reader.bytes(16, context: "patch name")
        let moduleCount = try reader.word(context: "module count")
        guard moduleCount >= 0, moduleCount <= declaredSizeWords else {
            throw PatchDecodeError.badCount(context: "module", count: moduleCount, wordOffset: reader.offsetWords - 1)
        }

        var modules: [ZoiaModuleEntry] = []
        modules.reserveCapacity(moduleCount)
        for index in 0..<moduleCount {
            modules.append(try decodeModule(index: index, from: &reader))
        }

        let connectionCount = try reader.word(context: "connection count")
        guard connectionCount >= 0, connectionCount * 5 <= declaredSizeWords else {
            throw PatchDecodeError.badCount(context: "connection", count: connectionCount, wordOffset: reader.offsetWords - 1)
        }
        var connections: [ZoiaConnection] = []
        connections.reserveCapacity(connectionCount)
        for _ in 0..<connectionCount {
            connections.append(ZoiaConnection(
                sourceModule: try reader.word(context: "connection source module"),
                sourceBlock: try reader.word(context: "connection source block"),
                destModule: try reader.word(context: "connection dest module"),
                destBlock: try reader.word(context: "connection dest block"),
                strengthRaw: try reader.word(context: "connection strength")
            ))
        }

        let pageCountRaw = try reader.word(context: "page count")
        guard pageCountRaw >= 0, pageCountRaw * 4 <= declaredSizeWords else {
            throw PatchDecodeError.badCount(context: "page", count: pageCountRaw, wordOffset: reader.offsetWords - 1)
        }
        var pageNamesRaw: [Data] = []
        pageNamesRaw.reserveCapacity(pageCountRaw)
        for _ in 0..<pageCountRaw {
            pageNamesRaw.append(try reader.bytes(16, context: "page name"))
        }

        let starredCount = try reader.word(context: "starred count")
        guard starredCount >= 0, starredCount <= declaredSizeWords else {
            throw PatchDecodeError.badCount(context: "starred", count: starredCount, wordOffset: reader.offsetWords - 1)
        }
        var starred: [ZoiaStarredParam] = []
        starred.reserveCapacity(starredCount)
        for _ in 0..<starredCount {
            let word = try reader.word(context: "starred param")
            starred.append(ZoiaStarredParam(
                moduleIndex: Int(Int16(truncatingIfNeeded: word)),
                blockField: Int(Int16(truncatingIfNeeded: word >> 16))
            ))
        }

        // The color block is one word per module; files from firmware that
        // predates it end right here.
        var colors: [Int] = []
        if reader.offsetWords < declaredSizeWords {
            colors.reserveCapacity(moduleCount)
            for _ in 0..<moduleCount {
                colors.append(try reader.word(context: "module color"))
            }
        }
        guard reader.offsetWords == declaredSizeWords else {
            throw PatchDecodeError.trailingSizeMismatch(declaredWords: declaredSizeWords, parsedWords: reader.offsetWords)
        }

        return ZoiaPatch(
            declaredSizeWords: declaredSizeWords,
            nameRaw: nameRaw,
            modules: modules,
            connections: connections,
            pageCountRaw: pageCountRaw,
            pageNamesRaw: pageNamesRaw,
            starred: starred,
            colors: colors
        )
    }

    private static func decodeModule(index: Int, from reader: inout WordReader) throws -> ZoiaModuleEntry {
        let entryStart = reader.offsetWords
        let sizeWords = try reader.word(context: "module \(index) size")
        let minWords = ZoiaModuleEntry.headerWords + ZoiaModuleEntry.nameWords
        guard sizeWords >= minWords, entryStart + sizeWords <= reader.limitWords else {
            throw PatchDecodeError.badModuleSize(moduleIndex: index, sizeWords: sizeWords, paramCount: 0)
        }

        let typeID = try reader.word(context: "module \(index) type")
        let version = try reader.word(context: "module \(index) version")
        let pageRaw = try reader.word(context: "module \(index) page")
        let headerColorID = try reader.word(context: "module \(index) color")
        let position = try reader.word(context: "module \(index) position")
        let paramCount = try reader.word(context: "module \(index) param count")
        let savedDataSizeField = try reader.word(context: "module \(index) saved-data size")

        let savedDataWords = sizeWords - minWords - paramCount
        guard paramCount >= 0, savedDataWords >= 0 else {
            throw PatchDecodeError.badModuleSize(moduleIndex: index, sizeWords: sizeWords, paramCount: paramCount)
        }

        let optionBytes = [UInt8](try reader.bytes(8, context: "module \(index) options"))

        var paramsRaw: [Int] = []
        paramsRaw.reserveCapacity(paramCount)
        for _ in 0..<paramCount {
            paramsRaw.append(try reader.word(context: "module \(index) param"))
        }

        let savedData = try reader.bytes(savedDataWords * 4, context: "module \(index) saved data")
        let nameRaw = try reader.bytes(16, context: "module \(index) name")

        return ZoiaModuleEntry(
            sizeWords: sizeWords,
            typeID: typeID,
            version: version,
            pageRaw: pageRaw,
            headerColorID: headerColorID,
            position: position,
            paramCount: paramCount,
            savedDataSizeField: savedDataSizeField,
            optionBytes: optionBytes,
            paramsRaw: paramsRaw,
            savedData: savedData,
            nameRaw: nameRaw
        )
    }
}

/// Cursor over little-endian 4-byte words, bounded by the declared patch
/// size once it is known.
private struct WordReader {
    let data: Data
    var offsetWords = 0
    var limitWords: Int

    init(data: Data) {
        self.data = data
        self.limitWords = data.count / 4
    }

    mutating func word(context: String) throws -> Int {
        guard offsetWords < limitWords else {
            throw PatchDecodeError.truncated(context: context, wordOffset: offsetWords)
        }
        let start = data.startIndex + offsetWords * 4
        let raw = data[start..<start + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        offsetWords += 1
        return Int(Int32(littleEndian: raw))
    }

    /// Reads a whole number of words as raw bytes.
    mutating func bytes(_ count: Int, context: String) throws -> Data {
        precondition(count % 4 == 0)
        let words = count / 4
        guard offsetWords + words <= limitWords else {
            throw PatchDecodeError.truncated(context: context, wordOffset: offsetWords)
        }
        let start = data.startIndex + offsetWords * 4
        offsetWords += words
        return Data(data[start..<start + count])
    }
}
