import Testing
@testable import VineTrack

struct ChemicalSearchV2Tests {
    @Test func deterministicRankingCoversPrimaryAndSecondaryFields() {
        let common = ["kocide blue"]
        #expect(ChemicalSearchV2Rank.rank(query: "Kocide Blue Xtra", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 1)
        #expect(ChemicalSearchV2Rank.rank(query: "Kocide", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 2)
        #expect(ChemicalSearchV2Rank.rank(query: "62764", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 5)
        #expect(ChemicalSearchV2Rank.rank(query: "hydroxide", productName: "Kocide Blue Xtra", commonNames: common, registrationNumber: "62764", activeNames: ["copper hydroxide"], registrant: "Corteva") == 6)
    }

    @Test func staleRequestCannotReplaceActiveRequest() {
        let old = UUID(); let current = UUID()
        #expect(!ChemicalSearchV2RequestGate.accepts(completed: old, active: current))
        #expect(ChemicalSearchV2RequestGate.accepts(completed: current, active: current))
    }

    @Test func minimumReviewSaveDoesNotRequireRegisteredUse() {
        let rate = ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")
        #expect(ChemicalSaveContract.evaluateMinimumOperational(productName: "Test", productUnit: "Litres", rates: [rate]).canSave)
    }

    @Test func photoRegistrationIdentityIsExtractedBeforeFallback() {
        #expect(ChemicalLabelIdentityOCR.apvmaNumber(in: "APVMA Product No. 62764") == "62764")
    }

    @Test func viticultureRatesKeepBothBasesAndSeparateOptions() {
        let uses = [
            ChemicalRegisteredUse(crop: "ORCHARDS, PLANTATIONS AND VINEYARDS", targetRaw: "Weeds", rates: [
                ChemicalLabelRate(basis: .rangePerHectare, minValue: 2.4, maxValue: 3.2, unit: "L"),
                ChemicalLabelRate(basis: .rangePer100Litres, minValue: 240, maxValue: 320, unit: "mL")
            ]),
            ChemicalRegisteredUse(crop: "Grapes", targetRaw: "Weeds", rates: [
                ChemicalLabelRate(basis: .per100Litres, value: 40, unit: "mL")
            ])
        ]
        let rates = ViticultureRates.fromRegisteredUses(uses)
        #expect(rates.perHectare.count == 1)
        #expect(rates.per100Litres.count == 2)
    }

    @Test func punctuationNormalisationFindsSpraySeed() {
        let name = "SPRAY.SEED 250 HERBICIDE"
        #expect(ChemicalSearchV2Rank.rank(query: "Spray Seed 250", productName: name, commonNames: [], registrationNumber: "46516", activeNames: [], registrant: nil) == 2)
        #expect(ChemicalSearchV2Rank.rank(query: "Spray.Seed 250", productName: name, commonNames: [], registrationNumber: "46516", activeNames: [], registrant: nil) == 2)
    }

    @Test func normalMasterSearchHasNoAIPath() {
        #expect(MasterChemicalV2Repository.invokesAI == false)
    }
}
