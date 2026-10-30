import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

/// A review binds to the actual recipe, not catalogue hints or regenerated line UUIDs.
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
        !tanks.isEmpty && tanks.allSatisfy { tank in
            tank.waterVolume.isFinite && tank.waterVolume > 0 && !tank.chemicals.isEmpty &&
            tank.chemicals.allSatisfy { product in
                !product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                product.volumePerTank.isFinite && product.volumePerTank > 0 &&
                actualRate(product, waterLitres: tank.waterVolume) != nil
            }
        }
    }
}

#if canImport(SwiftUI)
struct SprayActualRateConfirmation: View {
    let tanks: [SprayTank]
    @Binding var confirmed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Confirm actual chemical rates").font(.headline)
                FieldInfoButton(title: "Actual chemical rates", message: "Confirm the rates you will actually apply, not just the suggested label rates. Per-100 L values show the actual tank concentration, including concentration factor. Go back to Products to change a rate. The confirmed mix is saved with this Trip; later tank actuals remain separate.")
            }
            ForEach(Array(SprayStartRateReview.lines(tanks).enumerated()), id: \.offset) { _, line in
                Text(line).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if !SprayStartRateReview.isReviewable(tanks) {
                Text("Review the chemical rates and tank water before starting.").font(.caption).foregroundStyle(.orange)
            }
            Toggle("I confirm these actual rates", isOn: $confirmed)
                .disabled(!SprayStartRateReview.isReviewable(tanks))
                .accessibilityIdentifier("spray.confirmActualRates")
        }
        .onChange(of: SprayStartRateReview.evidence(tanks)) { _, _ in confirmed = false }
    }
}

#endif
