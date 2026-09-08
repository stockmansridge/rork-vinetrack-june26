import SwiftUI

struct ConfirmActualTankMixView: View {
    let record: SprayRecord
    let tank: SprayTank
    let tankCount: Int
    let onConfirm: (Double, [UUID: Double]) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var waterText: String
    @State private var chemicalTexts: [UUID: String]
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(record: SprayRecord, tank: SprayTank, tankCount: Int, onConfirm: @escaping (Double, [UUID: Double]) -> Bool) {
        self.record = record
        self.tank = tank
        self.tankCount = tankCount
        self.onConfirm = onConfirm
        _waterText = State(initialValue: Self.input(tank.waterVolume))
        _chemicalTexts = State(initialValue: Dictionary(uniqueKeysWithValues: tank.chemicals.map {
            ($0.id, Self.input($0.unit.fromBase($0.volumePerTank)))
        }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tank \(tank.tankNumber) of \(tankCount)")
                            .font(.headline)
                        LabeledContent("Planned", value: "\(TankMixDetailsView.number(tank.waterVolume)) L")
                        actualInputRow(text: $waterText, unit: "L", accessibilityName: "Actual water")
                        difference(planned: tank.waterVolume, actual: parsed(waterText), unit: "L")
                    }
                    .padding(.vertical, 4)
                } header: { Text("Water — Planned and Actual") }

                Section("Chemicals — Planned and Actual") {
                    ForEach(tank.chemicals) { chemical in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(chemical.name.isEmpty ? "Unnamed chemical" : chemical.name).font(.headline)
                            LabeledContent("Planned", value: "\(TankMixDetailsView.number(chemical.displayVolume)) \(chemical.unitLabel)")
                            actualInputRow(
                                text: Binding(
                                    get: { chemicalTexts[chemical.id] ?? "" },
                                    set: { chemicalTexts[chemical.id] = $0 }
                                ),
                                unit: chemical.unitLabel,
                                accessibilityName: "Actual \(chemical.name.isEmpty ? "chemical" : chemical.name)"
                            )
                            let actual = parsed(chemicalTexts[chemical.id] ?? "")
                            difference(planned: chemical.displayVolume, actual: actual, unit: chemical.unitLabel)
                            if actual == 0 {
                                Label("This product will be recorded as not added.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle("Confirm Actual Tank Mix")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isSaving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Confirm & Start Tank \(tank.tankNumber)") { confirm() }
                        .disabled(!isValid || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var isValid: Bool {
        guard let water = parsed(waterText), water.isFinite, water >= 0 else { return false }
        return tank.chemicals.allSatisfy {
            guard let amount = parsed(chemicalTexts[$0.id] ?? "") else { return false }
            return amount.isFinite && amount >= 0
        }
    }

    private func confirm() {
        guard let water = parsed(waterText), isValid else { return }
        isSaving = true
        let amounts = Dictionary(uniqueKeysWithValues: tank.chemicals.compactMap { chemical -> (UUID, Double)? in
            guard let display = parsed(chemicalTexts[chemical.id] ?? "") else { return nil }
            return (chemical.id, chemical.unit.toBase(display))
        })
        if onConfirm(water, amounts) { dismiss() } else { errorMessage = "The mix could not be saved locally. The tank was not started." }
        isSaving = false
    }

    private func actualInputRow(
        text: Binding<String>,
        unit: String,
        accessibilityName: String
    ) -> some View {
        HStack(spacing: 12) {
            Text("Actual")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(VineyardTheme.olive)
            Spacer(minLength: 12)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .font(.body.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(width: 120)
                .background(VineyardTheme.olive.opacity(0.10))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(VineyardTheme.olive.opacity(0.65), lineWidth: 1.5)
                }
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel(accessibilityName)
            Text(unit)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func difference(planned: Double, actual: Double?, unit: String) -> some View {
        if let actual, abs(actual - planned) > 0.000_000_1 {
            Text("Difference: \(actual > planned ? "+" : "")\(TankMixDetailsView.number(actual - planned)) \(unit)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func parsed(_ text: String) -> Double? {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return formatter.number(from: text)?.doubleValue
    }

    private static func input(_ value: Double) -> String {
        value.formatted(.number.locale(.current).grouping(.never).precision(.fractionLength(0...12)))
    }
}
