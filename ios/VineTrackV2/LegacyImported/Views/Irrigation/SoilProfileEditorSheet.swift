import SwiftUI

private extension String {
    var nonEmptyOrNil: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Manual soil profile editor for a paddock. Used by the Irrigation Advisor
/// soil buffer panel (Phase 1) and later by Block / Paddock detail.
///
/// Phase 2 will add a "Fetch soil from NSW SEED" button here that calls the
/// Supabase Edge Function and pre-fills the same fields with a lower
/// confidence value so users can review before saving.
struct SoilProfileEditorSheet: View {
    let vineyardId: UUID
    /// Nil = editing the vineyard-level fallback profile used by Whole
    /// Vineyard mode (saved with paddock_id = null).
    let paddockId: UUID?
    let paddockName: String
    let onSaved: (BackendSoilProfile?) -> Void

    private var isVineyardLevel: Bool { paddockId == nil }

    @Environment(\.dismiss) private var dismiss
    @Environment(BackendAccessControl.self) private var accessControl
    @Environment(MigratedDataStore.self) private var store
    @Environment(SystemAdminService.self) private var systemAdmin

    @State private var defaults: [SoilClassDefault] = []
    @State private var existing: BackendSoilProfile?

    @State private var selectedClass: IrrigationSoilClass = .unknown
    @State private var awcText: String = ""
    @State private var rootDepthText: String = ""
    @State private var allowedDepletionText: String = ""
    @State private var notes: String = ""

    @State private var isLoading: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var showDeleteConfirm: Bool = false

    // NSW SEED fetch state (Phase 2)
    @State private var isFetchingNSWSeed: Bool = false
    @State private var nswSeedSuggestion: NSWSeedSoilSuggestion?
    @State private var nswSeedMessage: String?
    @State private var nswSeedDisclaimer: String?
    @State private var nswSeedRawResponse: [String: Any]?
    @State private var nswSeedError: String?
    @State private var showOverwriteConfirm: Bool = false
    /// The most recently fetched SEED suggestion that has been auto-applied
    /// to the form. While this is non-nil and `hasManualEditsSinceSeed` is
    /// false, the toolbar Save button will persist using NSW SEED metadata
    /// (source = nsw_seed, isManualOverride = false) instead of overwriting
    /// the form values as a manual override.
    @State private var appliedSeedSuggestion: NSWSeedSoilSuggestion?
    @State private var hasManualEditsSinceSeed: Bool = false

    private let repository: any SoilProfileRepositoryProtocol = SupabaseSoilProfileRepository()
    private let nswSeedService = NSWSeedSoilLookupService()

    private var canEdit: Bool { accessControl.canChangeSettings }

    private var currentDefault: SoilClassDefault? {
        defaults.first(where: { $0.irrigationSoilClass == selectedClass.rawValue })
    }

    private var rootZoneCapacityMm: Double? {
        guard let awc = Double(awcText), let depth = Double(rootDepthText), awc > 0, depth > 0 else { return nil }
        return awc * depth
    }

    private var readilyAvailableMm: Double? {
        guard let rzc = rootZoneCapacityMm,
              let depl = Double(allowedDepletionText), depl > 0 else { return nil }
        return rzc * (depl / 100.0)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isLoading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading soil profile\u{2026}").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    soilClassSection
                    valuesSection
                    derivedSection
                    notesSection
                    if showNSWSeedSection {
                        nswSeedSection
                    }
                    if let suggestion = nswSeedSuggestion {
                        suggestionPreviewSection(suggestion)
                    }
                    if showRawDiagnostics, let raw = nswSeedRawResponse {
                        diagnosticsSection(raw)
                    }
                    if existing != nil, canEdit {
                        Section {
                            Button(role: .destructive) { showDeleteConfirm = true } label: {
                                Label("Reset soil profile", systemImage: "trash")
                            }
                        }
                    }
                    disclaimerSection
                }
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Soil Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text("Save")
                        }
                    }
                    .disabled(!canEdit || isSaving || isLoading)
                }
            }
            .task { await load() }
            .confirmationDialog("Reset soil profile for \(paddockName)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Reset", role: .destructive) { Task { await deleteProfile() } }
                Button("Cancel", role: .cancel) {}
            }
            .navigationTitle(isVineyardLevel ? "Whole Vineyard Soil" : "Soil Profile")
            .confirmationDialog(
                "Replace your manual soil values?",
                isPresented: $showOverwriteConfirm,
                titleVisibility: .visible
            ) {
                Button("Replace with NSW SEED values", role: .destructive) {
                    if let s = nswSeedSuggestion { applySuggestion(s) }
                }
                Button("Keep my values", role: .cancel) {}
            } message: {
                Text("This block already has a manual soil profile. Applying NSW SEED values will overwrite your tuned AWC, root depth and allowed depletion.")
            }
        }
    }

    // MARK: - NSW SEED gating

    private var vineyardCountry: String {
        store.vineyards.first(where: { $0.id == vineyardId })?.country ?? ""
    }

    private var isAustralianVineyard: Bool {
        let c = vineyardCountry.trimmingCharacters(in: .whitespaces).lowercased()
        if c.isEmpty { return false }
        return c == "au" || c == "aus" || c == "australia"
    }

    private var soilAwareEnabled: Bool {
        // Default to ON when the flag row is missing — keeps Phase 1 working
        // even before the flag is seeded.
        guard let flag = systemAdmin.flags[SystemFeatureFlagKey.soilAwareIrrigation] else { return true }
        return flag.isEnabled
    }

    private var showNSWSeedSection: Bool {
        // NSW SEED needs a paddock polygon centroid — only show for
        // per-paddock editor, not the vineyard-level fallback.
        canEdit && !isVineyardLevel && isAustralianVineyard && soilAwareEnabled
    }

    private var showRawDiagnostics: Bool {
        systemAdmin.isEnabled(SystemFeatureFlagKey.showNSWSeedDiagnostics)
    }

    // MARK: - NSW SEED Sections

    private var nswSeedSection: some View {
        Section {
            Button {
                Task { await fetchFromNSWSeed() }
            } label: {
                HStack {
                    if isFetchingNSWSeed {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.stack.3d.down.right")
                    }
                    Text(isFetchingNSWSeed ? "Fetching from NSW SEED\u{2026}" : "Fetch soil from NSW SEED")
                }
                .font(.subheadline.weight(.semibold))
            }
            .disabled(isFetchingNSWSeed || isSaving)
            if let msg = nswSeedMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = nswSeedError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("NSW SEED soil lookup")
        } footer: {
            Text("Estimates the soil profile from the NSW SEED Soil Landscapes layer using your paddock centroid. The NSW SEED API key stays on the server — it is never sent to your device.")
        }
    }

    private func suggestionPreviewSection(_ s: NSWSeedSoilSuggestion) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Soil landscape") {
                    Text((s.sourceName ?? s.soilLandscape)?.nonEmptyOrNil ?? "Not available")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle((s.sourceName ?? s.soilLandscape) == nil ? .secondary : .primary)
                }
                LabeledContent("SALIS code") {
                    Text((s.soilLandscapeCode ?? s.sourceFeatureId)?.nonEmptyOrNil ?? "Not available")
                        .font(.caption.monospaced())
                        .foregroundStyle((s.soilLandscapeCode ?? s.sourceFeatureId) == nil ? .secondary : .primary)
                }
                LabeledContent("Australian Soil Classification") {
                    Text(s.australianSoilClassification?.nonEmptyOrNil ?? "Not available")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(s.australianSoilClassification == nil ? .secondary : .primary)
                }
                LabeledContent("Land and Soil Capability") {
                    if let lsc = s.landSoilCapability?.nonEmptyOrNil {
                        if let n = s.landSoilCapabilityClass {
                            Text("\(lsc) (class \(n))").multilineTextAlignment(.trailing)
                        } else {
                            Text(lsc).multilineTextAlignment(.trailing)
                        }
                    } else {
                        Text("Not available").foregroundStyle(.secondary)
                    }
                }
                if let cls = s.irrigationSoilClass,
                   let typed = IrrigationSoilClass(rawValue: cls) {
                    LabeledContent("Suggested irrigation class") { Text(label(for: typed)) }
                }
                if let conf = s.confidence, !conf.isEmpty {
                    LabeledContent("Confidence") { Text(conf.capitalized) }
                }
                if showRawDiagnostics, let mv = s.modelVersion, !mv.isEmpty {
                    LabeledContent("Model version") {
                        Text(mv).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                if !s.matchedKeywords.isEmpty {
                    LabeledContent("Matched terms") {
                        Text(s.matchedKeywords.joined(separator: ", "))
                            .font(.caption)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            HStack {
                Button(role: .cancel) {
                    clearSuggestion()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    if hasUserTunedValues {
                        showOverwriteConfirm = true
                    } else {
                        applySuggestion(s)
                    }
                } label: {
                    Label("Apply", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(s.irrigationSoilClass == nil)
            }
            Text(s.disclaimer ?? "Soil information is estimated from NSW SEED mapping and may not reflect site-specific vineyard soil conditions. Adjust soil class and water-holding values using your own soil knowledge where needed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("NSW SEED suggestion")
        }
    }

    private func diagnosticsSection(_ raw: [String: Any]) -> some View {
        Section("Diagnostics (system admin)") {
            DisclosureGroup("Raw NSW SEED response") {
                Text(prettyJSON(raw))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasUserTunedValues: Bool {
        guard let existing else { return false }
        // Only treat as "user-tuned" when there is an existing manual
        // override with non-default values to protect.
        if !existing.isManualOverride { return false }
        return existing.availableWaterCapacityMmPerM != nil
            || existing.effectiveRootDepthM != nil
            || existing.managementAllowedDepletionPercent != nil
    }

    private func clearSuggestion() {
        nswSeedSuggestion = nil
        nswSeedRawResponse = nil
        nswSeedMessage = nil
        nswSeedError = nil
    }

    // MARK: - NSW SEED actions

    private func fetchFromNSWSeed() async {
        guard canEdit, !isFetchingNSWSeed, let pid = paddockId else { return }
        nswSeedError = nil
        nswSeedMessage = nil
        nswSeedSuggestion = nil
        nswSeedRawResponse = nil
        isFetchingNSWSeed = true
        defer { isFetchingNSWSeed = false }
        do {
            let result = try await nswSeedService.lookupPaddockSoil(
                vineyardId: vineyardId,
                paddockId: pid,
                persist: true
            )
            nswSeedRawResponse = result.rawResponse
            nswSeedDisclaimer = result.disclaimer
            if let suggestion = result.suggestion, result.found {
                nswSeedSuggestion = suggestion
                nswSeedMessage = nil
                // Auto-fill the editor immediately so that whether the user
                // taps Apply or the toolbar Save, the SEED values + metadata
                // are persisted (not silently overwritten as a manual
                // override).
                if !hasUserTunedValues {
                    autoFillFromSuggestion(suggestion)
                }
            } else {
                nswSeedMessage = result.message ?? "No NSW SEED soil match found at this paddock's centroid."
            }
        } catch let error as NSWSeedSoilLookupError {
            nswSeedError = error.errorDescription
        } catch {
            nswSeedError = "NSW SEED lookup failed: \(error.localizedDescription)"
        }
    }

    private func applySuggestion(_ s: NSWSeedSoilSuggestion) {
        autoFillFromSuggestion(s)
        clearSuggestion()
        Task { await saveFromSuggestion(s) }
    }

    /// Auto-fill the form from a SEED suggestion without saving. Called as
    /// soon as the suggestion arrives so the editor reflects NSW SEED
    /// values even before the user taps Apply or Save.
    private func autoFillFromSuggestion(_ s: NSWSeedSoilSuggestion) {
        if let raw = s.irrigationSoilClass,
           let cls = IrrigationSoilClass(rawValue: raw) {
            selectedClass = cls
            applyDefaultsForSelectedClass()
        }
        appliedSeedSuggestion = s
        hasManualEditsSinceSeed = false
    }

    /// Writes the suggestion (and its current numeric values) to
    /// `paddock_soil_profiles` via the existing upsert RPC, then refreshes
    /// the editor + Irrigation Advisor by calling `onSaved`. This is what
    /// fulfils the "persist=true writes directly to paddock_soil_profiles"
    /// contract from the iOS side — the Edge Function returns the
    /// suggestion, the iOS service persists it through the shared RPC so
    /// row-level security and audit fields are applied consistently.
    private func saveFromSuggestion(_ s: NSWSeedSoilSuggestion) async {
        guard canEdit else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let payload = SoilProfileUpsert(
            paddockId: paddockId,
            vineyardId: paddockId == nil ? vineyardId : nil,
            irrigationSoilClass: selectedClass.rawValue,
            availableWaterCapacityMmPerM: Double(awcText),
            effectiveRootDepthM: Double(rootDepthText),
            managementAllowedDepletionPercent: Double(allowedDepletionText),
            soilLandscape: s.soilLandscape,
            soilLandscapeCode: s.soilLandscapeCode ?? s.sourceFeatureId,
            australianSoilClassification: s.australianSoilClassification,
            australianSoilClassificationCode: s.australianSoilClassificationCode,
            landSoilCapability: s.landSoilCapability,
            landSoilCapabilityClass: s.landSoilCapabilityClass,
            soilDescription: s.sourceName,
            confidence: s.confidence,
            isManualOverride: false,
            manualNotes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            source: "nsw_seed",
            sourceProvider: "nsw_seed",
            sourceDataset: s.sourceDataset ?? "SoilsNearMe_Combined",
            sourceFeatureId: s.sourceFeatureId,
            sourceName: s.sourceName,
            countryCode: s.countryCode ?? "AU",
            regionCode: s.regionCode ?? "NSW",
            modelVersion: s.modelVersion ?? SoilProfileUpsert.currentModelVersion
        )
        do {
            let saved = try await repository.upsertSoilProfile(payload)
            existing = saved
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func prettyJSON(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Sections

    private var soilClassSection: some View {
        Section("Soil class") {
            Picker("Class", selection: $selectedClass) {
                ForEach(orderedClasses, id: \.self) { cls in
                    Text(label(for: cls)).tag(cls)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedClass) { _, _ in
                if appliedSeedSuggestion != nil { hasManualEditsSinceSeed = true }
                applyDefaultsForSelectedClass()
            }
            if let def = currentDefault, let desc = def.description, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !canEdit {
                Text("Read-only: only Owner or Manager can edit the soil profile.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var valuesSection: some View {
        Section {
            HStack {
                Text("Available water (mm/m)")
                Spacer()
                TextField("e.g. 150", text: $awcText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .disabled(!canEdit)
                    .onChange(of: awcText) { _, _ in
                        if appliedSeedSuggestion != nil { hasManualEditsSinceSeed = true }
                    }
            }
            HStack {
                Text("Effective root depth (m)")
                Spacer()
                TextField("e.g. 0.6", text: $rootDepthText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .disabled(!canEdit)
                    .onChange(of: rootDepthText) { _, _ in
                        if appliedSeedSuggestion != nil { hasManualEditsSinceSeed = true }
                    }
            }
            HStack {
                Text("Allowed depletion (%)")
                Spacer()
                TextField("e.g. 45", text: $allowedDepletionText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120)
                    .disabled(!canEdit)
                    .onChange(of: allowedDepletionText) { _, _ in
                        if appliedSeedSuggestion != nil { hasManualEditsSinceSeed = true }
                    }
            }
        } header: {
            Text("Soil water values")
        } footer: {
            Text("Defaults are pre-filled from the selected soil class. Override with your own observations where possible.")
        }
    }

    @ViewBuilder
    private var derivedSection: some View {
        if rootZoneCapacityMm != nil || readilyAvailableMm != nil {
            Section("Derived") {
                if let rzc = rootZoneCapacityMm {
                    LabeledContent("Root-zone capacity") {
                        Text(String(format: "%.0f mm", rzc)).foregroundStyle(.secondary)
                    }
                }
                if let raw = readilyAvailableMm {
                    LabeledContent("Readily available water") {
                        Text(String(format: "%.0f mm", raw)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var notesSection: some View {
        Section("Notes") {
            TextField("Site-specific notes (optional)", text: $notes, axis: .vertical)
                .lineLimit(2...5)
                .disabled(!canEdit)
        }
    }

    private var disclaimerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Soil information is estimated and may not reflect site-specific vineyard soil conditions. Adjust soil class and water-holding values using your own soil knowledge where needed.", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Class helpers

    private var orderedClasses: [IrrigationSoilClass] {
        if defaults.isEmpty {
            return IrrigationSoilClass.allCases
        }
        return defaults
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { $0.soilClass }
    }

    private func label(for cls: IrrigationSoilClass) -> String {
        defaults.first(where: { $0.irrigationSoilClass == cls.rawValue })?.label ?? cls.fallbackLabel
    }

    // MARK: - Load / Save

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loadedDefaults = try await repository.fetchSoilClassDefaults()
            let loadedProfile: BackendSoilProfile?
            if let pid = paddockId {
                loadedProfile = try await repository.fetchPaddockSoilProfile(paddockId: pid)
            } else {
                loadedProfile = try await repository.fetchVineyardDefaultSoilProfile(vineyardId: vineyardId)
            }
            defaults = loadedDefaults
            existing = loadedProfile
            applyExistingOrDefaults()
        } catch {
            errorMessage = "Failed to load soil profile: \(error.localizedDescription)"
        }
    }

    private func applyExistingOrDefaults() {
        if let existing {
            if let raw = existing.irrigationSoilClass,
               let cls = IrrigationSoilClass(rawValue: raw) {
                selectedClass = cls
            } else {
                selectedClass = .unknown
            }
            awcText = existing.availableWaterCapacityMmPerM.map { String(format: "%.0f", $0) } ?? ""
            rootDepthText = existing.effectiveRootDepthM.map { String(format: "%.2f", $0) } ?? ""
            allowedDepletionText = existing.managementAllowedDepletionPercent.map { String(format: "%.0f", $0) } ?? ""
            notes = existing.manualNotes ?? ""
            if awcText.isEmpty || rootDepthText.isEmpty || allowedDepletionText.isEmpty {
                applyDefaultsForSelectedClass(fillEmptyOnly: true)
            }
        } else {
            selectedClass = .unknown
            applyDefaultsForSelectedClass()
        }
    }

    private func applyDefaultsForSelectedClass(fillEmptyOnly: Bool = false) {
        guard let def = currentDefault else { return }
        if !fillEmptyOnly || awcText.isEmpty {
            awcText = String(format: "%.0f", def.defaultAwcMmPerM)
        }
        if !fillEmptyOnly || rootDepthText.isEmpty {
            rootDepthText = String(format: "%.2f", def.defaultRootDepthM)
        }
        if !fillEmptyOnly || allowedDepletionText.isEmpty {
            allowedDepletionText = String(format: "%.0f", def.defaultAllowedDepletionPercent)
        }
    }

    private func save() async {
        guard canEdit else { return }
        // If the user fetched a SEED suggestion and has NOT edited any
        // fields since it was auto-applied, persist it as a NSW SEED row
        // (preserves source / confidence / landscape / ASC / LSC) instead
        // of overwriting as a manual override.
        if let seed = appliedSeedSuggestion, !hasManualEditsSinceSeed {
            await saveFromSuggestion(seed)
            return
        }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        let payload = SoilProfileUpsert(
            paddockId: paddockId,
            vineyardId: paddockId == nil ? vineyardId : nil,
            irrigationSoilClass: selectedClass.rawValue,
            availableWaterCapacityMmPerM: Double(awcText),
            effectiveRootDepthM: Double(rootDepthText),
            managementAllowedDepletionPercent: Double(allowedDepletionText),
            confidence: "manual",
            isManualOverride: true,
            manualNotes: notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notes,
            source: "manual",
            sourceProvider: "manual"
        )
        do {
            let saved = try await repository.upsertSoilProfile(payload)
            onSaved(saved)
            dismiss()
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func deleteProfile() async {
        guard canEdit else { return }
        do {
            if let pid = paddockId {
                try await repository.deleteSoilProfile(paddockId: pid)
            } else {
                try await repository.deleteVineyardDefaultSoilProfile(vineyardId: vineyardId)
            }
            existing = nil
            onSaved(nil)
            dismiss()
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let raw = String(describing: error).lowercased()
        if raw.contains("not_authorized") {
            return "You don't have permission to edit the soil profile for this paddock."
        }
        if raw.contains("paddock_not_found") {
            return "Block not found."
        }
        if raw.contains("invalid_awc") {
            return "Available water capacity must be between 0 and 400 mm/m."
        }
        if raw.contains("invalid_root_depth") {
            return "Effective root depth must be between 0 and 5 m."
        }
        if raw.contains("invalid_allowed_depletion") {
            return "Allowed depletion must be between 0 and 100%."
        }
        if raw.contains("invalid_irrigation_soil_class") {
            return "Unknown irrigation soil class."
        }
        return "Failed to save soil profile: \(error.localizedDescription)"
    }
}
