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

    @Test func normalMasterSearchHasNoAIPath() {
        #expect(MasterChemicalV2Repository.invokesAI == false)
    }
}
