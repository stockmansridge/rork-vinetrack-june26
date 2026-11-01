import SwiftUI

/// Live current APPROVED catalogue facts for a vineyard-linked chemical.
/// Historical spray records, vineyard preferences, pending writes and the
/// saved chemical's pinned revision/identity are never modified by this view.
struct CatalogueSavedChemicalView: View {
    let chemical: SavedChemical
    var showsDetails: Bool = false

    @State private var revision: CatalogueWire?
    @State private var frontLabelPath: String?
    @State private var isCurrentApproved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                CatalogueLabelView(path: frontLabelPath, labelURL: revision?.text("manufacturer_label_url"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(revision?.text("product_name") ?? chemical.name).font(.headline)
                    Text(CatalogueWire.compactManufacturer(
                        revision?.text("manufacturer") ?? chemical.manufacturer
                    )).font(.caption)
                    if isCurrentApproved {
                        Label("VineTrack catalogue · automatically updated", systemImage: "checkmark.seal")
                            .font(.caption).foregroundStyle(.green)
                    } else if let revision {
                        Text(revision.badge).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Catalogue information unavailable; showing saved details")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let revision {
                if !revision.targets.isEmpty {
                    Text("Used for: " + revision.targets.joined(separator: " · ")).font(.caption)
                }
                if !revision.groupText.isEmpty {
                    Text(revision.groupText).font(.caption.weight(.semibold))
                }
                if showsDetails {
                    CatalogueRevisionDetailsView(revision: revision)
                    Text("Label rates are references, not a chosen dose. Apply the current label and conditions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                let group = CatalogueWire.resistanceText(
                    scheme: chemical.backendActivityGroupScheme,
                    codes: chemical.backendActivityGroups
                )
                if !group.isEmpty { Text(group).font(.caption) }
            }
        }
        // A refreshed effective chemical may have new label rates while the
        // SAVED revision pointer remains unchanged. Track the entire chemical,
        // not just that pinned revision, to re-read the latest approved master.
        .task(id: chemical) {
            revision = nil
            frontLabelPath = nil
            isCurrentApproved = false
            let repository = CatalogueRepository()
            var resolved: CatalogueWire?
            var approved = false

            if let productId = chemical.chemicalV3ProductId,
               let revisionId = try? await repository.approvedRevisionId(productId: productId),
               let current = try? await repository.revision(revisionId),
               current.text("review_status") == "approved",
               current.text("product_id")?.lowercased() == productId.uuidString.lowercased() {
                resolved = current
                approved = true
            }

            // Offline/unknown approval: never manufacture a newer revision or
            // downgrade a known saved label. Retain pinned facts if readable.
            if resolved == nil, let pinnedId = chemical.chemicalV3RevisionId {
                resolved = try? await repository.revision(pinnedId.uuidString)
            }
            guard !Task.isCancelled else { return }
            revision = resolved
            isCurrentApproved = approved
            if let resolved {
                let path = try? await repository.resolvedFrontLabelPath(for: resolved)
                guard !Task.isCancelled else { return }
                frontLabelPath = path
            }
        }
    }
}
