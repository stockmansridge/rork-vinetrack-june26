import SwiftUI

/// Add a chemical: **Search → Select → Review → Save**.
///
/// # Why this is three steps and not six
///
/// This flow used to run Search → Matched Product → Verify Chemical → Confirm,
/// with a warning on most of them. For the ordinary case that was four screens
/// to answer one question — "is this the product on my drum?" — and, worse, the
/// middle screens were READ-ONLY. When the resolver could not confirm a
/// registration it reported "no active ingredients were identified", the
/// operator could see Mancozeb on the search screen behind it, and there was
/// nothing they could do about it.
///
/// So the wizard is now a search screen that hands straight to the existing
/// Chemical Store editor, pre-populated with everything the lookup found. The
/// operator reviews real values, corrects anything wrong, and saves. Confirming
/// a product is an act of editing it, not an act of clicking through warnings
/// about it.
///
/// Trust rules are untouched: `ChemicalReviewMerge` writes lookup-derived values
/// with `ai_interpretation` provenance, so a product whose identity was not
/// confirmed still saves Unverified — with its chemistry present and editable.
/// Populating a field and trusting a field remain different things.
struct ChemicalMatchFlowView: View {
    /// Existing chemical being matched (legacy `needs_match` cleanup), or nil
    /// when adding something new.
    let existing: SavedChemical?
    /// Seeds the search box, so "Match & Verify" on a legacy record starts from
    /// the name the grower already uses.
    let prefillQuery: String
    /// Hands the persisted product back to whatever opened this flow — the
    /// Spray Program's product line, for instance, which binds it by id.
    let onSaved: ((SavedChemical) -> Void)?

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @State private var results: [ChemicalSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String?

    @State private var isLoadingProduct: Bool = false
    /// The populated, unsaved record under review. Presenting it IS the match
    /// step — there is no separate read-only confirmation of it.
    @State private var reviewDraft: SavedChemical?
    @State private var showManualEntry: Bool = false

    init(
        existing: SavedChemical? = nil,
        prefillQuery: String = "",
        onSaved: ((SavedChemical) -> Void)? = nil
    ) {
        self.existing = existing
        self.prefillQuery = prefillQuery
        self.onSaved = onSaved
    }

    /// Country comes from the vineyard profile. The operator already told
    /// VineTrack where they farm; asking again on every lookup would be both
    /// annoying and a chance to get it wrong, and country is part of product
    /// identity rather than a search preference.
    private var countryCode: String {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        )
    }

    var body: some View {
        NavigationStack {
            searchStep
                .navigationTitle(existing == nil ? "Add Chemical" : "Match & Verify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .sheet(isPresented: $showManualEntry) {
                    // Manual entry is the same editor with nothing prefilled.
                    EditSavedChemicalSheet(chemical: existing) { saved in
                        onSaved?(saved)
                        dismiss()
                    }
                }
                .sheet(item: $reviewDraft) { draft in
                    // THE Chemical Store editor, opened on the merged draft.
                    // `chemical:` stays the record being matched (nil when
                    // adding) so Save still takes the right create/update path;
                    // `prefill:` is what to show. Same screen, same Save.
                    EditSavedChemicalSheet(
                        chemical: existing,
                        prefill: draft
                    ) { saved in
                        onSaved?(saved)
                        dismiss()
                    }
                }
        }
        .onAppear {
            if query.isEmpty { query = prefillQuery }
        }
    }

    // MARK: - Search

    private var searchStep: some View {
        List {
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
                // No vineyard country -> no jurisdiction -> fail closed. The
                // footer below tells the operator what to set; searching a
                // guessed national register would verify the wrong label.
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching || countryCode.isEmpty)
            } header: {
                Text("Search for product")
            } footer: {
                if countryCode.isEmpty {
                    Text("Set your vineyard's country so products can be matched to the right national register.")
                } else {
                    Text("Searching products registered in \(countryCode). An AU and an NZ product with the same name are different registrations.")
                }
            }

            if let searchError {
                Section {
                    Label(searchError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.warning)
                    Button("Try Again") { Task { await runSearch() } }
                    Button("Enter Manually") { showManualEntry = true }
                }
            }

            if isLoadingProduct {
                Section {
                    HStack { ProgressView(); Text("Loading product details…") }
                }
            }

            if !results.isEmpty {
                Section {
                    ForEach(results) { result in
                        Button {
                            Task { await review(result) }
                        } label: {
                            searchResultRow(result)
                        }
                        .disabled(isLoadingProduct)
                    }
                } header: {
                    Text("Select the exact product")
                } footer: {
                    // A name match is a lead, not an identification.
                    Text("Product names repeat across manufacturers and countries. Choose the one on your label — you'll review every detail before saving.")
                }
            }

            Section {
                Button("Enter Manually") { showManualEntry = true }
            } footer: {
                Text("Manually entered products stay Unverified until they are matched to a registered product.")
            }
        }
    }

    private func searchResultRow(_ result: ChemicalSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.name)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
            if !result.brand.isEmpty {
                Text(result.brand)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if !countryCode.isEmpty {
                    tag(countryCode, tint: VineyardTheme.info)
                }
                if !result.primaryUse.isEmpty {
                    tag(result.primaryUse, tint: VineyardTheme.olive)
                }
            }
            if !result.activeIngredient.isEmpty {
                Text(result.activeIngredient)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    // MARK: - Actions

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await ChemicalInfoService()
                .searchChemicals(query: trimmed, country: countryCode)
            if results.isEmpty {
                searchError = "No products found. Try a different spelling, or enter the product manually."
            }
        } catch {
            // The typed query is deliberately left intact so a failed lookup
            // never costs the operator their input.
            results = []
            searchError = (error as? LocalizedError)?.errorDescription
                ?? "Lookup is unavailable. Check your connection and try again."
        }
    }

    /// Resolve the selected product and open it for review.
    ///
    /// A structured-lookup failure does NOT dead-end here. The search row
    /// already carries a canonical name, a manufacturer and usually an active,
    /// and throwing that away because a second request failed is the same
    /// data-loss this flow exists to stop. The draft opens with what is known
    /// and saves as Unverified, which is exactly what it is.
    private func review(_ result: ChemicalSearchResult) async {
        isLoadingProduct = true
        searchError = nil
        defer { isLoadingProduct = false }

        var lookup: ChemicalStructuredLookup?
        do {
            // The SELECTED candidate defines identity from here on — the typed
            // query ("Dithaine rainshield") is dead the moment an exact result
            // is chosen. A register candidate's number rides along as a pointer
            // so the resolver verifies THAT exact identity.
            lookup = try await ChemicalInfoService().lookupStructured(
                ChemicalStructuredLookupRequest(
                    selected: result,
                    country: countryCode,
                    fallbackQuery: query
                )
            )
        } catch {
            lookup = nil
        }

        // Jurisdiction gate, unchanged and still absolute: a product registered
        // in another country is refused OUTRIGHT. Its rates, WHP and re-entry
        // statements are another jurisdiction's law and must never become
        // saveable here — this is the one case where populating the form would
        // be worse than refusing it.
        if let lookup,
           let reason = ChemicalJurisdiction.rejectionReason(for: lookup, requestCountry: countryCode) {
            searchError = reason
            return
        }

        reviewDraft = ChemicalReviewMerge.reviewChemical(
            lookup: lookup,
            selected: result,
            existing: existing,
            countryCode: countryCode,
            vineyardId: store.selectedVineyard?.id ?? UUID()
        )
    }
}
