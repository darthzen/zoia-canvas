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

    /// Input anchor on the RIGHT edge, for cables whose source sits to
    /// the right of the destination: entering the row from the right
    /// with an arrowhead beats looping around the node's left side.
    static func inputAnchorRight(nodeOrigin: CGPoint, rowIndex: Int) -> CGPoint {
        CGPoint(
            x: nodeOrigin.x + width,
            y: nodeOrigin.y + headerHeight + CGFloat(rowIndex) * rowHeight + rowHeight / 2)
    }
}

/// Category colors lifted from Empress's fw5 module-index spreadsheet
/// section fills (extracted from the sheet's xlsx export 2026-08-08).
/// zoia_lib's "CV" category corresponds to Empress's "Control Modules".
/// Styled Scratch-fashion: the pastel is the block fill, a darkened shade
/// is the header/border, and text stays dark for contrast.
struct CategoryStyle {
    let fill: Color
    let header: Color
    let border: Color
    let text: Color

    init(r: Double, g: Double, b: Double) {
        fill = Color(red: r, green: g, blue: b)
        header = Color(red: r * 0.78, green: g * 0.78, blue: b * 0.78)
        border = Color(red: r * 0.55, green: g * 0.55, blue: b * 0.55)
        text = Color(red: 0.11, green: 0.11, blue: 0.13)
    }
}

func categoryStyle(_ category: String) -> CategoryStyle {
    switch category {
    case "Interface": CategoryStyle(r: 0xB8 / 255, g: 0xCC / 255, b: 0xE4 / 255)
    case "Audio": CategoryStyle(r: 0xE5 / 255, g: 0xB8 / 255, b: 0xB7 / 255)
    case "CV": CategoryStyle(r: 0xD6 / 255, g: 0xE3 / 255, b: 0xBC / 255)
    case "Analysis": CategoryStyle(r: 0xB4 / 255, g: 0xA7 / 255, b: 0xD6 / 255)
    case "Effect": CategoryStyle(r: 0xFF / 255, g: 0xE5 / 255, b: 0x99 / 255)
    default: CategoryStyle(r: 0.6, g: 0.6, b: 0.6)
    }
}

func categoryColor(_ category: String) -> Color {
    categoryStyle(category).fill
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
        let style = categoryStyle(spec?.category ?? "")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(zoiaColor(module.colorID))
                    .overlay(Circle().stroke(style.border, lineWidth: 1))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(style.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: NodeMetrics.headerHeight)
            .background(style.header)

            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                HStack(spacing: 4) {
                    if !block.type.isOutput {
                        PortDot(type: block.type)
                    }
                    Text(block.key)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(style.text.opacity(0.8))
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
        .background(style.fill)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : style.border,
                        lineWidth: isSelected ? 2.5 : 1.5))
        .shadow(radius: 3, y: 1)
    }
}

struct PortDot: View {
    let type: PortType

    var body: some View {
        Circle()
            .fill(type.isAudio ? Color.teal : Color.orange)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            .frame(width: NodeMetrics.portRadius * 2, height: NodeMetrics.portRadius * 2)
    }
}
