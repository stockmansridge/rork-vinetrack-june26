import XCTest
@testable import VineTrack

final class SprayBandedGroundCarrierTests: XCTestCase {
    private let tolerance: Double = 0.0001

    private func block() -> SprayBlockInput {
        SprayBlockInput(blockId: "block-a", grossAreaHectares: 9, mappedRowLengthMetres: 30_000, rowSpacingMetres: 3)
    }

    private func banded(
        basis: SprayCarrierBasis,
        areaBasis: SprayCarrierAreaBasis,
        rate: Double? = nil,
        manualTotal: Double? = nil,
        products: [SprayProductLineInput] = [],
        groundTarget: SprayGroundTarget = .undervine
    ) -> SprayGuidedFlow {
        var inputs = SprayGuidedInputs()
        inputs.operationType = .bandedSpray
        inputs.blocks = [block()]
        inputs.targets = [.weeds]
        inputs.groundTarget = groundTarget
        inputs.bandWidthTotalMetres = 1
        inputs.isGrowthStageResolved = true
        inputs.isEquipmentSelected = true
        inputs.isEquipmentConfirmed = true
        inputs.carrierBasis = basis
        inputs.carrierAreaBasis = areaBasis
        inputs.litresPerHectare = rate
        inputs.manualTotalLitres = manualTotal
        inputs.products = products
        return SprayGuidedFlow(inputs: inputs)
    }

    func testCanopyRegressionGuard() {
        let carrier = SprayCarrierVolumeCalculator.perHectare(
            litresPerHectare: 625,
            areaHectares: 10,
            concentrationFactor: 1.5,
            diluteLitresPerHectare: 937.5,
            rowLengthMetres: 31_250,
            rowSpacingMetres: 3.2
        )
        XCTAssertEqual(carrier.totalLitres, 6_250, accuracy: tolerance)
        XCTAssertEqual(carrier.concentrationFactor, 1.5, accuracy: tolerance)
    }

    func testTreatedAreaCarrier() {
        let plan = banded(basis: .litresPerHectare, areaBasis: .treatedArea, rate: 200).plan
        XCTAssertEqual(plan.treatedAreaHectares ?? 0, 3, accuracy: tolerance)
        XCTAssertEqual(plan.totalCarrierLitres, 600, accuracy: tolerance)
        XCTAssertEqual(plan.concentrationFactor, 1, accuracy: tolerance)
    }

    func testManualTotalCarrier() {
        let carrier = banded(basis: .manualTotalVolume, areaBasis: .treatedArea, manualTotal: 600).plan.carrier
        XCTAssertEqual(carrier.litresPerHectare ?? 0, 200, accuracy: tolerance)
        XCTAssertEqual(carrier.totalLitres, 600, accuracy: tolerance)
    }

    func testWholeBlockCarrier() {
        let plan = banded(basis: .litresPerHectare, areaBasis: .wholeBlockArea, rate: 200).plan
        XCTAssertEqual(plan.totalCarrierLitres, 1_800, accuracy: tolerance)
    }

    func testIndependentProductBases() {
        let products = [
            SprayProductLineInput(productId: "treated", name: "Treated", unit: "L", basis: .treatedArea, rate: 2),
            SprayProductLineInput(productId: "gross", name: "Gross", unit: "L", basis: .wholeBlockArea, rate: 2),
            SprayProductLineInput(productId: "water", name: "Water", unit: "mL", basis: .per100Litres, rate: 100),
        ]
        let lines = banded(basis: .litresPerHectare, areaBasis: .treatedArea, rate: 200, products: products).plan.productLines
        XCTAssertEqual(lines[0].totalQuantity ?? 0, 6, accuracy: tolerance)
        XCTAssertEqual(lines[1].totalQuantity ?? 0, 18, accuracy: tolerance)
        XCTAssertEqual(lines[2].totalQuantity ?? 0, 600, accuracy: tolerance)
    }

    func testGroundTargetsHaveNoCanopyBlocker() {
        for target in SprayGroundTarget.allCases {
            let flow = banded(basis: .litresPerHectare, areaBasis: .treatedArea, rate: 200, groundTarget: target)
            XCTAssertNil(flow.blocker(for: .carrier))
        }
    }
}
