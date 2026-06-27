import SwiftUI

struct CalculationSettingsView: View {
    @Environment(MigratedDataStore.self) private var store
    @State private var rates: CanopyWaterRateEntry = .defaults
    @State private var savedFeedback: Bool = false
    @State private var showResetAlert: Bool = false

    var body: some View {
        Form {
            Section {
                Text("These values represent litres per 100m of row for each canopy size and density combination. They are used to calculate the recommended water rate (L/ha) based on your row spacing.")
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
                Text("L/ha = (L per 100m) × 100 ÷ Row Spacing (m)")
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
                }
            }
        }
        .alert("Reset to Defaults?", isPresented: $showResetAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                rates = .defaults
                save()
            }
        } message: {
            Text("This will reset all canopy water rate volumes to their default values.")
        }
        .onAppear {
            rates = store.settings.canopyWaterRates
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
                        TextField("0", value: lowBinding, format: .number)
                            .keyboardType(.decimalPad)
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                        Text("L/100m")
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
                        TextField("0", value: highBinding, format: .number)
                            .keyboardType(.decimalPad)
                            .font(.body.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(.rect(cornerRadius: 8))
                        Text("L/100m")
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
                    Text("\(String(format: "%.0f", examplePer100m)) L/100m")
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("@ 2.8m row spacing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.0f", exampleLPerHa)) L/ha")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(VineyardTheme.olive)
                }
            }
        }
    }

    private func save() {
        var s = store.settings
        s.canopyWaterRates = rates
        store.updateSettings(s)
        savedFeedback.toggle()
    }
}
