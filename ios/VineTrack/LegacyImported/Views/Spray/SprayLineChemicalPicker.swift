import SwiftUI

/// Picks the exact Saved Chemical a manually entered spray line refers to.
///
/// The point of this screen is to remove name guessing from the manual spray
/// form. Once the operator taps a product here, the line carries that product's
/// IDENTIFIER, and the snapshot captured at save time is the chemistry of the
/// product they actually chose — not of whichever library entry happened to have
/// a similar name.
///
/// Three ways out, in the order an operator should want them: pick the product,
/// CREATE it, or record it unresolved.
///
/// Creating is here rather than in the Chemical Store because "the product
/// isn't in the list" happens mid-task, and sending someone to another screen
/// to fix it means abandoning whatever they were entering. It launches the
/// EXISTING Add Chemical form — same fields, same validation, same Chemical
/// Intelligence, same persistence — and hands the result straight back, so the
/// operator never creates a product and then has to go find it.
///
/// The unresolved escape hatch stays. A grower spraying something that is not in
/// their store yet must still be able to record the application, so it remains a
/// first-class option rather than a failure state — but it is no longer the only
/// alternative when a search finds nothing.
struct SprayLineChemicalPicker: View {
    /// The product currently bound to the line, so it can be shown as selected.
    let selectedId: UUID?
    /// Called with the chosen product, or `nil` for an explicit manual entry.
    let onSelect: (SavedChemical?) -> Void

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var isCreatingChemical: Bool = false

    /// Creating a product writes to the vineyard-shared Chemical Store, so it
    /// carries the same permission that store already enforces. Nothing is
    /// widened here.
    private var canCreateChemical: Bool { accessControl?.canManageSetup ?? false }

    /// The vineyard's jurisdiction, for marking foreign-registered products.
    /// Display only — selection stays possible; the mark prevents a foreign
    /// label silently reading as valid guidance for this vineyard's sprays.
    private var vineyardCountry: String {
        ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
    }

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

                if canCreateChemical {
                    Section {
                        Button {
                            isCreatingChemical = true
                        } label: {
                            Label("Add New Chemical", systemImage: "plus.circle.fill")
                                .font(.body.weight(.semibold))
                        }
                    } footer: {
                        Text("Opens the full Add Chemical form. Saving brings you straight back here with the new product selected.")
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
            .sheet(isPresented: $isCreatingChemical) {
                // THE existing Add Chemical flow, not a copy of it: search the
                // register, review what was found in the Chemical Store editor,
                // save. Seeded with whatever the operator already typed here, so
                // they do not retype the product name they just searched for.
                //
                // Cancelling closes only this sheet, so whatever sent the
                // operator here — a half-edited Program Step, a spray being
                // recorded — is still sitting underneath, untouched.
                ChemicalMatchFlowView(
                    prefillQuery: query.trimmingCharacters(in: .whitespacesAndNewlines)
                ) { created in
                    // Bound by Saved Chemical ID, never by name.
                    onSelect(created)
                    dismiss()
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
                // Foreign-registered products stay pickable — chemistry is what
                // resistance tracking needs — but their label facts are marked
                // as another jurisdiction's, never this vineyard's guidance.
                if case .mismatch(let registration, let vineyard) = ChemicalJurisdiction.suitability(
                    for: chemical, vineyardCountry: vineyardCountry
                ) {
                    ChemicalJurisdictionChip(
                        registrationCountry: registration,
                        vineyardCountry: vineyard
                    )
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
