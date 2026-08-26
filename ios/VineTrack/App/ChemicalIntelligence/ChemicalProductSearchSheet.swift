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
/// So this view owns the PRESENTATION of search and selection, and
/// `ChemicalReviewMerge` owns mapping. It never saves anything.
///
/// # It owns no state and no tasks
///
/// Everything that outlives a layout pass — the query, the rows, the in-flight
/// tasks and the resolved draft — lives in `ChemicalLookupCoordinator`, held by
/// the PRESENTING view. This view reads and writes that object and nothing
/// else. There is deliberately no `.onDisappear` cancellation here: on a real
/// phone `onDisappear` fires for rotation and for the system snapshot a
/// screenshot takes, and cancelling a 180 s resolve from it meant turning the
/// phone sideways killed the lookup.
struct ChemicalProductSearchSheet: View {
    /// The session. Owned by the presenter, not by this view.
    @Bindable var coordinator: ChemicalLookupCoordinator
    /// Seeds the search box.
    let initialQuery: String
    /// The record being re-identified, if any. Its id and operational data are
    /// preserved through the merge so a re-search corrects a product rather
    /// than replacing it with a stranger.
    let existing: SavedChemical?
    /// Receives the merged, unsaved draft. This view does NOT dismiss itself.
    let onReviewed: (SavedChemical) -> Void
    /// Shown as "Enter Manually" when provided. Absent inside the editor,
    /// where the operator is already looking at the manual form.
    let onManualEntry: (() -> Void)?

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    init(
        coordinator: ChemicalLookupCoordinator,
        initialQuery: String = "",
        existing: SavedChemical? = nil,
        onManualEntry: (() -> Void)? = nil,
        onReviewed: @escaping (SavedChemical) -> Void
    ) {
        self.coordinator = coordinator
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

    private var vineyardId: UUID { store.selectedVineyard?.id ?? UUID() }

    var body: some View {
        NavigationStack {
            List {
                searchSection
                Section {
                    ChemicalLookupDurationNotice(showsRepeatHint: true)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                if let searchError = coordinator.searchError { errorSection(searchError) }
                choiceNotice
                if coordinator.isResolving {
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
                    // The ONE place a lookup is cancelled by leaving.
                    Button("Cancel") {
                        coordinator.cancel(.operatorDismissed)
                        dismiss()
                    }
                }
            }
            .onAppear {
                ChemicalLookupTrace.log("search_view_appear")
                coordinator.seedQueryIfNeeded(initialQuery)
            }
            .onDisappear {
                // Deliberately NOT a cancellation point. Rotation, screenshots
                // and ordinary reconstruction all land here.
                ChemicalLookupTrace.log("search_view_disappear", "no cancellation")
            }
            .onChange(of: coordinator.reviewDraft?.id) { _, _ in
                if let draft = coordinator.reviewDraft { onReviewed(draft) }
            }
        }
    }

    // MARK: - Sections

    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Product name", text: $coordinator.query)
                    .autocorrectionDisabled()
                    .onSubmit { startSearch() }
            }
            Button {
                startSearch()
            } label: {
                if coordinator.isSearching {
                    HStack { ProgressView(); Text("Searching…") }
                } else {
                    Text("Search")
                }
            }
            .disabled(
                coordinator.query.trimmingCharacters(in: .whitespaces).isEmpty
                    || coordinator.isSearching
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

    @ViewBuilder
    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(VineyardTheme.warning)
            if let unresolvedRow = coordinator.unresolvedRow {
                // Retrying is the RIGHT first move: the resolver caches its
                // slow first pass, so a second attempt normally returns the
                // full register record immediately.
                Button("Try Again") { startSelect(unresolvedRow) }
                Button("Continue Without Register Details") {
                    coordinator.continueWithoutRegisterDetails(
                        country: countryCode,
                        existing: existing,
                        vineyardId: vineyardId
                    )
                }
                .foregroundStyle(.secondary)
            } else {
                Button("Try Again") { startSearch() }
            }
        } footer: {
            if coordinator.unresolvedRow != nil {
                Text("Continuing fills in only what the search result carried — no category, no label link and no registered uses. Everything stays editable, and nothing is saved until you press Save.")
            }
        }
    }

    /// Says out loud that the identity is NOT settled and the operator is the
    /// one deciding.
    ///
    /// Without this the top row of a list reads as "the answer" -- which is
    /// how an ambiguous query became a silent product decision. The server
    /// states whether it could establish an exact identity; when it could not,
    /// the screen says so in the operator's own terms rather than letting
    /// position imply confidence.
    @ViewBuilder
    private var choiceNotice: some View {
        if coordinator.requiresOperatorChoice, !coordinator.rows.isEmpty {
            Section {
                Label(
                    "More than one registered product could match. Choose the one on your label.",
                    systemImage: "questionmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } footer: {
                Text("Check the registration number on the drum against the number shown on each option.")
            }
        }
    }

    /// One section per tier, so the ordering is visible rather than implied.
    @ViewBuilder
    private var resultSections: some View {
        ForEach(ChemicalSearchTier.allCases, id: \.rawValue) { tier in
            let tierRows = coordinator.rows.filter { $0.tier == tier }
            if !tierRows.isEmpty {
                Section {
                    ForEach(tierRows) { row in
                        Button {
                            startSelect(row)
                        } label: {
                            resultRow(row)
                        }
                        .disabled(coordinator.isResolving)
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
        case .weakMatch:
            Text("These only mention your search words somewhere in their registered name. They are shown in case one is the product you meant.")
        }
    }

    /// One candidate, with the facts a viticulturist decides on.
    ///
    /// Registered name, registration number, registrant, active ingredient,
    /// category and vineyard relevance -- every one of which is printed on the
    /// drum in the operator's hand, so the choice can be made by comparison
    /// rather than by trust. Deliberately no confidence score: a model's
    /// self-assessment cannot be checked against a physical label, and putting
    /// it first invites deference on exactly the decision that has already
    /// gone wrong once.
    private func resultRow(_ row: ChemicalSearchRow) -> some View {
        let summary = ChemicalCandidateSummary(result: row.result, country: countryCode)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(summary.name)
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
            if !summary.registrationLabel.isEmpty {
                Text(summary.registrationLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Registration \(summary.registrationLabel)")
            }
            if !summary.registrant.isEmpty {
                Text(summary.registrant)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !summary.activeIngredient.isEmpty {
                Text(summary.activeIngredient)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if !summary.category.isEmpty {
                    Text(summary.category)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // Absent when the server does not KNOW -- a register listing
                // carries no use table, and "unknown" drawn as "none" would
                // libel a product with plenty of grapevine uses.
                if let note = summary.grapevineNote {
                    Text(note)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(
                            row.result.hasGrapevineUse == true
                                ? VineyardTheme.leafGreen
                                : .secondary
                        )
                }
            }
        }
    }

    // MARK: - Actions

    private func startSearch() {
        coordinator.startSearch(country: countryCode, savedChemicals: store.savedChemicals)
    }

    private func startSelect(_ row: ChemicalSearchRow) {
        coordinator.startSelect(
            row,
            country: countryCode,
            existing: existing,
            vineyardId: vineyardId
        )
    }
}
