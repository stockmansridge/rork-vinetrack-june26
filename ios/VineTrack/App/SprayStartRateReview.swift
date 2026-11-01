import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Recipe evidence binds a review to its calculated mix, independently of route selection.
nonisolated enum SprayStartRateReview {
    static func evidence(_ tanks: [SprayTank]) -> [String] {
        var result: [String] = ["tanks", String(tanks.count)]
        for tank in tanks {
            result.append("tank")
            result.append(String(tank.chemicals.count))
            result.append(String(tank.rowApplications.count))
            result.append(String(tank.tankNumber))
            result.append(String(tank.waterVolume))
            result.append(String(tank.sprayRatePerHa))
            result.append(String(tank.concentrationFactor))
            for product in tank.chemicals {
                result.append(product.savedChemicalId?.uuidString ?? "")
                result.append(product.name)
                result.append(product.unit.rawValue)
                result.append(product.reportedRateBasis.rawValue)
                result.append(String(product.ratePerHa))
                result.append(String(product.ratePer100L))
                result.append(String(product.volumePerTank))
                result.append(product.quantityBasis ?? "base")
            }
            for application in tank.rowApplications {
                result.append(String(application.startRow))
                result.append(String(application.endRow))
            }
        }
        return result
    }

    static func actualRate(_ chemical: SprayChemical, waterLitres: Double) -> Double? {
        let value: Double
        if chemical.reportedRateBasis == .per100Litres {
            guard waterLitres.isFinite, waterLitres > 0 else { return nil }
            // This is the concentration actually mixed, including any concentration factor.
            let amount = chemical.quantityBasis == "display" ? chemical.volumePerTank : chemical.unit.fromBase(chemical.volumePerTank)
            value = amount / waterLitres * 100
        } else {
            value = chemical.quantityBasis == "display" ? chemical.reportedRateBaseValue : chemical.displayReportedRate
        }
        return value.isFinite && value > 0 ? value : nil
    }

    static func lines(_ tanks: [SprayTank]) -> [String] {
        var seen: Set<String> = []
        return tanks.flatMap { tank in
            tank.chemicals.map { product in
                let amount = actualRate(product, waterLitres: tank.waterVolume)
                    .map { String(format: "%.10g", $0) } ?? "Needs a valid rate"
                let basis: String
                switch product.reportedRateBasis {
                case .wholeBlockArea: basis = "/whole block ha"
                case .treatedArea: basis = "/treated ha"
                case .per100Litres: basis = "/100 L mixed water"
                case .per100Metres: basis = "/100 m"
                }
                return "\(product.name): \(amount) \(product.unit.rawValue)\(basis)"
            }
        }.filter { seen.insert($0).inserted }
    }

    static func isReviewable(_ tanks: [SprayTank]) -> Bool {
        SprayInitialTankAmounts.firstTank(in: tanks) != nil && tanks.allSatisfy { tank in
            tank.waterVolume.isFinite && tank.waterVolume > 0 && !tank.chemicals.isEmpty &&
            tank.chemicals.allSatisfy { product in
                !product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                product.volumePerTank.isFinite && product.volumePerTank > 0 &&
                actualRate(product, waterLitres: tank.waterVolume) != nil
            }
        }
    }
}

/// Text is deliberately blank until the operator enters what was loaded.
/// Route choices never participate in this input or its validation.
nonisolated struct SprayInitialTankInput: Equatable {
    var waterText: String = ""
    var chemicalTexts: [UUID: String] = [:]

    init() {}

    init(amounts: SprayInitialTankAmounts, tank: SprayTank, formatter: RegionFormatter) {
        waterText = Self.input(formatter.volumeValue(litres: amounts.waterLitres))
        for chemical in tank.chemicals {
            if let amount = amounts.chemicalBaseAmounts[chemical.id] {
                chemicalTexts[chemical.id] = Self.input(chemical.unit.fromBase(amount))
            }
        }
    }

    func resolved(tank: SprayTank, formatter: RegionFormatter) -> SprayInitialTankAmounts? {
        guard let displayWater = SprayEditingNumber.completeValue(waterText), displayWater > 0,
              Set(tank.chemicals.map(\.id)).count == tank.chemicals.count else { return nil }
        var chemicals: [UUID: Double] = [:]
        for chemical in tank.chemicals {
            guard let value = SprayEditingNumber.completeValue(chemicalTexts[chemical.id] ?? ""),
                  value >= 0 else { return nil }
            chemicals[chemical.id] = chemical.unit.toBase(value)
        }
        // Never reinterpret a field retained from a different recipe.
        guard Set(chemicalTexts.keys).isSubset(of: Set(tank.chemicals.map(\.id))) else { return nil }
        let amounts = SprayInitialTankAmounts(tankId: tank.id, tankNumber: tank.tankNumber,
            waterLitres: formatter.volumeToCanonical(displayWater), chemicalBaseAmounts: chemicals)
        return amounts.isValid(for: tank) ? amounts : nil
    }

    static func plannedDisplayAmount(_ chemical: SprayChemical) -> Double {
        chemical.quantityBasis == "display" ? chemical.volumePerTank : chemical.displayVolume
    }

    static func input(_ value: Double) -> String {
        value.formatted(.number.locale(.current).grouping(.never).precision(.fractionLength(0...12)))
    }
}

#if canImport(SwiftUI)
struct SprayInitialTankActualsEditor: View {
    let tank: SprayTank
    let tankCount: Int
    let formatter: RegionFormatter
    @Binding var input: SprayInitialTankInput
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tank \(tank.tankNumber) — Actual amounts loaded").font(.headline)
                FieldInfoButton(title: "Actual tank contents", message: "The calculator is your guide. Enter the water and each chemical you actually put in this tank. These amounts are saved as the tank's actual-use record when you start. Enter 0 for a product you did not add. Later tanks are recorded when you fill them. Path selection does not change these amounts.")
            }
            VStack(alignment: .leading, spacing: 6) {
                calculatedAmount("Water", amount: formatter.formatVolume(litres: tank.waterVolume))
                actualField("Actual water", unit: formatter.volumeUnitAbbreviation,
                    text: $input.waterText, identifier: "spray.actualWater")
            }
            ForEach(tank.chemicals) { chemical in
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    calculatedAmount(chemical.name, amount: "\(SprayInitialTankInput.plannedDisplayAmount(chemical).formatted(.number.precision(.fractionLength(0...3)))) \(chemical.unitLabel)")
                    actualField("Actual amount added", unit: chemical.unitLabel,
                        text: Binding(get: { input.chemicalTexts[chemical.id] ?? "" },
                            set: { input.chemicalTexts[chemical.id] = $0 }),
                        identifier: "spray.actualChemical.\(chemical.id.uuidString)")
                    if SprayEditingNumber.completeValue(input.chemicalTexts[chemical.id] ?? "") == 0 {
                        Text("Recorded as not added.").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if tankCount > 1 {
                Text("Enter later tanks when you fill them.").font(.caption).foregroundStyle(.secondary)
            }
            if input.resolved(tank: tank, formatter: formatter) == nil {
                Text("Enter the actual water and every chemical amount.").font(.caption).foregroundStyle(.orange)
            } else {
                Label("Actual amounts ready to record", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(VineyardTheme.olive)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 12))
    }

    private func calculatedAmount(_ title: String, amount: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline).fixedSize()
                Spacer(minLength: 8)
                calculatedValue(amount).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                calculatedValue(amount)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func calculatedValue(_ amount: String) -> some View {
        (Text("Calculated - ").font(.subheadline.weight(.semibold)) +
            Text(amount).font(.title3.weight(.bold)))
            .foregroundStyle(colorScheme == .dark ? Color.cyan : Color.blue)
    }

    private func actualField(_ title: String, unit: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                TextField("Enter amount", text: text)
                    .keyboardType(.decimalPad)
                    .font(.title3)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.35)))
                    .accessibilityLabel(title)
                    .accessibilityIdentifier(identifier)
                Text(unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

#endif
