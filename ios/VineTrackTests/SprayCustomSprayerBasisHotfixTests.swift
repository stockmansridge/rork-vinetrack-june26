import Foundation
import Testing
@testable import VineTrack

/// Regression for the Australian custom-sprayer calibration unit crossing a
/// row-length carrier workflow without being reinterpreted as L/100 m.
struct SprayCustomSprayerBasisHotfixTests {
    private let tolerance = 0.001

    private func isClose(_ value: Double?, _ expected: Double, tolerance: Double? = nil) -> Bool {
        guard let value, value.isFinite else { return false }
        return abs(value - expected) <= (tolerance ?? self.tolerance)
    }

    private func australianFlow() -> SprayGuidedFlow {
        var canopy = SprayCanopySelection.unconfirmed
        canopy.choose(type: .vsp)
        canopy.choose(size: .small)
        canopy.choose(density: .low)

        var inputs = SprayGuidedInputs()
        inputs.sprayName = "Reported Australian job"
        inputs.operationType = .foliarSpray
        inputs.blocks = [
            SprayBlockInput(
                blockId: "reported-australian-job",
                grossAreaHectares: 6.122_386_7,
                mappedRowLengthMetres: 21_865.666_7,
                rowSpacingMetres: 2.8
            )
        ]
        inputs.targets = [.powderyMildew]
        inputs.sprayHeadTarget = .fullCanopy
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.isEquipmentConfirmed = true
        inputs.canopy = canopy
        inputs.canopyWaterRates = .defaults
        inputs.sprayVolumeChoice = .useCustomSprayerRate
        inputs.customSprayerRate = 300
        inputs.customSprayerBasis = .litresPerHectare
        inputs.carrierBasis = .litresPer100Metres
        inputs.tankCapacityLitres = 1_500
        inputs.products = [
            SprayProductLineInput(
                productId: "oil",
                name: "Oil",
                unit: "L",
                basis: .per100Litres,
                rate: 3
            ),
            SprayProductLineInput(
                productId: "sulphur",
                name: "Sulphur",
                unit: "Kg",
                basis: .per100Litres,
                rate: 500,
                unitDisplay: SprayProductUnitDisplay(
                    displayUnit: "Kg",
                    baseUnitsPerDisplayUnit: 1_000
                )
            ),
        ]

        return SprayGuidedFlow(
            inputs: inputs,
            profile: SprayVineyardProfile(countryCode: "AU")
        )
    }

    @Test("Australian 300 L/ha calibration remains 300 L/ha in an L/100 m carrier job")
    func australianCustomRateUsesCanonicalPlanEverywhere() throws {
        let flow = australianFlow()
        let decision = try #require(flow.volumeDecision)
        let plan = flow.plan

        #expect(isClose(decision.recommendedLitresPerHectare, 357.142_857))
        #expect(isClose(decision.actualLitresPerHectare, 300))
        #expect(isClose(decision.actualLitresPer100Metres, 8.4))
        #expect(isClose(decision.concentrationFactor, 1.190_476))

        #expect(isClose(plan.carrier.litresPerHectare, 300))
        #expect(isClose(plan.carrier.appliedLitresPer100Metres, 8.4))
        #expect(isClose(plan.totalCarrierLitres, 1_836.716))
        #expect(isClose(plan.concentrationFactor, 1.190_476))
        #expect(plan.tankSplit.totalTanks == 2)
        #expect(isClose(plan.tankSplit.lastTankLitres, 336.716))

        let oil = try #require(plan.productLines.first { $0.name == "Oil" })
        let sulphur = try #require(plan.productLines.first { $0.name == "Sulphur" })
        #expect(isClose(oil.totalQuantity, 65.597))
        #expect(isClose(sulphur.totalQuantity.map { $0 / 1_000 }, 10.932_833))

        let snapshot = try #require(flow.snapshot)
        #expect(isClose(snapshot.carrierLitresPerHectare, 300))
        #expect(isClose(snapshot.appliedLitresPer100m, 8.4))
        #expect(isClose(snapshot.totalCarrierLitres, 1_836.716))
        #expect(isClose(snapshot.concentrationFactor, 1.190_476))

        let tankVolumes = [plan.tankSplit.tankCapacityLitres, plan.tankSplit.lastTankLitres]
        let persistedTanks = tankVolumes.enumerated().map { index, waterVolume in
            plan.persistedTank(tankNumber: index + 1, waterVolume: waterVolume)
        }
        #expect(persistedTanks.count == 2)
        #expect(persistedTanks.allSatisfy { isClose($0.sprayRatePerHa, 300) })
        #expect(isClose(persistedTanks.last?.waterVolume, 336.716))

        #expect(!isClose(plan.carrier.litresPerHectare, 10_714.3, tolerance: 0.1))
        #expect(!isClose(plan.totalCarrierLitres, 65_597, tolerance: 1))
        #expect(!isClose(oil.totalQuantity, 1_968, tolerance: 1))
        #expect(!isClose(sulphur.totalQuantity.map { $0 / 1_000 }, 328, tolerance: 1))
    }

    @Test("Custom sprayer input basis follows profile policy, not the selected carrier basis")
    func profilePreservesAustralianAndSWNZInputContracts() {
        let australia = SprayVineyardProfile(countryCode: "AU")
        let swnz = SprayVineyardProfile(countryCode: "NZ")

        #expect(australia.resolvedPolicy == .either)
        #expect(australia.customSprayerInputBasis == .litresPerHectare)
        #expect(swnz.resolvedPolicy == .litresPer100MetresOnly)
        #expect(swnz.customSprayerInputBasis == .litresPer100Metres)
    }
}
