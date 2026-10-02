import SwiftUI

/// Linked revision is display-only; never copied into saved_chemicals.
struct CatalogueSavedChemicalView: View {
    let chemical: SavedChemical
    @State private var revision: CatalogueWire?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CatalogueLabelView(path: revision?.text("front_label_image_path"), labelURL: chemical.labelURL.isEmpty ? revision?.text("manufacturer_label_url") : chemical.labelURL)
                VStack(alignment: .leading) {
                    Text(chemical.name).font(.headline)
                    Text(CatalogueWire.compactManufacturer(chemical.manufacturer)).font(.caption)
                    Text(revision?.badge ?? "VineTrack catalogue").font(.caption)
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
            if let id = chemical.chemicalV3RevisionId { revision = try? await CatalogueRepository().revision(id.uuidString) }
        }
    }
}
