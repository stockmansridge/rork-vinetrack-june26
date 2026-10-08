import SwiftUI

struct CalculationSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    private var fmt: RegionFormatter { store.settings.regionFormatter }
    @State private var rates: CanopyWaterRateEntry = .defaults
    @State private var inputs: [String: RegionalInput] = [:]
    @State private var editedInputs: [String: String] = [:]

    private func carrierInput(_ name: String, _ canonical: Binding<Double>) -> Binding<String> {
        Binding(get: { editedInputs[name] ?? inputs[name]?.text ?? String(fmt.volumePer100LengthValue(canonical.wrappedValue)) }, set: { text in
            editedInputs[name] = text
            if let value = inputs[name]?.resolve(text, inverse: fmt.volumePer100LengthToCanonical), value >= 0 { canonical.wrappedValue = value }
        })
    }
    private var hasValidInputs: Bool {
        editedInputs.allSatisfy { name, text in
            guard let value = inputs[name]?.resolve(text, inverse: fmt.volumePer100LengthToCanonical) else { return false }
            return value >= 0
        }
    }
    @State private var savedFeedback: Bool = false
    @State private var showResetAlert: Bool = false

    var body: some View {
        Form {
            Section {
                Text("These values represent \(fmt.volumePer100LengthUnit) of row for each canopy size and density combination. They calculate the recommended carrier rate (\(fmt.volumePerAreaUnit)) from row spacing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            canopyRateSection(title: "Small Canopy", description: CanopySize.small.description, lowBinding: $rates.smallLow, highBinding: $rates.smallHigh, imageName: "CanopySmall")
            canopyRateSection(title: "Medium Canopy", description: CanopySize.medium.description, lowBinding: $rates.mediumLow, highBinding: $rates.mediumHigh, imageName: nil)
            canopyRateSection(title: "Large Canopy", description: CanopySize.large.description, lowBinding: $rates.largeLow, highBinding: $rates.largeHigh, imageName: nil)
            canopyRateSection(title: "Full Canopy", description: CanopySize.full.description, lowBinding: $rates.fullLow, highBinding: $rates.fullHigh, imageName: nil)

            Section {
                exampleCalculation
            } header: {
                Text("Example Calculation")
            } footer: {
                Text("Carrier per area is calculated from carrier per row length and row spacing, then converted to \(fmt.volumePerAreaUnit).")
            }

            Section {
                Button {
                    showResetAlert = true
                } label: {
                    Label("Reset to Defaults", systemImage: "arrow.counterclockwise")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Calculation Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: savedFeedback)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                }.disabled(!hasValidInputs)
            }
        }
        .alert("Reset to Defaults?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                rates = .defaults
                seedInputs()
                save()
            }
        } message: {
            Text("This will reset all canopy water rate volumes to their default values.")
        }
        .onAppear {
            rates = store.settings.canopyWaterRates
            seedInputs()
        }
    }

    private func canopyRateSection(title: String, description: String, lowBinding: Binding<Double>, highBinding: Binding<Double>, imageName: String?) -> some View {
        Section {
            if let imageName {
                HStack {
                    Spacer()
                    Image(imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 100)
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Low Density")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("0", text: carrierInput(title + "Low", lowBinding))
                            .keyboardType(.decimalPad)
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                        Text(fmt.volumePer100LengthUnit)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text("High Density")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField("0", text: carrierInput(title + "High", highBinding))
                            .keyboardType(.decimalPad)
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                        Text(fmt.volumePer100LengthUnit)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(description)
        }
    }

    private var exampleCalculation: some View {
        VStack(alignment: .leading, spacing: 8) {
            let exampleRowSpacing: Double = 2.8
            let examplePer100m = rates.mediumLow
            let exampleLPerHa = CanopyWaterRate.litresPerHa(litresPer100m: examplePer100m, rowSpacingMetres: exampleRowSpacing)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Medium / Low Density")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fmt.formatVolumePer100Length(examplePer100m))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("@ \(fmt.formatLength(metres: exampleRowSpacing)) row spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fmt.formatVolumePerArea(litresPerHectare: exampleLPerHa))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(VineyardTheme.olive)
                }
            }
        }
    }

    private func seedInputs() {
        let values: [(String, Double)] = [("Small CanopyLow", rates.smallLow), ("Small CanopyHigh", rates.smallHigh), ("Medium CanopyLow", rates.mediumLow), ("Medium CanopyHigh", rates.mediumHigh), ("Large CanopyLow", rates.largeLow), ("Large CanopyHigh", rates.largeHigh), ("Full CanopyLow", rates.fullLow), ("Full CanopyHigh", rates.fullHigh)]
        inputs = Dictionary(uniqueKeysWithValues: values.map { ($0.0, RegionalInput(canonical: $0.1, forward: fmt.volumePer100LengthValue)) })
        editedInputs = [:]
    }

    private func save() {
        guard hasValidInputs else { return }
        var s = store.settings
        s.canopyWaterRates = rates
        store.updateSettings(s)
        savedFeedback.toggle()
    }
}
