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
/// ONE sheet presenter instead of stacked `.sheet` modifiers. Chaining several
/// onto the same view makes their content views share a presentation slot, and
/// rebuilding the parent can tear down and re-create the one that is open —
/// which is how a populated Review Chemical form could lose its contents just
/// because the operator opened and closed a sub-editor.
///
/// The `chemistry` case is deliberately absent. There is no second chemical
/// editor any more.
private enum ChemicalEditorSheet: Identifiable {
    case search
    case reverify

    var id: Int {
        switch self {
        case .search: return 0
        case .reverify: return 1
        }
    }
}

/// THE Chemical Store editor — one page, one record.
///
/// # What it is not, any more
///
/// It used to double as a second product-lookup pipeline, and it used to show
/// the operator two editable copies of the same product. The outer form had
/// `Use / Problem`, `Target Problem`, `Rate per ha` and `Rate per 100L`; a
/// second full editor behind an "Edit Chemistry & Identity" button had crop,
/// target, structured rates, withholding and re-entry. On a real Dithane
/// Rainshield lookup the inner screen held `2.5 kg/ha` while the outer one
/// displayed `Rate per ha: 0` — not two records, but two UIs over one record,
/// contradicting each other.
///
/// Both are gone. There is one lookup (`ChemicalProductSearchSheet`), one
/// mapping authority (`ChemicalReviewMerge`), and one editor: this screen,
/// which renders the structured sql/194 chemistry directly as its own sections.
/// The legacy scalars are produced FROM that record at save time and are never
/// edited beside it.
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
    /// Registration plumbing stays collapsed. A grower edits agronomy; the
    /// identity fields underneath are VineTrack's problem unless they ask.
    @State private var showTechnicalDetails: Bool = false
    /// An approved label can register dozens of crops. A vineyard operator
    /// should not scroll past peaches, tobacco and turf to reach grapevines,
    /// so the rest stay collapsed until asked for. Presentation only — every
    /// use is still on the record and still saved.
    @State private var showsNonVineyardUses: Bool = false
    /// Whether the lookup-review use summary is showing every target.
    ///
    /// A register reply can carry forty grapevine targets. Reviewing a lookup
    /// is a decision about the PRODUCT and its rate, so the targets are
    /// evidence rather than the task, and the first five are enough to
    /// recognise the label by.
    @State private var showsAllReviewedUses: Bool = false
    @State private var deleteCoordinator = ChemicalDeleteCoordinator()
    /// The lookup session for "search the register again".
    ///
    /// Held HERE rather than inside the search sheet so a rotation, a
    /// screenshot or any other view reconstruction cannot cancel a resolve
    /// that is already running.
    @State private var lookupCoordinator = ChemicalLookupCoordinator()

    init(
        chemical: SavedChemical?,
        prefill: SavedChemical? = nil,
        serverDefaultRateOptions: ChemicalServerDefaultRateOptions? = nil,
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
            fallbackCountry: "",
            serverDefaultRateOptions: serverDefaultRateOptions
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
                // Task §7 information architecture. The order is the WORKFLOW:
                // identify the product → confirm its chemistry and resistance
                // → confirm the grapevine rates → reach the labels → save.
                // Pricing, notes and research provenance follow, in that order,
                // because none of them is why the operator opened the screen.
                //
                // 1. Product
                productSection
                // 2. Active Ingredients & Resistance
                activeIngredientsSection
                // 3. Default rate — the DECISION, placed before the label
                // evidence it is taken from. A first add cannot be saved until
                // it is answered (`session.requiresDefaultRateConfirmation`),
                // so burying it under a long registered-use list made the one
                // mandatory question the last thing an operator found.
                if session.isRegisteredForGrapevine {
                    defaultRatesSection
                }
                // 4. Grapevine Uses & Rates — the label evidence the decision
                // above was made from, unedited.
                registeredUsesSection
                if showsProductRates {
                    productRatesSection
                }
                if !session.hasStructuredUses {
                    legacyUseSection
                }
                // 4. Labels & References
                labelsSection
                // Fertiliser pack/N-P-K stays with the operational data it
                // belongs to, not among the label evidence.
                if session.productCategory?.isFertiliser == true {
                    fertiliserSection
                }
                // 5. Purchase / Pricing
                if canViewFinancials {
                    purchaseSection
                }
                // 6. Notes
                notesSection
                // 7. Advanced / Verification Evidence — collapsed by default
                advancedSection
                if chemical != nil {
                    reverifySection
                }
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
                        coordinator: lookupCoordinator,
                        initialQuery: session.name,
                        existing: chemical
                    ) { reviewed in
                        // The re-search replaces the product, so it must also
                        // replace the server options: keeping the previous
                        // product's identities would attach one product's
                        // register rates to another.
                        session.apply(
                            reviewed: reviewed,
                            serverDefaultRateOptions: lookupCoordinator
                                .reviewDefaultRateOptions,
                            fallbackCountry: resolvedCountry
                        )
                        lookupCoordinator.finishReview()
                        activeSheet = nil
                    }
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
                Label(lookupActionTitle, systemImage: lookupActionSymbol)
            }
        } footer: {
            Text(lookupActionFooter)
        }
    }

    /// What the lookup action IS, in the operator's situation.
    ///
    /// Reviewing a lookup, the question on the operator's mind is "is this even
    /// the right product?" — and until now their only way out of a wrong
    /// candidate was Cancel, which reads as "abandon everything I have done".
    /// So the action says plainly that it changes the product.
    private var lookupActionTitle: String {
        if session.isReviewingLookup { return "Change Product" }
        return session.name.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Search for this product"
            : "Search the register again"
    }

    private var lookupActionSymbol: String {
        session.isReviewingLookup ? "arrow.triangle.2.circlepath" : "magnifyingglass"
    }

    private var lookupActionFooter: String {
        if session.isReviewingLookup {
            // Says exactly what survives the swap. "Nothing is saved until you
            // press Save" is the sentence that makes the action safe to try.
            return "Not the product on your drum? This returns to the register "
                + "search so you can pick a different one. Your price, pack size, "
                + "stock and notes are kept; the label details are replaced, and "
                + "any default rate chosen for the old product is cleared. "
                + "Nothing is saved until you press Save."
        }
        return "Looks the product up again and refills the product details below. Everything found stays editable, and nothing is saved until you press Save."
    }

    private var productSection: some View {
        Section {
            LabeledField(label: "Chemical / Product Name") {
                TextField("e.g. Synertrol Horti Oil", text: $session.name)
            }
            ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "product_name"))

            // The registration identity, in the jurisdiction's own words, and
            // on the FIRST section — it is how two similarly named products are
            // told apart, so hiding it behind a disclosure made the one fact
            // that establishes identity the hardest thing on the screen to
            // find. VineTrack still fills it in from a lookup and still never
            // demands it for an unverified record.
            if let terms = session.registrationTerms {
                LabeledField(label: terms.fieldLabel) {
                    TextField(terms.placeholder, text: $session.chemistryDraft.registrationNumber)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
            } else if let line = session.registrationCompactLine {
                Label(line, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            // Held back until the record actually claims a registration — see
            // `showsRegistrationIssues`. An operator who has not yet chosen a
            // registered product is not being told they forgot a number nobody
            // asked them for.
            if session.showsRegistrationIssues {
                ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "registration"))
            }

            Picker("Category", selection: $session.productCategory) {
                Text("Uncategorised").tag(ProductCategory?.none)
                ForEach(ProductCategory.allCases) { option in
                    Text(option.label).tag(ProductCategory?.some(option))
                }
            }
            ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "product_category"))

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

            // ONE manufacturer field. It writes the structured registrant, and
            // `SavedChemical.manufacturer` is projected from it on save — there
            // is no second box that could hold a different answer.
            LabeledField(label: "Manufacturer") {
                TextField("e.g. Syngenta", text: $session.manufacturer)
            }
        } header: {
            Text("Product")
        } footer: {
            if let terms = session.registrationTerms {
                Text(terms.helpText)
            } else {
                Text("Fertiliser and nutrient categories unlock pack, N-P-K and inventory fields used by the Fertiliser Calculator.")
            }
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

    /// The actives, EDITABLE, on the main screen.
    ///
    /// This used to be a read-only summary with a button through to a second
    /// editor that held the real thing. Mancozeb 640 g/kg FRAC M3 is what the
    /// operator checks against the drum in their hand, so it lives here — and it
    /// is the same value the resistance model reads, not a copy of it.
    private var activeIngredientsSection: some View {
        Section {
            // The product-level resistance state, stated rather than inferred
            // (task §10, sql/210). A blank used to mean three different things
            // — classified, group-free by design, or simply unestablished — and
            // the Resistance Planner consumes the difference, so the operator
            // is shown the same three answers instead of a gap.
            LabeledContent("Resistance") {
                ChemicalResistanceStateBadge(state: session.resistanceState)
            }
            if session.resistanceState == .unresolved, !session.populatedActives.isEmpty {
                Text("Add the resistance group for each active, or mark it Not applicable. Until then this product is left out of resistance warnings and the Resistance Planner.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach($session.chemistryDraft.actives) { $active in
                ChemicalManualActiveEditor(
                    active: $active,
                    canRemove: session.chemistryDraft.actives.count > 1,
                    onRemove: { removeActive(active.id) }
                )
            }
            ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "active_ingredients"))
            Button {
                session.chemistryDraft.actives.append(ChemicalManualActiveDraft())
            } label: {
                Label("Add Active Ingredient", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Text("Active Ingredients & Resistance")
                Spacer()
                let summary = ChemicalManualEntry.groupSummary(session.chemistryDraft)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Each active ingredient carries its own resistance group, so a two-active product genuinely belongs to both groups at once — which is what resistance planning needs to know.")
        }
    }

    private func removeActive(_ id: UUID) {
        session.chemistryDraft.actives.removeAll { $0.id == id }
        if session.chemistryDraft.actives.isEmpty {
            session.chemistryDraft.actives = [ChemicalManualActiveDraft()]
        }
    }

    /// Crop, target, rate, basis, withholding, re-entry and restrictions — the
    /// canonical rate UI.
    ///
    /// `Rate per ha` and `Rate per 100L` used to sit on this screen as separate
    /// editable numbers, reading `0` while the real 2.5 kg/ha lived one screen
    /// deeper. They are gone: a registered use carries its rate WITH the basis
    /// the label quotes it against, and two scalars cannot express that.
    @ViewBuilder
    private var registeredUsesSection: some View {
        // Reviewing a lookup is not authoring. The uses arrived from the
        // register seconds ago and the operator has nothing to correct in them
        // yet; drawing forty full editors — each with its own Change, remove,
        // "Add Rate For This Use", withholding period and "No registered rate
        // captured" line — buried the one question that actually blocks the
        // save, which is the default rate above.
        if session.isReviewingLookup {
            reviewedUsesSummarySection
        } else {
            editableRegisteredUsesSection
        }
    }

    /// The authoring form: manual entry, and editing a record already on file.
    /// Unchanged behaviour — every registered use stays fully editable here.
    private var editableRegisteredUsesSection: some View {
        Section {
            ForEach($session.chemistryDraft.uses) { $use in
                if use.isViticultural {
                    ChemicalManualUseEditor(
                        use: $use,
                        onRemove: { session.chemistryDraft.uses.removeAll { $0.id == use.id } }
                    )
                }
            }
            if nonVineyardUseCount > 0 {
                DisclosureGroup(isExpanded: $showsNonVineyardUses) {
                    ForEach($session.chemistryDraft.uses) { $use in
                        if !use.isViticultural {
                            ChemicalManualUseEditor(
                                use: $use,
                                onRemove: {
                                    session.chemistryDraft.uses.removeAll { $0.id == use.id }
                                }
                            )
                        }
                    }
                } label: {
                    Label(
                        "Other crops on this label (\(nonVineyardUseCount))",
                        systemImage: "list.bullet.rectangle"
                    )
                    .font(.subheadline)
                }
            }
            // The missing-rate notice belongs to Default Rates, which owns the
            // rate decision. It is repeated here ONLY when that section is off
            // screen (no grapevine registration), so it is shown exactly once
            // and never lost.
            if !defaultRatesSectionIsVisible {
                ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "rates"))
            }
            ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "registered_uses"))

            // Valid label rates whose governing condition the label never
            // attributed (task §5). The numbers are authoritative; the
            // association is not, so the operator has to say which applies
            // before a spray calculation may use one.
            if session.ratesNeedingConditionChoice > 0 {
                ChemicalRateAmbiguityNotice(count: session.ratesNeedingConditionChoice)
            }

            Button {
                session.chemistryDraft.uses.append(ChemicalManualUseDraft())
            } label: {
                Label("Add Registered Use", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Grapevine Uses & Rates")
        } footer: {
            Text(vineyardUseCount > 0 && nonVineyardUseCount > 0
                ? "A use is a crop and a target the product is registered against, with the rate as the label states it and any withholding or re-entry period. The basis is kept exactly as printed — a per-100 L rate is never restated per hectare. Grapevine uses are shown first; the label's other crops are kept in full under “Other crops”."
                : "A use is a crop and a target the product is registered against, with the rate as the label states it and any withholding or re-entry period. The basis is kept exactly as printed — a per-100 L rate is never restated per hectare.")
        }
    }

    /// The lookup-review summary: what the register says this product is
    /// registered against on grapevines, and nothing more.
    ///
    /// Read-only on purpose. The rate decision lives in Default Rates above,
    /// and repeating a rate control per target is what produced two different
    /// places to answer the same mandatory question.
    private var reviewedUsesSummarySection: some View {
        let targets = reviewedGrapevineTargets
        let visible = showsAllReviewedUses ? targets : Array(targets.prefix(5))
        return Section {
            if targets.isEmpty {
                Text("No grapevine target was named on the label.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // The crop, stated ONCE. It was previously repeated as a full
                // "Crop: Grapevine" field on every single use.
                Text("Grapevine")
                    .font(.subheadline.weight(.semibold))
                ForEach(visible, id: \.self) { target in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 5))
                            .foregroundStyle(.tertiary)
                        Text(target)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if targets.count > 5 {
                    Button(showsAllReviewedUses
                        ? "Show fewer"
                        : "Show all \(targets.count) uses") {
                        showsAllReviewedUses.toggle()
                    }
                    .font(.callout)
                }
            }
            if nonVineyardUseCount > 0 {
                DisclosureGroup(isExpanded: $showsNonVineyardUses) {
                    // Read-only too: still on the record, still saved, but not
                    // something to edit while confirming a lookup.
                    ForEach(session.chemistryDraft.uses.filter { !$0.isViticultural }) { use in
                        Text(reviewedOtherCropSummary(use))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Label(
                        "Other crops on this label (\(nonVineyardUseCount))",
                        systemImage: "list.bullet.rectangle"
                    )
                    .font(.subheadline)
                }
            }
            if !defaultRatesSectionIsVisible {
                ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "rates"))
            }
            ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "registered_uses"))
        } header: {
            Text("Registered grapevine uses (\(targets.count))")
        } footer: {
            Text("What the register lists this product against on grapevines. Confirm the rate this vineyard doses by in Default Rates above.")
        }
    }

    /// Grapevine target names, deduplicated case-insensitively, in label order.
    ///
    /// A register reply routinely states the same target several times under
    /// different conditions. Those are different RATES, not different targets,
    /// and listing "Powdery mildew" six times said nothing six times.
    private var reviewedGrapevineTargets: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for use in session.chemistryDraft.uses where use.isViticultural {
            let target = use.targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { continue }
            guard seen.insert(target.lowercased()).inserted else { continue }
            ordered.append(target)
        }
        return ordered
    }

    private func reviewedOtherCropSummary(_ use: ChemicalManualUseDraft) -> String {
        let crop = use.crop.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = use.targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        return [crop, target].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// Whether the Default Rates section is on screen. It owns the missing-rate
    /// notice whenever it is, so the notice is never drawn twice.
    private var defaultRatesSectionIsVisible: Bool {
        session.isRegisteredForGrapevine
    }

    private var vineyardUseCount: Int {
        session.chemistryDraft.uses.count(where: \.isViticultural)
    }

    private var nonVineyardUseCount: Int {
        session.chemistryDraft.uses.count - vineyardUseCount
    }

    /// Whether to offer product-level label rates.
    ///
    /// Shown when the record has some — including an older record whose scalar
    /// rate was lifted into structure as this screen opened — or when there are
    /// no uses yet to hang a rate on.
    private var showsProductRates: Bool {
        !session.chemistryDraft.productRates.isEmpty || session.chemistryDraft.uses.isEmpty
    }

    private var productRatesSection: some View {
        Section {
            ForEach($session.chemistryDraft.productRates) { $rate in
                ChemicalManualRateEditor(
                    rate: $rate,
                    onRemove: { session.chemistryDraft.productRates.removeAll { $0.id == rate.id } }
                )
            }
            Button {
                session.chemistryDraft.productRates.append(ChemicalManualRateDraft())
            } label: {
                Label("Add Label Rate", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Product Label Rates")
        } footer: {
            Text("Rates the label states for the product as a whole. This is not your spray rate or carrier volume — those belong to each spray job.")
        }
    }

    /// The old free-text use, offered ONLY while nothing structured exists.
    ///
    /// Once a registered use is on record it is authoritative, and this section
    /// disappears rather than competing with it.
    private var legacyUseSection: some View {
        Section {
            LabeledField(label: "Use / Problem") {
                TextField("e.g. Fungicide", text: $session.use)
            }
            LabeledField(label: "Target Problem") {
                TextField("e.g. Powdery Mildew", text: $session.problem)
            }
        } header: {
            Text("Use")
        } footer: {
            Text("No registered use is on record for this product yet. Adding one above records the crop, target, rate, withholding period and re-entry period properly — these two boxes cannot.")
        }
    }

    /// The operator's operational default rate, per basis (task §5–§7).
    ///
    /// # Why this is separate from the registered rates above
    ///
    /// The section above records what the LABEL says — every registered rate,
    /// with its condition, unedited. This records what THIS VINEYARD doses by.
    /// Choosing here changes no registered rate and removes none: the label did
    /// not change because a grower picked a number off it, and a re-verification
    /// still has the full list to compare against.
    private var defaultRatesSection: some View {
        Section {
            ChemicalDefaultRatesView(
                plan: session.defaultRatePlan,
                selectedIds: session.selectedDefaultRateIds,
                values: session.defaultRateValues,
                onSelect: { basis, option in
                    session.selectDefaultRate(option, for: basis)
                },
                onSetValue: { basis, value in
                    // Refused when the label does not authorise it. The
                    // registered range itself is never edited by this.
                    session.setDefaultRateValue(value, for: basis)
                },
                onClearValue: { basis in
                    session.clearDefaultRateValue(for: basis)
                }
            )
            // The rate gate lives with the rate decision. It used to sit under
            // the registered-use list, which is where an operator looked for a
            // control that was never there.
            ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "rates"))
        } header: {
            Text("Default Rates")
        } footer: {
            Text(defaultRatesFooter)
        }
    }

    private var defaultRatesFooter: String {
        var base = "The rate VineTrack will start a spray calculation from. "
            + "Chosen from the registered grapevine rates below — the two bases "
            + "are decided separately and never converted into one another."
        // Says WHY Save is disabled. This is wording only: the rule itself is
        // `session.isValid`, so this line can never let a save through or hold
        // one back on its own.
        if session.isAwaitingDefaultRateConfirmation {
            base += " Confirm the rate this vineyard uses before saving — for a "
                + "label range, enter your own rate from inside it."
        }
        guard session.jurisdiction == nil,
              session.defaultRatePlan.requiresChoice
        else { return base }
        // Honest about WHY it is asking: with no vineyard state on record it
        // cannot narrow a state-conditioned label, and it will not guess.
        return base + " This label conditions rates by state, and VineTrack "
            + "has no state on record for this vineyard, so it cannot narrow "
            + "them for you."
    }

    /// Two DISTINCT external references (task §8).
    ///
    /// The regulator label is the authoritative document — APVMA in Australia,
    /// ACVM/EPA in New Zealand — and it leads the section with its own Open
    /// action. The manufacturer page is supplementary and is drawn as such:
    /// separate label, separate row, secondary wording. A marketing page must
    /// never be able to pass for an approved label, which is why these are two
    /// fields and not one "link".
    private var labelsSection: some View {
        Section {
            // MANUFACTURER LABEL FIRST.
            //
            // This is the label a grower physically holds and the one whose
            // rate table VineTrack reads. The regulator's copy stays directly
            // beneath it and is never replaced — leading with the practical
            // document is not the same as discarding the authoritative one.
            LabeledURLField(
                label: "Manufacturer label",
                placeholder: "https://...",
                text: $session.manufacturerLabelURL,
                onOpenFailure: { message in
                    linkAlertMessage = message
                    showLinkAlert = true
                }
            )

            LabeledURLField(
                label: officialLabelFieldLabel,
                placeholder: "https://...",
                text: $session.labelURL,
                onOpenFailure: { message in
                    linkAlertMessage = message
                    showLinkAlert = true
                }
            )
            ChemicalSaveIssueNotice(issues: session.saveIssues(forField: "label_reference"))

            LabeledURLField(
                label: "Manufacturer product page (optional)",
                placeholder: "https://...",
                text: $session.productURL,
                onOpenFailure: { message in
                    linkAlertMessage = message
                    showLinkAlert = true
                }
            )
        } header: {
            Text("Labels & References")
        } footer: {
            Text("The manufacturer label is the practical label VineTrack reads rates from. The \(officialLabelFieldLabel.lowercased()) is the authoritative registration document and is always kept. A manufacturer product page is supplementary and is never shown as an approved label.")
        }
    }

    /// The regulator's own name for its label, so the field says what it IS.
    ///
    /// "Official Label URL" was true but anonymous. In Australia the
    /// authoritative document is the APVMA label, and naming it is what makes
    /// the distinction from the manufacturer page below self-evident.
    private var officialLabelFieldLabel: String {
        guard let scheme = session.registrationTerms?.schemes.first else {
            return "Official regulator label"
        }
        return "\(scheme.label) label"
    }

    /// Registration identity: a compact line, with the plumbing behind a
    /// disclosure.
    ///
    /// The identifier matters enormously INTERNALLY — telling similarly named
    /// products apart, matching the official register, linking the Master
    /// Catalogue, re-verification, refusing cross-country matches. None of that
    /// makes it something to hand a grower as a blank, required-looking box
    /// labelled "Registration Number", which is jargon for a number they can
    /// only find on the drum under its own national name.
    ///
    /// So VineTrack fills it in when a lookup finds one, states it in the
    /// jurisdiction's own words, says plainly when there is none, and never asks.
    private var advancedSection: some View {
        Section {
            // The RESULT of verification stays visible — that is what the
            // operator needs. The machinery that produced it goes inside.
            if let intelligence = session.editOutcome?.intelligence ?? session.seedIntelligence {
                LabeledContent("Verification") {
                    Text(intelligence.resolvedVerificationStatus.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Verification evidence", isExpanded: $showTechnicalDetails) {
                technicalDetails
            }
            .font(.subheadline)

            HStack(spacing: 8) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.secondary)
                Text("Saved chemicals are shared with all users of this vineyard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Research provenance, source URLs and extraction details are kept for auditing. You should not need them for normal use.")
        }
    }

    /// Identity plumbing and evidence. Collapsed by default, never required.
    @ViewBuilder
    private var technicalDetails: some View {
        Picker("Registered in", selection: $session.countryCode) {
            Text("Not stated").tag("")
            Text("Australia").tag("AU")
            Text("New Zealand").tag("NZ")
            // A vineyard may stock an imported product, so the product's own
            // country is never assumed to be the vineyard's.
            if !["", "AU", "NZ"].contains(session.countryCode) {
                Text(session.countryCode).tag(session.countryCode)
            }
        }

        // Only ever the registers that exist in this jurisdiction. An APVMA
        // field has no meaning in New Zealand, and the reverse.
        if let terms = session.registrationTerms {
            Picker("Register", selection: $session.chemistryDraft.registrationScheme) {
                Text("Not stated").tag(ChemicalRegistrationScheme?.none)
                ForEach(terms.schemes, id: \.self) { scheme in
                    Text(scheme.label).tag(ChemicalRegistrationScheme?.some(scheme))
                }
            }
            LabeledField(label: terms.fieldLabel) {
                TextField(terms.placeholder, text: $session.chemistryDraft.registrationNumber)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
        }

        if let intelligence = session.editOutcome?.intelligence ?? session.seedIntelligence {
            LabeledContent("Evidence") {
                Text(intelligence.resolvedVerificationStatus.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !intelligence.verification.conflicts.isEmpty {
                ChemicalConflictCard(conflicts: intelligence.verification.conflicts)
                    .padding(.vertical, 4)
            }
            if !intelligence.verification.unresolvedFields.isEmpty {
                Text("Not established: "
                     + intelligence.verification.unresolvedFields.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
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
                 : "Search for this product above to identify it against the register.")
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
        // The legacy scalars are DERIVED here, from the structured record, and
        // written alongside it for older clients and the existing API. Nothing
        // on this screen edits them, so a stale scalar has no way back into the
        // chemistry:
        //
        //     structured Chemical Intelligence  →  legacy compatibility fields
        //
        // and never the reverse.
        let legacy = session.legacyProjection()
        let rates = legacy.rates

        // Preserve existing purchase data when the editor cannot see/edit
        // financials so that owners/managers don't lose cost values when a
        // supervisor/operator edits the same chemical for other details.
        var purchase: ChemicalPurchase? = canViewFinancials ? nil : chemical?.purchase
        if canViewFinancials, session.trackPurchase {
            let containerSize = Double(session.containerSizeText) ?? 0
            let cost = Double(session.costText) ?? 0
            if containerSize > 0 || cost > 0 {
                purchase = ChemicalPurchase(
                    brand: legacy.manufacturer,
                    activeIngredient: legacy.activeIngredient,
                    chemicalGroup: legacy.chemicalGroup,
                    labelURL: legacy.labelURL,
                    costDollars: cost,

                    containerSizeML: containerSize,
                    containerUnit: session.containerUnit
                )
            }
        }

        let parseOptional: (String) -> Double? = { Double($0.replacingOccurrences(of: ",", with: ".")) }
        let productForm = session.formType == .liquid ? "liquid" : "solid"
        let packUnit = session.formType == .liquid ? "L" : "kg"

        if var existing = chemical {
            existing.name = session.name
            existing.unit = session.unit
            existing.chemicalGroup = legacy.chemicalGroup
            existing.use = legacy.use
            existing.manufacturer = legacy.manufacturer
            existing.notes = session.notes
            existing.problem = legacy.problem
            existing.ratePerHa = legacy.ratePerHa
            existing.activeIngredient = legacy.activeIngredient
            // Mode of action is no longer an editable chemistry input — the group
            // is structured per active now — so whatever the record already held
            // is carried through untouched rather than dropped.
            existing.modeOfAction = session.modeOfAction
            existing.labelURL = legacy.labelURL
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
            // The structured chemistry this edit should persist.
            //
            // `intelligenceToPersist` — NOT `editOutcome` — for the same reason
            // the create path below uses it. `editOutcome` is deliberately nil
            // when the draft round-trips unchanged, because there is nothing NEW
            // to reconcile. On a plain edit that is exactly right: the record
            // already holds this chemistry, so writing it again would be a
            // no-op.
            //
            // On MATCH & VERIFY it was a silent data loss. There the session is
            // seeded from the reviewed lookup (`prefill`), so "unchanged" means
            // "the operator accepted the lookup as found" — the single most
            // likely outcome of a review. `outcome` was nil, this line never
            // ran, and the record kept the OLD intelligence it was matched to:
            // registration number, actives, registered uses, WHP, re-entry,
            // restrictions and sources all discarded at the moment of saving
            // them.
            //
            // Worse, the legacy scalars a few lines above are projected from
            // `intelligenceToPersist`, so the row ended up internally
            // inconsistent — `active_ingredient` naming the newly found
            // chemistry while the structured columns still described the old
            // product.
            //
            // Falling back to the seed keeps the unrelated-edit case identical
            // (it rewrites the same value it read) while making the reviewed
            // lookup actually persist. Android's match flow always writes its
            // resolved intelligence; this is what brings iOS level with it.
            if let persisted = session.intelligenceToPersist {
                existing.chemicalIntelligence = persisted
            }
            // The confirmed operational default (sql/214). Written only when
            // this edit actually carries a confirmed choice; otherwise the
            // stored default is left exactly as it was, so saving an unrelated
            // change can never erase a decision the operator made earlier or on
            // another device.
            if let confirmed = session.storedDefaultRates {
                existing.defaultRates = confirmed
            }
            store.updateSavedChemical(existing)
            return store.savedChemicals.first { $0.id == existing.id } ?? existing
        } else {
            let new = SavedChemical(
                name: session.name,
                ratePerHa: legacy.ratePerHa,
                unit: session.unit,
                chemicalGroup: legacy.chemicalGroup,
                use: legacy.use,
                manufacturer: legacy.manufacturer,
                notes: session.notes,
                problem: legacy.problem,
                activeIngredient: legacy.activeIngredient,
                rates: rates,
                purchase: purchase,
                labelURL: legacy.labelURL,
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
                masterSourceRevision: session.masterSourceRevision,
                // The confirmed operational default (sql/214). Nil when the
                // operator confirmed nothing — a new chemical with no confirmed
                // rate simply records none, which is honest and leaves the
                // label evidence in `registered_uses` untouched.
                defaultRates: session.storedDefaultRates
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
