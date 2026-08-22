import SwiftUI

/// The ONE product lookup screen.
///
/// # Why there is only one
///
/// iOS used to run two independent lookup pipelines. This one, and a second
/// inside the Chemical Store editor ("Search with AI") which called a different
/// server action and mapped the reply into the form's fields by hand — filling
/// `active_ingredient` and `chemical_group` as free text while leaving the
/// structured sql/194 chemistry completely empty. That is why a reviewed
/// product could show "No active ingredients recorded" and, two lines below,
/// "Recorded as text: Mancozeb · M5". Two pipelines, two answers, one screen.
///
/// So this view owns search and selection, and `ChemicalReviewMerge` owns
/// mapping. It never saves anything: it hands back a populated, unsaved
/// `SavedChemical` draft and lets its caller decide what that means — the Add
/// Chemical flow opens the editor on it, and the editor's own "Search again"
/// applies it to the session in place. One lookup, one merge, one shape of
/// result.
struct ChemicalProductSearchSheet: View {
    /// Seeds the search box.
    let initialQuery: String
    /// The record being re-identified, if any. Its id and operational data are
    /// preserved through the merge so a re-search corrects a product rather
    /// than replacing it with a stranger.
    let existing: SavedChemical?
    /// Receives the merged, unsaved draft. This view does NOT dismiss itself:
    /// the Add Chemical flow stays open to present the editor, while the
    /// editor's own "search again" closes it. The caller knows which.
    let onReviewed: (SavedChemical) -> Void
    /// Shown as "Enter Manually" when provided. Absent inside the editor,
    /// where the operator is already looking at the manual form.
    let onManualEntry: (() -> Void)?

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var rows: [ChemicalSearchRow] = []
    @State private var isSearching: Bool = false
    @State private var isResolving: Bool = false
    @State private var searchError: String?
    @State private var hasSeededQuery: Bool = false

    init(
        initialQuery: String = "",
        existing: SavedChemical? = nil,
        onManualEntry: (() -> Void)? = nil,
        onReviewed: @escaping (SavedChemical) -> Void
    ) {
        self.initialQuery = initialQuery
        self.existing = existing
        self.onManualEntry = onManualEntry
        self.onReviewed = onReviewed
    }

    /// Country comes from the vineyard profile. Product registration is
    /// country-scoped law, so a missing country fails closed rather than
    /// guessing a register.
    private var countryCode: String {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        )
    }

    var body: some View {
        NavigationStack {
            List {
                searchSection
                if let searchError { errorSection(searchError) }
                if isResolving {
                    Section {
                        HStack { ProgressView(); Text("Loading product details…") }
                    }
                }
                resultSections
                if let onManualEntry {
                    Section {
                        Button("Enter Manually") { onManualEntry() }
                    } footer: {
                        Text("Manually entered products stay Unverified until they are matched to a registered product.")
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add Chemical" : "Match & Verify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                // Once-guarded. `onAppear` fires again whenever this sheet
                // re-appears, and re-seeding would throw away whatever the
                // operator had retyped.
                guard !hasSeededQuery else { return }
                hasSeededQuery = true
                if query.isEmpty { query = initialQuery }
            }
        }
    }

    // MARK: - Sections

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Product name", text: $query)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await runSearch() } }
            }
            Button {
                Task { await runSearch() }
            } label: {
                if isSearching {
                    HStack { ProgressView(); Text("Searching…") }
                } else {
                    Text("Search")
                }
            }
            .disabled(
                query.trimmingCharacters(in: .whitespaces).isEmpty
                    || isSearching
                    || countryCode.isEmpty
            )
        } header: {
            Text("Search for product")
        } footer: {
            if countryCode.isEmpty {
                Text("Set your vineyard's country so products can be matched to the right national register.")
            } else {
                Text("Searching products registered in \(countryCode). An AU and an NZ product with the same name are different registrations.")
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(VineyardTheme.warning)
            Button("Try Again") { Task { await runSearch() } }
        }
    }

    /// One section per tier, so the ordering is visible rather than implied.
    @ViewBuilder
    private var resultSections: some View {
        ForEach(ChemicalSearchTier.allCases, id: \.rawValue) { tier in
            let tierRows = rows.filter { $0.tier == tier }
            if !tierRows.isEmpty {
                Section {
                    ForEach(tierRows) { row in
                        Button {
                            Task { await select(row) }
                        } label: {
                            resultRow(row)
                        }
                        .disabled(isResolving)
                    }
                } header: {
                    Text(tier.label)
                } footer: {
                    tierFooter(tier)
                }
            }
        }
    }

    @ViewBuilder
    private func tierFooter(_ tier: ChemicalSearchTier) -> some View {
        switch tier {
        case .alreadyInStore:
            Text("You already stock this product. Selecting it updates that record instead of creating a second copy.")
        case .approvedMaster:
            Text("Reviewed and approved for \(countryCode) in the VineTrack catalogue.")
        case .officialRegister:
            Text("Listed in the national register. Choose the one on your label — you'll review every detail before saving.")
        case .suggestion:
            Text("Not confirmed against the register. You can still use it: everything found is filled in for you to check against the label.")
        }
    }

    private func resultRow(_ row: ChemicalSearchRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.result.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                if row.isDuplicate {
                    Text("In store")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(VineyardTheme.leafGreen.opacity(0.14))
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .clipShape(Capsule())
                }
            }
            if !row.result.brand.isEmpty {
                Text(row.result.brand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !row.result.activeIngredient.isEmpty {
                Text(row.result.activeIngredient)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Actions

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            let results = try await ChemicalInfoService()
                .searchChemicals(query: trimmed, country: countryCode)
            rows = ChemicalSearchRanking.ordered(
                results: results,
                savedChemicals: store.savedChemicals,
                vineyardCountry: countryCode
            )
            if rows.isEmpty {
                searchError = "No products found. Try a different spelling, or enter the product manually."
            }
        } catch {
            // The typed query is deliberately left intact so a failed lookup
            // never costs the operator their input.
            rows = []
            searchError = (error as? LocalizedError)?.errorDescription
                ?? "Lookup is unavailable. Check your connection and try again."
        }
    }

    /// Resolve the selected product and hand back the merged draft.
    ///
    /// A structured-lookup failure does NOT dead-end here. The search row
    /// already carries a canonical name, a manufacturer and usually an active,
    /// and throwing that away because a second request failed is the same
    /// data-loss this flow exists to stop.
    private func select(_ row: ChemicalSearchRow) async {
        isResolving = true
        searchError = nil
        defer { isResolving = false }

        var lookup: ChemicalStructuredLookup?
        do {
            // The SELECTED candidate defines identity from here on — the typed
            // query ("Dithaine rainshield") is dead the moment an exact result
            // is chosen.
            lookup = try await ChemicalInfoService().lookupStructured(
                ChemicalStructuredLookupRequest(
                    selected: row.result,
                    country: countryCode,
                    fallbackQuery: query
                )
            )
        } catch {
            lookup = nil
        }

        // Jurisdiction rejection stays absolute: another country's rates, WHP
        // and re-entry statements are another country's law, and this is the
        // one case where populating the form would be worse than refusing.
        if let lookup,
           let reason = ChemicalJurisdiction.rejectionReason(for: lookup, requestCountry: countryCode) {
            searchError = reason
            return
        }

        onReviewed(ChemicalReviewMerge.reviewChemical(
            lookup: lookup,
            selected: row.result,
            // Selecting a row that matches something already in the store
            // corrects THAT record rather than creating a duplicate.
            existing: existing ?? row.existing,
            countryCode: countryCode,
            vineyardId: store.selectedVineyard?.id ?? UUID()
        ))
    }
}
