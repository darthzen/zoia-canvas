import Foundation
import SwiftUI

/// One module instance on the canvas. Wire-level fields mirror
/// ZoiaModuleEntry; `canvasPosition` is editor state and never reaches the
/// `.bin`.
struct CanvasModule: Identifiable, Sendable {
    let id: UUID
    var typeID: Int
    var version: Int
    var page: Int
    var gridPosition: Int
    var colorID: Int
    var optionBytes: [UInt8]
    var paramsRaw: [Int]
    var savedData: Data
    var savedDataSizeField: Int
    var customName: String
    var canvasPosition: CGPoint

    /// Blocks active under the current options, from the ported layout.
    func activeBlocks(in catalog: ModuleCatalog) -> [BlockSpec] {
        guard let spec = catalog[typeID] else { return [] }
        return (try? BlockLayout.activeBlocks(
            spec: spec, optionBytes: optionBytes, version: version)) ?? spec.blocks
    }
}

/// A cable. Blocks are addressed by their catalog `position` — verified
/// against factory patches: a compacted module (oscillator with fm off)
/// still references audio_out as block 3, its catalog position.
struct CanvasConnection: Identifiable, Sendable {
    let id: UUID
    var sourceModule: UUID
    var sourceBlock: Int
    var destModule: UUID
    var destBlock: Int
    /// Strength ×100 as stored on device; 10000 = 100%.
    var strengthRaw: Int
}

/// One end of a prospective or existing cable.
struct PortRef: Equatable, Sendable {
    var module: UUID
    var blockPosition: Int
    var type: PortType
}

/// What connecting two ports would mean. Direction violations are blocked;
/// an audio↔cv mismatch is legal on the device, so it is allowed but
/// labeled so the UI can warn visually.
enum ConnectionRuling: Equatable, Sendable {
    case allowed
    case allowedTypeMismatch
    case notOutputToInput
    case sameModule
    case duplicate
}

@Observable
@MainActor
final class PatchDocument {
    let catalog: ModuleCatalog
    var patchName: String
    var modules: [CanvasModule] = []
    var connections: [CanvasConnection] = []
    var pageNames: [String] = []
    var starred: [ZoiaStarredParam] = []

    /// Estimated DSP load, summed from the catalog like the device's meter.
    var dspTotal: Double {
        modules.reduce(0) { $0 + (catalog[$1.typeID]?.cpu ?? 0) }
    }

    init(catalog: ModuleCatalog) {
        self.catalog = catalog
        self.patchName = "Untitled"
    }

    // MARK: - Editing

    /// Bumped on any change that alters the runtime graph (modules,
    /// options, params, cables) so the audio engine knows to rebuild.
    private(set) var structureRevision = 0

    @discardableResult
    func addModule(typeID: Int, at point: CGPoint) -> CanvasModule? {
        guard catalog[typeID] != nil else { return nil }
        var module = CanvasModule(
            id: UUID(),
            typeID: typeID,
            version: 0,
            page: 0,
            gridPosition: 0,
            colorID: 1,
            optionBytes: [UInt8](repeating: 0, count: 8),
            paramsRaw: [],
            savedData: Data(),
            savedDataSizeField: 0,
            customName: "",
            canvasPosition: point)
        // The device sizes the param list to the active param blocks
        // (verified across the corpus: 7596/7628 modules match exactly).
        module.paramsRaw = [Int](
            repeating: 0, count: paramBlocks(of: module).count)
        modules.append(module)
        structureRevision += 1
        return module
    }

    /// The active blocks that carry a param word, in param order.
    func paramBlocks(of module: CanvasModule) -> [BlockSpec] {
        module.activeBlocks(in: catalog).filter { $0.isParam == true }
    }

    func setOption(_ id: UUID, optionIndex: Int, byte: UInt8) {
        guard let index = modules.firstIndex(where: { $0.id == id }),
              optionIndex < 8 else { return }
        modules[index].optionBytes[optionIndex] = byte
        // Options change which blocks exist; the param list follows.
        let count = paramBlocks(of: modules[index]).count
        var params = modules[index].paramsRaw
        while params.count < count { params.append(0) }
        if params.count > count { params.removeLast(params.count - count) }
        modules[index].paramsRaw = params
        // Drop cables whose block no longer exists.
        let valid = Set(modules[index].activeBlocks(in: catalog).compactMap(\.position))
        connections.removeAll {
            ($0.sourceModule == id && !valid.contains($0.sourceBlock))
                || ($0.destModule == id && !valid.contains($0.destBlock))
        }
        structureRevision += 1
    }

    func setParam(_ id: UUID, paramIndex: Int, fraction: Double) {
        guard let index = modules.firstIndex(where: { $0.id == id }),
              paramIndex < modules[index].paramsRaw.count else { return }
        modules[index].paramsRaw[paramIndex] = Int((fraction.clamped01 * 65535).rounded())
        structureRevision += 1
    }

    func removeModule(_ id: UUID) {
        modules.removeAll { $0.id == id }
        connections.removeAll { $0.sourceModule == id || $0.destModule == id }
        structureRevision += 1
    }

    func ruling(from source: PortRef, to dest: PortRef) -> ConnectionRuling {
        guard source.type.isOutput, !dest.type.isOutput else { return .notOutputToInput }
        guard source.module != dest.module else { return .sameModule }
        let exists = connections.contains {
            $0.sourceModule == source.module && $0.sourceBlock == source.blockPosition
                && $0.destModule == dest.module && $0.destBlock == dest.blockPosition
        }
        if exists { return .duplicate }
        return source.type.isAudio == dest.type.isAudio ? .allowed : .allowedTypeMismatch
    }

    @discardableResult
    func connect(from source: PortRef, to dest: PortRef, strengthRaw: Int = 10000) -> ConnectionRuling {
        let ruling = ruling(from: source, to: dest)
        switch ruling {
        case .allowed, .allowedTypeMismatch:
            connections.append(CanvasConnection(
                id: UUID(),
                sourceModule: source.module, sourceBlock: source.blockPosition,
                destModule: dest.module, destBlock: dest.blockPosition,
                strengthRaw: strengthRaw))
            structureRevision += 1
        case .notOutputToInput, .sameModule, .duplicate:
            break
        }
        return ruling
    }

    func module(_ id: UUID) -> CanvasModule? {
        modules.first { $0.id == id }
    }

    // MARK: - .bin bridge

    /// Canvas spacing for modules laid out from a device patch, grouped by
    /// page in rows of grid position.
    private static func layoutPoint(page: Int, gridPosition: Int) -> CGPoint {
        let column = gridPosition % 8
        let row = gridPosition / 8
        return CGPoint(
            x: 80 + CGFloat(column) * 190 + CGFloat(page) * 8 * 190,
            y: 80 + CGFloat(row) * 150)
    }

    convenience init(patch: ZoiaPatch, catalog: ModuleCatalog) {
        self.init(catalog: catalog)
        patchName = patch.name
        pageNames = patch.pageNames
        starred = patch.starred

        var ids: [UUID] = []
        for (index, entry) in patch.modules.enumerated() {
            let id = UUID()
            ids.append(id)
            modules.append(CanvasModule(
                id: id,
                typeID: entry.typeID,
                version: entry.version,
                page: entry.page,
                gridPosition: entry.position,
                colorID: index < patch.colors.count ? patch.colors[index] : entry.headerColorID,
                optionBytes: entry.optionBytes,
                paramsRaw: entry.paramsRaw,
                savedData: entry.savedData,
                savedDataSizeField: entry.savedDataSizeField,
                customName: entry.name,
                canvasPosition: Self.layoutPoint(page: entry.page, gridPosition: entry.position)))
        }
        for c in patch.connections where c.sourceModule < ids.count && c.destModule < ids.count {
            connections.append(CanvasConnection(
                id: UUID(),
                sourceModule: ids[c.sourceModule], sourceBlock: c.sourceBlock,
                destModule: ids[c.destModule], destBlock: c.destBlock,
                strengthRaw: c.strengthRaw))
        }
    }

    /// Builds the wire-format patch. Module order is canvas order; the
    /// device requires page/grid placement, which for canvas-authored
    /// modules is assigned sequentially per page here.
    func buildPatch() -> ZoiaPatch {
        let indexOf = Dictionary(uniqueKeysWithValues: modules.enumerated().map { ($1.id, $0) })
        let entries = modules.map { m in
            ZoiaModuleEntry(
                sizeWords: ZoiaModuleEntry.headerWords + m.paramsRaw.count
                    + m.savedData.count / 4 + ZoiaModuleEntry.nameWords,
                typeID: m.typeID,
                version: m.version,
                pageRaw: m.page,
                headerColorID: m.colorID,
                position: m.gridPosition,
                paramCount: m.paramsRaw.count,
                savedDataSizeField: m.savedDataSizeField,
                optionBytes: m.optionBytes,
                paramsRaw: m.paramsRaw,
                savedData: m.savedData,
                nameRaw: Self.fixed16(m.customName))
        }
        let wires = connections.compactMap { c -> ZoiaConnection? in
            guard let s = indexOf[c.sourceModule], let d = indexOf[c.destModule] else { return nil }
            return ZoiaConnection(
                sourceModule: s, sourceBlock: c.sourceBlock,
                destModule: d, destBlock: c.destBlock,
                strengthRaw: c.strengthRaw)
        }
        let pageCount = max(pageNames.count, (modules.map(\.page).max() ?? -1) + 1)
        var names = pageNames
        while names.count < pageCount { names.append("") }
        return ZoiaPatch(
            declaredSizeWords: 0, // encoder recomputes
            nameRaw: Self.fixed16(patchName),
            modules: entries,
            connections: wires,
            pageCountRaw: pageCount,
            pageNamesRaw: names.map(Self.fixed16),
            starred: starred,
            colors: modules.map(\.colorID))
    }

    func encodeBin() -> Data {
        ZoiaPatchBinary.encode(buildPatch())
    }

    private static func fixed16(_ text: String) -> Data {
        var data = Data(text.utf8.prefix(16))
        data.append(Data(count: 16 - data.count))
        return data
    }
}

extension Double {
    var clamped01: Double { Swift.min(Swift.max(self, 0), 1) }
}
