import Foundation

/// Port type of a module block — determines what a cable may connect.
enum PortType: String, Decodable, Sendable {
    case audioIn = "audio_in"
    case audioOut = "audio_out"
    case cvIn = "cv_in"
    case cvOut = "cv_out"

    var isOutput: Bool { self == .audioOut || self == .cvOut }
    var isAudio: Bool { self == .audioIn || self == .audioOut }
}

/// One grid block of a module, in on-device order.
struct BlockSpec: Decodable, Sendable {
    let key: String
    let position: Int?
    let isDefault: Bool?
    let isParam: Bool?
    let type: PortType
}

/// An option value as stored in the catalog — the *index* in the values
/// array is the byte written into the patch binary.
enum OptionValue: Decodable, Sendable, Equatable, CustomStringConvertible {
    case text(String)
    case number(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .text(s)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }

    var description: String {
        switch self {
        case .text(let s): return s
        case .number(let n):
            return n == n.rounded() ? String(Int(n)) : String(n)
        }
    }
}

/// One module option; byte order in the binary follows the catalog's
/// option array order.
struct OptionSpec: Decodable, Sendable {
    let key: String
    let values: [OptionValue]
}

/// Human documentation from the Empress firmware-5 module index.
struct ModuleDoc: Decodable, Sendable {
    struct DocBlock: Decodable, Sendable {
        let num: String
        let name: String
        let knob: String
        let function: String
        let connectsTo: String
    }

    let description: String
    let avgDSP: String
    let blocks: [DocBlock]
    let options: [String: String]
    let notes: [String]
}

/// Everything known about one ZOIA module type.
struct ModuleSpec: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let category: String
    let cpu: Double
    let paramCount: Int
    let minBlocks: Int
    let maxBlocks: Int
    let defaultBlocks: Int
    let blocks: [BlockSpec]
    let options: [OptionSpec]
    let doc: ModuleDoc?
}

/// The full module catalog, bundled as ModuleCatalog.json.
struct ModuleCatalog: Sendable {
    let formatVersion: Int
    let modules: [ModuleSpec]
    private let byID: [Int: Int]

    subscript(id: Int) -> ModuleSpec? {
        byID[id].map { modules[$0] }
    }

    static func loadBundled() throws -> ModuleCatalog {
        guard let url = Bundle(for: BundleLocator.self)
            .url(forResource: "ModuleCatalog", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ModuleCatalog(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        let raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        formatVersion = raw.formatVersion
        modules = raw.modules
        byID = Dictionary(uniqueKeysWithValues: raw.modules.enumerated().map { ($1.id, $0) })
    }

    private struct RawCatalog: Decodable {
        let formatVersion: Int
        let modules: [ModuleSpec]
    }
}

private final class BundleLocator {}
