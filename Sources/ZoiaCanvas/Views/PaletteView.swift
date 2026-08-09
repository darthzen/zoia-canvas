import SwiftUI

/// Scratch-style module palette: collapsible category sections, every row
/// a solid block in its category color, matching the nodes they become on
/// the canvas. Clicking adds a module; dragging places it under the cursor.
struct PaletteView: View {
    let catalog: ModuleCatalog
    let onAdd: (Int) -> Void

    @State private var searchText = ""
    @State private var collapsed: Set<String> = []

    private var grouped: [(category: String, modules: [ModuleSpec])] {
        let visible = catalog.modules.filter {
            searchText.isEmpty
                || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.category.localizedCaseInsensitiveContains(searchText)
        }
        return Dictionary(grouping: visible, by: \.category)
            .map { (category: $0.key, modules: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search modules", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(grouped, id: \.category) { group in
                        section(group)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(minWidth: 190, maxWidth: 240)
    }

    private func isExpanded(_ category: String) -> Bool {
        !searchText.isEmpty || !collapsed.contains(category)
    }

    @ViewBuilder
    private func section(_ group: (category: String, modules: [ModuleSpec])) -> some View {
        let style = categoryStyle(group.category)
        Button {
            if collapsed.contains(group.category) {
                collapsed.remove(group.category)
            } else {
                collapsed.insert(group.category)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded(group.category) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                Text(group.category)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(group.modules.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundStyle(style.text)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(style.header)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)

        if isExpanded(group.category) {
            ForEach(group.modules) { spec in
                moduleRow(spec, style: style)
            }
        }
    }

    private func moduleRow(_ spec: ModuleSpec, style: CategoryStyle) -> some View {
        Button {
            onAdd(spec.id)
        } label: {
            HStack {
                Text(spec.name)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(String(format: "%.1f%%", spec.cpu))
                    .font(.system(size: 9, design: .monospaced))
                    .opacity(0.65)
            }
            .foregroundStyle(style.text)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(style.fill)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(style.border, lineWidth: 1))
            .padding(.leading, 10)
        }
        .buttonStyle(.plain)
        .help(spec.doc?.description ?? spec.name)
        .onDrag {
            NSItemProvider(object: "zoia-module:\(spec.id)" as NSString)
        }
    }
}
