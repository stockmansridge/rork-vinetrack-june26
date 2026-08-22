import SwiftUI

/// The operator-facing Search → Match → Verify → Confirm workflow.
///
/// The whole point of this flow is that identifying a product and trusting a
/// product are separate acts. The wizard collects EVIDENCE; it never sets the
/// trust level itself. Every screen submits what it found to
/// `ChemicalIntelligence.resolvedVerificationStatus`, and that computed value
/// is what gets displayed and saved — which is why there is no "mark as
/// verified" button anywhere in this file.
struct ChemicalMatchFlowView: View {
    /// Existing chemical being matched (legacy `needs_match` cleanup), or nil
    /// when adding something new.
    let existing: SavedChemical?
    /// Seeds the search box, so "Match & Verify" on a legacy record starts from
    /// the name the grower already uses.
    let prefillQuery: String

    @Environment(MigratedDataStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private enum Step {
        case search, match, verify, confirm
    }

    @State private var step: Step = .search
    @State private var query: String = ""
    @State private var results: [ChemicalSearchResult] = []
    @State private var isSearching: Bool = false
    @State private var searchError: String?

    @State private var selected: ChemicalSearchResult?
    @State private var isLoadingStructured: Bool = false
    @State private var structuredError: String?
    @State private var intelligence: ChemicalIntelligence?
    /// The resolver's quarantined reading, kept so a refusal can be EXPLAINED.
    ///
    /// Never merged into `intelligence`, never saved: it is the reason the
    /// canonical fields are empty, not a substitute for them.
    @State private var advisory: ChemicalLookupAdvisory?
    @State private var guidance: String?
    @State private var withholdingReason: ChemicalEvidenceWithholdingReason?

    @State private var showManualEntry: Bool = false

    /// An existing store record that already carries the candidate's exact
    /// registration identity. Computed when the operator continues to the
    /// confirm step; saving then updates that record instead of adding a
    /// second copy. Mirrors the Android match sheet's duplicate guard.
    @State private var duplicateOf: SavedChemical?
    /// Master catalogue reference when the structured lookup was served from
    /// an APPROVED master row (sql/199). Nil on AI-sourced lookups.
    @State private var masterMatch: ChemicalMasterMatch?

    init(existing: SavedChemical? = nil, prefillQuery: String = "") {
        self.existing = existing
        self.prefillQuery = prefillQuery
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
            Group {
                switch step {
                case .search: searchStep
                case .match: matchStep
                case .verify: verifyStep
                case .confirm: confirmStep
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showManualEntry) {
                // Manual entry reuses the existing editor. A product typed by
                // hand stays Unverified no matter how completely it is filled
                // in, because completeness is not evidence.
                EditSavedChemicalSheet(chemical: existing)
            }
        }
        .onAppear {
            if query.isEmpty { query = prefillQuery }
        }
    }

    private var title: String {
        switch step {
        case .search: return existing == nil ? "Add Chemical" : "Match & Verify"
        case .match: return "Matched Product"
        case .verify: return "Verify Chemical"
        case .confirm: return "Confirm"
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

            if !results.isEmpty {
                Section {
                    ForEach(results) { result in
                        Button {
                            selected = result
                            step = .match
                            Task { await loadStructured(for: result) }
                        } label: {
                            searchResultRow(result)
                        }
                    }
                } header: {
                    Text("Select the exact product")
                } footer: {
                    // A name match is a lead, not an identification.
                    Text("Product names repeat across manufacturers and countries. Choose the one on your label.")
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
            // Search mixes register rows with model suggestions, and drawing
            // them identically is what let an unverifiable guess look like a
            // register hit — until Verify refused it and appeared to lose data.
            Text(result.provenanceLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(
                    result.isAuthoritativeCandidate ? VineyardTheme.success : VineyardTheme.warning
                )
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

    // MARK: - Match

    private var matchStep: some View {
        List {
            if isLoadingStructured {
                Section {
                    HStack { ProgressView(); Text("Looking up product details…") }
                }
            }

            Section("Matched Product") {
                ChemicalIdentityView(
                    productName: intelligence?.registration?.registeredProductName
                        ?? selected?.name ?? query,
                    registration: intelligence?.registration,
                    productCategory: intelligence?.productCategory ?? ""
                )
            }

            Section {
                // Identity strength is decided by whether a register and number
                // are actually present — never by how confident the lookup felt.
                let registration = intelligence?.registration
                if registration?.isAuthoritativeIdentity == true {
                    Label("Exact registered identity found", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(VineyardTheme.success)
                } else if registration != nil {
                    Label("Likely match", systemImage: "circle.lefthalf.filled")
                        .foregroundStyle(VineyardTheme.info)
                    Text("A registration number could not be confirmed for this product.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Product identity incomplete", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(VineyardTheme.warning)
                    Text("No national registration was found. This product can be saved, but it cannot become Verified.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Identity status")
            }

            if let structuredError {
                Section {
                    Label(structuredError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(VineyardTheme.warning)
                    Button("Try Again") {
                        if let selected { Task { await loadStructured(for: selected) } }
                    }
                    Button("Enter Manually") { showManualEntry = true }
                }
            }

            Section {
                Button("Back to search") { step = .search }
                Button("Continue") { step = .verify }
                    .disabled(intelligence == nil)
            }
        }
    }

    // MARK: - Verify

    private var verifyStep: some View {
        List {
            if let intel = intelligence {
                let resolved = intel.resolvedVerificationStatus

                if !intel.verification.conflicts.isEmpty {
                    Section {
                        ChemicalConflictCard(conflicts: intel.verification.conflicts)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                Section("Product identity") {
                    ChemicalIdentityView(
                        productName: intel.registration?.registeredProductName
                            ?? selected?.name ?? query,
                        registration: intel.registration,
                        productCategory: intel.productCategory
                    )
                }

                Section {
                    if intel.activeIngredients.isEmpty {
                        Text("No active ingredients were established for this product.")
                            .font(.caption)
                            .foregroundStyle(VineyardTheme.warning)
                        evidenceWithholdingExplanation
                    } else {
                        ForEach(intel.activeIngredients) { active in
                            ChemicalActiveIngredientRow(active: active)
                        }
                    }
                } header: {
                    Text("Active ingredients")
                } footer: {
                    if intel.activityGroups.count > 1 {
                        // Say it in words as well as chips: a mixture belongs to
                        // every one of its groups at once, and rotating off only
                        // one of them is exactly how resistance develops.
                        Text("This is a mixture. All \(intel.activityGroups.count) activity groups apply independently for resistance purposes.")
                    }
                }

                if !intel.activityGroups.isEmpty {
                    Section("Activity groups") {
                        ChemicalGroupSummaryLine(groups: intel.activityGroups)
                        Text("Derived from the active ingredients above.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Section {
                    ChemicalVerificationEvidenceView(
                        verification: intel.verification,
                        resolvedStatus: resolved
                    )
                } header: {
                    Text("Verification")
                } footer: {
                    Text(resolved.detail)
                }

                if !intel.registeredUses.flatMap(\.rates).isEmpty {
                    Section {
                        ChemicalLabelRatesView(uses: intel.registeredUses)
                    }
                }

                Section("Registered uses") {
                    // The label-source flag only ever changes the WORDING of a
                    // label-parsed zero-day withholding period ("not required
                    // when used as directed"); it never invents or alters a
                    // value. Derived from the payload's own cited sources.
                    ChemicalRegisteredUsesView(
                        uses: intel.registeredUses,
                        hasManufacturerLabelSource: intel.hasManufacturerLabelSource
                    )
                }

                Section {
                    Button("Back") { step = .match }
                    Button("Continue") {
                        // Duplicate prevention keys off registration identity,
                        // never name similarity: two products can share a name
                        // and be different registrations, and the same
                        // registration is the same product however it was typed.
                        duplicateOf = ChemicalStoreMatching.findByRegistrationIdentity(
                            in: store.savedChemicals,
                            registration: intel.registration,
                            excludingId: existing?.id
                        )
                        step = .confirm
                    }
                }
            }
        }
    }

    /// Why the canonical chemistry is empty, and what the resolver read anyway.
    ///
    /// This is the fix for the reported defect. The evidence was always being
    /// withheld deliberately; what was missing was any way for the app to SAY
    /// so. The suggestion below is drawn as explicitly unverified and is not
    /// saved, selectable or promotable — showing it does not make it evidence.
    @ViewBuilder
    private var evidenceWithholdingExplanation: some View {
        if let reason = withholdingReason {
            VStack(alignment: .leading, spacing: 6) {
                Label(reason.headline, systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VineyardTheme.info)
                Text(reason.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }

        if let advisory, advisory.hasContent {
            VStack(alignment: .leading, spacing: 4) {
                Text("Unverified reading")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(VineyardTheme.warning)
                if !advisory.activeIngredientSummary.isEmpty {
                    Text(advisory.activeIngredientSummary)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Text("Not recorded, and not used for resistance. Enter the product manually if you can confirm it from the label.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }

        if let guidance, !guidance.isEmpty {
            Text(guidance)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Confirm

    private var confirmStep: some View {
        List {
            if let intel = intelligence {
                let resolved = intel.resolvedVerificationStatus

                Section("Summary") {
                    summaryRow("Product", intel.registration?.registeredProductName
                               ?? selected?.name ?? query)
                    summaryRow("Country", intel.registration?.countryCode ?? countryCode)
                    summaryRow("Registration",
                               intel.registration?.displayIdentifier ?? "Not confirmed")
                    if let master = masterMatch {
                        summaryRow("Source", "Master catalogue · rev \(master.masterRevision)")
                    }
                    summaryRow("Actives", intel.activeIngredients.isEmpty
                               ? "None identified"
                               : intel.legacyActiveIngredient)
                    summaryRow("Activity groups", intel.activityGroups.isEmpty
                               ? "Unknown"
                               : intel.legacyChemicalGroup)
                    summaryRow("Registered uses", intel.registeredUses.isEmpty
                               ? "Not confirmed"
                               : "\(intel.registeredUses.count)")
                    HStack {
                        Text("Verification")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 110, alignment: .leading)
                        ChemicalVerificationBadge(status: resolved)
                    }
                }

                if let duplicate = duplicateOf {
                    Section {
                        Label("Already in Chemical Store", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(VineyardTheme.warning)
                        Text("“\(duplicate.name)” already has this exact registration identity. Update that record instead of adding a second copy.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            save(intel, into: duplicate)
                            dismiss()
                        } label: {
                            Text("Update existing record")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                    }
                }

                Section {
                    if duplicateOf == nil {
                        Button {
                            save(intel)
                            dismiss()
                        } label: {
                            Text(existing == nil ? "Add to Chemical Store" : "Save Chemical")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                    }
                    Button("Back") { step = .verify }
                } footer: {
                    Text("The structured record is saved in full. The older Active Ingredient and Chemical Group fields are kept in step with it for compatibility.")
                }
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.weight(.medium))
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

    private func loadStructured(for result: ChemicalSearchResult) async {
        isLoadingStructured = true
        structuredError = nil
        defer { isLoadingStructured = false }
        do {
            // The SELECTED candidate defines the identity from here on — the
            // typed query ("Dithaine rainshield") is dead the moment an exact
            // result is chosen. A register candidate's number rides along as a
            // pointer so the strict resolver verifies THAT exact identity,
            // which also disambiguates same-name pack registrations.
            let request = ChemicalStructuredLookupRequest(
                selected: result,
                country: countryCode,
                fallbackQuery: query
            )
            let lookup = try await ChemicalInfoService().lookupStructured(request)
            // Jurisdiction gate: a payload registered in another country — or
            // a master row keyed to one — is refused OUTRIGHT, exactly like a
            // failed lookup. Foreign label rates, WHP, re-entry statements and
            // uses must never be convertible, saveable or linkable here.
            if let reason = ChemicalJurisdiction.rejectionReason(
                for: lookup, requestCountry: countryCode
            ) {
                masterMatch = nil
                intelligence = nil
                clearAdvisory()
                structuredError = reason
                return
            }
            // Master-served lookups carry the catalogue reference the saved
            // record retains (sql/199). AI-sourced lookups carry none.
            masterMatch = lookup.isMasterMatch ? lookup.master : nil
            intelligence = lookup.intelligence()

            // Keep the resolver's account of WHY it withheld what it withheld.
            // Presentation only — nothing here is merged, promoted or saved.
            advisory = lookup.aiSuggestion
            guidance = lookup.guidance
            withholdingReason = ChemicalEvidenceWithholding.reason(
                discovery: lookup.discovery,
                hasEstablishedActives: !lookup.establishedNoChemistry,
                selectedSource: result.source,
                selectedRegistrationNumber: result.registrationNumber,
                registerName: countryCode
            )
            if lookup.establishedNoChemistry,
               result.source == ChemicalSearchResult.officialRegisterSource {
                // Search offered a register row that the strict resolver would
                // not re-verify. That is the two contracts disagreeing about
                // one product, not a user error, and it should be visible in
                // diagnostics rather than absorbed silently.
                #if DEBUG
                print("[ChemicalMatchFlow] register candidate did not re-verify: \(result.name)")
                #endif
            }
        } catch {
            // No silent downgrade to the old AI shape: treating an unstructured
            // answer as if it were verified evidence is the exact failure this
            // stage exists to prevent.
            masterMatch = nil
            intelligence = nil
            clearAdvisory()
            structuredError = (error as? LocalizedError)?.errorDescription
                ?? "Structured lookup is unavailable. Retry, or enter the product manually."
        }
    }

    private func clearAdvisory() {
        advisory = nil
        guidance = nil
        withholdingReason = nil
    }

    /// Writes the confirmed intelligence onto a record.
    ///
    /// `target` is the duplicate the operator chose to update in place of
    /// adding a second copy; otherwise the record being matched (legacy
    /// cleanup) or a brand-new one. Non-chemistry fields on an updated record
    /// — pack size, price, inventory — are untouched, mirroring Android.
    private func save(_ intel: ChemicalIntelligence, into target: SavedChemical? = nil) {
        var chemical = target ?? existing ?? SavedChemical(
            vineyardId: store.selectedVineyard?.id ?? UUID()
        )
        let name = intel.registration?.registeredProductName
            ?? selected?.name
            ?? query
        chemical.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let registrant = intel.registration?.registrant, !registrant.isEmpty {
            chemical.manufacturer = registrant
        } else if let brand = selected?.brand,
                  !brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  chemical.manufacturer.isEmpty {
            // Manufacturer from the row the operator picked. Display metadata,
            // not chemistry and not identity: it populates no active, cites no
            // source and cannot move `resolvedVerificationStatus`. Only ever
            // fills a blank, so a confirmed registrant is never overwritten.
            chemical.manufacturer = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !intel.productCategory.isEmpty {
            chemical.productCategory = intel.productCategory
        }
        if let reference = intel.registration?.labelReference, !reference.isEmpty {
            chemical.labelURL = LabelURLValidator.sanitize(reference)
        }
        chemical.chemicalIntelligence = intel
        // Master catalogue provenance (sql/199): a master-served lookup links
        // the record to the catalogue product at the revision its chemistry
        // was copied from. An AI-sourced save leaves any existing link
        // untouched — Re-verify owns drift resolution; nothing here guesses.
        if let master = masterMatch {
            chemical.masterChemicalId = master.masterChemicalId
            chemical.masterSourceRevision = master.masterRevision
        }
        // Legacy scalars are written as a DERIVED mirror so old clients and the
        // existing API keep rendering something familiar. Nothing reads them
        // back for a resistance decision.
        let projection = chemical.legacyProjection
        chemical.activeIngredient = projection.activeIngredient
        chemical.chemicalGroup = projection.chemicalGroup

        if target == nil && existing == nil {
            store.addSavedChemical(chemical)
        } else {
            store.updateSavedChemical(chemical)
        }
    }
}
