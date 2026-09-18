import Testing
@testable import VineTrack

struct ChemicalManualMinimumSaveContractTests {
    @Test("manual single rate saves without optional metadata or registered uses")
    func minimumSingleRateSaves() throws {
        var session = ChemicalReviewSession.make(
            chemical: nil,
            prefill: nil,
            fallbackCountry: ""
        )
        session.name = "Manual Wetter"
        session.productCategory = nil
        session.chemistryDraft.productRates = [
            ChemicalManualRateDraft(basis: .perHectare, valueText: "2", unit: "L")
        ]

        #expect(session.isValid)
        #expect(session.saveEvaluation.violations.isEmpty)
        #expect(session.intelligenceForSave?.registeredUses.isEmpty == true)
        let slot = try #require(session.defaultRatesForSave?.perHectare)
        #expect(slot.value == 2)
        #expect(slot.entryMethod == "manual")
        #expect(slot.optionKey.isEmpty)
        #expect(slot.rateIds.isEmpty)
    }

    @Test("manual range requires both numeric bounds in order")
    func rangeValidation() {
        let missingMaximum = ChemicalSaveContract.evaluateMinimumOperational(
            productName: "Manual Fungicide",
            productUnit: "Kg",
            rates: [ChemicalLabelRate(
                basis: .rangePerHectare,
                minValue: 0.5,
                unit: "kg"
            )]
        )
        #expect(missingMaximum.violations.contains { $0.code == .rateValueInvalid })

        let valid = ChemicalSaveContract.evaluateMinimumOperational(
            productName: "Manual Fungicide",
            productUnit: "Kg",
            rates: [ChemicalLabelRate(
                basis: .rangePerHectare,
                minValue: 0.5,
                maxValue: 1,
                unit: "kg"
            )]
        )
        #expect(valid.isSatisfied)
        #expect(!valid.violations.contains { $0.code == .productCategoryMissing })
        #expect(!valid.violations.contains { $0.code == .grapevineUseMissing })
    }

    @Test("name rate and product unit are the only minimum blockers")
    func requiredFieldsAreExplicit() {
        let evaluation = ChemicalSaveContract.evaluateMinimumOperational(
            productName: " ",
            productUnit: " ",
            rates: []
        )
        #expect(Set(evaluation.violations.map(\.code)) == [
            .productNameMissing,
            .productUnitMissing,
            .usableRateMissing,
        ])
    }
}
