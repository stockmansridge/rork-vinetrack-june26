import SwiftUI

/// The structured manual Chemical editor.
///
/// This replaces the legacy scalar chemistry boxes — one `Active Ingredient`
/// text field and one `Chemical Group` text field — with the shape the record
/// actually has: a list of actives, each carrying its own concentration and its
/// own resistance group, plus structured label rates and structured uses.
///
/// The operator can no longer produce `Chemical Group = "3 + 11"`, because that
/// string was never a fact about a product. They produce Tebuconazole → FRAC 3
/// and Azoxystrobin → FRAC 11, two independent relationships, and `"FRAC 3 + 11"`
/// is displayed back to them as a derived summary.
///
/// Every decision this screen makes is delegated to `ChemicalManualEntry`. The
/// view collects text; it does not decide what any of it means, and in
/// particular it never decides what the record's verification status becomes.
struct ChemicalManualEditorView: View {
    @Environment(\.dismiss) private var dismiss

    /// The draft being edited. Bound so the parent form keeps the edits when
    /// this sheet closes and writes them with its own Save.
    @Binding var draft: ChemicalManualDraft

    /// The record's stored intelligence, for reconciling against. `nil` for a
    /// brand-new product.
    let existing: ChemicalIntelligence?

    @State private var showAllCountries: Bool = false

    /// What storing this draft would do to the record's trust.
    ///
    /// Recomputed as the operator types so the consequence is visible before
    /// they commit, and computed by the domain so this screen cannot flatter it.
    private var outcome: ChemicalEditOutcome {
        ChemicalManualEntry.outcome(for: draft, existing: existing)
    }

    private var problems: [String] { ChemicalManualEntry.problems(in: draft) }

    var body: some View {
        NavigationStack {
            Form {
                verificationSection
                productSection
                activesSection
                productRatesSection
                usesSection
                if !problems.isEmpty { problemsSection }
            }
            .navigationTitle("Chemistry & Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Verification

    /// Trust, stated at the top, alongside what the current draft would make it.
    ///
    /// There is no control here. Verification is the conclusion the evidence
    /// reaches, so the only honest thing a manual editor can do about it is
    /// report it.
    private var verificationSection: some View {
        Section {
            HStack {
                Text("Current")
                Spacer()
                ChemicalVerificationBadge(
                    status: existing?.resolvedVerificationStatus ?? .unverified
                )
            }
            HStack {
                Text("After saving")
                Spacer()
                ChemicalVerificationBadge(status: outcome.resolvedStatus)
            }
            if let warning = outcome.warning {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Verification will be updated", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            if !outcome.intelligence.verification.conflicts.isEmpty {
                ChemicalConflictCard(conflicts: outcome.intelligence.verification.conflicts)
                    .padding(.vertical, 4)
            }
        } header: {
            Text("Verification")
        } footer: {
            Text("Information you enter yourself is recorded as unverified. It stays that way until Match & Verify or Re-verify confirms it against a register — completing every field does not make it verified.")
        }
    }

    // MARK: - Product

    private var productSection: some View {
        Section {
            LabeledField(label: "Product Name") {
                TextField("e.g. Custom Tank Mix Partner", text: $draft.productName)
            }
            Picker("Country", selection: $draft.countryCode) {
                Text("Not stated").tag("")
                Text("Australia").tag("AU")
                Text("New Zealand").tag("NZ")
                // A vineyard may stock an imported product, so the country the
                // product is registered in is not assumed to be the vineyard's.
                if !["", "AU", "NZ"].contains(draft.countryCode) {
                    Text(draft.countryCode).tag(draft.countryCode)
                }
            }
            Picker("Product Type", selection: $draft.productCategory) {
                Text("Uncategorised").tag("")
                ForEach(ProductCategory.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            LabeledField(label: "Manufacturer / Registrant (optional)") {
                TextField("e.g. Syngenta", text: $draft.registrant)
            }
            Picker("Register (optional)", selection: $draft.registrationScheme) {
                Text("Not stated").tag(ChemicalRegistrationScheme?.none)
                ForEach(schemeOptions, id: \.self) { scheme in
                    Text(scheme.label).tag(ChemicalRegistrationScheme?.some(scheme))
                }
            }
            LabeledField(label: "Registration Number (optional)") {
                TextField("e.g. 62764", text: $draft.registrationNumber)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
        } header: {
            Text("Product")
        } footer: {
            Text("A registration number you type is recorded as your own entry, not as confirmed identity. It is the first thing Match & Verify and Re-verify will use when they check this product against the register later.")
        }
    }

    /// Registers offered for the chosen country, with the full list as a
    /// fallback so an imported product is never unrepresentable.
    private var schemeOptions: [ChemicalRegistrationScheme] {
        let forCountry = ChemicalRegistrationScheme.schemes(forCountryCode: draft.countryCode)
        guard !forCountry.isEmpty else { return ChemicalRegistrationScheme.allCases }
        return forCountry + [.other]
    }

    // MARK: - Active ingredients

    /// The heart of the editor: one row per active, each with its own group.
    private var activesSection: some View {
        Section {
            ForEach($draft.actives) { $active in
                ChemicalManualActiveEditor(
                    active: $active,
                    canRemove: draft.actives.count > 1,
                    onRemove: { remove(activeId: active.id) }
                )
            }
            Button {
                draft.actives.append(ChemicalManualActiveDraft())
            } label: {
                Label("Add Active Ingredient", systemImage: "plus.circle.fill")
            }
        } header: {
            HStack {
                Text("Active Ingredients")
                Spacer()
                let summary = ChemicalManualEntry.groupSummary(draft)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Each active ingredient carries its own resistance group. A two-active product genuinely belongs to both groups at once, which is what resistance planning needs to know — so it is recorded as two separate entries, not as one combined group.")
        }
    }

    private func remove(activeId: UUID) {
        draft.actives.removeAll { $0.id == activeId }
        if draft.actives.isEmpty { draft.actives = [ChemicalManualActiveDraft()] }
    }

    // MARK: - Product label rates

    /// Rates the LABEL states for the product, which is not the same thing as
    /// the carrier volume a particular pass is mixed at.
    private var productRatesSection: some View {
        Section {
            ForEach($draft.productRates) { $rate in
                ChemicalManualRateEditor(
                    rate: $rate,
                    onRemove: { draft.productRates.removeAll { $0.id == rate.id } }
                )
            }
            Button {
                draft.productRates.append(ChemicalManualRateDraft())
            } label: {
                Label("Add Label Rate", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Product Label Rates")
        } footer: {
            Text("The rate as the label states it — per hectare, per 100 L, or a range. This is not your spray rate or carrier volume: those belong to each spray job, and the vineyard's carrier settings are unaffected by what you enter here.")
        }
    }

    // MARK: - Uses

    private var usesSection: some View {
        Section {
            ForEach($draft.uses) { $use in
                ChemicalManualUseEditor(
                    use: $use,
                    onRemove: { draft.uses.removeAll { $0.id == use.id } }
                )
            }
            Button {
                draft.uses.append(ChemicalManualUseDraft())
            } label: {
                Label("Add Use", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Uses & Restrictions")
        } footer: {
            Text("A use is a crop and a target the product is registered against, with the rate and any withholding or re-entry period that applies. Recorded as your own entry until authoritative evidence confirms it.")
        }
    }

    // MARK: - Problems

    private var problemsSection: some View {
        Section("Check These") {
            ForEach(problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Active ingredient editor

/// One active ingredient, with its own concentration and its own group.
private struct ChemicalManualActiveEditor: View {
    @Binding var active: ChemicalManualActiveDraft
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Active ingredient name", text: $active.name)
                    .font(.subheadline.weight(.semibold))
                    .autocorrectionDisabled()
                if canRemove {
                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove active ingredient")
                }
            }

            HStack(spacing: 8) {
                TextField("Concentration", text: $active.concentrationText)
                    .keyboardType(.decimalPad)
                    .frame(maxWidth: 110)
                Picker("Unit", selection: $active.concentrationUnit) {
                    Text("Unit").tag(ChemicalConcentrationUnit?.none)
                    ForEach(ChemicalConcentrationUnit.allCases, id: \.self) { unit in
                        Text(unit.label).tag(ChemicalConcentrationUnit?.some(unit))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            // Scheme first, then code. A bare "3" means nothing until the system
            // is known: FRAC 3 and IRAC 3 are unrelated chemistries.
            Picker("Resistance Group System", selection: $active.scheme) {
                Text("Not stated").tag(ChemicalActivityGroupScheme?.none)
                Text("FRAC — Fungicides").tag(ChemicalActivityGroupScheme?.some(.frac))
                Text("HRAC — Herbicides").tag(ChemicalActivityGroupScheme?.some(.hrac))
                Text("IRAC — Insecticides").tag(ChemicalActivityGroupScheme?.some(.irac))
                Text("Not applicable").tag(ChemicalActivityGroupScheme?.some(.notApplicable))
            }
            .font(.subheadline)

            if active.scheme != nil, active.scheme != .notApplicable {
                LabeledContent("Group") {
                    // Free text on purpose. Resistance classification tables are
                    // reissued annually and gain codes; a hard-coded list would
                    // make this year's product unrecordable next season.
                    TextField("e.g. 3, 11, M5, 4A", text: $active.groupCode)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                }
                .font(.subheadline)
            }

            if let reference = referenceGroup {
                Label(
                    "Reference table: \(reference.displayLabel)",
                    systemImage: "checkmark.seal"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// What the local classification table says this active belongs to, shown as
    /// help while typing.
    ///
    /// Only ever displayed. The operator's own value is what gets stored, and a
    /// genuine disagreement is raised as a conflict by the reconciler rather than
    /// being silently corrected here.
    private var referenceGroup: ChemicalActivityGroup? {
        let name = active.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 3 else { return nil }
        return AuthoritativeActivityGroups.group(forActiveNamed: name)
    }
}

// MARK: - Rate editor

/// One label rate: a basis, then whichever value shape that basis needs.
private struct ChemicalManualRateEditor: View {
    @Binding var rate: ChemicalManualRateDraft
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Basis", selection: $rate.basis) {
                    ForEach(ChemicalLabelRateBasis.allCases, id: \.self) { basis in
                        Text(basis.label).tag(basis)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.subheadline)
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove label rate")
            }

            switch rate.basis {
            case .perHectare, .per100Litres:
                HStack(spacing: 8) {
                    TextField("Rate", text: $rate.valueText)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 100)
                    unitField
                    Text(rate.basis.suffix)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .rangePerHectare, .rangePer100Litres:
                HStack(spacing: 8) {
                    TextField("Min", text: $rate.minText)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 74)
                    Text("–").foregroundStyle(.secondary)
                    TextField("Max", text: $rate.maxText)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 74)
                    unitField
                    Text(rate.basis.suffix)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            case .other:
                TextField("Rate as the label words it", text: $rate.rawText)
                    .font(.subheadline)
            }

            TextField("Rate name, e.g. High disease pressure (optional)", text: $rate.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var unitField: some View {
        Picker("Unit", selection: $rate.unit) {
            ForEach(["L", "mL", "kg", "g"], id: \.self) { unit in
                Text(unit).tag(unit)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

// MARK: - Use editor

/// One registered use: crop, target, its own rates, and its restrictions.
private struct ChemicalManualUseEditor: View {
    @Binding var use: ChemicalManualUseDraft
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Crop, e.g. Grapes", text: $use.crop)
                    .font(.subheadline.weight(.semibold))
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove use")
            }

            TextField("Target, e.g. Powdery Mildew", text: $use.targetRaw)
                .font(.subheadline)

            // VineTrack's own targets assist entry without bounding it: a label
            // may register a target VineTrack has no word for, and that use must
            // still be recordable.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SprayTarget.allCases) { target in
                        Button {
                            use.targetRaw = target.label
                        } label: {
                            Text(target.label)
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ForEach($use.rates) { $rate in
                ChemicalManualRateEditor(
                    rate: $rate,
                    onRemove: { use.rates.removeAll { $0.id == rate.id } }
                )
            }
            Button {
                use.rates.append(ChemicalManualRateDraft())
            } label: {
                Label("Add Rate For This Use", systemImage: "plus.circle")
                    .font(.caption)
            }

            LabeledContent("Withholding Period") {
                HStack(spacing: 4) {
                    TextField("0", text: $use.withholdingPeriodDaysText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("days").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            LabeledContent("Re-entry Period") {
                HStack(spacing: 4) {
                    TextField("0", text: $use.reEntryPeriodHoursText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("hours").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            TextField("Label restrictions (optional)", text: $use.restrictions, axis: .vertical)
                .font(.caption)
                .lineLimit(1...3)
        }
        .padding(.vertical, 6)
    }
}
