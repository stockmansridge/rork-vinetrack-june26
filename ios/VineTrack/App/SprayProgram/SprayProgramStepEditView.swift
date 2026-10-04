import SwiftUI

/// Editor for one reusable Program Step, whichever side of the wire it lives on.
///
/// One editing experience, two persistence targets. A Program Step is the same
/// idea whether it was written on this device or in the Admin Portal, so it gets
/// the same screen; only the write underneath differs:
///
///   * local  -> the existing `spray_records` template path
///   * portal -> the existing `public.spray_jobs` row, UPDATED IN PLACE
///
/// Deliberately NOT `SprayRecordFormView`. That screen edits an application that
/// happened — date, weather, tanks applied, rows sprayed, operator, cost — and
/// pushing a portal Program Step through it would both show fields that mean
/// nothing on reusable configuration and persist it as a local spray record.
/// Nothing here creates a second copy of anything.
struct SprayProgramStepEditView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(SprayJobTemplateService.self) private var portalTemplates
    @Environment(SprayTargetLibraryService.self) private var targetLibrary
    @Environment(NetworkMonitor.self) private var network
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessControl) private var accessControl

    let step: SprayProgramStep
    /// The step as it reads AFTER a successful save, so the detail screen can
    /// show the new configuration immediately instead of waiting for a sync.
    let onSaved: (SprayProgramStep) -> Void

    @State private var draft: SprayProgramStepDraft
    @State private var productBeingReplaced: SprayProgramProductDraft.ID?
    @State private var plannedRateTexts: [UUID: String] = [:]
    @State private var isChoosingTarget: Bool = false
    /// Set as soon as the operator touches the target list, so a library sync
    /// landing mid-edit can re-word an existing tag but never re-open a target
    /// they just removed.
    @State private var hasEditedTargets: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String?

    init(step: SprayProgramStep, onSaved: @escaping (SprayProgramStep) -> Void) {
        self.step = step
        self.onSaved = onSaved
        _draft = State(initialValue: SprayProgramStepDraft(step: step))
    }

    /// A portal Program Step is the shared row. There is no offline mutation
    /// queue for `spray_jobs`, so rather than stage a local shadow that might
    /// never reach the server, the save is blocked and says so.
    private var requiresConnection: Bool {
        step.isPortalManaged && !network.isOnline
    }

    private var canSave: Bool {
        draft.isValid && !isSaving && !requiresConnection
    }

    /// The vineyard's spray profile, read from the vineyard and never
    /// re-derived here.
    private var sprayProfile: SprayVineyardProfile {
        store.selectedVineyard?.sprayProfile
            ?? SprayVineyardProfile(countryCode: store.settings.regionSettings.countryCode)
    }

    /// The label rate bases this vineyard's carrier workflow starts from.
    ///
    /// A Program Step is configuration rather than an application, so there is
    /// no live carrier choice to read; the vineyard's own default workflow is
    /// the honest answer. This seeds a product being ADDED or REPLACED only —
    /// a rate and basis already saved on a step is an explicit decision and is
    /// loaded verbatim by `SprayProgramStepDraft(step:)`.
    private var preferredRateBases: [ChemicalRateBasis] {
        SprayRateBasisPreference.order(for: sprayProfile)
    }

    /// The basis a brand-new product line starts on before a product is chosen.
    private var initialProductBasis: SprayProductRateBasis {
        SprayRateBasisPreference.fallbackBasis(for: sprayProfile) == .per100Litres
            ? .per100Litres
            : .wholeBlockArea
    }

    var body: some View {
        Form {
            if requiresConnection {
                Section {
                    Label(
                        SprayProgramStepWriteError.offline.localizedDescription,
                        systemImage: "wifi.slash"
                    )
                    .font(.subheadline)
                    .foregroundStyle(VineyardTheme.warning)
                } footer: {
                    Text("This Program Step is shared with the Admin Portal, so changes are saved straight to the vineyard's program. You can still view it and plan a spray from it offline.")
                }
            }

            identitySection
            growthStageSection
            targetSection
            productsSection
            applicationSection

            Section("Notes") {
                TextField("Notes", text: $draft.notes, axis: .vertical)
                    .lineLimit(3...8)
            }

            Section {
                // Says plainly what this screen is not for, because the old
                // shared record form is where an operator would expect to find
                // these and their absence should read as deliberate.
                Text("A Program Step is reusable configuration. Spray date, weather, tanks, rows sprayed, operator and cost belong to the sprays you record from it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Edit Program Step")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .sheet(isPresented: replacingBinding) {
            SprayLineChemicalPicker(
                selectedId: replacementTarget?.savedChemicalId,
                onSelect: applyReplacement
            )
        }
        .sheet(isPresented: $isChoosingTarget) {
            SprayTargetChooserSheet(
                selected: draft.targets,
                vineyardTargets: vineyardTargetSuggestions,
                onSelect: { tag in
                    hasEditedTargets = true
                    draft.addTarget(tag)
                },
                onCreate: createCustomTarget
            )
        }
        .task { await loadTargetLibrary() }
        .alert(
            "Couldn't save",
            isPresented: .init(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
        ) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            TextField("Program Step name", text: $draft.name)
        } header: {
            Text("Name")
        } footer: {
            if let error = draft.validationError {
                Text(error).foregroundStyle(VineyardTheme.warning)
            }
        }
    }

    // MARK: - Growth stage

    @ViewBuilder
    private var growthStageSection: some View {
        Section {
            if step.isPortalManaged {
                Picker("E-L growth stage", selection: growthStageBinding) {
                    Text("Not stated").tag(String?.none)
                    ForEach(GrowthStage.allStages) { stage in
                        Text(stage.displayName).tag(String?.some(stage.code))
                    }
                }
            } else {
                LabeledContent("E-L growth stage") {
                    Text(step.elStageLabel ?? "Not stated")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Growth Stage")
        } footer: {
            Text(
                step.isPortalManaged
                    ? "The stage this step is timed for. \u{201C}Not stated\u{201D} is a real answer \u{2014} a step that doesn't name a stage says so."
                    : "A local Program Step has no stored growth stage; it's read from the step name, e.g. \u{201C}EL12 Pre-Flowering\u{201D}."
            )
        }
    }

    private var growthStageBinding: Binding<String?> {
        Binding(
            get: {
                guard let code = draft.growthStageCode else { return nil }
                // Match on stage NUMBER so "E-L 12" from the portal selects the
                // same row as "EL12" rather than falling out of the picker.
                let number = ELStageParser.stageNumber(fromCode: code)
                return GrowthStage.allStages
                    .first { ELStageParser.stageNumber(fromCode: $0.code) == number }?
                    .code
            },
            set: { draft.growthStageCode = $0 }
        )
    }

    // MARK: - Targets

    private var targetSection: some View {
        Section {
            if draft.targets.isEmpty {
                Text("No targets on this step yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                SprayTargetChipsView(tags: draft.normalisedTargets) { tag in
                    hasEditedTargets = true
                    draft.removeTarget(tag)
                }
                .padding(.vertical, 2)
            }

            Button {
                isChoosingTarget = true
            } label: {
                Label("Add Target", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium))
            }
        } header: {
            Text("Targets")
        } footer: {
            // Every selected target is stored, whether or not VineTrack has a
            // typed case for it. The recognised ones additionally prefill the
            // calculator; the rest are not silently dropped for the crime of
            // not being in a six-case enum.
            Text("Targets VineTrack recognises prefill the Spray Calculator. Your vineyard's own targets are stored and reusable across Program Steps here.")
        }
    }

    /// Everything this vineyard could reasonably want to reuse: its library
    /// entries plus the custom targets already on its Program Steps.
    private var vineyardTargetSuggestions: [SprayTargetTag] {
        let labels = targetLibrary.labels(vineyardId: store.selectedVineyardId)
        let steps = SprayProgramCatalog.steps(
            localRecords: store.sprayRecords,
            portalRecords: portalTemplates.templateRecords,
            portalRows: portalTemplates.templates
        )
        return targetLibrary.customTags(
            vineyardId: store.selectedVineyardId,
            observed: SprayProgramCatalog.observedTargetTags(steps, labels: labels)
        )
    }

    /// Add a brand-new custom target: onto this step immediately, and into the
    /// vineyard's library so the next Program Step offers it.
    ///
    /// The tag lands on the step even if the library write fails. The step is
    /// what states what the spray is for; the library is a convenience, and
    /// losing the operator's target because a catalogue insert was refused
    /// would be the wrong way round.
    private func createCustomTarget(_ wording: String) {
        guard let tag = SprayTargetVocabulary.tag(wording: wording) else { return }
        hasEditedTargets = true
        draft.addTarget(tag)
        guard tag.isCustom, let vineyardId = store.selectedVineyardId else { return }
        Task { await targetLibrary.addCustomTarget(wording: tag.label, vineyardId: vineyardId) }
    }

    /// Pull the vineyard's target vocabulary, then re-word any tag that loaded
    /// as a de-slugged approximation.
    private func loadTargetLibrary() async {
        guard let vineyardId = store.selectedVineyardId else { return }
        await targetLibrary.refresh(vineyardId: vineyardId)
        guard !hasEditedTargets else { return }
        draft.targets = step.targetTags(labels: targetLibrary.labels(vineyardId: vineyardId))
    }

    // MARK: - Products

    private var productsSection: some View {
        Section {
            if draft.products.isEmpty {
                Text("No products on this step yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach($draft.products) { $product in
                productRow($product)
            }
            .onDelete { offsets in
                draft.products.remove(atOffsets: offsets)
            }

            Button {
                draft.products.append(SprayProgramProductDraft(basis: initialProductBasis))
                productBeingReplaced = draft.products.last?.id
            } label: {
                Label("Add Product", systemImage: "plus.circle.fill")
            }
        } header: {
            Text("Products")
        } footer: {
            Text("A step remembers the intended product rate. Carrier volume, tanks and final application choices are confirmed when planning the spray.")
        }
    }

    @ViewBuilder
    private func productRow(_ product: Binding<SprayProgramProductDraft>) -> some View {
        let resolved = product.wrappedValue.isResolved(in: store.savedChemicals)
        let saved = store.savedChemicals.first { $0.id == product.wrappedValue.savedChemicalId }

        VStack(alignment: .leading, spacing: 10) {
            // ONE product action, in the header, for every line — resolved or
            // not. The unresolved row used to carry a second "Replace Product"
            // button under its warning, which made the same action look like
            // two different ones depending on where you tapped.
            HStack(alignment: .firstTextBaseline) {
                Text(product.wrappedValue.name.isEmpty ? "Select a product" : product.wrappedValue.name)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("Replace Product") { productBeingReplaced = product.wrappedValue.id }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }

            if let saved {
                HStack(spacing: 6) {
                    ChemicalVerificationBadge(status: saved.verificationStatus, compact: true, chemical: saved)
                    let groups = saved.resolvedIntelligence.activityGroups
                    if !groups.isEmpty {
                        Text(groups.legacyGroupProjection)
                            .font(.caption2)
                            .foregroundStyle(VineyardTheme.olive)
                    }
                }
            } else if !product.wrappedValue.name.isEmpty {
                // Informational only. It states the fact and stops — the fix is
                // the header's Replace Product. It stays until the operator
                // explicitly picks the product; nothing here name-matches this
                // line into looking verified.
                Label(
                    "\(product.wrappedValue.name) is not in your Chemical Store",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(VineyardTheme.warning)
            }

            plannedRateEditor(product, chemical: saved)
            if resolved, let saved {
                Text("Saved as \(saved.name)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private func plannedRateEditor(_ product: Binding<SprayProgramProductDraft>, chemical: SavedChemical?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Planned rate").font(.caption.weight(.semibold))
            TextField("Not set", text: Binding(get: { plannedRateTexts[product.wrappedValue.id] ?? (product.wrappedValue.rate > 0 ? String(product.wrappedValue.rate) : "") }, set: {
                plannedRateTexts[product.wrappedValue.id] = $0
                product.wrappedValue.rate = $0.isEmpty ? 0 : (Double($0.replacingOccurrences(of: ",", with: ".")) ?? .nan)
                product.wrappedValue.rateSource = .programStep
            })).keyboardType(.decimalPad)
            Picker("Unit", selection: product.unit) {
                Text("L").tag(ChemicalUnit.litres); Text("mL").tag(ChemicalUnit.millilitres)
                Text("kg").tag(ChemicalUnit.kilograms); Text("g").tag(ChemicalUnit.grams)
            }.onChange(of: product.wrappedValue.unit) { _, _ in product.wrappedValue.rateSource = .programStep }
            Picker("Basis", selection: product.basis) {
                Text("Per hectare").tag(SprayProductRateBasis.wholeBlockArea)
                Text("Per 100 L").tag(SprayProductRateBasis.per100Litres)
            }.onChange(of: product.wrappedValue.basis) { _, _ in product.wrappedValue.rateSource = .programStep }
            if product.wrappedValue.rate > 0 {
                Text(product.wrappedValue.rateSource == .vineyardPreferred ? "From \(store.selectedVineyard?.name ?? "Vineyard") preferred rate" : "Program Step rate")
                    .font(.caption).foregroundStyle(.secondary)
                if let chemical {
                    let unit = product.wrappedValue.unit
                    let rawUnit = unit == .litres ? "L" : unit == .kilograms ? "kg" : unit.rawValue
                    let rate = VineyardPreferredRate(amount: product.wrappedValue.rate, unit: rawUnit, basis: product.wrappedValue.basis == .per100Litres ? .per100Litres : .perHectare)
                    if let warning = OperationalRateResolver.warning(rate, chemical: chemical) { Text(warning).font(.caption).foregroundStyle(.orange) }
                }
            }
            Text("Saving records this step's intended rate, without changing the vineyard preference. Clear the amount to choose it when planning.").font(.caption2).foregroundStyle(.secondary)
        }.disabled(!(accessControl?.canManageSprayProgram ?? false))
    }

    // MARK: - Product replacement

    private var replacementTarget: SprayProgramProductDraft? {
        guard let productBeingReplaced else { return nil }
        return draft.products.first { $0.id == productBeingReplaced }
    }

    private var replacingBinding: Binding<Bool> {
        Binding(
            get: { productBeingReplaced != nil },
            set: { if !$0 { productBeingReplaced = nil } }
        )
    }

    private func applyReplacement(_ chemical: SavedChemical?) {
        defer { productBeingReplaced = nil }
        guard let targetId = productBeingReplaced,
              let index = draft.products.firstIndex(where: { $0.id == targetId }) else { return }

        guard let chemical else {
            draft.products[index].clearProduct(name: draft.products[index].name)
            return
        }
        // Replacing a product is a NEW choice of product, so it seeds from the
        // vineyard's workflow preference rather than inheriting the basis the
        // outgoing product happened to use. A 100 m runoff vineyard swapping in
        // a product with a per-100 L label rate gets that rate.
        let choices = SprayRegisteredUseRates.vineyardRates(for: chemical).filter { $0.isSelectable && $0.preset == nil }
        draft.products[index].replaceProduct(with: chemical, seedRate: choices.count == 1 ? choices.first : nil)
        plannedRateTexts.removeValue(forKey: targetId)
    }

    // MARK: - Application

    private var applicationSection: some View {
        Section("Application") {
            Picker("Method", selection: $draft.operationType) {
                ForEach(OperationType.allCases, id: \.self) { type in
                    Text(type.rawValue).tag(type)
                }
            }

            Picker("Spray unit", selection: $draft.equipmentId) {
                Text("Not set").tag(UUID?.none)
                ForEach(availableEquipment) { item in
                    Text(item.name).tag(UUID?.some(item.id))
                }
            }

            Picker("Tractor", selection: $draft.tractorId) {
                Text("Not set").tag(UUID?.none)
                ForEach(availableTractors) { item in
                    Text(item.displayName).tag(UUID?.some(item.id))
                }
            }
        }
    }

    private var availableEquipment: [SprayEquipmentItem] {
        let vineyardId = store.selectedVineyardId
        return store.sprayEquipment.filter { vineyardId == nil || $0.vineyardId == vineyardId }
    }

    /// Operational picker for a Program Step: selected vineyard only. With no
    /// vineyard selected the correct answer is "nothing", not "everything".
    ///
    /// # Genuine tractors ONLY — and why this list must never widen
    ///
    /// A Program Step is a `spray_jobs` row, and `spray_jobs.tractor_id` is a
    /// foreign key into `public.tractors`. That table has no `machine_id`
    /// column. Merging vineyard machines into this picker — exactly what the
    /// Portal wizard did — would either violate the constraint or, worse,
    /// succeed against a coincidentally valid id and silently record the wrong
    /// asset against a planned job.
    ///
    /// `spray_records` legitimately carries both identities and its picker is
    /// labelled "Power unit" accordingly. This one is labelled "Tractor" and
    /// means it. Machine support here needs a deliberate schema change first.
    private var availableTractors: [Tractor] {
        store.currentTractors
    }

    // MARK: - Save

    private func save() {
        guard let error = draft.validationError else {
            step.isPortalManaged ? savePortal() : saveLocal()
            return
        }
        saveError = error
    }

    /// Local Program Steps keep their existing persistence path, untouched.
    private func saveLocal() {
        let updated = draft.applied(to: step.record)
        store.updateSprayRecord(updated)
        onSaved(SprayProgramStep(record: updated, source: .local))
        dismiss()
    }

    /// Portal Program Steps update the SAME `spray_jobs` row.
    ///
    /// No new record, no new id, no copy into `MigratedDataStore`: after this
    /// there is still exactly one Program Step, and both the portal and mobile
    /// are reading it.
    private func savePortal() {
        guard !requiresConnection else {
            saveError = SprayProgramStepWriteError.offline.localizedDescription
            return
        }
        isSaving = true
        let payload = draft.portalPayload(updatedBy: auth.userId)
        Task {
            do {
                let saved = try await portalTemplates.updateProgramStep(id: step.id, payload: payload)
                isSaving = false
                onSaved(
                    SprayProgramStep(
                        record: saved.toSprayRecord(),
                        source: .portal,
                        growthStageCode: saved.growthStageCode,
                        targetRaw: saved.target
                    )
                )
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
