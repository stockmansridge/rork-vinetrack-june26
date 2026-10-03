import SwiftUI

/// Linked revision is display-only; never copied into saved_chemicals.
struct CatalogueSavedChemicalView: View {
    let chemical: SavedChemical
    var showsDetails: Bool = false
    @State private var revision: CatalogueWire?
    @State private var frontLabelPath: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                CatalogueLabelView(path: frontLabelPath, labelURL: revision?.text("manufacturer_label_url"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(revision?.text("product_name") ?? chemical.name).font(.headline)
                    Text(CatalogueWire.compactManufacturer(revision?.text("manufacturer") ?? chemical.manufacturer)).font(.caption)
                    if let revision { Text(revision.badge).font(.caption).foregroundStyle(.secondary) }
                    else { Text("Catalogue information unavailable").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let revision {
                if !revision.targets.isEmpty { Text("Used for: " + revision.targets.joined(separator: " · ")).font(.caption) }
                if !revision.groupText.isEmpty { Text(revision.groupText).font(.caption.weight(.semibold)) }
                if showsDetails { CatalogueRevisionDetailsView(revision: revision) }
            } else {
                let group = CatalogueWire.resistanceText(scheme: chemical.backendActivityGroupScheme, codes: chemical.backendActivityGroups)
                if !group.isEmpty { Text(group).font(.caption) }
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
