import SwiftUI

struct SprayPresetsView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl
    @State private var showAddChemical: Bool = false
    @State private var showAddPreset: Bool = false
    @State private var editingChemical: SavedChemical?
    @State private var editingPreset: SavedSprayPreset?
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()

    private var canManageSetup: Bool { accessControl?.canManageSetup ?? false }

    var body: some View {
        List {
            chemicalsSection
            tankPresetsSection
        }
        .navigationTitle("Spray Presets")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAddChemical) {
            // Adding starts with identification, not a blank form: search the
            // register, pick the exact product, review what was found. Same
            // flow as the Chemical Store and the Spray Program.
            ChemicalMatchFlowView()
        }
        .sheet(item: $editingChemical) { chem in
            EditSavedChemicalSheet(chemical: chem)
        }
        .sheet(isPresented: $showAddPreset) {
            EditSavedSprayPresetSheet(preset: nil)
        }
        .sheet(item: $editingPreset) { preset in
            EditSavedSprayPresetSheet(preset: preset)
        }
        .chemicalDeletionActions(coordinator: deleteCoordinator, store: store)
    }

    private var chemicalsSection: some View {
        Section {
            ForEach(store.savedChemicals) { chemical in
                Group {
                    if canManageSetup {
                        Button {
                            editingChemical = chemical
                        } label: { chemicalRowContent(chemical) }
                    } else {
                        chemicalRowContent(chemical)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if canManageSetup {
                        Button(role: .destructive) {
                            deleteCoordinator.pending = chemical
                        } label: {
                            let inUse = store.isSavedChemicalInUseLocally(chemical.id)
                            Label(inUse ? "Archive" : "Delete", systemImage: inUse ? "archivebox" : "trash")
                        }
                    }
                }
            }

            if canManageSetup {
                Button {
                    showAddChemical = true
                } label: {
                    Label("Add Chemical", systemImage: "plus.circle")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "flask.fill")
                    .foregroundStyle(VineyardTheme.olive)
                    .font(.caption)
                Text("Chemicals")
            }
        } footer: {
            if canManageSetup {
                Text("Saved chemicals are shared with all users of this vineyard.")
            } else {
                Text("Setup data is managed by vineyard owners and managers.")
            }
        }
    }

    @ViewBuilder
    private func chemicalRowContent(_ chemical: SavedChemical) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(chemical.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                if !chemical.activeIngredient.isEmpty {
                    Text(chemical.activeIngredient)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(String(format: "%.2f", chemical.ratePerHa)) \(chemical.unit.rawValue)/Ha")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if canManageSetup {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var tankPresetsSection: some View {
        Section {
            ForEach(store.savedSprayPresets) { preset in
                Group {
                    if canManageSetup {
                        Button {
                            editingPreset = preset
                        } label: { presetRowContent(preset) }
                    } else {
                        presetRowContent(preset)
                    }
                }
                .swipeActions(edge: .trailing) {
                    if canManageSetup {
                        Button(role: .destructive) {
                            store.deleteSavedSprayPreset(preset)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            if canManageSetup {
                Button {
                    showAddPreset = true
                } label: {
                    Label("Add Tank Preset", systemImage: "plus.circle")
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(VineyardTheme.olive)
                    .font(.caption)
                Text("Tank Presets")
            }
        } footer: {
            Text("Tank presets save Water Volume, Spray Rate, and Concentration Factor.")
        }
    }

    @ViewBuilder
    private func presetRowContent(_ preset: SavedSprayPreset) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text("\(Int(preset.waterVolume))L • \(Int(preset.sprayRatePerHa))L/Ha • CF \(String(format: "%.1f", preset.concentrationFactor))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canManageSetup {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Edit Saved Chemical Sheet

/// Which secondary screen the editor is showing.
///
/// ONE sheet presenter instead of four stacked `.sheet` modifiers. Chaining
/// several sheets onto the same view makes their content views share a
/// presentation slot, and rebuilding the parent can tear down and re-create the
/// one that is open — which is how a populated Review Chemical form could lose
/// its contents just because the operator opened and closed Chemistry &
/// Identity, or the store ticked underneath it.
private enum ChemicalEditorSheet: Identifiable {
    case search
    case chemistry
    case reverify

    var id: Int {
        switch self {
        case .search: return 0
        case .chemistry: return 1
        case .reverify: return 2
        }
    }
}

/// THE Chemical Store editor — a pure editor over one stable draft.
///
/// # What it is not, any more
///
/// It used to double as a second product-lookup pipeline: a "Search with AI"
/// action called its own server endpoint and mapped the reply into its own
/// fields, filling the legacy free-text chemistry while leaving the structured
/// sql/194 record empty. Two pipelines producing two different answers for the
/// same product is what put "No active ingredients recorded" directly above
/// "Recorded as text: Mancozeb · M5" on the same screen.
///
/// Now there is one lookup implementation (`ChemicalProductSearchSheet`) and
/// one mapping authority (`ChemicalReviewMerge`). This view resolves nothing on
/// its own and runs no background lookup: it is handed a draft, it edits it,
/// and it saves it.
///
/// # Draft lifecycle
///
/// The whole form is ONE `@State` value, seeded once by
/// `ChemicalReviewSession.make`. Nothing re-seeds on redraw, on scroll, on
/// `onAppear`, on scene change or on sheet dismissal. Once Review Chemical is
/// open, its values change only when the operator changes them.
struct EditSavedChemicalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    /// Purchase cost data (container size, dollar cost) is owner/manager only.
    /// Supervisors/operators can still see other chemical details but the
    /// purchase/cost section is hidden so they never see pricing.
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    /// The EXISTING record being edited. Nil when adding.
    ///
    /// Distinct from `prefill` on purpose: this is what decides whether Save
    /// updates a record or creates one, and a looked-up product that has never
    /// been saved must take the create path.
    let chemical: SavedChemical?

    /// A populated but UNSAVED draft to open the form on — the Review Chemical
    /// case.
    ///
    /// Everything a lookup found is merged into a `SavedChemical` by
    /// `ChemicalReviewMerge` and handed here, so the operator reviews and
    /// corrects real values instead of retyping them into a blank form. It is
    /// the same screen, the same fields and the same Save: "review what we
    /// found" is not a different kind of editing, and giving it its own screen
    /// is how the two would drift apart.
    private let prefill: SavedChemical?

    /// Called with the product this form just persisted.
    ///
    /// Exists so callers that need the RESULT of a creation — the Spray Program
    /// editor, which must bind the new product to the line that sent the
    /// operator here — can reuse this exact screen instead of forking a
    /// simplified copy of it. Nil for the Chemical Store's own use, where the
    /// store list is the destination and there is nothing to hand back.
    private let onSaved: ((SavedChemical) -> Void)?

    /// THE draft. Every field on this screen lives here.
    ///
    /// One `@State` rather than twenty-five, so the form has one owner and one
    /// lifetime. It is seeded once in `init` and never re-seeded: a redraw
    /// cannot empty it, and there is no `onAppear` that quietly rewrites part
    /// of it on the sheet's second appearance.
    @State private var session: ChemicalReviewSession

    @State private var activeSheet: ChemicalEditorSheet?
    @State private var linkAlertMessage: String?
    @State private var showLinkAlert: Bool = false
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()

    init(
        chemical: SavedChemical?,
        prefill: SavedChemical? = nil,
        onSaved: ((SavedChemical) -> Void)? = nil
    ) {
        self.chemical = chemical
        self.prefill = prefill
        self.onSaved = onSaved
        // ONE seeding path for both cases, run ONCE. A reviewed lookup and a
        // stored record populate the identical fields; only what Save does
        // differs. `@State` keeps the value produced here for the lifetime of
        // the editor, so re-running this initialiser on a parent redraw cannot
        // overwrite anything the operator has typed.
        _session = State(initialValue: ChemicalReviewSession.make(
            chemical: chemical,
            prefill: prefill,
            fallbackCountry: ""
        ))
    }

    private static func formatRate(_ value: Double) -> String {
        ChemicalReviewSession.formatRate(value)
    }

    /// The country a manual entry defaults to, from the vineyard profile.
    private var resolvedCountry: String {
        ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        )
    }

    /// "Review Chemical" for a looked-up product, so the operator understands
    /// they are checking findings rather than filling in a blank form.
    private var reviewTitle: String {
        if prefill != nil { return "Review Chemical" }
        return chemical == nil ? "New Chemical" : "Edit Chemical"
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.settings.aiSuggestionsEnabled {
                    lookupSection
                }
                productSection
                chemistrySection
                if chemical != nil {
                    reverifySection
                }
                detailsSection
                ratesSection
                if session.productCategory?.isFertiliser == true {
                    fertiliserSection
                }
                if canViewFinancials {
                    purchaseSection
                }
                sharingSection
                notesSection
                if chemical != nil {
                    dangerZoneSection
                }
            }
            .navigationTitle(reviewTitle)
            .navigationBarTitleDisplayMode(.inline)
            // ONE sheet presenter. Four stacked `.sheet` modifiers shared a
            // presentation slot, and a parent rebuild while one was open could
            // tear down the editor underneath it — which is how a populated
            // Review Chemical form lost its contents after Chemistry & Identity
            // was opened and closed. There is deliberately no `onAppear` work
            // here either: the country default is applied once when the session
            // is seeded, not on every re-appearance of the sheet.
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .search:
                    // The SAME lookup the Add Chemical flow uses. It hands back a
                    // merged draft, which is applied to this session — one
                    // lookup, one merge, one review. Nothing is saved here.
                    ChemicalProductSearchSheet(
                        initialQuery: session.name,
                        existing: chemical
                    ) { reviewed in
                        session.apply(reviewed: reviewed, fallbackCountry: resolvedCountry)
                    }
                case .chemistry:
                    ChemicalManualEditorView(
                        draft: $session.chemistryDraft,
                        existing: session.seedIntelligence
                    )
                case .reverify:
                    if let chemical {
                        // Closing this form after a successful re-verification is
                        // not cosmetic. The session was captured from the record
                        // when the editor opened, so a Save afterwards would write
                        // the pre-check values straight back over the update just
                        // accepted.
                        ChemicalReverifyFlowView(chemical: chemical) { dismiss() }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let saved = save() { onSaved?(saved) }
                        dismiss()
                    }
                    .disabled(!session.isValid)
                }
            }
            .alert("Link", isPresented: $showLinkAlert, presenting: linkAlertMessage) { _ in
                Button("OK", role: .cancel) {}
            } message: { msg in
                Text(msg)
            }
            .chemicalDeletionActions(coordinator: deleteCoordinator, store: store)
            .onChange(of: deleteCoordinator.didDeleteId) { _, newValue in
                if newValue != nil { dismiss() }
            }
            .onChange(of: session.formType) { _, newValue in
                if !newValue.units.contains(session.unit) {
                    session.unit = newValue.units.first ?? .litres
                }
                if !newValue.units.contains(session.containerUnit) {
                    session.containerUnit = newValue.units.first ?? .litres
                }
            }
        }
    }

    /// Re-run the product lookup from inside the editor.
    ///
    /// This is NOT a second pipeline. It opens the same search screen the Add
    /// Chemical flow opens, resolves through the same resolver and maps through
    /// the same `ChemicalReviewMerge`, then replaces this session's product data
    /// with the result. What the operator owns — price, pack, stock, notes — is
    /// left alone: re-identifying a product says nothing about what it cost.
    private var lookupSection: some View {
        Section {
            Button {
                activeSheet = .search
            } label: {
                Label(
                    session.name.trimmingCharacters(in: .whitespaces).isEmpty
                        ? "Search for this product"
                        : "Search the register again",
                    systemImage: "magnifyingglass"
                )
            }
        } footer: {
            Text("Looks the product up again and refills the product details below. Everything found stays editable, and nothing is saved until you press Save.")
        }
    }

    private var productSection: some View {
        Section {
            LabeledField(label: "Chemical / Product Name") {
                TextField("e.g. Synertrol Horti Oil", text: $session.name)
            }
            Picker("Category", selection: $session.productCategory) {
                Text("Uncategorised").tag(ProductCategory?.none)
                ForEach(ProductCategory.allCases) { option in
                    Text(option.label).tag(ProductCategory?.some(option))
                }
            }
            Picker("Form", selection: $session.formType) {
                ForEach(ChemicalFormType.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            .pickerStyle(.segmented)
            Picker("Unit", selection: $session.unit) {
                ForEach(session.formType.units, id: \.self) { u in
                    Text(u.rawValue).tag(u)
                }
            }
        } header: {
            Text("Product")
        } footer: {
            Text("Fertiliser and nutrient categories unlock pack, N-P-K and inventory fields used by the Fertiliser Calculator.")
        }
    }

    /// Pack, nutrient analysis and inventory inputs — shown only for
    /// fertiliser/nutrient categories so ordinary spray chemicals stay clean.
    private var fertiliserSection: some View {
        Group {
            Section("Pack & Inventory") {
                Toggle("Organic certified", isOn: $session.organicCertified)
                LabeledContent("Pack size (\(session.formType == .liquid ? "L" : "kg"))") {
                    TextField("25", text: $session.packSizeText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                if canViewFinancials {
                    LabeledContent("Price per pack ($)") {
                        TextField("Optional", text: $session.packPriceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if session.formType == .liquid {
                    LabeledContent("Density (kg/L)") {
                        TextField("Optional", text: $session.densityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Stock on hand (packs)") {
                    TextField("Optional", text: $session.inventoryText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }

            Section {
                LabeledContent("Nitrogen (N) %") {
                    TextField("0", text: $session.nitrogenText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Phosphorus %") {
                    TextField("0", text: $session.phosphorusText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Potassium %") {
                    TextField("0", text: $session.potassiumText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Picker("P & K basis", selection: $session.analysisBasis) {
                    ForEach(FertiliserAnalysisBasis.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            } header: {
                Text("Nutrient Analysis")
            } footer: {
                Text("Record whether the label lists elemental P/K or oxide (P\u{2082}O\u{2085}/K\u{2082}O) values — mixing them up causes major rate errors.")
            }

            Section("Application Notes") {
                TextField("Optional notes", text: $session.applicationNotes, axis: .vertical)
                    .lineLimit(2...4)
            }
        }
    }

    /// The product's chemistry, as structure rather than as free text.
    ///
    /// This section is what replaced the `Active Ingredient` and `Chemical Group`
    /// boxes. It shows each active with its own group, the derived product-level
    /// summary, and how many label rates and uses are on record — then hands off
    /// to the structured editor for the actual work.
    private var chemistrySection: some View {
        // Read from the STRUCTURED draft, which a lookup now hydrates directly.
        // This list saying "none" while the legacy line below it read "Mancozeb"
        // was the visible symptom of two pipelines disagreeing; there is one
        // pipeline now, and this is its output.
        let actives = session.populatedActives
        let summary = ChemicalManualEntry.groupSummary(session.chemistryDraft)
        let rateCount = session.chemistryDraft.productRates.count
            + session.chemistryDraft.uses.reduce(0) { $0 + $1.rates.count }
        return Section {
            if actives.isEmpty {
                Label("No active ingredients recorded", systemImage: "flask")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(actives) { active in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(active.name)
                                .font(.subheadline.weight(.medium))
                            if !active.concentrationText.isEmpty {
                                Text("\(active.concentrationText) \(active.concentrationUnit?.label ?? "")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let scheme = active.scheme, scheme != .notApplicable,
                           !ChemicalActivityGroup.normaliseCode(active.groupCode).isEmpty {
                            Text("\(scheme.label) \(ChemicalActivityGroup.normaliseCode(active.groupCode))")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(VineyardTheme.olive.opacity(0.12))
                                .foregroundStyle(VineyardTheme.olive)
                                .clipShape(Capsule())
                        } else {
                            Text("No group")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            if !summary.isEmpty {
                LabeledContent("Product groups") {
                    Text(summary).font(.subheadline.weight(.semibold))
                }
            }
            if rateCount > 0 || !session.chemistryDraft.uses.isEmpty {
                LabeledContent("Label rates & uses") {
                    Text("\(rateCount) rate\(rateCount == 1 ? "" : "s") · "
                         + "\(session.chemistryDraft.uses.count) use\(session.chemistryDraft.uses.count == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                activeSheet = .chemistry
            } label: {
                Label(
                    actives.isEmpty ? "Enter Chemistry & Identity" : "Edit Chemistry & Identity",
                    systemImage: "square.and.pencil"
                )
            }

            // ONE quiet statement of fact, next to the identity it is about.
            // Not a warning and not a blocker: an unconfirmed registration says
            // nothing about whether the chemistry below is right, and repeating
            // it on every screen is what made the old flow feel like a refusal.
            if session.registrationNotConfirmed {
                Label("Registration not confirmed", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // A legacy record's free-text chemistry, shown read-only so the
            // operator can see what the old columns hold while they restate it as
            // structure. Nothing calculates from these strings.
            //
            // Only ever reachable for a record that has never been structured:
            // when a lookup finds actives they appear in the list above, not
            // here, and this block stays hidden.
            if actives.isEmpty,
               !session.activeIngredient.isEmpty || !session.chemicalGroup.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recorded as text")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text([session.activeIngredient, session.chemicalGroup]
                        .filter { !$0.isEmpty }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Active Ingredients")
        } footer: {
            Text("Each active ingredient carries its own resistance group, so a two-active product belongs to both groups independently. Anything you enter yourself stays unverified until Match & Verify or Re-verify confirms it.")
        }
    }

    private var detailsSection: some View {
        Section {
            LabeledField(label: "Use / Problem") {
                TextField("e.g. Fungicide", text: $session.use)
            }
            LabeledField(label: "Target Problem") {
                TextField("e.g. Powdery Mildew", text: $session.problem)
            }
            LabeledField(label: "Manufacturer") {
                TextField("e.g. Syngenta", text: $session.manufacturer)
            }
            if let warning = session.editOutcome?.warning {
                verificationWarning(warning)
            }
            LabeledURLField(
                label: "Official Label URL",
                placeholder: "https://...",
                text: $session.labelURL,
                onOpenFailure: { message in
                    linkAlertMessage = message
                    showLinkAlert = true
                }
            )
            LabeledURLField(
                label: "Product Page URL",
                placeholder: "https://...",
                text: $session.productURL,
                onOpenFailure: { message in
                    linkAlertMessage = message
                    showLinkAlert = true
                }
            )
        } header: {
            Text("Details")
        } footer: {
            Text("Use Label URL only for the official product label, preferably a PDF. Product pages may be used for manufacturer or marketing information, but are never shown as the official label.")
        }
    }

    /// Re-verify Chemical, or an honest explanation of why it is not available.
    ///
    /// Eligibility and the reason string both come from `ChemicalReverification`.
    /// The UI asks the domain rather than re-deriving the rule, so the action can
    /// never appear on a record the flow would refuse to run on.
    private var reverifySection: some View {
        let country = ChemicalRegistration.normaliseCountry(
            ChemicalInfoService.resolveCountry(vineyardCountry: store.selectedVineyard?.country)
        )
        let offered = chemical.map {
            ChemicalReverification.isOffered(for: $0, fallbackCountry: country)
        } ?? false
        let reason = chemical.flatMap {
            ChemicalReverification.unavailableReason(for: $0, fallbackCountry: country)
        }
        return Section {
            if let chemical {
                HStack {
                    Text("Verification")
                    Spacer()
                    ChemicalVerificationBadge(status: chemical.verificationStatus)
                }
                // Registration identity vs the CURRENT vineyard's jurisdiction.
                // The record keeps its own country — it is never re-keyed — but
                // a foreign label must never read as valid vineyard guidance.
                if case .mismatch(let registration, let vineyard) = ChemicalJurisdiction.suitability(
                    for: chemical, vineyardCountry: country
                ) {
                    ChemicalJurisdictionMismatchBanner(
                        registrationCountry: registration,
                        vineyardCountry: vineyard
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            if offered {
                Button {
                    activeSheet = .reverify
                } label: {
                    Label("Re-verify Chemical", systemImage: "arrow.triangle.2.circlepath")
                }
            } else if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Chemical Intelligence")
        } footer: {
            Text(offered
                 ? "Re-checks this product against the register using the registration details VineTrack already holds. Nothing is changed until you review and accept it."
                 : "Products without registration details are identified through Match & Verify first.")
        }
    }

    /// States the trust consequence of a resistance-critical correction without
    /// blocking it. Absent unless verification actually falls, so an operator
    /// fixing a typo in a note is never lectured about resistance.
    private func verificationWarning(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Verification will be updated", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var ratesSection: some View {
        Section {
            LabeledField(label: "Rate per ha") {
                HStack {
                    TextField("0", text: $session.ratePerHaText)
                        .keyboardType(.decimalPad)
                    Text("\(session.unit.rawValue)/ha")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
            LabeledField(label: "Rate per 100L water") {
                HStack {
                    TextField("0", text: $session.ratePer100LText)
                        .keyboardType(.decimalPad)
                    Text("\(session.unit.rawValue)/100L")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Rates")
        } footer: {
            Text("Enter either or both. The Spray Calculator lets the operator pick which basis to use per job.")
        }
    }

    private var purchaseSection: some View {
        Section {
            Toggle("Track Purchase Info", isOn: $session.trackPurchase.animation())
            if session.trackPurchase {
                HStack {
                    Text("Container Size")
                    Spacer()
                    TextField("0", text: $session.containerSizeText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Picker("Unit", selection: $session.containerUnit) {
                        ForEach(session.formType.units, id: \.self) { u in
                            Text(u.rawValue).tag(u)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                HStack {
                    Text("Cost")
                    Spacer()
                    Text("$")
                        .foregroundStyle(.secondary)
                    TextField("0.00", text: $session.costText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                }
            }
        } header: {
            Text("Purchase Tracking")
        } footer: {
            Text("Used to calculate chemical cost in spray reports. AI does not fill in pricing — enter it from your invoice.")
        }
    }

    private var sharingSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                Text("Saved chemicals are shared with all users of this vineyard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dangerZoneSection: some View {
        Section {
            if let chemical {
                let inUseLocally = store.isSavedChemicalInUseLocally(chemical.id)
                Button {
                    deleteCoordinator.pending = chemical
                } label: {
                    Label("Archive Chemical", systemImage: "archivebox")
                        .foregroundStyle(.orange)
                }
                .disabled(deleteCoordinator.isWorking)

                if !inUseLocally {
                    Button(role: .destructive) {
                        deleteCoordinator.pending = chemical
                    } label: {
                        Label("Delete Permanently", systemImage: "trash")
                    }
                    .disabled(deleteCoordinator.isWorking)
                }
            }
        } header: {
            Text("Manage Chemical")
        } footer: {
            Text("Archiving hides the chemical from active lists but keeps it for historical records. Permanent delete is only available when this chemical has not been used in any spray records — the server makes the final decision.")
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $session.notes)
                    .frame(minHeight: 80)
                    .padding(8)
                    .background(Color(.systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(.separator), lineWidth: 0.5)
                    )
                    .clipShape(.rect(cornerRadius: 8))
            }
            .padding(.vertical, 4)
        }
    }

    /// - Returns: the product as the store now holds it, so a caller can select
    ///   what was just created without searching for it by name.
    ///
    /// The ONE write path. Whether the product came from the approved master
    /// catalogue, the official register, a structured lookup, an `ai_suggestion`
    /// or the operator's own typing, the vineyard record it produces is a row in
    /// `saved_chemicals` written from here.
    @discardableResult
    private func save() -> SavedChemical? {
        let perHaDisplay = Double(session.ratePerHaText) ?? 0
        let per100LDisplay = Double(session.ratePer100LText) ?? 0

        var rates: [ChemicalRate] = []
        if perHaDisplay > 0 {
            rates.append(ChemicalRate(
                id: session.existingPerHaRateId ?? UUID(),
                label: "Per Ha",
                value: session.unit.toBase(perHaDisplay),
                basis: .perHectare
            ))
        }
        if per100LDisplay > 0 {
            rates.append(ChemicalRate(
                id: session.existingPer100LRateId ?? UUID(),
                label: "Per 100L",
                value: session.unit.toBase(per100LDisplay),
                basis: .per100Litres
            ))
        }

        // Preserve existing purchase data when the editor cannot see/edit
        // financials so that owners/managers don't lose cost values when a
        // supervisor/operator edits the same chemical for other details.
        var purchase: ChemicalPurchase? = canViewFinancials ? nil : chemical?.purchase
        if canViewFinancials, session.trackPurchase {
            let containerSize = Double(session.containerSizeText) ?? 0
            let cost = Double(session.costText) ?? 0
            if containerSize > 0 || cost > 0 {
                purchase = ChemicalPurchase(
                    brand: session.manufacturer,
                    activeIngredient: session.activeIngredient,
                    chemicalGroup: session.chemicalGroup,
                    labelURL: session.labelURL,
                    costDollars: cost,

                    containerSizeML: containerSize,
                    containerUnit: session.containerUnit
                )
            }
        }

        let parseOptional: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
        let productForm = session.formType == .liquid ? "liquid" : "solid"
        let packUnit = session.formType == .liquid ? "L" : "kg"

        // Legacy scalars are now OUTPUTS of the structured record. They are
        // rewritten only when there is structured chemistry to derive them from,
        // so a record that has never been structured keeps its original text and
        // is not blanked by the act of saving it.
        let outcome = session.editOutcome
        let structured = outcome?.intelligence
            ?? (session.hasAuthoredChemistry ? session.seedIntelligence : nil)
        let projectedActive = structured?.legacyActiveIngredient ?? ""
        let projectedGroup = structured?.legacyChemicalGroup ?? ""
        let legacyActive = projectedActive.isEmpty ? session.activeIngredient : projectedActive
        let legacyGroup = projectedGroup.isEmpty ? session.chemicalGroup : projectedGroup

        if var existing = chemical {
            existing.name = session.name
            existing.unit = session.unit
            existing.chemicalGroup = legacyGroup
            existing.use = session.use
            existing.manufacturer = session.manufacturer
            existing.notes = session.notes
            existing.problem = session.problem
            existing.ratePerHa = perHaDisplay
            existing.activeIngredient = legacyActive
            // Mode of action is no longer an editable chemistry input — the group
            // is structured per active now — so whatever the record already held
            // is carried through untouched rather than dropped.
            existing.modeOfAction = session.modeOfAction
            existing.labelURL = session.labelURL
            existing.productURL = session.productURL
            existing.rates = rates
            existing.purchase = purchase
            existing.productCategory = session.productCategory?.rawValue ?? ""
            existing.productForm = productForm
            existing.packSize = parseOptional(session.packSizeText)
            existing.packUnit = packUnit
            // Preserve pricing authored by owners/managers when the current
            // editor cannot see financials.
            existing.pricePerPack = canViewFinancials
                ? parseOptional(session.packPriceText)
                : chemical?.pricePerPack
            existing.density = parseOptional(session.densityText)
            existing.nitrogenPercent = parseOptional(session.nitrogenText)
            existing.phosphorusPercent = parseOptional(session.phosphorusText)
            existing.potassiumPercent = parseOptional(session.potassiumText)
            existing.analysisBasis = session.analysisBasis.rawValue
            existing.organicCertified = session.organicCertified
            existing.inventoryQuantity = parseOptional(session.inventoryText)
            existing.inventoryUnit = parseOptional(session.inventoryText) != nil
                ? "packs"
                : existing.inventoryUnit
            existing.applicationNotes = session.applicationNotes
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Master catalogue reference (sql/199). Set only when the product
            // was taken from an APPROVED master; otherwise left exactly as it
            // was, because nothing here has re-derived it.
            if let masterId = session.masterChemicalId {
                existing.masterChemicalId = masterId
                existing.masterSourceRevision = session.masterSourceRevision
            }
            // Re-resolved intelligence when resistance-critical chemistry
            // changed, so a hand-edited group cannot leave a stale `verified`
            // status or an authoritative citation for the OLD value behind.
            // Left untouched on an unrelated edit.
            if let outcome {
                existing.chemicalIntelligence = outcome.intelligence
            }
            store.updateSavedChemical(existing)
            return store.savedChemicals.first { $0.id == existing.id } ?? existing
        } else {
            let new = SavedChemical(
                name: session.name,
                ratePerHa: perHaDisplay,
                unit: session.unit,
                chemicalGroup: legacyGroup,
                use: session.use,
                manufacturer: session.manufacturer,
                notes: session.notes,
                problem: session.problem,
                activeIngredient: legacyActive,
                rates: rates,
                purchase: purchase,
                labelURL: session.labelURL,
                productURL: session.productURL,
                modeOfAction: session.modeOfAction,
                productCategory: session.productCategory?.rawValue ?? "",
                productForm: productForm,
                packSize: parseOptional(session.packSizeText),
                packUnit: packUnit,
                pricePerPack: canViewFinancials ? parseOptional(session.packPriceText) : nil,
                density: parseOptional(session.densityText),
                nitrogenPercent: parseOptional(session.nitrogenText),
                phosphorusPercent: parseOptional(session.phosphorusText),
                potassiumPercent: parseOptional(session.potassiumText),
                analysisBasis: session.analysisBasis.rawValue,
                organicCertified: session.organicCertified,
                inventoryQuantity: parseOptional(session.inventoryText),
                inventoryUnit: parseOptional(session.inventoryText) != nil ? "packs" : "",
                applicationNotes: session.applicationNotes
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                // A manually created product is born structured. Its status is
                // whatever `ChemicalManualEntry` reconciled it to — Unverified,
                // or Conflict where the reference table positively disagrees.
                //
                // Falling back to the reviewed draft matters: when the operator
                // changes nothing, `editOutcome` is nil because there is nothing
                // NEW to reconcile — and without this the entire looked-up
                // record would save as an empty shell, which is the original bug
                // in a new place.
                chemicalIntelligence: session.intelligenceToPersist,
                // Only ever populated from an approved master match; nil for
                // every other origin, which is valid forever.
                masterChemicalId: session.masterChemicalId,
                masterSourceRevision: session.masterSourceRevision
            )
            store.addSavedChemical(new)
            // The store stamps the vineyard onto its own copy, so read the
            // stored value back rather than handing out the pre-insert one.
            return store.savedChemicals.first { $0.id == new.id } ?? new
        }
    }
}

// MARK: - Edit Saved Spray Preset Sheet

struct EditSavedSprayPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    let preset: SavedSprayPreset?

    @State private var name: String = ""
    @State private var waterVolumeText: String = ""
    @State private var sprayRateText: String = ""
    @State private var concentrationText: String = "1.0"

    init(preset: SavedSprayPreset?) {
        self.preset = preset
        if let p = preset {
            _name = State(initialValue: p.name)
            _waterVolumeText = State(initialValue: String(format: "%.0f", p.waterVolume))
            _sprayRateText = State(initialValue: String(format: "%.0f", p.sprayRatePerHa))
            _concentrationText = State(initialValue: String(format: "%.1f", p.concentrationFactor))
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Preset Name", text: $name)
                }
                Section("Volumes") {
                    HStack {
                        Text("Water Volume")
                        Spacer()
                        TextField("0", text: $waterVolumeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("L")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Spray Rate")
                        Spacer()
                        TextField("0", text: $sprayRateText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("L/Ha")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Concentration Factor")
                        Spacer()
                        TextField("1.0", text: $concentrationText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                }
            }
            .navigationTitle(preset == nil ? "New Preset" : "Edit Preset")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    private func save() {
        let water = Double(waterVolumeText) ?? 0
        let rate = Double(sprayRateText) ?? 0
        let cf = Double(concentrationText) ?? 1.0
        if var existing = preset {
            existing.name = name
            existing.waterVolume = water
            existing.sprayRatePerHa = rate
            existing.concentrationFactor = cf
            store.updateSavedSprayPreset(existing)
        } else {
            let new = SavedSprayPreset(
                name: name,
                waterVolume: water,
                sprayRatePerHa: rate,
                concentrationFactor: cf
            )
            store.addSavedSprayPreset(new)
        }
    }
}

// MARK: - Labeled Field Helpers

/// A form field with a small, persistent grey label above a bordered white input.
struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(.separator), lineWidth: 0.5)
                )
                .clipShape(.rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}

/// A labeled URL field with a trailing open-in-browser button.
/// The button is only visible when the field contains a valid http(s) URL.
struct LabeledURLField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let onOpenFailure: (String) -> Void

    @Environment(\.openURL) private var openURL

    private var resolvedURL: URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme: String
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            withScheme = trimmed
        } else {
            withScheme = "https://" + trimmed
        }
        guard let url = URL(string: withScheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let url = resolvedURL {
                    Button {
                        openURL(url) { accepted in
                            if !accepted {
                                onOpenFailure("This link could not be opened.")
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 18, weight: .regular))
                            .foregroundStyle(VineyardTheme.olive)
                            .padding(4)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(label)")
                }
            }
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(.systemBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
            .clipShape(.rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }
}
