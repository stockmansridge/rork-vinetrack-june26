import Foundation
import Testing
@testable import VineTrack

@MainActor
struct SprayCarrierProvenanceTests {
    @Test func operatorBasisSurvivesNormalisationAndServerRoundTrip() throws {
        for basis in [SprayCarrierBasis.manualTotalVolume, .litresPerHectare, .litresPer100Metres] {
            var input = SprayGuidedInputs()
            input.operationType = basis == .manualTotalVolume ? .bandedSpray : .foliarSpray
            input.groundTarget = .undervine
            input.bandWidthTotalMetres = 1.0
            input.blocks = [SprayBlockInput(blockId: "block", grossAreaHectares: 10, mappedRowLengthMetres: 31250, rowSpacingMetres: 3.2)]
            input.targets = [.powderyMildew]
            input.sprayHeadTarget = .fullCanopy
            input.isGrowthStageResolved = true
            input.isEquipmentSelected = true
            input.isEquipmentConfirmed = true
            input.tankCapacityLitres = 2000
            input.carrierBasis = basis
            input.manualTotalLitres = 400.125
            input.litresPerHectare = 600
            input.appliedLitresPer100Metres = 20
            input.products = [SprayProductLineInput(productId: "product", name: "Product", unit: "mL", basis: .per100Litres, rate: 150)]
            if basis != .manualTotalVolume {
                var canopy = SprayCanopySelection.unconfirmed
                canopy.choose(type: .vsp); canopy.choose(size: .medium); canopy.choose(density: .high)
                input.canopy = canopy
                input.isCanopyConfirmed = true
                input.sprayVolumeChoice = .useCustomSprayerRate
                input.customSprayerBasis = basis
                input.customSprayerRate = basis == .litresPerHectare ? 600 : 20
            }
            let flow = SprayGuidedFlow(inputs: input)
            #expect(flow.effectiveCarrierBasis == basis)
            let carrier = try #require(flow.carrier)
            #expect(carrier.basis == (basis == .manualTotalVolume ? .litresPerHectare : basis))
            let snapshot = try #require(flow.snapshot)
            #expect(snapshot.carrierVolumeBasis == basis)
            #expect(snapshot.totalCarrierLitres == carrier.totalLitres)
            let server = SprayCarrierBasisSyncContract.serverValue(for: snapshot.carrierVolumeBasis)
            #expect(server == (basis == .manualTotalVolume ? "manual_actual_total" : basis.rawValue))
            #expect(SprayCarrierBasisSyncContract.basis(fromServerValue: server) == basis)
            #expect(SprayApplicationSnapshot(plan: flow.plan).carrierVolumeBasis == carrier.basis)
            let reference = SprayCalculationReferenceBuilder.make(flow: flow)
            if basis == .manualTotalVolume {
                #expect(carrier.totalLitres == 400.125)
                #expect(flow.plan.productLines.first?.totalQuantity == 600.1875)
                #expect(reference.water.first { $0.id == "totalWater" }?.workings == "Entered directly — not calculated from a rate or an area")
                #expect(reference.products.first?.lines.first { $0.id == "cf" }?.value == "Not used")
                #expect(reference.canopy.isEmpty && reference.volume.isEmpty)
            } else {
                #expect(reference.water.first { $0.id == "totalWater" }?.workings?.contains("Entered directly") != true)
                #expect(reference.products.first?.lines.first { $0.id == "cf" }?.value != "Not used")
            }
        }
        #expect(SprayCarrierBasisSyncContract.basis(fromServerValue: "l_per_ha") == .litresPerHectare)
    }
}
