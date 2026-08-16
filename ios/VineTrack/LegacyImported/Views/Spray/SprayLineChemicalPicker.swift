import SwiftUI

/// Picks the exact Saved Chemical a manually entered spray line refers to.
///
/// The point of this screen is to remove name guessing from the manual spray
/// form. Once the operator taps a product here, the line carries that product's
/// IDENTIFIER, and the snapshot captured at save time is the chemistry of the
/// product they actually chose — not of whichever library entry happened to have
/// a similar name.
///
/// It also keeps the honest escape hatch. A grower spraying something that is not
/// in their store yet must still be able to record the application, so "enter it
/// manually" is a first-class option rather than a failure state.
struct SprayLineChemicalPicker: View {
    /// The product currently bound to the line, so it can be shown as selected.
    let selectedId: UUID?
    /// Called with the chosen product, or `nil` for an explicit manual entry.
    let onSelect: (SavedChemical?) -> Void

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""

    /// Active products for the selected vineyard, plus whatever is already bound
    /// even if it has since been archived — a line must not silently lose its
    /// product because the store was tidied up.
    private var candidates: [SavedChemical] {
        let all = store.savedChemicals.filter { $0.isActive || $0.id == selectedId }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return all.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        // Search is a FILTER for the human, never an identity decision: it
        // narrows what is shown, and only an explicit tap binds a product.
        return all
            .filter {
                $0.name.localizedStandardContains(trimmed)
                    || $0.activeIngredient.localizedStandardContains(trimmed)
                    || $0.manufacturer.localizedStandardContains(trimmed)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Section {
                        ContentUnavailableView(
                            query.isEmpty ? "No chemicals yet" : "No matches",
                            systemImage: "flask",
                            description: Text(
                                query.isEmpty
                                    ? "Add products to your Chemical Store to track resistance across your sprays."
                                    : "No product in your Chemical Store matches that search."
                            )
                        )
                    }
                } else {
                    Section {
                        ForEach(candidates) { chemical in
                            Button {
                                onSelect(chemical)
                                dismiss()
                            } label: {
                                row(chemical)
                            }
                        }
                    } header: {
                        Text("Chemical Store")
                    } footer: {
                        Text("The product you pick is recorded by its Chemical Store record, so its activity groups are frozen onto this spray.")
                    }
                }

                Section {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        Label("Product not in Chemical Store", systemImage: "square.and.pencil")
                    }
                } footer: {
                    // Not a warning, a statement. Recording the spray matters
                    // more than knowing its chemistry, but the operator should
                    // know what they are trading away.
                    Text("Type the product name on the record instead. The application is kept in full, but its chemistry cannot be assessed for resistance until the product is added to your Chemical Store.")
                }
            }
            .searchable(text: $query, prompt: "Search your Chemical Store")
            .navigationTitle("Select Chemical")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ chemical: SavedChemical) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(chemical.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if !chemical.activeIngredient.isEmpty {
                    Text(chemical.activeIngredient)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    ChemicalVerificationBadge(status: chemical.verificationStatus)
                    let codes = chemical.activityGroupCodes
                    if !codes.isEmpty {
                        Text(codes.joined(separator: " + "))
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(VineyardTheme.olive.opacity(0.12))
                            .foregroundStyle(VineyardTheme.olive)
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer()
            if chemical.id == selectedId {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(VineyardTheme.success)
            }
        }
    }
}
