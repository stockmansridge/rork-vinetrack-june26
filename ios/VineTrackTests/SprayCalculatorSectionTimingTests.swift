import Foundation
import Testing
@testable import VineTrack

/// Model-side cost comparison of the exact repeated plan reads removed from the product section.
struct SprayCalculatorSectionTimingTests {
    @Test func repeatedSectionPlanReadsVersusSingleSnapshot() {
        for (blocks, products) in [(5, 3), (30, 10), (100, 20)] {
            var inputs = SprayGuidedInputs()
            inputs.blocks = (0..<blocks).map { SprayBlockInput(blockId: "b\($0)", blockName: "Synthetic", grossAreaHectares: 1, rowSpacingMetres: 2.8) }
            inputs.carrierBasis = .manualTotalVolume
            inputs.manualTotalLitres = 1500
            inputs.tankCapacityLitres = 1500
            inputs.products = (0..<products).map { SprayProductLineInput(productId: "p\($0)", name: "Synthetic", unit: "L", basis: .wholeBlockArea, rate: 2) }
            let flow = SprayGuidedFlow(inputs: inputs)
            var before: Double = 0
            let start = ContinuousClock.now
            for _ in 0..<30 {
                for index in 0..<products { before += flow.plan.productLines[index].totalQuantity ?? 0 }
            }
            let oldDuration = start.duration(to: .now)
            var after: Double = 0
            let optimizedStart = ContinuousClock.now
            for _ in 0..<30 {
                let snapshot = flow.plan.productLines
                for line in snapshot { after += line.totalQuantity ?? 0 }
            }
            let newDuration = optimizedStart.duration(to: .now)
            #expect(before == after)
            #expect(after == Double(30 * products * blocks * 2))
            print("CALCULATOR_SECTION blocks=\(blocks) products=\(products) iterations=30 before=\(oldDuration) after=\(newDuration) plan_reads=\(30 * products)->30 checksum=\(after)")
        }
    }
}
