import SwiftUI

/// Separate operational editor shared by catalogue, manual and legacy Chemical Store records.
struct VineyardPreferredRateSection: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.accessControl) private var accessControl
    let chemical: SavedChemical
    @State private var amount: String
    @State private var unit: String
    @State private var basis: ChemicalRateBasis
    @State private var note: String
    @State private var message: String? = nil
    @State private var revision: CatalogueWire? = nil

    init(chemical: SavedChemical) {
        self.chemical = chemical
        _amount = State(initialValue: chemical.vineyardPreferredRate.map { String($0.amount) } ?? "")
        _unit = State(initialValue: chemical.vineyardPreferredRate?.unit ?? "L")
        _basis = State(initialValue: chemical.vineyardPreferredRate?.basis ?? .perHectare)
        _note = State(initialValue: chemical.vineyardPreferredRate?.note ?? "")
    }
    private var vineyardName: String { store.selectedVineyard?.name ?? "Vineyard" }
    private var canEdit: Bool { (accessControl?.canManageSetup ?? false) && store.selectedVineyardId == chemical.vineyardId }
    private var current: SavedChemical { store.savedChemicals.first { $0.id == chemical.id } ?? chemical }
    private var draft: VineyardPreferredRate? {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let result = VineyardPreferredRate(amount: value, unit: unit, basis: basis, note: note.isEmpty ? nil : note,
            updatedAt: ISO8601DateFormatter().string(from: Date()), updatedBy: auth.userId)
        return result.isValid ? result : nil
    }
    var body: some View {
        Section("\(vineyardName) Preferred Rate") {
            if let rate = current.vineyardPreferredRate, rate.isValid { Text(rate.text).font(.headline) }
            else { Text("No preferred vineyard rate set").foregroundStyle(.secondary) }
            Text("Used as the first choice when planning sprays for this vineyard, unless the Program Step has its own rate. Vineyard-defined, not a registered label rate.")
                .font(.caption).foregroundStyle(.secondary)
            if canEdit {
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                Picker("Unit", selection: $unit) { ForEach(["L", "mL", "kg", "g"], id: \.self) { Text($0).tag($0) } }
                Picker("Basis", selection: $basis) { Text("Per hectare").tag(ChemicalRateBasis.perHectare); Text("Per 100 L").tag(ChemicalRateBasis.per100Litres) }
                TextField("Note (optional)", text: $note, axis: .vertical)
                Button("Save preferred rate") { save(draft) }.disabled(draft == nil)
                if current.vineyardPreferredRate != nil {
                    Button("Clear preferred rate", role: .destructive) { amount = ""; save(nil) }
                }
            }
            if let rate = draft, let warning = revision.flatMap({ OperationalRateResolver.warning(rate, revision: $0) }) ?? OperationalRateResolver.warning(rate, chemical: current) {
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: chemical.chemicalV3RevisionId) {
            guard let id = chemical.chemicalV3RevisionId else { return }
            let loaded = try? await CatalogueRepository().revision(id.uuidString)
            guard !Task.isCancelled else { return }
            revision = loaded
        }
    }
    private func save(_ rate: VineyardPreferredRate?) {
        guard canEdit, current.isActive else { return }
        store.setVineyardPreferredRate(rate, chemicalId: chemical.id)
        message = "Saved on this device; queued for vineyard sync."
    }
}
