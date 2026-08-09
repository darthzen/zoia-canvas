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

    func removeConnection(_ id: UUID) {
        guard connections.contains(where: { $0.id == id }) else { return }
        connections.removeAll { $0.id == id }
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

    // MARK: - Pages
    //
    // Pages are device-UI structure (8×5 grid views); the canvas shows
    // them as horizontal bands one `pageStride` apart. None of these
    // operations touch the runtime graph, so none bump structureRevision.

    /// Canvas x-distance between consecutive page bands.
    static let pageStride: CGFloat = 8 * 190

    /// Pages that exist: named ones plus any page a module sits on;
    /// never less than one.
    var pageCount: Int {
        max(pageNames.count, (modules.map(\.page).max() ?? -1) + 1, 1)
    }

    func pageName(_ index: Int) -> String {
        index < pageNames.count ? pageNames[index] : ""
    }

    func modules(onPage index: Int) -> [CanvasModule] {
        modules.filter { $0.page == index }
    }

    func renamePage(_ index: Int, to name: String) {
        guard index >= 0, index < pageCount else { return }
        while pageNames.count <= index { pageNames.append("") }
        // The wire format stores 16 ASCII bytes.
        pageNames[index] = String(name.unicodeScalars.filter(\.isASCII).prefix(16))
    }

    @discardableResult
    func addPage() -> Int? {
        let index = pageCount
        guard index < ZoiaPatchBinary.maxPages else { return nil }
        while pageNames.count <= index { pageNames.append("") }
        return index
    }

    /// Removes an empty page; later pages shift down and their modules'
    /// canvas bands follow. Occupied pages and the last page stay.
    @discardableResult
    func removePage(_ index: Int) -> Bool {
        guard index >= 0, index < pageCount, pageCount > 1,
              modules(onPage: index).isEmpty else { return false }
        if index < pageNames.count { pageNames.remove(at: index) }
        for i in modules.indices where modules[i].page > index {
            modules[i].page -= 1
            modules[i].canvasPosition.x -= Self.pageStride
        }
        return true
    }

    /// Reassigns a module's page, shifting its canvas position into the
    /// destination band.
    func moveModule(_ id: UUID, toPage page: Int) {
        guard let index = modules.firstIndex(where: { $0.id == id }),
              page >= 0, page < ZoiaPatchBinary.maxPages,
              page != modules[index].page else { return }
        let delta = page - modules[index].page
        modules[index].page = page
        modules[index].canvasPosition.x += CGFloat(delta) * Self.pageStride
    }

    // MARK: - .bin bridge

    /// Layered, circuit-style layout for modules imported from a device
    /// patch. Each page ranks its wired modules by signal depth (longest
    /// path from the page's sources, cycles broken at the lowest grid
    /// position), so cables flow left to right; a barycenter sweep
    /// orders each rank to reduce crossings. Chains deeper than the page
    /// band is wide wrap onto a fresh tier below, and modules with no
    /// cables on their page flow-pack into a final tier — both keep the
    /// footprint compact instead of one long ribbon or one tall column.
    private func packImportedLayout() {
        let hGap: CGFloat = 60   // cable room between rank columns
        let vGap: CGFloat = 24
        let tierGap: CGFloat = 60
        let margin: CGFloat = 80
        let pitch = NodeMetrics.width + hGap
        let ranksPerTier = max(1, Int((Self.pageStride - margin * 2 + hGap) / pitch))
        // Off-page connector cards render beside their module — leftward
        // of inputs fed from another page, rightward of outputs feeding
        // one. Ranks containing such modules reserve a corridor on that
        // side so no neighbouring rank lands under the cards.
        let cardClearance = CableLayer.stubLength + CableLayer.cardSize.width + 10
        let indexOf = Dictionary(uniqueKeysWithValues: modules.enumerated().map { ($1.id, $0) })

        var offPageOut = Set<Int>()
        var offPageIn = Set<Int>()
        for c in connections {
            guard let s = indexOf[c.sourceModule], let d = indexOf[c.destModule],
                  modules[s].page != modules[d].page else { continue }
            offPageOut.insert(s)
            offPageIn.insert(d)
        }

        func height(_ i: Int) -> CGFloat {
            NodeMetrics.height(blockCount: modules[i].activeBlocks(in: catalog).count)
        }

        for page in 0..<pageCount {
            let pageIndices = modules.indices
                .filter { modules[$0].page == page }
                .sorted { modules[$0].gridPosition < modules[$1].gridPosition }
            guard !pageIndices.isEmpty else { continue }
            let onPage = Set(pageIndices)

            var preds: [Int: Set<Int>] = [:]
            var succs: [Int: Set<Int>] = [:]
            for c in connections {
                guard let s = indexOf[c.sourceModule], let d = indexOf[c.destModule],
                      s != d, onPage.contains(s), onPage.contains(d) else { continue }
                preds[d, default: []].insert(s)
                succs[s, default: []].insert(d)
            }
            let wired = pageIndices.filter { preds[$0] != nil || succs[$0] != nil }
            let isolated = pageIndices.filter { preds[$0] == nil && succs[$0] == nil }

            // Rank by longest path from the sources.
            var rank: [Int: Int] = [:]
            var remaining = Set(wired)
            while !remaining.isEmpty {
                var ready = wired.filter { n in
                    remaining.contains(n)
                        && (preds[n] ?? []).allSatisfy { !remaining.contains($0) }
                }
                if ready.isEmpty {   // cycle: break at the lowest grid position
                    ready = [wired.first { remaining.contains($0) }!]
                }
                for n in ready {
                    rank[n] = ((preds[n] ?? []).compactMap { rank[$0] }.max() ?? -1) + 1
                    remaining.remove(n)
                }
            }
            let rankCount = (rank.values.max() ?? -1) + 1
            var orders: [[Int]] = (0..<max(rankCount, 0)).map { r in
                wired.filter { rank[$0] == r }
            }

            // Barycenter sweeps: order each rank by the mean position of
            // its neighbors in the adjacent ranks.
            var pos: [Int: Double] = [:]
            func reindex() {
                for order in orders {
                    for (i, n) in order.enumerated() { pos[n] = Double(i) }
                }
            }
            func barycenter(_ n: Int, _ neighbors: [Int: Set<Int>]) -> Double {
                let anchors = (neighbors[n] ?? []).compactMap { pos[$0] }
                return anchors.isEmpty ? pos[n] ?? 0
                    : anchors.reduce(0, +) / Double(anchors.count)
            }
            reindex()
            for _ in 0..<2 where rankCount > 1 {
                for r in 1..<rankCount {
                    let keys = Dictionary(uniqueKeysWithValues:
                        orders[r].map { ($0, barycenter($0, preds)) })
                    orders[r].sort { keys[$0]! < keys[$1]! }
                    reindex()
                }
                for r in stride(from: rankCount - 2, through: 0, by: -1) {
                    let keys = Dictionary(uniqueKeysWithValues:
                        orders[r].map { ($0, barycenter($0, succs)) })
                    orders[r].sort { keys[$0]! < keys[$1]! }
                    reindex()
                }
            }

            // Place: ranks are columns with card corridors reserved
            // where a rank talks to other pages, wrapping to a new tier
            // when the page band runs out of width.
            let bandStart = margin + CGFloat(page) * Self.pageStride
            let bandEnd = CGFloat(page) * Self.pageStride + Self.pageStride - margin
            var tierY = margin
            var rankIndex = 0
            while rankIndex < rankCount {
                var x = bandStart
                var tierHeight: CGFloat = 0
                var placedInTier = 0
                while rankIndex < rankCount {
                    let rank = orders[rankIndex]
                    let needsBefore = rank.contains { offPageIn.contains($0) }
                    let needsAfter = rank.contains { offPageOut.contains($0) }
                    let startX = x + (needsBefore ? cardClearance : 0)
                    let endX = startX + NodeMetrics.width + (needsAfter ? cardClearance : 0)
                    if placedInTier > 0, endX > bandEnd { break }
                    var y = tierY
                    for n in rank {
                        modules[n].canvasPosition = CGPoint(x: startX, y: y)
                        y += height(n) + vGap
                    }
                    tierHeight = max(tierHeight, y - vGap - tierY)
                    x = startX + pitch + (needsAfter ? cardClearance : 0)
                    placedInTier += 1
                    rankIndex += 1
                }
                tierY += tierHeight + tierGap
            }

            // Unwired modules (UI buttons, pixels, …) flow-pack below the
            // graph so they never tangle with the cabling.
            var column = 0
            var rowY = tierY
            var rowMaxHeight: CGFloat = 0
            for n in isolated {
                if column == ranksPerTier {
                    column = 0
                    rowY += rowMaxHeight + vGap
                    rowMaxHeight = 0
                }
                modules[n].canvasPosition = CGPoint(
                    x: margin + CGFloat(page) * Self.pageStride + CGFloat(column) * pitch,
                    y: rowY)
                rowMaxHeight = max(rowMaxHeight, height(n))
                column += 1
            }
        }
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
                canvasPosition: .zero))
        }
        for c in patch.connections where c.sourceModule < ids.count && c.destModule < ids.count {
            connections.append(CanvasConnection(
                id: UUID(),
                sourceModule: ids[c.sourceModule], sourceBlock: c.sourceBlock,
                destModule: ids[c.destModule], destBlock: c.destBlock,
                strengthRaw: c.strengthRaw))
        }
        packImportedLayout()
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
