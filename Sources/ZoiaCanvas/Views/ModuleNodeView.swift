import SwiftUI

/// Geometry shared by the node view and the cable layer so port anchors
/// line up exactly.
enum NodeMetrics {
    static let width: CGFloat = 170
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 20
    static let portRadius: CGFloat = 5

    static func height(blockCount: Int) -> CGFloat {
        headerHeight + CGFloat(max(blockCount, 1)) * rowHeight + 8
    }

    /// Port anchor in world coordinates. Inputs sit on the left edge,
    /// outputs on the right.
    static func portAnchor(nodeOrigin: CGPoint, rowIndex: Int, isOutput: Bool) -> CGPoint {
        CGPoint(
            x: nodeOrigin.x + (isOutput ? width : 0),
            y: nodeOrigin.y + headerHeight + CGFloat(rowIndex) * rowHeight + rowHeight / 2)
    }
}

/// The ZOIA header colors, code 1–15 in device order.
func zoiaColor(_ code: Int) -> Color {
    switch code {
    case 1: .blue
    case 2: .green
    case 3: .red
    case 4: .yellow
    case 5: .cyan
    case 6: Color(red: 1, green: 0, blue: 1)
    case 7: .white
    case 8: .orange
    case 9: Color(red: 0.7, green: 1, blue: 0.3)
    case 10: Color(red: 0.2, green: 0.9, blue: 0.7)
    case 11: Color(red: 0.4, green: 0.7, blue: 1)
    case 12: .purple
    case 13: .pink
    case 14: Color(red: 1, green: 0.75, blue: 0.6)
    case 15: Color(red: 1, green: 0.65, blue: 0.2)
    default: .gray
    }
}

struct ModuleNodeView: View {
    let module: CanvasModule
    let spec: ModuleSpec?
    let blocks: [BlockSpec]
    let isSelected: Bool

    var title: String {
        module.customName.isEmpty ? (spec?.name ?? "Module \(module.typeID)") : module.customName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(zoiaColor(module.colorID))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: NodeMetrics.headerHeight)
            .background(.quaternary)

            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                HStack(spacing: 4) {
                    if !block.type.isOutput {
                        PortDot(type: block.type)
                    }
                    Text(block.key)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity,
                               alignment: block.type.isOutput ? .trailing : .leading)
                    if block.type.isOutput {
                        PortDot(type: block.type)
                    }
                }
                .padding(.horizontal, 3)
                .frame(height: NodeMetrics.rowHeight)
            }
            Spacer(minLength: 8)
        }
        .frame(width: NodeMetrics.width,
               height: NodeMetrics.height(blockCount: blocks.count))
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4),
                        lineWidth: isSelected ? 2 : 1))
        .shadow(radius: 3, y: 1)
    }
}

struct PortDot: View {
    let type: PortType

    var body: some View {
        Circle()
            .fill(type.isAudio ? Color.teal : Color.orange)
            .frame(width: NodeMetrics.portRadius * 2, height: NodeMetrics.portRadius * 2)
    }
}
