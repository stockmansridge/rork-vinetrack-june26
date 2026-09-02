import SwiftUI
import UIKit

struct YieldDeterminationCalculatorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var authService
    /// Canonical seasonal estimates (sql/221). Saving calculator settings is
    /// what makes the server re-derive them.
    @Environment(SeasonYieldEstimateService.self) private var seasonYield

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    enum PruneMethod: String, CaseIterable, Identifiable {
        case spur = "Spur"
        case cane = "Cane"
        var id: String { rawValue }
    }

    @State private var selectedPaddockId: UUID?
    /// Baseline of the values most recently loaded/saved for the selected
    /// block. Autosave skips when nothing actually changed, so loading a
    /// block (or merely viewing an unsaved one) never writes a record.
    @State private var loadedSnapshot: PruningYieldSettings?
    @State private var pruneMethod: PruneMethod = .spur
    @State private var bunchesPerBudText: String = "1.5"

    // Spur inputs
    @State private var budsPerSpurText: String = "2"
    @State private var spursPerVineText: String = "6"

    // Cane inputs
    @State private var budsPerCaneText: String = "10"
    @State private var canesPerVineText: String = "4"

    @State private var vinesPerHaText: String = ""
    @State private var bunchWeightText: String = "120"

    @State private var lastSavedAt: Date?
    @State private var showSavedToast: Bool = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case bunchesPerBud, budsPerSpur, spursPerVine, budsPerCane, canesPerVine, vinesPerHa, bunchWeight
    }

    private var vineyardPaddocks: [Paddock] {
        guard let vid = store.selectedVineyard?.id else { return store.paddocks }
        return store.paddocks.filter { $0.vineyardId == vid }
    }

    private var selectedPaddock: Paddock? {
        guard let id = selectedPaddockId else { return nil }
        return store.paddocks.first(where: { $0.id == id })
    }

    private var bunchesPerBud: Double { parse(bunchesPerBudText) }
    private var budsPerSpur: Double { parse(budsPerSpurText) }
    private var spursPerVine: Double { parse(spursPerVineText) }
    private var budsPerCane: Double { parse(budsPerCaneText) }
    private var canesPerVine: Double { parse(canesPerVineText) }
    private var vinesPerHa: Double { parse(vinesPerHaText) }
    private var bunchWeightGrams: Double { parse(bunchWeightText) }

    private var budsPerVine: Double {
        switch pruneMethod {
        case .spur: return budsPerSpur * spursPerVine
        case .cane: return budsPerCane * canesPerVine
        }
    }

    private var bunchesPerHa: Double {
        bunchesPerBud * budsPerVine * vinesPerHa
    }

    private var yieldKgPerHa: Double {
        bunchesPerHa * bunchWeightGrams / 1000.0
    }

    private var yieldTonnesPerHa: Double {
        yieldKgPerHa / 1000.0
    }

    private var totalYieldTonnes: Double? {
        guard let paddock = selectedPaddock, paddock.areaHectares > 0 else { return nil }
        return yieldTonnesPerHa * paddock.areaHectares
    }

    private var formulaText: String {
        switch pruneMethod {
        case .spur:
            return "Yield / Ha = Bunches/Bud × Buds/Spur × Spurs/Vine × Vines/Ha × Bunch Weight"
        case .cane:
            return "Yield / Ha = Bunches/Bud × Buds/Cane × Canes/Vine × Vines/Ha × Bunch Weight"
        }
    }

    var body: some View {
        Form {
            Section("Block") {
                if vineyardPaddocks.isEmpty {
                    Text("No blocks available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Block", selection: $selectedPaddockId) {
                        Text("Select…").tag(UUID?.none)
                        ForEach(vineyardPaddocks) { paddock in
                            Text(paddock.name).tag(Optional(paddock.id))
                        }
                    }
                    .pickerStyle(.menu)

                    if let paddock = selectedPaddock {
                        LabeledContent("Area") {
                            Text(fmt.formatArea(hectares: paddock.areaHectares))
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Vines") {
                            Text("\(paddock.effectiveVineCount)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Pruning Method") {
                Picker("Method", selection: $pruneMethod) {
                    ForEach(PruneMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.segmented)

                Text(pruneMethod == .spur
                     ? "Spur pruning: short canes (spurs) left with a set number of buds each."
                     : "Cane pruning: longer canes retained on each vine with multiple buds per cane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Inputs") {
                inputRow(label: "Bunches / Bud", text: $bunchesPerBudText, field: .bunchesPerBud)

                switch pruneMethod {
                case .spur:
                    inputRow(label: "Buds / Spur", text: $budsPerSpurText, field: .budsPerSpur)
                    inputRow(label: "Spurs / Vine", text: $spursPerVineText, field: .spursPerVine)
                case .cane:
                    inputRow(label: "Buds / Cane", text: $budsPerCaneText, field: .budsPerCane)
                    inputRow(label: "Canes / Vine", text: $canesPerVineText, field: .canesPerVine)
                }

                inputRow(label: "Vines / Ha", text: $vinesPerHaText, field: .vinesPerHa)
                inputRow(label: "Bunch Weight (g)", text: $bunchWeightText, field: .bunchWeight)
            }

            Section("Calculated") {
                LabeledContent("Buds / Vine") {
                    Text(budsPerVine, format: .number.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                LabeledContent("Bunches / Ha") {
                    Text(bunchesPerHa, format: .number.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                LabeledContent("Yield / \(fmt.areaUnitAbbreviation) (kg)") {
                    Text(fmt.formatYieldPerArea(perHectare: yieldKgPerHa, unitLabel: "kg", fractionDigits: 1))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                LabeledContent("Yield / \(fmt.areaUnitAbbreviation) (t)") {
                    Text(fmt.formatYieldPerArea(perHectare: yieldTonnesPerHa, fractionDigits: 1))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .monospacedDigit()
                }

                if let total = totalYieldTonnes {
                    LabeledContent("Block Total") {
                        Text(String(format: "%.1f t", total))
                            .font(.headline.weight(.bold))
                            .foregroundStyle(VineyardTheme.leafGreen)
                            .monospacedDigit()
                    }
                }
            }

            Section {
                Text(formulaText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    saveResult()
                } label: {
                    Label("Save Result", systemImage: "square.and.arrow.down.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(VineyardTheme.leafGreen)
                .disabled(yieldTonnesPerHa <= 0)

                if let lastSavedAt {
                    Text("Last saved \(lastSavedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay(alignment: .top) {
            if showSavedToast {
                Text("Saved")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle("Pruning Yield Calculator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear {
            if selectedPaddockId == nil {
                selectedPaddockId = vineyardPaddocks.first?.id
            }
            loadSettings(for: selectedPaddockId)
        }
        .onChange(of: selectedPaddockId) { oldValue, newValue in
            if let oldValue { saveSettings(for: oldValue) }
            loadSettings(for: newValue)
        }
        .onChange(of: pruneMethod) { _, _ in saveSettings(for: selectedPaddockId) }
        .onChange(of: bunchesPerBudText) { _, _ in saveSettings(for: selectedPaddockId) }
        .onChange(of: budsPerSpurText) { _, _ in saveSettings(for: selectedPaddockId) }
        .onChange(of: spursPerVineText) { _, _ in saveSettings(for: selectedPaddockId) }
        .onChange(of: budsPerCaneText) { _, _ in saveSettings(for: selectedPaddockId) }
        .onChange(of: canesPerVineText) { _, _ in saveSettings(for: selectedPaddockId) }
        .onChange(of: vinesPerHaText) { _, _ in saveSettings(for: selectedPaddockId) }
        .onChange(of: bunchWeightText) { _, _ in saveSettings(for: selectedPaddockId) }
    }

    /// Load the selected block's saved configuration from the SHARED store
    /// (sql/181). Falls back to the legacy pre-sql/181 device-local save
    /// (display only — adopted into the shared store on first edit or first
    /// sync), then to the canonical defaults. Every field is reset so one
    /// block's values can never leak into another block.
    private func loadSettings(for paddockId: UUID?) {
        guard let paddockId else {
            applyDefaults(for: nil)
            loadedSnapshot = nil
            return
        }
        if let saved = store.pruningYieldSettings(for: paddockId) {
            apply(saved)
            loadedSnapshot = saved
        } else if let userId = authService.userId?.uuidString,
                  let legacy = PruningYieldSettings.legacySettings(userId: userId, paddockId: paddockId) {
            let converted = PruningYieldSettings.fromLegacy(
                legacy,
                vineyardId: store.selectedVineyard?.id ?? UUID(),
                paddockId: paddockId
            )
            apply(converted)
            loadedSnapshot = converted
        } else {
            applyDefaults(for: paddockId)
            loadedSnapshot = currentSettings(for: paddockId)
        }
    }

    /// Autosave the selected block's values into the shared store. Skipped
    /// when nothing changed since the last load/save, so programmatic loads
    /// never create records for blocks the user only looked at.
    ///
    /// A real save then asks the server to re-derive the vintage's canonical
    /// estimates (`refresh_pruning_yield_estimates`) and reloads the overview,
    /// so Yield Overview and Grape Allocation move the moment the inputs do.
    /// The refresh never downgrades a bunch_count or manual estimate.
    private func saveSettings(for paddockId: UUID?) {
        guard let paddockId, let vineyard = store.selectedVineyard else { return }
        let current = currentSettings(for: paddockId)
        if let snapshot = loadedSnapshot, snapshot.paddockId == paddockId, current.inputsEqual(to: snapshot) {
            return
        }
        store.savePruningYieldSettings(current)
        loadedSnapshot = current

        let vintage = currentVintage
        Task {
            await seasonYield.refreshAfterPruningSettingsSaved(
                vineyardId: vineyard.id,
                vintage: vintage
            )
        }
    }

    /// The vintage the calculator's settings feed. Pruning settings are not
    /// themselves vintage-scoped, so the refresh always targets the season the
    /// grower is currently working on.
    private var currentVintage: Int {
        VintageResolver.vintageYear(
            for: Date(),
            seasonStartMonth: store.settings.seasonStartMonth,
            seasonStartDay: store.settings.seasonStartDay
        )
    }

    private func apply(_ settings: PruningYieldSettings) {
        pruneMethod = settings.pruneMethod == "cane" ? .cane : .spur
        bunchesPerBudText = PruningYieldInputFormat.text(settings.bunchesPerBud)
        budsPerSpurText = PruningYieldInputFormat.text(settings.budsPerSpur)
        spursPerVineText = PruningYieldInputFormat.text(settings.spursPerVine)
        budsPerCaneText = PruningYieldInputFormat.text(settings.budsPerCane)
        canesPerVineText = PruningYieldInputFormat.text(settings.canesPerVine)
        vinesPerHaText = PruningYieldInputFormat.text(settings.vinesPerHa)
        bunchWeightText = PruningYieldInputFormat.text(settings.bunchWeightGrams)
    }

    /// The current field values as a shared-contract record for the block.
    /// When the block already has a saved record its id is reused (the store
    /// keeps ids stable anyway — one record per block).
    private func currentSettings(for paddockId: UUID) -> PruningYieldSettings {
        PruningYieldSettings(
            id: store.pruningYieldSettings(for: paddockId)?.id ?? UUID(),
            vineyardId: store.selectedVineyard?.id ?? UUID(),
            paddockId: paddockId,
            pruneMethod: pruneMethod == .cane ? "cane" : "spur",
            bunchesPerBud: bunchesPerBud,
            budsPerSpur: budsPerSpur,
            spursPerVine: spursPerVine,
            budsPerCane: budsPerCane,
            canesPerVine: canesPerVine,
            vinesPerHa: PruningYieldInputFormat.parseOptional(vinesPerHaText),
            bunchWeightGrams: bunchWeightGrams
        )
    }

    private func inputRow(label: String, text: Binding<String>, field: Field) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .frame(maxWidth: 120)
                .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                    if let textField = notification.object as? UITextField {
                        textField.selectAll(nil)
                    }
                }
        }
    }

    /// Canonical defaults for an unsaved block. EVERY field resets (not just
    /// Vines/Ha) so the previous block's values never leak into a new block.
    private func applyDefaults(for paddockId: UUID?) {
        pruneMethod = .spur
        bunchesPerBudText = PruningYieldInputFormat.text(PruningYieldDefaults.bunchesPerBud)
        budsPerSpurText = PruningYieldInputFormat.text(PruningYieldDefaults.budsPerSpur)
        spursPerVineText = PruningYieldInputFormat.text(PruningYieldDefaults.spursPerVine)
        budsPerCaneText = PruningYieldInputFormat.text(PruningYieldDefaults.budsPerCane)
        canesPerVineText = PruningYieldInputFormat.text(PruningYieldDefaults.canesPerVine)
        bunchWeightText = PruningYieldInputFormat.text(PruningYieldDefaults.bunchWeightGrams)
        vinesPerHaText = ""
        guard let paddockId, let paddock = store.paddocks.first(where: { $0.id == paddockId }) else { return }
        let area = paddock.areaHectares
        let vines = Double(paddock.effectiveVineCount)
        if area > 0, vines > 0 {
            vinesPerHaText = String(format: "%.0f", vines / area)
        }
    }

    private func parse(_ text: String) -> Double {
        Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func saveResult() {
        guard let vineyardId = store.selectedVineyard?.id else { return }
        let result = YieldDeterminationResult(
            vineyardId: vineyardId,
            paddockId: selectedPaddockId,
            pruneMethod: pruneMethod.rawValue,
            bunchesPerBud: bunchesPerBud,
            budsPerSpur: budsPerSpur,
            spursPerVine: spursPerVine,
            budsPerCane: budsPerCane,
            canesPerVine: canesPerVine,
            vinesPerHa: vinesPerHa,
            bunchWeightGrams: bunchWeightGrams,
            budsPerVine: budsPerVine,
            bunchesPerHa: bunchesPerHa,
            yieldKgPerHa: yieldKgPerHa,
            yieldTonnesPerHa: yieldTonnesPerHa,
            totalYieldTonnes: totalYieldTonnes,
            createdBy: authService.userId?.uuidString
        )
        store.saveYieldDeterminationResult(result)
        lastSavedAt = result.createdAt
        withAnimation(.easeOut(duration: 0.2)) { showSavedToast = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(.easeIn(duration: 0.2)) { showSavedToast = false }
        }
    }
}
