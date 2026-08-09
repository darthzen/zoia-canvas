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

    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize = .zero
    @State private var zoom: CGFloat = 1.0
    @State private var pendingCable: PendingCable?
    @State private var draggedModule: (id: UUID, start: CGPoint)?
    @State private var selectedCable: UUID?
    @State private var renamingPage: Int?
    @State private var renameText = ""

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                DotGridBackground(offset: offset, zoom: zoom)
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    CableLayer(document: document,
                               pending: pendingCableSegments(),
                               selectedCable: selectedCable,
                               offset: offset, zoom: zoom,
                               time: timeline.date.timeIntervalSinceReferenceDate)
                }
                nodes
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(MagnifyGesture().onChanged { zoom = min(max($0.magnification, 0.25), 3) })
            .onTapGesture { location in
                selection = nil
                selectedCable = cableHit(at: toWorld(location))
            }
            .onDrop(of: [.plainText], isTargeted: nil) { providers, location in
                dropModule(providers: providers, at: toWorld(location))
            }
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

    private var pageBar: some View {
        HStack(spacing: 4) {
            ForEach(0..<document.pageCount, id: \.self) { page in
                let name = document.pageName(page)
                Button {
                    jump(to: page)
                } label: {
                    Text(name.isEmpty ? "\(page + 1)" : "\(page + 1) · \(name)")
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(currentPage == page ? Color.accentColor.opacity(0.3) : .clear,
                                    in: Capsule())
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

    /// The page band nearest the viewport's left edge — highlight only.
    private var currentPage: Int {
        let page = Int(((-offset.width / zoom + PatchDocument.pageStride / 2)
                        / PatchDocument.pageStride).rounded(.down))
        return min(max(page, 0), document.pageCount - 1)
    }

    private func jump(to page: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            offset.width = 40 * zoom - CGFloat(page) * PatchDocument.pageStride * zoom
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
            .scaleEffect(zoom, anchor: .topLeading)
            .position(nodeCenter(module, blockCount: blocks.count))
            .onTapGesture {
                selection = module.id
                selectedCable = nil
            }
            .gesture(nodeGesture(module, blocks: blocks))
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

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = CGSize(width: panStart.width + value.translation.width,
                                height: panStart.height + value.translation.height)
            }
            .onEnded { _ in panStart = offset }
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

    // MARK: - Cable hit testing (world coordinates)

    /// The cable nearest the tap, within a constant ~12pt screen radius.
    /// Distance to a cable is the minimum over sampled points of its
    /// bezier — cheap, runs only on tap, and 24 samples stay well inside
    /// the radius for the curvature these cables can reach.
    private func cableHit(at world: CGPoint) -> UUID? {
        let radius = 12 / zoom
        var best: (id: UUID, distance: CGFloat)?
        for connection in document.connections {
            guard let (from, to) = CableLayer.worldEndpoints(connection, in: document)
            else { continue }
            let dx = max(abs(to.x - from.x) * 0.5, 30)
            let c1 = CGPoint(x: from.x + dx, y: from.y)
            let c2 = CGPoint(x: to.x - dx, y: to.y)
            for i in 0...24 {
                let t = CGFloat(i) / 24
                let u = 1 - t
                let x = u * u * u * from.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * to.x
                let y = u * u * u * from.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * to.y
                let distance = hypot(x - world.x, y - world.y)
                if distance <= radius, distance < (best?.distance ?? .infinity) {
                    best = (connection.id, distance)
                }
            }
        }
        return best?.id
    }
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
    let offset: CGSize
    let zoom: CGFloat
    /// Drives the flow animation; connection strength scales its speed and
    /// brightness. When the audio engine exists this will modulate off live
    /// signal instead.
    let time: TimeInterval

    var body: some View {
        Canvas { context, _ in
            for connection in document.connections {
                guard let path = cablePath(connection) else { continue }
                let color = cableColor(connection)
                let strength = min(max(Double(connection.strengthRaw) / 10000, 0), 1)

                // Selection halo under everything else on the cable.
                if connection.id == selectedCable {
                    context.stroke(path, with: .color(.white.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 5 * zoom, lineCap: .round))
                }
                // Glow underlay, then the cable body.
                context.stroke(path, with: .color(color.opacity(0.25)),
                               style: StrokeStyle(lineWidth: 6 * zoom, lineCap: .round))
                context.stroke(path, with: .color(color),
                               style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .round))

                // Bespoke-style energy flow: bright dashes marching from
                // output to input. Phase decreases so motion runs with the
                // path direction (source → destination).
                let speed = (40 + 80 * strength) * zoom
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.25 + 0.5 * strength)),
                    style: StrokeStyle(
                        lineWidth: 2.2 * zoom, lineCap: .round,
                        dash: [3 * zoom, 13 * zoom],
                        dashPhase: -CGFloat(time.truncatingRemainder(dividingBy: 3600)) * speed))
            }
            if let pending {
                let path = bezier(from: transform(pending.from), to: transform(pending.to))
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

    /// Both cable endpoints in world coordinates — shared with the
    /// editor's cable hit testing so selection and drawing agree.
    static func worldEndpoints(_ connection: CanvasConnection,
                               in document: PatchDocument) -> (from: CGPoint, to: CGPoint)? {
        func anchor(module: CanvasModule, blockPosition: Int, wantOutput: Bool) -> CGPoint? {
            let blocks = module.activeBlocks(in: document.catalog)
            for (row, block) in blocks.enumerated()
            where (block.position ?? row) == blockPosition && block.type.isOutput == wantOutput {
                return NodeMetrics.portAnchor(
                    nodeOrigin: module.canvasPosition, rowIndex: row, isOutput: wantOutput)
            }
            return nil
        }
        guard let source = document.module(connection.sourceModule),
              let dest = document.module(connection.destModule),
              let from = anchor(module: source, blockPosition: connection.sourceBlock, wantOutput: true),
              let to = anchor(module: dest, blockPosition: connection.destBlock, wantOutput: false)
        else { return nil }
        return (from, to)
    }

    private func cablePath(_ connection: CanvasConnection) -> Path? {
        guard let (from, to) = Self.worldEndpoints(connection, in: document) else { return nil }
        return bezier(from: transform(from), to: transform(to))
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
