import SwiftUI

/// Searchable module list, grouped by category. Clicking a module adds it
/// to the document.
struct PaletteView: View {
    let catalog: ModuleCatalog
    let onAdd: (Int) -> Void

    @State private var searchText = ""

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
            List {
                ForEach(grouped, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.modules) { spec in
                            Button {
                                onAdd(spec.id)
                            } label: {
                                HStack {
                                    Text(spec.name)
                                        .font(.system(size: 12))
                                    Spacer()
                                    Text(String(format: "%.1f%%", spec.cpu))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(spec.doc?.description ?? spec.name)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 190, maxWidth: 240)
    }
}
