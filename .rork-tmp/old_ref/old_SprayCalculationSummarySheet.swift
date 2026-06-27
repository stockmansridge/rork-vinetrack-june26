import SwiftUI

struct SprayCalculationSummarySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessControl) private var accessControl
    let result: SprayCalculationResult
    let sprayName: String
    let jobStarted: Bool

    private var numberOfTanks: Int {
        result.fullTankCount + (result.lastTankLitres > 0 ? 1 : 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerBanner

                    tankOverviewCard

                    ForEach(1...max(numberOfTanks, 1), id: \.self) { tankNumber in
                        tankCard(tankNumber: tankNumber)
                    }

                    if result.concentrationFactor != 1.0 {
                        cfNotice
                    }

                    if let costing = result.costingSummary, accessControl?.canViewFinancials ?? false {
                        costSummaryCard(costing)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mix Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(jobStarted ? "Continue" : "Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var headerBanner: some View {
        VStack(spacing: 8) {
            Image(systemName: jobStarted ? "checkmark.circle.fill" : "clock.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(jobStarted ? VineyardTheme.olive : VineyardTheme.leafGreen)
                .symbolEffect(.bounce, value: jobStarted)

            Text(jobStarted ? "Job Started" : "Job Saved")
                .font(.title3.bold())

            if !sprayName.isEmpty {
                Text(sprayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("Chemical amounts required per tank")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            (jobStarted ? VineyardTheme.olive : VineyardTheme.leafGreen).opacity(0.08)
        )
        .clipShape(.rect(cornerRadius: 14))
    }

    private var tankOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(.blue)
                Text("Overview")
                    .font(.subheadline.weight(.semibold))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                overviewCell(label: "Total Area", value: "\(String(format: "%.2f", result.totalAreaHectares)) ha", icon: "square.dashed", color: VineyardTheme.olive)
                overviewCell(label: "Total Water", value: "\(String(format: "%.0f", result.totalWaterLitres)) L", icon: "drop.fill", color: .blue)
                overviewCell(label: "Full Tanks", value: "\(result.fullTankCount)", icon: "fuelpump.fill", color: VineyardTheme.earthBrown)
                overviewCell(label: "Last Tank", value: "\(String(format: "%.0f", result.lastTankLitres)) L", icon: "drop.halffull", color: .orange)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func overviewCell(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.semibold))
            }
            Spacer()
        }
        .padding(8)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 8))
    }

    private func tankCard(tankNumber: Int) -> some View {
        let isLastTank = tankNumber == numberOfTanks && result.lastTankLitres > 0 && result.fullTankCount > 0
        let isPartialOnly = numberOfTanks == 1 && result.lastTankLitres > 0 && result.lastTankLitres < result.tankCapacityLitres
        let waterVolume: Double = (isLastTank || isPartialOnly) ? result.lastTankLitres : result.tankCapacityLitres

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "drop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    Text("Tank \(tankNumber)")
                        .font(.headline)
                }
                Spacer()
                if isLastTank || isPartialOnly {
                    Text("Partial")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Text("\(String(format: "%.0f", waterVolume)) L water")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Divider()

            ForEach(result.chemicalResults) { chemResult in
                let amount = (isLastTank || isPartialOnly) ? chemResult.amountInLastTank : chemResult.amountPerFullTank

                HStack(spacing: 12) {
                    Image(systemName: "flask.fill")
                        .font(.subheadline)
                        .foregroundStyle(VineyardTheme.leafGreen)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(chemResult.chemicalName)
                            .font(.subheadline.weight(.medium))
                        Text("Rate: \(String(format: "%.0f", chemResult.unit.fromBase(chemResult.selectedRate))) \(chemResult.unit.rawValue)/\(chemResult.basis == .perHectare ? "ha" : "100L")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formatAmount(chemResult.unit.fromBase(amount), unit: chemResult.unit))
                            .font(.title3.bold())
                            .foregroundStyle(VineyardTheme.olive)
                        Text(chemResult.unit.rawValue)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(VineyardTheme.olive.opacity(0.06))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var cfNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Concentration Factor Applied")
                    .font(.caption.weight(.semibold))
                Text("\(String(format: "%.2f", result.concentrationFactor))× — \(result.concentrationFactor > 1.0 ? "Concentrate spray" : "Dilute spray")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.08))
        .clipShape(.rect(cornerRadius: 10))
    }

    private func costSummaryCard(_ costing: SprayCostingSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(VineyardTheme.vineRed)
                Text("Cost Summary")
                    .font(.subheadline.weight(.semibold))
            }

            ForEach(costing.chemicalCosts) { cost in
                HStack {
                    Text(cost.chemicalName)
                        .font(.subheadline)
                    Spacer()
                    Text("$\(String(format: "%.2f", cost.totalCost))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("Total Cost")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("$\(String(format: "%.2f", costing.grandTotal))")
                    .font(.headline)
                    .foregroundStyle(VineyardTheme.vineRed)
            }

            HStack {
                Text("Per Hectare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("$\(String(format: "%.2f", costing.grandTotalPerHectare))/ha")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(VineyardTheme.earthBrown)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func formatAmount(_ value: Double, unit: ChemicalUnit) -> String {
        if value >= 100 {
            return String(format: "%.0f", value)
        } else if value >= 10 {
            return String(format: "%.1f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }
}
