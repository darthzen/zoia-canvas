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
    /// A pinned module keeps its `gridPosition` through every reflow —
    /// set by manual placement, and on import so authored layouts hold.
    var gridPinned = false
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
        reflowGrid()
        resolvePageBoundaries()
        return modules.last
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
        reflowGrid()   // options change the block count, so the span
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
        reflowGrid()
        resolvePageBoundaries()
    }

    func removeConnection(_ id: UUID) {
        guard connections.contains(where: { $0.id == id }) else { return }
        connections.removeAll { $0.id == id }
        structureRevision += 1
        reflowGrid()
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
            reflowGrid()   // a new cable can change flow order
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
    // them as horizontal content-width bands. None of these operations
    // touch the runtime graph, so none bump structureRevision.

    /// Minimum canvas x-distance between consecutive page origins; a
    /// page whose content is wider pushes every later page right.
    static let pageStride: CGFloat = 8 * 190
    /// Air between one page's content and the next page's origin.
    static let pageGap: CGFloat = 120

    /// Where each page starts on the canvas. Maintained by
    /// `resolvePageBoundaries()`; read through `pageOriginX(_:)`.
    private(set) var pageOriginsX: [CGFloat] = [0]

    func pageOriginX(_ page: Int) -> CGFloat {
        if page < pageOriginsX.count { return pageOriginsX[page] }
        // Pages past the stored list (just added, still empty) continue
        // at the minimum stride.
        let last = pageOriginsX.last ?? 0
        return last + CGFloat(page - pageOriginsX.count + 1) * Self.pageStride
    }

    /// The page whose band contains a canvas x — how the editor knows
    /// which page is under the viewport.
    func page(forX x: CGFloat) -> Int {
        for page in 1..<pageCount where x < pageOriginX(page) {
            return page - 1
        }
        return pageCount - 1
    }

    /// Re-derives every page origin from the previous page's content
    /// width and slides later pages' modules over — in both directions,
    /// so pages open up when content grows and close ranks when it
    /// shrinks. Within-page positions never change here.
    func resolvePageBoundaries() {
        let count = pageCount
        // Cross-page sources grow rightward connector cards; leave room
        // for the card corridor while the expanded layout is showing.
        var hasOffPageOut = Set<Int>()
        if isCardLayoutExpanded {
            let pageOf = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0.page) })
            for c in connections {
                if let s = pageOf[c.sourceModule], let d = pageOf[c.destModule], s != d {
                    hasOffPageOut.insert(s)
                }
            }
        }
        // One left-to-right pass: a page's shift feeds into where its
        // own content ends, which decides the NEXT page's origin —
        // shifts cascade, so origins and content must move together.
        var newOrigins: [CGFloat] = [0]
        for page in 1..<max(count, 1) {
            let previous = page - 1
            let previousShift = newOrigins[previous] - pageOriginX(previous)
            let contentRight = modules(onPage: previous)
                .map { $0.canvasPosition.x + NodeMetrics.width }.max()
                .map { $0 + previousShift }
            let allowance: CGFloat = hasOffPageOut.contains(previous)
                ? CableLayer.stubLength + CableLayer.cardSize.width + 10 : 40
            let width = contentRight.map {
                max(Self.pageStride, $0 + allowance + Self.pageGap - newOrigins[previous])
            } ?? Self.pageStride
            newOrigins.append(newOrigins[previous] + width)
        }
        // Page 0 shifts too: removing the first page leaves the
        // promoted page's content at its old origin.
        for page in 0..<count {
            let shift = newOrigins[page] - pageOriginX(page)
            guard shift != 0 else { continue }
            for i in modules.indices where modules[i].page == page {
                modules[i].canvasPosition.x += shift
            }
        }
        pageOriginsX = newOrigins
    }

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
        }
        // Drop the removed page's origin so stored origins line up with
        // the renumbered pages, then let the normalizer close the gap.
        if index < pageOriginsX.count { pageOriginsX.remove(at: index) }
        resolvePageBoundaries()
        reflowGrid()   // overflow is keyed by page index
        return true
    }

    /// Reassigns a module's page, shifting its canvas position into the
    /// destination band.
    func moveModule(_ id: UUID, toPage page: Int) {
        guard let index = modules.firstIndex(where: { $0.id == id }),
              page >= 0, page < ZoiaPatchBinary.maxPages,
              page != modules[index].page else { return }
        // Keep the module's offset within its band across the move.
        let relative = modules[index].canvasPosition.x
            - pageOriginX(modules[index].page)
        modules[index].page = page
        modules[index].canvasPosition.x = pageOriginX(page) + relative
        // A pinned slot belongs to the page it was pinned on.
        modules[index].gridPinned = false
        resolvePageBoundaries()
        reflowGrid()
    }

    // MARK: - Pedal grid placement
    //
    // The device shows each page as an 8×5 button grid; a module lights
    // one button per active block from its gridPosition. The reflow
    // below keeps every unpinned module's slot current after each
    // structural change, so the minimap and export always describe the
    // layout the pedal will actually show.

    /// Buttons on one device page.
    static let pageButtonCount = 40

    /// Buttons a module occupies on the device grid.
    /// ASSUMPTION (unverified on hardware): one button per active block.
    func buttonSpan(_ module: CanvasModule) -> Int {
        max(module.activeBlocks(in: catalog).count, 1)
    }

    /// Modules that don't fit their page's 40 buttons, by page — filled
    /// by `reflowGrid()`. Non-empty blocks export.
    private(set) var gridOverflow: [Int: [UUID]] = [:]

    /// Human-readable reasons export must refuse, one per full page.
    var gridExportBlockers: [String] {
        gridOverflow.keys.sorted().map { page in
            let names = (gridOverflow[page] ?? []).compactMap { id in
                module(id).map {
                    $0.customName.isEmpty
                        ? (catalog[$0.typeID]?.name ?? "?") : $0.customName
                }
            }
            let label = pageName(page).isEmpty
                ? "Page \(page + 1)" : "Page \(page + 1) (\(pageName(page)))"
            return "\(label) is out of buttons for: \(names.joined(separator: ", "))"
        }
    }

    /// Pins a module to a device-grid button and reflows the rest of
    /// its page around it.
    func setGridPosition(_ id: UUID, to position: Int) {
        guard let index = modules.firstIndex(where: { $0.id == id }),
              position >= 0, position < Self.pageButtonCount else { return }
        modules[index].gridPosition = position
        modules[index].gridPinned = true
        reflowGrid()
    }

    /// Returns a manually placed module to automatic flow placement.
    func unpinGridPosition(_ id: UUID) {
        guard let index = modules.firstIndex(where: { $0.id == id }) else { return }
        modules[index].gridPinned = false
        reflowGrid()
    }

    /// Assigns every unpinned module a device-grid slot, page by page:
    /// signal-flow order (longest path from the page's sources, cycles
    /// broken at the lowest array index; unwired modules follow in
    /// array order — stable under canvas dragging), packed first-fit
    /// around whatever is pinned. Modules that don't fit park past
    /// button 40 — nothing overlaps, the minimap clips them, and
    /// `gridOverflow` records the page as blocked.
    ///
    /// Pinned modules never move here. Two pinned modules may overlap
    /// if the user (or an imported patch under a wrong span guess)
    /// says so — authored placement outranks our occupancy model.
    func reflowGrid() {
        gridOverflow = [:]
        let indexOf = Dictionary(uniqueKeysWithValues: modules.enumerated().map { ($1.id, $0) })
        for page in 0..<pageCount {
            let pageIndices = modules.indices.filter { modules[$0].page == page }
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
            let unwired = pageIndices.filter { preds[$0] == nil && succs[$0] == nil }

            var rank: [Int: Int] = [:]
            var remaining = Set(wired)
            while !remaining.isEmpty {
                var ready = wired.filter { n in
                    remaining.contains(n)
                        && (preds[n] ?? []).allSatisfy { !remaining.contains($0) }
                }
                if ready.isEmpty {
                    ready = [wired.first { remaining.contains($0) }!]
                }
                for n in ready {
                    rank[n] = ((preds[n] ?? []).compactMap { rank[$0] }.max() ?? -1) + 1
                    remaining.remove(n)
                }
            }
            let order = wired.sorted { (rank[$0]!, $0) < (rank[$1]!, $1) } + unwired

            var occupied = [Bool](repeating: false, count: Self.pageButtonCount)
            for n in pageIndices where modules[n].gridPinned {
                // Some device patches place modules past button 40
                // (e.g. Euroburo layouts); clamp instead of trusting it.
                let start = max(modules[n].gridPosition, 0)
                let end = min(start + buttonSpan(modules[n]), Self.pageButtonCount)
                for b in start..<max(start, end) { occupied[b] = true }
            }
            var spill = Self.pageButtonCount
            for n in order where !modules[n].gridPinned {
                let span = buttonSpan(modules[n])
                var start = 0
                var placed = false
                while start + span <= Self.pageButtonCount {
                    let range = start..<(start + span)
                    if range.allSatisfy({ !occupied[$0] }) {
                        modules[n].gridPosition = start
                        for b in range { occupied[b] = true }
                        placed = true
                        break
                    }
                    start += 1
                }
                if !placed {
                    modules[n].gridPosition = spill
                    spill += span
                    gridOverflow[page, default: []].append(modules[n].id)
                }
            }
        }
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
    /// With `reserveCardCorridors` the layout keeps clearance beside
    /// and beneath every rank that talks to other pages, so expanded
    /// connector cards have somewhere to live. The collapsed default
    /// shows cards as port nodules that occupy no canvas space, and
    /// packs dense instead.
    private func packImportedLayout(reserveCardCorridors: Bool) {
        let hGap: CGFloat = 60   // cable room between rank columns
        let vGap: CGFloat = 24
        let tierGap: CGFloat = 60
        let margin: CGFloat = 80
        let pitch = NodeMetrics.width + hGap
        // Off-page connector cards render beside their module — leftward
        // of inputs fed from another page, rightward of outputs feeding
        // one. Ranks containing such modules reserve a corridor on that
        // side so no neighbouring rank lands under the cards.
        let cardClearance: CGFloat = reserveCardCorridors
            ? CableLayer.stubLength + CableLayer.cardSize.width + 10 : 0
        let indexOf = Dictionary(uniqueKeysWithValues: modules.enumerated().map { ($1.id, $0) })

        var offPageOut = Set<Int>()
        var offPageIn = Set<Int>()
        var cardsOut: [Int: Int] = [:]
        var cardsIn: [Int: Int] = [:]
        for c in connections {
            guard let s = indexOf[c.sourceModule], let d = indexOf[c.destModule],
                  modules[s].page != modules[d].page else { continue }
            offPageOut.insert(s)
            offPageIn.insert(d)
            cardsOut[s, default: 0] += 1
            cardsIn[d, default: 0] += 1
        }
        // Every off-page connection is one card, and a column's cards
        // stack downward — the stack can outgrow the modules beside it,
        // so vertical spacing must clear it too.
        let cardPitch = CableLayer.cardSize.height + 10
        func stackHeight(_ cards: Int) -> CGFloat {
            reserveCardCorridors && cards > 0 ? CGFloat(cards) * cardPitch - 10 : 0
        }

        func height(_ i: Int) -> CGFloat {
            NodeMetrics.height(blockCount: modules[i].activeBlocks(in: catalog).count)
        }

        // Pages are content-width: each page's origin follows the
        // previous page's actual extent, never less than one stride.
        var pageOrigin: CGFloat = 0
        var origins: [CGFloat] = []
        for page in 0..<pageCount {
            origins.append(pageOrigin)
            defer {
                let contentRight = modules.indices
                    .filter { modules[$0].page == page }
                    .map { modules[$0].canvasPosition.x + NodeMetrics.width }.max()
                let hasCardsAfter = reserveCardCorridors
                    && modules.indices.contains { modules[$0].page == page && offPageOut.contains($0) }
                let allowance: CGFloat = hasCardsAfter ? cardClearance : 40
                pageOrigin += contentRight.map {
                    max(Self.pageStride, $0 + allowance + Self.pageGap - pageOrigin)
                } ?? Self.pageStride
            }
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
            let bandStart = pageOrigin + margin
            let bandEnd = pageOrigin + Self.pageStride - margin
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
                    let beforeCards = rank.reduce(0) { $0 + (cardsIn[$1] ?? 0) }
                    let afterCards = rank.reduce(0) { $0 + (cardsOut[$1] ?? 0) }
                    tierHeight = max(tierHeight, y - vGap - tierY,
                                     stackHeight(beforeCards), stackHeight(afterCards))
                    x = startX + pitch + (needsAfter ? cardClearance : 0)
                    placedInTier += 1
                    rankIndex += 1
                }
                tierY += tierHeight + tierGap
            }

            // Modules with no on-page cables (UI buttons, pixels, …)
            // flow-pack below the graph so they never tangle with the
            // cabling. They can still talk to other pages, so a cell
            // reserves the same card corridors the ranked columns do.
            var flowX = bandStart
            var rowY = tierY
            var rowMaxHeight: CGFloat = 0
            for n in isolated {
                let leftClear: CGFloat = offPageIn.contains(n) ? cardClearance : 0
                let rightClear: CGFloat = offPageOut.contains(n) ? cardClearance : 0
                let cell = leftClear + NodeMetrics.width + rightClear
                if flowX > bandStart, flowX + cell > bandEnd {
                    flowX = bandStart
                    rowY += rowMaxHeight + vGap
                    rowMaxHeight = 0
                }
                modules[n].canvasPosition = CGPoint(x: flowX + leftClear, y: rowY)
                rowMaxHeight = max(rowMaxHeight, height(n),
                                   stackHeight(cardsIn[n] ?? 0),
                                   stackHeight(cardsOut[n] ?? 0))
                flowX += cell + hGap
            }
        }
        pageOriginsX = origins
    }

    // MARK: - Expanded card layout

    /// Collapsed-mode positions and page origins saved while expand-all
    /// is active, so toggling back restores the arrangement instead of
    /// re-deriving it.
    private var collapsedPositions: [UUID: CGPoint]?
    private var collapsedOrigins: [CGFloat]?

    /// Whether the canvas is currently in the expanded-card layout.
    var isCardLayoutExpanded: Bool { collapsedPositions != nil }

    /// Re-lay the canvas with corridors and clearance for every
    /// off-page connector card, then push modules clear of any card
    /// the corridor estimates missed. The current arrangement is
    /// saved and comes back via `restoreCollapsedCardLayout()`.
    func applyExpandedCardLayout() {
        if collapsedPositions == nil {
            collapsedPositions = Dictionary(
                uniqueKeysWithValues: modules.map { ($0.id, $0.canvasPosition) })
            collapsedOrigins = pageOriginsX
        }
        packImportedLayout(reserveCardCorridors: true)
        relaxCardClearance()
    }

    func restoreCollapsedCardLayout() {
        guard let saved = collapsedPositions else { return }
        for i in modules.indices {
            if let p = saved[modules[i].id] { modules[i].canvasPosition = p }
        }
        if let origins = collapsedOrigins { pageOriginsX = origins }
        collapsedPositions = nil
        collapsedOrigins = nil
    }

    /// Card stacks slide downward past whatever tier spacing predicted,
    /// so estimates alone cannot guarantee a clear canvas. This pass
    /// measures the actually-resolved cards and pushes any module
    /// underneath one straight down, repeating until nothing moves.
    /// Moves are strictly downward, so the loop is monotone; the
    /// iteration cap is a backstop, not the expected exit.
    private func relaxCardClearance() {
        let cardGap: CGFloat = 12
        let moduleGap: CGFloat = 24
        func rect(_ i: Int) -> CGRect {
            CGRect(origin: modules[i].canvasPosition,
                   size: CGSize(
                       width: NodeMetrics.width,
                       height: NodeMetrics.height(
                           blockCount: modules[i].activeBlocks(in: catalog).count)))
        }
        for _ in 0..<64 {
            let cards = CableLayer.resolvedStubs(in: self, offsets: [:])
            var moved = false
            // Upper modules settle first so a push cascades cleanly.
            for i in modules.indices.sorted(by: {
                (modules[$0].canvasPosition.y, $0) < (modules[$1].canvasPosition.y, $1)
            }) {
                let r = rect(i)
                var pushedY = r.minY
                for card in cards where card.card.intersects(r) {
                    pushedY = max(pushedY, card.card.maxY + cardGap)
                }
                for j in modules.indices where j != i {
                    let other = rect(j)
                    let jAbove = (other.minY, j) < (r.minY, i)
                    if jAbove, other.intersects(r) {
                        pushedY = max(pushedY, other.maxY + moduleGap)
                    }
                }
                if pushedY > r.minY {
                    modules[i].canvasPosition.y = pushedY
                    moved = true
                }
            }
            if !moved { return }
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
                gridPinned: true,
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
        packImportedLayout(reserveCardCorridors: false)
        reflowGrid()   // everything is pinned; this only surveys overflow
    }

    /// Builds the wire-format patch. Module order is canvas order;
    /// placement copies each module's page and gridPosition, which the
    /// live reflow keeps current. Callers must refuse to export while
    /// `gridExportBlockers` is non-empty — these positions are written
    /// verbatim, parked overflow included.
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
