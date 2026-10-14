import Foundation
import Testing
@testable import VineTrack

struct SprayCalculatorTimingTests {
    @Test func repeatedPlanReads() {
        var inputs = SprayGuidedInputs()
        inputs.blocks = (0..<100).map { SprayBlockInput(blockId: "b\($0)", blockName: "Synthetic", grossAreaHectares: 1, rowSpacingMetres: 2.8) }
        inputs.carrierBasis = .manualTotalVolume
        inputs.manualTotalLitres = 1500
        inputs.tankCapacityLitres = 1500
        inputs.products = (0..<20).map { SprayProductLineInput(productId: "p\($0)", name: "Synthetic", unit: "L", basis: .wholeBlockArea, rate: 2) }
        let flow = SprayGuidedFlow(inputs: inputs)
        var checksum: Double = 0
        let start = ContinuousClock.now
        for _ in 0..<300 {
            checksum += flow.plan.carrier.totalLitres
            checksum += flow.geometry.grossAreaHectares
            checksum += flow.plan.productLines[0].totalQuantity ?? 0
        }
        let duration = start.duration(to: .now)
        print("CALCULATOR_TIMING repeated_plan_300 duration=\(duration) checksum=\(checksum)")
        #expect(checksum > 0)
        #expect(flow.plan.productLines[0].totalQuantity == 200)
    }
}
