import Testing
@testable import VineTrack

@Suite("Chemical label rate normalisation")
struct ChemicalLabelRateNormalizerTests {
    @Test("Per-100 L range retains both bounds and bare unit")
    func per100Range() {
        let rate = ChemicalLabelRateNormalizer.parse("240–320 mL/100 L")
        #expect(rate?.basis == .rangePer100Litres)
        #expect(rate?.minValue == 240)
        #expect(rate?.maxValue == 320)
        #expect(rate?.value == nil)
        #expect(rate?.unit == "mL")
    }

    @Test("Per-hectare range retains both bounds and bare unit")
    func perHectareRange() {
        let rate = ChemicalLabelRateNormalizer.parse("2.4–3.2 L/ha")
        #expect(rate?.basis == .rangePerHectare)
        #expect(rate?.minValue == 2.4)
        #expect(rate?.maxValue == 3.2)
        #expect(rate?.unit == "L")
    }

    @Test("Contradictory denominator is not calculable")
    func contradiction() {
        let malformed = ChemicalLabelRate(basis: .per100Litres, value: 240, unit: "L/ha")
        #expect(ChemicalLabelRateNormalizer.normalize(malformed) == nil)
    }

    @Test("320 mL per 100 L over 1200 L is 3840 mL")
    func calculatorAcceptance() {
        let context = SprayQuantityContext(
            grossAreaHectares: 6,
            treatedAreaHectares: nil,
            carrierLitres: 1200,
            concentrationFactor: 1,
            rowLengthMetres: nil
        )
        let total = SprayProductQuantityCalculator.totalQuantity(
            rate: 320, basis: .per100Litres, context: context
        )
        #expect(total == 3840)
        #expect(total.map { $0 / 1000 } == 3.84)
        #expect(total.map { $0 / 6 } == 640)
    }
}
