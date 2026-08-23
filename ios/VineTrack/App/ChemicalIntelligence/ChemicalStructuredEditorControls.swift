import SwiftUI

/// The structured chemistry controls, as reusable rows.
///
/// These used to be private to `ChemicalManualEditorView` — a second, full
/// chemical editor reached from a button on the Review Chemical screen. That
/// arrangement gave the operator two editable copies of the same product:
/// Review Chemical showed "Rate per ha: 0" while the Chemistry & Identity
/// screen behind it held the real 2.5 kg/ha, and both claimed to be the record.
///
/// The second editor is gone. Its controls live here and are rendered directly
/// as sections of the one Review Chemical form, so there is one place to read a
/// rate and one place to change it.

// MARK: - Active ingredient editor

/// One active ingredient, with its own concentration and its own group.
struct ChemicalManualActiveEditor: View {
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
struct ChemicalManualRateEditor: View {
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

// MARK: - Target vocabulary policy

/// When VineTrack's own target vocabulary may be offered as chips.
///
/// A registered use is the REGULATOR'S record. Showing VineTrack's generic
/// target list under every authoritative APVMA use row presented those words as
/// though the label registered them, when they are only VineTrack's vocabulary.
/// An operator reading a use as evidence could not tell which targets came from
/// the label and which came from the app.
///
/// The suggestions are therefore an EDITING aid, not part of the record's
/// display: they appear only where the operator is actually choosing a target.
nonisolated enum ChemicalTargetSuggestionPolicy {

    /// Whether to offer the vineyard target vocabulary for this use.
    ///
    /// Shown while editing, and when there is no target yet — an empty use is
    /// an unanswered question, so the vocabulary is help rather than a claim
    /// about the label.
    static func showsVocabularySuggestions(targetRaw: String, isEditingTarget: Bool) -> Bool {
        isEditingTarget || targetRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the given text names this VineTrack target.
    ///
    /// Compared case- and diacritic-insensitively because the field is free
    /// text: a target imported as "powdery mildew " is the same answer as the
    /// chip's "Powdery Mildew", and showing it as unselected would invite the
    /// operator to tap the chip and create a second spelling of one target.
    static func matches(targetRaw: String, target: SprayTarget) -> Bool {
        targetRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(target.label, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

// MARK: - Use editor

/// One registered use: crop, target, its own rates, and its restrictions.
struct ChemicalManualUseEditor: View {
    @Binding var use: ChemicalManualUseDraft
    let onRemove: () -> Void

    /// Whether the operator has opened this target for editing.
    ///
    /// Local to the row on purpose: opening one use's target must not reveal
    /// the vocabulary under every other use on the label.
    @State private var isEditingTarget: Bool = false

    private var showsTargetSuggestions: Bool {
        ChemicalTargetSuggestionPolicy.showsVocabularySuggestions(
            targetRaw: use.targetRaw,
            isEditingTarget: isEditingTarget
        )
    }

    private func matchesTarget(_ target: SprayTarget) -> Bool {
        ChemicalTargetSuggestionPolicy.matches(targetRaw: use.targetRaw, target: target)
    }

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

            targetField

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

    /// The target, shown as the label states it until the operator chooses to
    /// change it.
    ///
    /// In normal review the registered target reads as a plain authoritative
    /// value with nothing of VineTrack's alongside it. "Change" is what turns
    /// the row into an editor, and only then does the vineyard vocabulary
    /// appear — where its role as a suggestion is unambiguous.
    @ViewBuilder
    private var targetField: some View {
        if showsTargetSuggestions {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Target, e.g. Powdery Mildew", text: $use.targetRaw)
                        .font(.subheadline)
                    if isEditingTarget {
                        Button("Done") { isEditingTarget = false }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                }

                // The vocabulary assists entry without bounding it: a label may
                // register a target VineTrack has no word for, and that use must
                // still be recordable — hence a free-text field with chips
                // beside it rather than a picker.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(SprayTarget.allCases) { target in
                            let isSelected = matchesTarget(target)
                            Button {
                                // Tapping the chip already in the field clears
                                // it. Without this the chips are one-way: a
                                // mis-tap could be corrected only by choosing a
                                // different target or retyping by hand.
                                use.targetRaw = isSelected ? "" : target.label
                            } label: {
                                HStack(spacing: 3) {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.weight(.bold))
                                    }
                                    Text(target.label)
                                        .font(.caption2)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.accentColor.opacity(isSelected ? 0.28 : 0.12))
                                .foregroundStyle(isSelected ? Color.accentColor : .primary)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        }
                    }
                }

                Text("Suggestions from VineTrack's vineyard targets. Type the target exactly as the label words it if it is not listed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(use.targetRaw)
                    .font(.subheadline)
                Spacer()
                Button("Change") { isEditingTarget = true }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }
}
