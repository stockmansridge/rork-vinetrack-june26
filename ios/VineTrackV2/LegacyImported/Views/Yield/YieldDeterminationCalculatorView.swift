import SwiftUI
import UIKit

struct YieldDeterminationCalculatorView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var authService

    private var fmt: RegionFormatter { store.settings.regionFormatter }

    enum PruneMethod: String, CaseIterable, Identifiable {
        case spur = "Spur"
        case cane = "Cane"
        var id: String { rawValue }
    }

    private nonisolated struct SavedSettings: Codable {
        var pruneMethod: String
        var bunchesPerBud: String
        var budsPerSpur: String
        var spursPerVine: String
        var budsPerCane: String
        var canesPerVine: String
        var vinesPerHa: String
        var bunchWeight: String
    }

    @State private var selectedPaddockId: UUID?
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
        .navigationTitle("Yield Determination Calculator")
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

    private func settingsKey(for paddockId: UUID) -> String? {
        guard let userId = authService.userId?.uuidString else { return nil }
        return "vinetrack_yield_determination_\(userId)_\(paddockId.uuidString)"
    }

    private func loadSettings(for paddockId: UUID?) {
        guard let paddockId, let key = settingsKey(for: paddockId),
              let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(SavedSettings.self, from: data) else {
            applyPaddockDefaults()
            return
        }
        pruneMethod = PruneMethod(rawValue: saved.pruneMethod) ?? .spur
        bunchesPerBudText = saved.bunchesPerBud
        budsPerSpurText = saved.budsPerSpur
        spursPerVineText = saved.spursPerVine
        budsPerCaneText = saved.budsPerCane
        canesPerVineText = saved.canesPerVine
        vinesPerHaText = saved.vinesPerHa
        bunchWeightText = saved.bunchWeight
    }

    private func saveSettings(for paddockId: UUID?) {
        guard let paddockId, let key = settingsKey(for: paddockId) else { return }
        let settings = SavedSettings(
            pruneMethod: pruneMethod.rawValue,
            bunchesPerBud: bunchesPerBudText,
            budsPerSpur: budsPerSpurText,
            spursPerVine: spursPerVineText,
            budsPerCane: budsPerCaneText,
            canesPerVine: canesPerVineText,
            vinesPerHa: vinesPerHaText,
            bunchWeight: bunchWeightText
        )
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: key)
        }
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

    private func applyPaddockDefaults() {
        guard let paddock = selectedPaddock else { return }
        let area = paddock.areaHectares
        let vines = Double(paddock.effectiveVineCount)
        if area > 0, vines > 0 {
            let computed = vines / area
            vinesPerHaText = String(format: "%.0f", computed)
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
