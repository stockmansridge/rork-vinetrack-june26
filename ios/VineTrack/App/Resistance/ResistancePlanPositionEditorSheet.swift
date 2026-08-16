import SwiftUI

/// Chemistry editor for one planned position.
///
/// GROUP FIRST, PRODUCT SECOND. The operator picks a FRAC group before any brand is
/// offered, because rotation is a property of the mode of action and leading with
/// products invites planning a season around what is in the shed rather than around
/// what the strategy permits. Products appear only once a group is chosen, and only
/// from the vineyard's own Chemical Store.
struct ResistancePlanPositionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let position: ResistancePlannedPosition
    let positionIndex: Int
    let plannerRequest: ResistancePlanner.Request
    let chemicalCandidates: [ResistancePlanChemicalCandidate]
    let jurisdiction: ResistanceJurisdiction
    let onSave: (ResistancePlannedPosition) -> Void

    @State private var selectedSignature: ResistanceGroupSignature?
    @State private var selectedProductIds: Set<String> = []
    @State private var hasTargetDate: Bool = false
    @State private var targetDate: Date = Date()
    @State private var growthStage: String = ""
    @State private var note: String = ""

    private var groupOptions: [ResistancePlanGroupOption] {
        ResistancePlanner.groupOptions(at: positionIndex, request: plannerRequest)
    }

    private var productOptions: [ResistancePlanProductOption] {
        guard let signature = selectedSignature else { return [] }
        return ResistancePlanner.productOptions(
            for: signature,
            candidates: chemicalCandidates,
            jurisdiction: jurisdiction
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                recommendationSection
                groupSection
                if selectedSignature != nil { productSection }
                timingSection
                noteSection
            }
            .navigationTitle("Spray \(positionIndex + 1) chemistry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(selectedSignature == nil)
                }
            }
            .onAppear(perform: seed)
        }
    }

    // MARK: - Recommendation

    private var recommendationSection: some View {
        Section {
            // Language is deliberately permissive, never prescriptive: these are
            // strategy-compatible options, not a "best product" and not an
            // instruction to spray.
            Text("Prefer a different effective FRAC group from the recent sequence. The options below are strategy-compatible for the selected blocks at this point in the sequence.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Recommended next chemistry")
        }
    }

    // MARK: - Groups

    private var groupSection: some View {
        Section {
            if groupOptions.isEmpty {
                Text("No strategy-compatible group could be identified for this position. Review the earlier positions in the sequence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(groupOptions, id: \.listing.displayName) { option in
                Button {
                    // Changing the group invalidates any product chosen for the old
                    // one, so the selection is cleared rather than silently carried
                    // onto chemistry it no longer matches.
                    selectedSignature = option.listing.signature
                    selectedProductIds = []
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedSignature == option.listing.signature
                              ? "largecircle.fill.circle"
                              : "circle")
                            .foregroundStyle(selectedSignature == option.listing.signature
                                             ? VineyardTheme.leafGreen : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.listing.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(option.listing.modeOfActionName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(option.status.label)
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(option.status == .goodFit ? VineyardTheme.leafGreen : .orange)
                                if option.differsFromRecentSequence {
                                    Text("rotates away from recent groups")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Browse by FRAC group")
        } footer: {
            Text("A FRAC group does not establish registered grape use, disease efficacy or a suitable rate. Always check the product label.")
                .font(.caption2)
        }
    }

    // MARK: - Products

    private var productSection: some View {
        Section {
            if productOptions.isEmpty {
                Text("No product in this vineyard's Chemical Store carries this group. You can still plan the group on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(productOptions) { option in
                Button {
                    toggleProduct(option)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedProductIds.contains(option.candidate.savedChemicalId)
                              ? "checkmark.square.fill"
                              : "square")
                            .foregroundStyle(selectedProductIds.contains(option.candidate.savedChemicalId)
                                             ? VineyardTheme.leafGreen : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(option.candidate.productName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text(option.candidate.availability.plannerMark)
                                    .font(.caption)
                            }
                            Text(option.candidate.groups.displayLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !option.isExactSignatureMatch {
                                Text("Also contains other groups — evaluated as a co-formulation")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            // Registered-use evidence, stated as evidence. Never
                            // presented as a registration claim the data cannot support.
                            Text(option.registeredUseNote)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let caveat = option.caveat {
                                Label(caveat, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("\(selectedSignature?.displayLabel ?? "") options in Chemical Store")
        } footer: {
            Text("Optional. A product adds identity and verification state; the resistance result comes from the group structure either way.")
                .font(.caption2)
        }
    }

    // MARK: - Timing & notes

    private var timingSection: some View {
        Section {
            Toggle("Target a date", isOn: $hasTargetDate)
            if hasTargetDate {
                DatePicker("Target", selection: $targetDate, displayedComponents: .date)
            }
            TextField("Growth stage (optional)", text: $growthStage)
        } header: {
            Text("Timing")
        } footer: {
            // Stated plainly, because it is a real design decision the operator can
            // see the effects of: reordering changes the warnings, editing a date does
            // not.
            Text("Optional. The sequence — not the date — drives the resistance result, so positions can be planned by order alone.")
                .font(.caption2)
        }
    }

    private var noteSection: some View {
        Section("Note") {
            TextField("Planner note (optional)", text: $note, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    // MARK: - State

    private func seed() {
        let codes = Array(position.componentGroups)
        selectedSignature = codes.isEmpty ? nil : ResistanceGroupSignature.of(codes)
        selectedProductIds = Set(position.products.compactMap(\.savedChemicalId))
        if let date = position.targetDateEpochMs {
            hasTargetDate = true
            targetDate = Date(timeIntervalSince1970: Double(date) / 1000)
        }
        growthStage = position.growthStage ?? ""
        note = position.note ?? ""
    }

    private func toggleProduct(_ option: ResistancePlanProductOption) {
        let id = option.candidate.savedChemicalId
        if selectedProductIds.contains(id) {
            selectedProductIds.remove(id)
        } else {
            selectedProductIds.insert(id)
        }
    }

    private func save() {
        guard let signature = selectedSignature else { return }
        var updated = position
        let chosen = productOptions.filter { selectedProductIds.contains($0.candidate.savedChemicalId) }

        if chosen.isEmpty {
            // Group-only planning: one stipulated product line carrying the chosen
            // group and no brand.
            updated.products = [
                ResistancePlannedProduct(groups: signature, source: .group)
            ]
        } else {
            // A chosen product's OWN signature is used, not the group the operator
            // browsed by. Picking a 7+3 co-formulation from a Group 7 list really is
            // planning 7+3, and evaluating it as bare Group 7 would hide the Group 3
            // application entirely.
            updated.products = chosen.map { option in
                ResistancePlannedProduct(
                    groups: option.candidate.groups,
                    source: .savedChemical,
                    savedChemicalId: option.candidate.savedChemicalId,
                    productName: option.candidate.productName,
                    chemicalAvailability: option.candidate.availability,
                    registeredForPlannedDisease: option.candidate.registeredForDisease
                )
            }
        }

        updated.targetDateEpochMs = hasTargetDate
            ? Int64(targetDate.timeIntervalSince1970 * 1000)
            : nil
        updated.growthStage = growthStage.isEmpty ? nil : growthStage
        updated.note = note.isEmpty ? nil : note
        onSave(updated)
        dismiss()
    }
}
