import SwiftUI

/// Linked revision is display-only; never copied into saved_chemicals.
struct CatalogueSavedChemicalView: View {
    let chemical: SavedChemical
    @State private var revision: CatalogueWire?
    @State private var frontLabelPath: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CatalogueLabelView(path: frontLabelPath, labelURL: revision?.text("manufacturer_label_url") ?? (chemical.labelURL.isEmpty ? nil : chemical.labelURL))
                VStack(alignment: .leading) {
                    Text(chemical.name).font(.headline)
                    Text(CatalogueWire.compactManufacturer(chemical.manufacturer)).font(.caption)
                    if let revision { Text(revision.badge).font(.caption) }
                    else if chemical.chemicalV3RevisionId != nil { Text("Catalogue information unavailable").font(.caption) }
                    Text(revision?.groupText ?? [chemical.backendActivityGroupScheme?.uppercased() ?? "", chemical.backendActivityGroups.joined(separator: " + ")].filter { !$0.isEmpty }.joined(separator: " "))
                }
            }
            if let revision {
                Text("Used for: " + revision.targets.joined(separator: " · ")).font(.caption)
                if let url = revision.text("manufacturer_product_url"), let link = URL(string: url), link.scheme == "https" { Link("Manufacturer product", destination: link) }
                Text(chemical.manufacturer).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: chemical.chemicalV3RevisionId) {
            revision = nil
            frontLabelPath = nil
            guard let id = chemical.chemicalV3RevisionId else { return }
            let repository = CatalogueRepository()
            guard let exactRevision = try? await repository.revision(id.uuidString), !Task.isCancelled else { return }
            revision = exactRevision
            let path = try? await repository.resolvedFrontLabelPath(for: exactRevision)
            guard !Task.isCancelled else { return }
            frontLabelPath = path
        }
    }
}
