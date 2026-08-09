import SwiftUI

/// A resolved port on the canvas: which module/block plus where it sits in
/// world coordinates.
private struct PortHit {
    var ref: PortRef
    var anchor: CGPoint
}

/// An in-progress cable drag.
private struct PendingCable {
    var source: PortRef
    var sourceAnchor: CGPoint
    var current: CGPoint
    var ruling: ConnectionRuling?
}

struct PatchEditorView: View {
    @Bindable var document: PatchDocument
    @Binding var selection: UUID?
    /// Live engine, for the cable activity lights: flow dashes appear
    /// only while the patch plays AND the lane's source block carries
    /// signal. Nil (previews, tests) draws plain cables.
    var engine: AudioEngine?

    private var isPlaying: Bool { engine?.isRunning ?? false }

    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var pendingCable: PendingCable?
    @State private var draggedModule: (id: UUID, start: CGPoint)?
    @State private var selectedCable: UUID?
    @State private var renamingPage: Int?
    @State private var renameText = ""
    /// Editor frame in WINDOW coordinates (bottom-left origin — the same
    /// space as NSEvent.locationInWindow, so the scroll monitor needs no
    /// coordinate conversion).
    @State private var editorWindowFrame: CGRect = .zero
    @State private var editorWindowNumber = -1
    @State private var scrollMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var zoomAtGestureStart: CGFloat?
    /// Where the user has dragged off-page connector cards; editor
    /// state only, reset on file open with the rest of the view.
    @State private var stubOffsets: [CableLayer.StubKey: CGSize] = [:]
    /// Connector ends opened from their nodule into a full card.
    /// Editor state, like `stubOffsets` — never persisted.
    @State private var expandedStubs: Set<CableLayer.StubKey> = []
    private var expandAll: Bool { document.isCardLayoutExpanded }
    @AppStorage("cableStyle") private var cableStyleRaw = CableStyle.curved.rawValue
    private var cableStyle: CableStyle { CableStyle(rawValue: cableStyleRaw) ?? .curved }
    private enum CanvasDrag {
        case pan
        case card(CableLayer.StubKey, CGSize)
    }
    @State private var canvasDrag: CanvasDrag?
    /// Delete only reaches onDeleteCommand while the editor is first
    /// responder; every click into the canvas reclaims focus (the search
    /// field and inspector take it while typing).
    @FocusState private var editorFocused: Bool

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                DotGridBackground(offset: offset, zoom: zoom)
                pageFrames
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                                        paused: !isPlaying && pendingCable == nil)) { timeline in
                    CableLayer(document: document,
                               pending: pendingCableSegments(),
                               selectedCable: selectedCable,
                               stubOffsets: stubOffsets,
                               style: cableStyle,
                               expandedStubs: expandedStubs,
                               expandAll: expandAll,
                               pass: .under,
                               engine: engine,
                               offset: offset, zoom: zoom,
                               time: timeline.date.timeIntervalSinceReferenceDate)
                }
                nodes
                // Expanded cards sit above the nodes: a card opened from
                // a nodule is a transient inspector and must be readable
                // wherever it lands.
                CableLayer(document: document,
                           pending: nil,
                           selectedCable: selectedCable,
                           stubOffsets: stubOffsets,
                           style: cableStyle,
                           expandedStubs: expandedStubs,
                           expandAll: expandAll,
                           pass: .over,
                           engine: nil,
                           offset: offset, zoom: zoom,
                           time: 0)
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            // Pinch zoom accumulates across gestures: magnification is
            // relative to THIS pinch's start, so it scales the zoom the
            // gesture began at rather than overwriting it.
            .gesture(MagnifyGesture()
                .onChanged { value in
                    let base = zoomAtGestureStart ?? zoom
                    zoomAtGestureStart = base
                    zoom = min(max(base * value.magnification, 0.25), 3)
                }
                .onEnded { _ in zoomAtGestureStart = nil })
            // Single click router for the whole canvas: module under the
            // cursor wins, then cable, then clear. One place decides, so
            // node taps and cable taps can't fight over the selection.
            // Single click router for the whole canvas, tested in draw
            // order top-down: expanded cards float above nodes, so their
            // ✕ and body outrank modules; nodules sit outside module
            // frames and open their card.
            .onTapGesture { location in
                let world = toWorld(location)
                if let key = noduleHit(at: world) {
                    expandedStubs.insert(key)
                } else if !expandAll, let key = closeHit(at: world) {
                    expandedStubs.remove(key)
                } else if let hit = expandedCardHit(at: world) {
                    // Second tap on a selected card follows the cable
                    // to its far end.
                    if hit.id == selectedCable, let jump = hit.jump {
                        jumpToWorld(jump)
                    }
                    selectedCable = hit.id
                    selection = nil
                } else if let module = moduleHit(at: world) {
                    selection = module.id
                    selectedCable = nil
                } else if let hit = cableHit(at: world) {
                    // Second tap on a selected off-page stub follows the
                    // cable to its far end.
                    if hit.id == selectedCable, let jump = hit.jump {
                        jumpToWorld(jump)
                    }
                    selectedCable = hit.id
                    selection = nil
                } else {
                    selection = nil
                    selectedCable = nil
                }
                editorFocused = true
            }
            .onDrop(of: [.plainText], isTargeted: nil) { providers, location in
                dropModule(providers: providers, at: toWorld(location))
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($editorFocused)
        .background(WindowFrameReader(frame: $editorWindowFrame,
                                      windowNumber: $editorWindowNumber)
            .allowsHitTesting(false))
        .onAppear {
            editorFocused = true
            installEventMonitors()
        }
        // Leaving expand-all lands back on nodules everywhere — stale
        // per-card expansions would reopen cards the user never clicked.
        .onChange(of: document.isCardLayoutExpanded) { _, expanded in
            if !expanded { expandedStubs = [] }
        }
        .onDisappear {
            for monitor in [scrollMonitor, keyMonitor].compactMap({ $0 }) {
                NSEvent.removeMonitor(monitor)
            }
            scrollMonitor = nil
            keyMonitor = nil
        }
        .onDeleteCommand {
            if let cable = selectedCable {
                document.removeConnection(cable)
                selectedCable = nil
            } else if let selected = selection {
                document.removeModule(selected)
                selection = nil
            }
        }
        .overlay(alignment: .bottom) { pageBar }
        .alert("Rename page \((renamingPage ?? 0) + 1)",
               isPresented: .init(get: { renamingPage != nil },
                                  set: { if !$0 { renamingPage = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let page = renamingPage { document.renamePage(page, to: renameText) }
                renamingPage = nil
            }
            Button("Cancel", role: .cancel) { renamingPage = nil }
        }
    }

    // MARK: - Pages

    /// Faint labeled frame around each page's content, so page
    /// boundaries read on the single shared canvas. Fitted to the
    /// union of the page's module rects and its visible connector
    /// cards, and drawn beneath everything interactive.
    private var pageFrames: some View {
        Canvas { context, _ in
            // Nested funcs are nonisolated; snapshot the view state.
            let zoom = zoom
            let offset = offset
            func toView(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * zoom + offset.width, y: p.y * zoom + offset.height)
            }
            // A visible card belongs to the page of the module whose
            // port it hangs off, wherever stacking moved it.
            let connectionByID = Dictionary(
                uniqueKeysWithValues: document.connections.map { ($0.id, $0) })
            var cardBoxes: [Int: CGRect] = [:]
            for item in CableLayer.resolvedStubs(in: document, offsets: stubOffsets,
                                                 only: visibleCardKeys) {
                guard let connection = connectionByID[item.key.connection],
                      let owner = document.module(item.key.isSource
                          ? connection.sourceModule : connection.destModule)
                else { continue }
                cardBoxes[owner.page] = cardBoxes[owner.page].map {
                    $0.union(item.card)
                } ?? item.card
            }
            for page in 0..<document.pageCount {
                var box: CGRect?
                for m in document.modules(onPage: page) {
                    let r = CGRect(
                        origin: m.canvasPosition,
                        size: CGSize(width: NodeMetrics.width,
                                     height: NodeMetrics.height(
                                         blockCount: m.activeBlocks(in: document.catalog).count)))
                    box = box.map { $0.union(r) } ?? r
                }
                if let cards = cardBoxes[page] { box = box.map { $0.union(cards) } ?? cards }
                guard let box else { continue }   // empty page, no frame
                // Padding covers port nodules and breathing room.
                let world = box.insetBy(dx: -28, dy: -28)
                let view = CGRect(origin: toView(world.origin),
                                  size: CGSize(width: world.width * zoom,
                                               height: world.height * zoom))
                let shape = Path(roundedRect: view, cornerRadius: 10 * zoom)
                context.fill(shape, with: .color(.primary.opacity(0.03)))
                context.stroke(shape, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

                let name = document.pageName(page)
                let label = context.resolve(
                    Text(name.isEmpty ? "Page \(page + 1)" : "\(page + 1) · \(name)")
                        .font(.system(size: 11 * zoom, weight: .semibold))
                        .foregroundStyle(.secondary))
                context.draw(label,
                             at: CGPoint(x: view.minX + 10 * zoom, y: view.minY - 6 * zoom),
                             anchor: .bottomLeading)
            }
        }
        .allowsHitTesting(false)
    }

    private var pageBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(0..<document.pageCount, id: \.self) { page in
                let name = document.pageName(page)
                Button {
                    jump(to: page)
                } label: {
                    VStack(spacing: 2) {
                        pageTile(page)
                            .overlay(alignment: .topTrailing) {
                                if let over = document.gridOverflow[page]?.count, over > 0 {
                                    Text("+\(over)")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 3)
                                        .background(.red, in: Capsule())
                                        .offset(x: 4, y: -4)
                                        .help("\(over) module(s) don't fit this page's 40 buttons")
                                }
                            }
                        Text(name.isEmpty ? "\(page + 1)" : "\(page + 1) · \(name)")
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .frame(maxWidth: 72)
                    }
                    .padding(3)
                    .background(currentPage == page ? Color.accentColor.opacity(0.3) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename…") {
                        renameText = name
                        renamingPage = page
                    }
                    Button("Delete", role: .destructive) { document.removePage(page) }
                        .disabled(!document.modules(onPage: page).isEmpty
                                  || document.pageCount == 1)
                }
            }
            Button {
                if let added = document.addPage() { jump(to: added) }
            } label: {
                Image(systemName: "plus").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Add page")
        }
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 10)
    }

    /// The page as the pedal shows it, rendered by the shared LED-grid
    /// painter.
    private func pageTile(_ page: Int) -> some View {
        Canvas { context, size in
            drawLEDGrid(&context, rect: CGRect(origin: .zero, size: size),
                        modules: document.modules(onPage: page),
                        catalog: document.catalog)
        }
        .frame(width: 64, height: 40)
    }

    /// The page band nearest the viewport's left edge — highlight only.
    private var currentPage: Int {
        document.page(forX: -offset.width / zoom + PatchDocument.pageStride / 2)
    }

    private func jump(to page: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            offset.width = (40 - document.pageOriginX(page)) * zoom
        }
        panStart = offset
    }

    private var nodes: some View {
        ForEach(document.modules) { module in
            let blocks = module.activeBlocks(in: document.catalog)
            ModuleNodeView(
                module: module,
                spec: document.catalog[module.typeID],
                blocks: blocks,
                isSelected: selection == module.id)
            // Center-anchored scale pairs with nodeCenter: .position places
            // the unscaled frame's center, so scaling about that center puts
            // the visual top-left exactly at toView(canvasPosition) — the
            // same point the cable layer and hit testing use.
            .scaleEffect(zoom)
            .position(nodeCenter(module, blockCount: blocks.count))
            .gesture(nodeGesture(module, blocks: blocks))
            .contextMenu {
                Button("Delete \(module.customName.isEmpty ? (document.catalog[module.typeID]?.name ?? "Module") : module.customName)",
                       role: .destructive) {
                    document.removeModule(module.id)
                    if selection == module.id { selection = nil }
                }
            }
        }
    }

    private func dropModule(providers: [NSItemProvider], at world: CGPoint) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String,
                  text.hasPrefix("zoia-module:"),
                  let typeID = Int(text.dropFirst("zoia-module:".count)) else { return }
            Task { @MainActor in
                let centered = CGPoint(x: world.x - NodeMetrics.width / 2, y: world.y - 14)
                if let added = document.addModule(typeID: typeID, at: centered) {
                    selection = added.id
                }
            }
        }
        return true
    }

    // MARK: - Coordinate transforms

    private func toView(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * zoom + offset.width, y: world.y * zoom + offset.height)
    }

    private func toWorld(_ view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x - offset.width) / zoom, y: (view.y - offset.height) / zoom)
    }

    private func nodeCenter(_ module: CanvasModule, blockCount: Int) -> CGPoint {
        let origin = toView(module.canvasPosition)
        return CGPoint(
            x: origin.x + NodeMetrics.width * zoom / 2,
            y: origin.y + NodeMetrics.height(blockCount: blockCount) * zoom / 2)
    }

    // MARK: - Gestures

    /// Local NSEvent monitors, both scoped by editorWindowFrame /
    /// editorWindowNumber (window coordinates, from WindowFrameReader):
    /// - scrollWheel: two-finger trackpad panning. SwiftUI has no
    ///   scroll-wheel gesture on macOS; events over the palette and
    ///   inspector pass through to their ScrollViews.
    /// - keyDown ⌫/⌦: deletes the selected cable or module. The SwiftUI
    ///   focus system proved unreliable for onDeleteCommand here, so the
    ///   key is handled at the AppKit layer; keystrokes while a text
    ///   field is editing pass through untouched.
    /// - keyDown ⌘=/⌘-/⌘0: zoom in, out, and reset — the standard
    ///   document-view zoom keys, handled here for the same reason.
    private func installEventMonitors() {
        installScrollMonitor()
        installKeyMonitor()
    }

    /// =/- on the main row and keypad, plus 0 for reset.
    private static let zoomInKeys: Set<UInt16> = [24, 69]
    private static let zoomOutKeys: Set<UInt16> = [27, 78]
    private static let zoomResetKey: UInt16 = 29

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            if modifiers == .command,
               Self.zoomInKeys.contains(keyCode) || Self.zoomOutKeys.contains(keyCode)
                   || keyCode == Self.zoomResetKey {
                let zoomWindowNumber = event.window?.windowNumber ?? -2
                let handled = MainActor.assumeIsolated { () -> Bool in
                    guard zoomWindowNumber == editorWindowNumber else { return false }
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if keyCode == Self.zoomResetKey {
                            zoom = 1
                        } else if Self.zoomInKeys.contains(keyCode) {
                            zoom = min(zoom * 1.25, 3)
                        } else {
                            zoom = max(zoom / 1.25, 0.25)
                        }
                    }
                    return true
                }
                return handled ? nil : event
            }
            guard keyCode == 51 || keyCode == 117,  // ⌫ / ⌦, with or without ⌘
                  modifiers.subtracting(.command).isEmpty
            else { return event }
            let windowNumber = event.window?.windowNumber ?? -2
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard windowNumber == editorWindowNumber,
                      !(NSApp.keyWindow?.firstResponder is NSTextView) else { return false }
                if let cable = selectedCable {
                    document.removeConnection(cable)
                    selectedCable = nil
                    return true
                }
                if let selected = selection {
                    document.removeModule(selected)
                    selection = nil
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // NSEvent is not Sendable; pull the values out before hopping
            // into the isolation the monitor already runs on (main thread).
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            let location = event.locationInWindow
            let windowNumber = event.window?.windowNumber ?? -2
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard windowNumber == editorWindowNumber,
                      editorWindowFrame.contains(location) else { return false }
                offset.width += deltaX
                offset.height += deltaY
                panStart = offset
                return true
            }
            return handled ? nil : event
        }
    }

    /// Canvas-background drag: starting on an off-page connector card
    /// moves that card; anywhere else pans. The mode locks at the first
    /// change so a drag can't switch targets mid-flight.
    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if canvasDrag == nil {
                    if let key = stubCardHit(at: toWorld(value.startLocation)) {
                        canvasDrag = .card(key, stubOffsets[key] ?? .zero)
                    } else {
                        canvasDrag = .pan
                    }
                }
                switch canvasDrag {
                case .card(let key, let base):
                    stubOffsets[key] = CGSize(
                        width: base.width + value.translation.width / zoom,
                        height: base.height + value.translation.height / zoom)
                case .pan, nil:
                    offset = CGSize(width: panStart.width + value.translation.width,
                                    height: panStart.height + value.translation.height)
                }
            }
            .onEnded { _ in
                if case .pan = canvasDrag { panStart = offset }
                canvasDrag = nil
            }
    }

    /// Connector ends currently shown as cards; nil means all of them.
    private var visibleCardKeys: Set<CableLayer.StubKey>? {
        expandAll ? nil : expandedStubs
    }

    /// The topmost expanded connector card under a world point.
    private func stubCardHit(at world: CGPoint) -> CableLayer.StubKey? {
        CableLayer.resolvedStubs(in: document, offsets: stubOffsets,
                                 only: visibleCardKeys)
            .last { $0.card.contains(world) }?.key
    }

    /// The topmost collapsed nodule near a world point.
    private func noduleHit(at world: CGPoint) -> CableLayer.StubKey? {
        guard !expandAll else { return nil }
        return CableLayer.resolvedStubs(in: document, offsets: stubOffsets)
            .filter { !expandedStubs.contains($0.key) }
            .last {
                let center = CableLayer.noduleCenter($0.stub)
                return hypot(center.x - world.x, center.y - world.y)
                    <= CableLayer.noduleRadius + 4
            }?.key
    }

    /// The ✕ of an expanded card under a world point.
    private func closeHit(at world: CGPoint) -> CableLayer.StubKey? {
        CableLayer.resolvedStubs(in: document, offsets: stubOffsets,
                                 only: visibleCardKeys)
            .last { CableLayer.closeRect(for: $0.card).contains(world) }?.key
    }

    /// An expanded card's body under a world point, with the jump
    /// target its second click follows.
    private func expandedCardHit(at world: CGPoint) -> (id: UUID, jump: CGPoint?)? {
        CableLayer.resolvedStubs(in: document, offsets: stubOffsets,
                                 only: visibleCardKeys)
            .last { $0.card.contains(world) }
            .map { ($0.key.connection, $0.stub.jumpTarget) }
    }

    /// One gesture per node: starting near a port drags a cable; anywhere
    /// else moves the node.
    private func nodeGesture(_ module: CanvasModule, blocks: [BlockSpec]) -> some Gesture {
        DragGesture(coordinateSpace: .named("editor"))
            .onChanged { value in
                if pendingCable != nil || draggedModule != nil {
                    updateActiveDrag(value)
                    return
                }
                let world = toWorld(value.startLocation)
                if let hit = portHit(near: world, in: module, blocks: blocks),
                   hit.ref.type.isOutput {
                    pendingCable = PendingCable(
                        source: hit.ref, sourceAnchor: hit.anchor, current: world)
                } else {
                    draggedModule = (module.id, module.canvasPosition)
                    selection = module.id
                    selectedCable = nil
                    editorFocused = true
                }
                updateActiveDrag(value)
            }
            .onEnded { value in
                if let pending = pendingCable {
                    if let target = portHit(near: toWorld(value.location)),
                       !target.ref.type.isOutput {
                        document.connect(from: pending.source, to: target.ref)
                    }
                    pendingCable = nil
                }
                // A finished node drag may have widened (or narrowed)
                // its page; later pages slide to fit.
                if draggedModule != nil { document.resolvePageBoundaries() }
                draggedModule = nil
            }
    }

    private func updateActiveDrag(_ value: DragGesture.Value) {
        if var pending = pendingCable {
            let world = toWorld(value.location)
            pending.current = world
            if let target = portHit(near: world), !target.ref.type.isOutput {
                pending.ruling = document.ruling(from: pending.source, to: target.ref)
            } else {
                pending.ruling = nil
            }
            pendingCable = pending
        } else if let dragged = draggedModule,
                  let index = document.modules.firstIndex(where: { $0.id == dragged.id }) {
            document.modules[index].canvasPosition = CGPoint(
                x: dragged.start.x + value.translation.width / zoom,
                y: dragged.start.y + value.translation.height / zoom)
        }
    }

    // MARK: - Port hit testing (world coordinates)

    private func portHit(near world: CGPoint) -> PortHit? {
        for module in document.modules {
            if let hit = portHit(near: world, in: module,
                                 blocks: module.activeBlocks(in: document.catalog)) {
                return hit
            }
        }
        return nil
    }

    private func portHit(near world: CGPoint, in module: CanvasModule,
                         blocks: [BlockSpec]) -> PortHit? {
        let grabRadius: CGFloat = 14
        for (row, block) in blocks.enumerated() {
            let anchor = NodeMetrics.portAnchor(
                nodeOrigin: module.canvasPosition, rowIndex: row,
                isOutput: block.type.isOutput)
            if hypot(anchor.x - world.x, anchor.y - world.y) <= grabRadius {
                return PortHit(
                    ref: PortRef(module: module.id,
                                 blockPosition: block.position ?? row,
                                 type: block.type),
                    anchor: anchor)
            }
        }
        return nil
    }

    private func pendingCableSegments() -> CableLayer.Pending? {
        guard let pending = pendingCable else { return nil }
        return CableLayer.Pending(
            from: pending.sourceAnchor, to: pending.current,
            isAudio: pending.source.type.isAudio, ruling: pending.ruling)
    }

    // MARK: - Hit testing (world coordinates)

    /// Topmost module whose frame contains the point (later modules draw
    /// on top, so search in reverse document order).
    private func moduleHit(at world: CGPoint) -> CanvasModule? {
        for module in document.modules.reversed() {
            let blocks = module.activeBlocks(in: document.catalog)
            let frame = CGRect(origin: module.canvasPosition,
                               size: CGSize(width: NodeMetrics.width,
                                            height: NodeMetrics.height(blockCount: blocks.count)))
            if frame.contains(world) { return module }
        }
        return nil
    }

    /// The cable nearest the tap, within a constant ~12pt screen radius.
    /// Direct cables measure against 24 sampled bezier points; off-page
    /// connectors against their stub segments (extended past the tip to
    /// cover the label pill). A stub hit carries the counterpart port so
    /// a second tap on a selected stub can jump to it.
    private func cableHit(at world: CGPoint) -> (id: UUID, jump: CGPoint?)? {
        let radius = 12 / zoom
        var best: (id: UUID, jump: CGPoint?, distance: CGFloat)?
        func consider(_ id: UUID, _ distance: CGFloat, _ jump: CGPoint?) {
            if distance <= radius, distance < (best?.distance ?? .infinity) {
                best = (id, jump, distance)
            }
        }
        func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let lengthSquared = ab.x * ab.x + ab.y * ab.y
            let t = lengthSquared == 0 ? 0
                : min(max(((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / lengthSquared, 0), 1)
            return hypot(p.x - (a.x + t * ab.x), p.y - (a.y + t * ab.y))
        }
        func considerBezier(_ id: UUID, _ p0: CGPoint, _ c1: CGPoint,
                            _ c2: CGPoint, _ p3: CGPoint, jump: CGPoint? = nil) {
            for i in 0...24 {
                let t = CGFloat(i) / 24
                let u = 1 - t
                let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x
                let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y
                consider(id, hypot(x - world.x, y - world.y), jump)
            }
        }
        for connection in document.connections {
            guard case .direct(let e)? = CableLayer.geometry(connection, in: document)
            else { continue }   // off-page connectors tested via their cards below
            switch cableStyle {
            case .curved:
                let (c1, c2) = CableLayer.worldControlPoints(e)
                considerBezier(connection.id, e.from, c1, c2, e.to)
            case .angular:
                let route = CableLayer.angularRoute(from: e.from, to: e.to,
                                                    entersRight: e.entersRight)
                for i in 1..<route.count {
                    consider(connection.id,
                             segmentDistance(world, route[i - 1], route[i]), nil)
                }
            }
        }
        for item in CableLayer.resolvedStubs(in: document, offsets: stubOffsets,
                                             only: visibleCardKeys) {
            if item.card.contains(world) {
                consider(item.key.connection, 0, item.stub.jumpTarget)
                continue
            }
            let route = CableLayer.stubRoute(item, style: cableStyle)
            if route.isBezier {
                considerBezier(item.key.connection, route.points[0], route.points[1],
                               route.points[2], route.points[3],
                               jump: item.stub.jumpTarget)
                continue
            }
            for i in 1..<route.points.count {
                consider(item.key.connection,
                         segmentDistance(world, route.points[i - 1], route.points[i]),
                         item.stub.jumpTarget)
            }
        }
        guard let best else { return nil }
        return (best.id, best.jump)
    }

    /// Pans so a world point lands at the viewport center — how a stub
    /// tap follows a cross-page cable to its other end.
    private func jumpToWorld(_ point: CGPoint) {
        withAnimation(.easeInOut(duration: 0.3)) {
            offset = CGSize(
                width: editorWindowFrame.width / 2 - point.x * zoom,
                height: editorWindowFrame.height / 2 - point.y * zoom)
        }
        panStart = offset
    }
}

/// Paints a page as the pedal's 8×5 LED button grid into `rect`: one
/// cell per button, each module lighting one button per active block
/// from its grid position, wrapping every 8 — the device's own layout
/// rule. With `highlight` set, every other module dims so the
/// highlighted one reads as "the cable lands here". Shared by the page
/// bar tiles and the off-page connector cards.
@MainActor
func drawLEDGrid(_ context: inout GraphicsContext, rect: CGRect,
                 modules: [CanvasModule], catalog: ModuleCatalog,
                 highlight: UUID? = nil) {
    let cellWidth = rect.width / 8
    let cellHeight = rect.height / 5
    func cell(_ position: Int) -> Path {
        Path(roundedRect: CGRect(
            x: rect.minX + CGFloat(position % 8) * cellWidth,
            y: rect.minY + CGFloat(position / 8) * cellHeight,
            width: cellWidth, height: cellHeight)
            .insetBy(dx: cellWidth * 0.06 + 0.3, dy: cellHeight * 0.06 + 0.3),
            cornerRadius: cellWidth * 0.12)
    }
    for position in 0..<40 {
        context.fill(cell(position), with: .color(.primary.opacity(0.08)))
    }
    for module in modules {
        let span = max(module.activeBlocks(in: catalog).count, 1)
        let dimmed = highlight != nil && module.id != highlight
        let color = zoiaColor(module.colorID).opacity(dimmed ? 0.25 : 1)
        for block in 0..<span where module.gridPosition + block < 40 {
            context.fill(cell(module.gridPosition + block), with: .color(color))
        }
    }
}

/// How cables and connector stub lines render: swooping beziers, or
/// circuit-trace orthogonal runs (horizontal/vertical segments with
/// gently rounded corners). Persisted under the "cableStyle" default.
enum CableStyle: String, CaseIterable {
    case curved
    case angular
}

/// Draws every cable plus the in-progress drag, in one Canvas pass.
struct CableLayer: View {
    struct Pending {
        var from: CGPoint
        var to: CGPoint
        var isAudio: Bool
        var ruling: ConnectionRuling?
    }

    let document: PatchDocument
    let pending: Pending?
    let selectedCable: UUID?
    /// User-dragged card positions for off-page connectors, keyed by
    /// connector end; editor state, never persisted to the patch.
    let stubOffsets: [StubKey: CGSize]
    let style: CableStyle
    /// Which connector ends show a full card; everything else draws as
    /// a port nodule. `expandAll` overrides the set.
    let expandedStubs: Set<StubKey>
    let expandAll: Bool
    /// Split so expanded cards can render above module nodes while
    /// cables, stub lines, and nodules stay beneath them.
    enum Pass { case under, over }
    let pass: Pass
    /// Live engine for per-lane activity. Nil draws plain cables.
    let engine: AudioEngine?
    let offset: CGSize
    let zoom: CGFloat
    /// Drives the flow animation; signal level gates it per lane and
    /// connection strength scales its speed and brightness.
    let time: TimeInterval

    var body: some View {
        // One engine query per frame for every lane: flow lights appear
        // only while the patch plays and the source block carries signal.
        let indexOf = Dictionary(uniqueKeysWithValues: document.modules.enumerated().map { ($1.id, $0) })
        let sources = document.connections.map {
            (module: indexOf[$0.sourceModule] ?? -1, block: $0.sourceBlock)
        }
        let levels = (engine?.isRunning ?? false)
            ? (engine?.sourceLevels(sources) ?? []) : []
        return Canvas { context, _ in
            if pass == .over {
                let connectionByID = Dictionary(
                    uniqueKeysWithValues: document.connections.map { ($0.id, $0) })
                for item in Self.resolvedStubs(
                    in: document, offsets: stubOffsets,
                    only: expandAll ? nil : expandedStubs) {
                    guard let connection = connectionByID[item.key.connection]
                    else { continue }
                    drawStubCard(item, in: &context,
                                 color: cableColor(connection),
                                 selected: connection.id == selectedCable,
                                 showClose: !expandAll)
                }
                return
            }
            for (index, connection) in document.connections.enumerated() {
                guard let geometry = Self.geometry(connection, in: document) else { continue }
                let color = cableColor(connection)
                let selected = connection.id == selectedCable

                switch geometry {
                case .direct(let endpoints):
                    let path = cablePath(endpoints)
                    if endpoints.entersRight {
                        context.fill(arrowhead(at: transform(endpoints.to), pointing: -1),
                                     with: .color(color))
                    }
                    let strength = min(max(Double(connection.strengthRaw) / 10000, 0), 1)

                    // Selection halo under everything else on the cable.
                    if selected {
                        context.stroke(path, with: .color(.white.opacity(0.9)),
                                       style: StrokeStyle(lineWidth: 5 * zoom, lineCap: .round))
                    }
                    // Glow underlay, then the cable body.
                    context.stroke(path, with: .color(color.opacity(0.25)),
                                   style: StrokeStyle(lineWidth: 6 * zoom, lineCap: .round))
                    context.stroke(path, with: .color(color),
                                   style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .round))

                    // Energy flow: bright dashes marching source → destination,
                    // drawn only for lanes with live signal. Phase decreases so
                    // motion runs with the path direction.
                    guard index < levels.count, levels[index] > 0.001 else { continue }
                    let speed = (40 + 80 * strength) * zoom
                    context.stroke(
                        path,
                        with: .color(.white.opacity(0.25 + 0.5 * strength)),
                        style: StrokeStyle(
                            lineWidth: 2.2 * zoom, lineCap: .round,
                            dash: [3 * zoom, 13 * zoom],
                            dashPhase: -CGFloat(time.truncatingRemainder(dividingBy: 3600)) * speed))

                case .offPage:
                    break   // drawn from resolvedStubs below, post-stacking
                }
            }
            // Expanded ends draw a stub line here and their card in the
            // `over` pass (above module nodes); collapsed ends draw only
            // a nodule at the port. Card resolution is limited to the
            // expanded set so hidden cards never shift visible ones.
            let connectionByID = Dictionary(
                uniqueKeysWithValues: document.connections.map { ($0.id, $0) })
            let visibleKeys: Set<StubKey>? = expandAll ? nil : expandedStubs
            for item in Self.resolvedStubs(in: document, offsets: stubOffsets,
                                           only: visibleKeys) {
                guard let connection = connectionByID[item.key.connection] else { continue }
                drawStubLine(item, in: &context,
                             color: cableColor(connection),
                             selected: connection.id == selectedCable)
            }
            if !expandAll {
                for item in Self.resolvedStubs(in: document, offsets: stubOffsets)
                where !expandedStubs.contains(item.key) {
                    guard let connection = connectionByID[item.key.connection]
                    else { continue }
                    drawNodule(item, in: &context,
                               color: cableColor(connection),
                               selected: connection.id == selectedCable)
                }
            }
            if let pending {
                let path: Path = switch style {
                case .curved:
                    bezier(from: transform(pending.from), to: transform(pending.to))
                case .angular:
                    Self.roundedPath(
                        Self.angularRoute(from: pending.from, to: pending.to,
                                          entersRight: false).map(transform),
                        radius: Self.angularCornerRadius * zoom)
                }
                let color: Color = switch pending.ruling {
                case .allowed, nil: pending.isAudio ? .teal : .orange
                case .allowedTypeMismatch: .yellow
                case .notOutputToInput, .sameModule, .duplicate: .red
                }
                context.stroke(
                    path, with: .color(color.opacity(0.9)),
                    style: StrokeStyle(
                        lineWidth: 2 * zoom, dash: [6 * zoom, 4 * zoom],
                        dashPhase: -CGFloat(time.truncatingRemainder(dividingBy: 3600)) * 60 * zoom))
            }
        }
        .allowsHitTesting(false)
    }

    private func transform(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * zoom + offset.width, y: world.y * zoom + offset.height)
    }

    /// A cable's endpoints in world coordinates, plus which side of the
    /// destination it enters. A source right of its destination enters
    /// the input row from the RIGHT edge (marked with an arrowhead)
    /// rather than looping around the node's left side.
    struct Endpoints {
        var from: CGPoint
        var to: CGPoint
        var entersRight: Bool
    }

    /// One labelled end of an off-page connector: a cross-page cable
    /// draws as a short stub at each port instead of a canvas-spanning
    /// bezier, schematic off-sheet-reference style. `jumpTarget` is the
    /// counterpart port, so a second click on a selected stub pans there.
    struct Stub {
        var port: CGPoint
        var tip: CGPoint
        var label: String
        var jumpTarget: CGPoint
        /// The far end's page and module, for the LED-grid card that
        /// shows where the connector lands.
        var farPage: Int
        var farModuleID: UUID
    }

    enum Geometry {
        case direct(Endpoints)
        case offPage(source: Stub, dest: Stub)
    }

    static let stubLength: CGFloat = 46

    /// Identifies one end of one off-page connector — the unit a user
    /// can drag.
    struct StubKey: Hashable {
        var connection: UUID
        var isSource: Bool
    }

    /// A stub with its card rectangle settled: fixed world-space card
    /// size, stacked to avoid overlapping siblings, then shifted by any
    /// user drag. Drawing, hit testing, and dragging all consume this
    /// one resolution so they cannot disagree.
    struct ResolvedStub {
        var key: StubKey
        var stub: Stub
        var card: CGRect
        var rightward: Bool
    }

    static let cardSize = CGSize(width: 214, height: 56)

    /// `only` limits resolution (and therefore stacking) to the given
    /// connector ends — collapsed nodules must not push visible cards
    /// around, so callers pass the expanded set; nil resolves all.
    static func resolvedStubs(in document: PatchDocument,
                              offsets: [StubKey: CGSize],
                              only keys: Set<StubKey>? = nil) -> [ResolvedStub] {
        var items: [ResolvedStub] = []
        for connection in document.connections {
            guard case .offPage(let source, let dest)? = geometry(connection, in: document)
            else { continue }
            for (stub, isSource) in [(source, true), (dest, false)] {
                let key = StubKey(connection: connection.id, isSource: isSource)
                if let keys, !keys.contains(key) { continue }
                let rightward = stub.tip.x >= stub.port.x
                let card = CGRect(
                    x: rightward ? stub.tip.x : stub.tip.x - cardSize.width,
                    y: stub.tip.y - cardSize.height / 2,
                    width: cardSize.width, height: cardSize.height)
                items.append(ResolvedStub(
                    key: key, stub: stub, card: card, rightward: rightward))
            }
        }
        // Stack cards that share a column and direction so none overlap:
        // sort by desired y and push each below the one above.
        let groups = Dictionary(grouping: items.indices) { index in
            "\(items[index].rightward)-\(Int((items[index].card.minX / 20).rounded()))"
        }
        for (_, indices) in groups {
            let sorted = indices.sorted {
                (items[$0].card.minY, items[$0].key.connection.uuidString, items[$0].key.isSource ? 0 : 1)
                    < (items[$1].card.minY, items[$1].key.connection.uuidString, items[$1].key.isSource ? 0 : 1)
            }
            var nextY = -CGFloat.infinity
            for index in sorted {
                let y = max(items[index].card.minY, nextY)
                items[index].card.origin.y = y
                nextY = y + cardSize.height + 10
            }
        }
        // User drags apply after stacking so a moved card stays put.
        for index in items.indices {
            if let shift = offsets[items[index].key] {
                items[index].card.origin.x += shift.width
                items[index].card.origin.y += shift.height
            }
        }
        return items
    }

    private struct ResolvedPorts {
        var source: CanvasModule
        var dest: CanvasModule
        var sourceRow: Int
        var destRow: Int
        var sourceKey: String
        var destKey: String
    }

    private static func resolve(_ connection: CanvasConnection,
                                in document: PatchDocument) -> ResolvedPorts? {
        func row(_ module: CanvasModule, blockPosition: Int,
                 wantOutput: Bool) -> (Int, String)? {
            let blocks = module.activeBlocks(in: document.catalog)
            for (row, block) in blocks.enumerated()
            where (block.position ?? row) == blockPosition && block.type.isOutput == wantOutput {
                return (row, block.key)
            }
            return nil
        }
        guard let source = document.module(connection.sourceModule),
              let dest = document.module(connection.destModule),
              let (sourceRow, sourceKey) = row(
                  source, blockPosition: connection.sourceBlock, wantOutput: true),
              let (destRow, destKey) = row(
                  dest, blockPosition: connection.destBlock, wantOutput: false)
        else { return nil }
        return ResolvedPorts(source: source, dest: dest,
                             sourceRow: sourceRow, destRow: destRow,
                             sourceKey: sourceKey, destKey: destKey)
    }

    private static func displayName(_ module: CanvasModule,
                                    in document: PatchDocument) -> String {
        module.customName.isEmpty
            ? (document.catalog[module.typeID]?.name ?? "?") : module.customName
    }

    /// Shared with the editor's cable hit testing so selection and
    /// drawing agree.
    static func geometry(_ connection: CanvasConnection,
                         in document: PatchDocument) -> Geometry? {
        guard let r = resolve(connection, in: document) else { return nil }
        let from = NodeMetrics.portAnchor(
            nodeOrigin: r.source.canvasPosition, rowIndex: r.sourceRow, isOutput: true)
        let left = NodeMetrics.portAnchor(
            nodeOrigin: r.dest.canvasPosition, rowIndex: r.destRow, isOutput: false)
        guard r.source.page != r.dest.page else {
            guard from.x > left.x else {
                return .direct(Endpoints(from: from, to: left, entersRight: false))
            }
            return .direct(Endpoints(
                from: from,
                to: NodeMetrics.inputAnchorRight(
                    nodeOrigin: r.dest.canvasPosition, rowIndex: r.destRow),
                entersRight: true))
        }
        return .offPage(
            source: Stub(
                port: from,
                tip: CGPoint(x: from.x + stubLength, y: from.y),
                label: "\(displayName(r.dest, in: document)) · \(r.destKey)",
                jumpTarget: left,
                farPage: r.dest.page,
                farModuleID: r.dest.id),
            dest: Stub(
                port: left,
                tip: CGPoint(x: left.x - stubLength, y: left.y),
                label: "\(displayName(r.source, in: document)) · \(r.sourceKey)",
                jumpTarget: from,
                farPage: r.source.page,
                farModuleID: r.source.id))
    }

    /// Bezier control points in world coordinates, shared with hit
    /// testing. Forward cables bow half their span; right-entry cables
    /// use a short stub on both ends so the turnback hugs the nodes.
    static func worldControlPoints(_ e: Endpoints) -> (CGPoint, CGPoint) {
        if e.entersRight {
            let stub = min(40 + abs(e.to.y - e.from.y) * 0.1, 90)
            return (CGPoint(x: e.from.x + stub, y: e.from.y),
                    CGPoint(x: e.to.x + stub, y: e.to.y))
        }
        let dx = max(abs(e.to.x - e.from.x) * 0.5, 30)
        return (CGPoint(x: e.from.x + dx, y: e.from.y),
                CGPoint(x: e.to.x - dx, y: e.to.y))
    }

    /// The angular style's route: horizontal and vertical runs only,
    /// H-V-H, in world coordinates. Shared with hit testing. Right-entry
    /// cables detour around the right side; everything else turns at the
    /// midpoint between the ports.
    static func angularRoute(from: CGPoint, to: CGPoint, entersRight: Bool) -> [CGPoint] {
        let turnX = entersRight
            ? max(from.x, to.x) + stubLength
            : (from.x + to.x) / 2
        return [from,
                CGPoint(x: turnX, y: from.y),
                CGPoint(x: turnX, y: to.y),
                to]
    }

    /// Corner radius for the angular style — curly-bracket corners,
    /// visibly squared-off but not sharp. World units.
    static let angularCornerRadius: CGFloat = 8

    /// Polyline with each interior corner rounded off, clamped so short
    /// segments never fold back on themselves.
    static func roundedPath(_ points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for i in 1..<max(points.count - 1, 1) {
            let previous = points[i - 1]
            let corner = points[i]
            let next = points[i + 1]
            let inLength = hypot(corner.x - previous.x, corner.y - previous.y)
            let outLength = hypot(next.x - corner.x, next.y - corner.y)
            guard inLength > 0.01, outLength > 0.01 else { continue }
            let r = min(radius, inLength / 2, outLength / 2)
            let inDir = CGPoint(x: (corner.x - previous.x) / inLength,
                                y: (corner.y - previous.y) / inLength)
            let outDir = CGPoint(x: (next.x - corner.x) / outLength,
                                 y: (next.y - corner.y) / outLength)
            path.addLine(to: CGPoint(x: corner.x - inDir.x * r, y: corner.y - inDir.y * r))
            path.addQuadCurve(
                to: CGPoint(x: corner.x + outDir.x * r, y: corner.y + outDir.y * r),
                control: corner)
        }
        if points.count > 1 { path.addLine(to: points[points.count - 1]) }
        return path
    }

    private func cablePath(_ e: Endpoints) -> Path {
        switch style {
        case .curved:
            let (c1, c2) = Self.worldControlPoints(e)
            var path = Path()
            path.move(to: transform(e.from))
            path.addCurve(to: transform(e.to),
                          control1: transform(c1), control2: transform(c2))
            return path
        case .angular:
            let route = Self.angularRoute(from: e.from, to: e.to,
                                          entersRight: e.entersRight)
            return Self.roundedPath(route.map(transform),
                                    radius: Self.angularCornerRadius * zoom)
        }
    }

    /// Arrowhead at an input port — what distinguishes a cable ENTERING
    /// an edge from one leaving it. `pointing` is the x-direction of
    /// travel: -1 arrives leftward (right-edge entry), +1 rightward
    /// (off-page stub into a left-edge input).
    private func arrowhead(at tip: CGPoint, pointing: CGFloat) -> Path {
        let s = 5 * zoom
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: tip.x - pointing * s * 1.6, y: tip.y - s))
        path.addLine(to: CGPoint(x: tip.x - pointing * s * 1.6, y: tip.y + s))
        path.closeSubpath()
        return path
    }

    /// A stub line's route from port to card edge in world coordinates —
    /// styled exactly like a cable, shared with hit testing. Curved gets
    /// horizontal-tangent bezier control points; angular gets the H-V-H
    /// route.
    static func stubRoute(_ item: ResolvedStub, style: CableStyle)
        -> (points: [CGPoint], isBezier: Bool) {
        let port = item.stub.port
        let edge = CGPoint(x: item.rightward ? item.card.minX : item.card.maxX,
                           y: item.card.midY)
        switch style {
        case .curved:
            let sign: CGFloat = edge.x >= port.x ? 1 : -1
            let dx = max(abs(edge.x - port.x) * 0.5, 24)
            return ([port,
                     CGPoint(x: port.x + sign * dx, y: port.y),
                     CGPoint(x: edge.x - sign * dx, y: edge.y),
                     edge], true)
        case .angular:
            let midX = (port.x + edge.x) / 2
            return ([port,
                     CGPoint(x: midX, y: port.y),
                     CGPoint(x: midX, y: edge.y),
                     edge], false)
        }
    }

    /// The stub line from an off-page connector's port to its card edge,
    /// following the card wherever stacking or dragging put it.
    private func drawStubLine(_ item: CableLayer.ResolvedStub,
                              in context: inout GraphicsContext,
                              color: Color, selected: Bool) {
        let route = Self.stubRoute(item, style: style)
        let viewPoints = route.points.map(transform)
        var line = Path()
        if route.isBezier {
            line.move(to: viewPoints[0])
            line.addCurve(to: viewPoints[3],
                          control1: viewPoints[1], control2: viewPoints[2])
        } else {
            line = Self.roundedPath(viewPoints,
                                    radius: Self.angularCornerRadius * zoom)
        }
        if selected {
            context.stroke(line, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 5 * zoom, lineCap: .round))
        }
        context.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .round))
        if !item.key.isSource {   // cable arrives INTO this input
            context.fill(arrowhead(at: transform(item.stub.port), pointing: 1),
                         with: .color(color))
        }
    }

    /// Where a collapsed connector end shows its nodule: just off the
    /// module edge at the port row, on the side the card would open.
    static func noduleCenter(_ stub: Stub) -> CGPoint {
        let sign: CGFloat = stub.tip.x >= stub.port.x ? 1 : -1
        return CGPoint(x: stub.port.x + sign * noduleOffset, y: stub.port.y)
    }
    static let noduleOffset: CGFloat = 12
    static let noduleRadius: CGFloat = 7

    /// The ✕ region of an expanded card, in world coordinates.
    static func closeRect(for card: CGRect) -> CGRect {
        CGRect(x: card.maxX - 18, y: card.minY + 4, width: 14, height: 14)
    }

    /// A collapsed off-page connector end: a dot in the far module's
    /// color (matching its LED in the minimap and card tiles), ringed
    /// in the cable's signal color. Clicking it opens the full card.
    private func drawNodule(_ item: CableLayer.ResolvedStub,
                            in context: inout GraphicsContext,
                            color: Color, selected: Bool) {
        let center = transform(Self.noduleCenter(item.stub))
        let r = Self.noduleRadius * zoom
        let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r,
                                            width: 2 * r, height: 2 * r))
        let farColor = document.module(item.stub.farModuleID).map { zoiaColor($0.colorID) }
            ?? .gray
        context.fill(circle, with: .color(farColor))
        context.stroke(circle, with: .color(selected ? .white : color),
                       lineWidth: (selected ? 2 : 1.2) * zoom)
    }

    /// An off-page connector's card: the far page's LED grid with the
    /// far module lit bright and everything else dimmed, the page name,
    /// and the far module · port. The grid mirrors the page bar's
    /// minimap so the two views cross-reference.
    private func drawStubCard(_ item: CableLayer.ResolvedStub,
                              in context: inout GraphicsContext,
                              color: Color, selected: Bool, showClose: Bool) {
        let stub = item.stub
        let card = CGRect(
            origin: transform(item.card.origin),
            size: CGSize(width: item.card.width * zoom, height: item.card.height * zoom))
        let shape = Path(roundedRect: card, cornerRadius: 6 * zoom)
        // Opaque backing first — the card must occlude cables running
        // underneath it, then take the cable-color tint.
        context.fill(shape, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.fill(shape, with: .color(color.opacity(selected ? 0.30 : 0.13)))
        context.stroke(shape, with: .color(color.opacity(0.7)),
                       lineWidth: selected ? 2 : 1)

        // Fixed internal layout in world units, scaled by zoom: LED tile
        // left, two text lines right, labels clipped to the text column.
        let pad = 6 * zoom
        let tileRect = CGRect(x: card.minX + pad, y: card.midY - 20 * zoom,
                              width: 64 * zoom, height: 40 * zoom)
        drawLEDGrid(&context, rect: tileRect,
                    modules: document.modules(onPage: stub.farPage),
                    catalog: document.catalog,
                    highlight: stub.farModuleID)

        let pageName = document.pageName(stub.farPage)
        let title = context.resolve(
            Text(clipped(pageName.isEmpty ? "page \(stub.farPage + 1)"
                                          : "\(stub.farPage + 1) · \(pageName)", to: 20))
                .font(.system(size: 10 * zoom, weight: .semibold))
                .foregroundStyle(.primary))
        let subtitle = context.resolve(
            Text(clipped(stub.label, to: 26))
                .font(.system(size: 9 * zoom)).foregroundStyle(color))
        let textX = tileRect.maxX + 8 * zoom
        context.draw(title, at: CGPoint(x: textX, y: card.minY + 19 * zoom),
                     anchor: .leading)
        context.draw(subtitle, at: CGPoint(x: textX, y: card.minY + 37 * zoom),
                     anchor: .leading)

        if showClose {
            let world = Self.closeRect(for: item.card)
            let box = CGRect(origin: transform(world.origin),
                             size: CGSize(width: world.width * zoom,
                                          height: world.height * zoom))
            var cross = Path()
            let inset = box.insetBy(dx: 4 * zoom, dy: 4 * zoom)
            cross.move(to: CGPoint(x: inset.minX, y: inset.minY))
            cross.addLine(to: CGPoint(x: inset.maxX, y: inset.maxY))
            cross.move(to: CGPoint(x: inset.maxX, y: inset.minY))
            cross.addLine(to: CGPoint(x: inset.minX, y: inset.maxY))
            context.stroke(cross, with: .color(.secondary),
                           style: StrokeStyle(lineWidth: 1.2 * zoom, lineCap: .round))
        }
    }

    private func clipped(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    private func cableColor(_ connection: CanvasConnection) -> Color {
        guard let source = document.module(connection.sourceModule) else { return .gray }
        let blocks = source.activeBlocks(in: document.catalog)
        let isAudio = blocks.first { ($0.position ?? -1) == connection.sourceBlock }?.type.isAudio ?? true
        return (isAudio ? Color.teal : Color.orange).opacity(0.8)
    }

    private func bezier(from: CGPoint, to: CGPoint) -> Path {
        var path = Path()
        let dx = max(abs(to.x - from.x) * 0.5, 30 * zoom)
        path.move(to: from)
        path.addCurve(to: to,
                      control1: CGPoint(x: from.x + dx, y: from.y),
                      control2: CGPoint(x: to.x - dx, y: to.y))
        return path
    }
}

/// Invisible AppKit view that reports its frame in window coordinates
/// (bottom-left origin) plus the window number — exactly what the scroll
/// monitor needs to scope itself to the editor. hitTest returns nil so
/// it never intercepts clicks.
private struct WindowFrameReader: NSViewRepresentable {
    @Binding var frame: CGRect
    @Binding var windowNumber: Int

    final class Reporter: NSView {
        var onChange: ((CGRect, Int) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() {
            super.layout()
            report()
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }
        private func report() {
            guard let window else { return }
            onChange?(convert(bounds, to: nil), window.windowNumber)
        }
    }

    func makeNSView(context: Context) -> Reporter {
        let view = Reporter()
        view.onChange = { newFrame, newNumber in
            // Defer past the current layout pass; direct writes here are
            // state mutation during view update.
            Task { @MainActor in
                frame = newFrame
                windowNumber = newNumber
            }
        }
        return view
    }

    func updateNSView(_ view: Reporter, context: Context) {}
}

/// The original dot-grid substrate, now parameterized.
struct DotGridBackground: View {
    let offset: CGSize
    let zoom: CGFloat
    private let dotSpacing: CGFloat = 24

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(nsColor: .underPageBackgroundColor)))
            let spacing = dotSpacing * zoom
            guard spacing > 4 else { return }
            let dotSize: CGFloat = 1.5 * zoom
            var x = offset.width.truncatingRemainder(dividingBy: spacing)
            while x < size.width {
                var y = offset.height.truncatingRemainder(dividingBy: spacing)
                while y < size.height {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x - dotSize / 2, y: y - dotSize / 2,
                                               width: dotSize, height: dotSize)),
                        with: .color(.secondary.opacity(0.35)))
                    y += spacing
                }
                x += spacing
            }
        }
    }
}
