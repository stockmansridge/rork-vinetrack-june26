import Foundation
import Testing
@testable import VineTrack

@MainActor
struct VineyardPreferredRateTests {
    @Test func noGrapevineCatalogueAndManualProductsKeepSeparatePreference() throws {
        for isCatalogue in [true, false] {
            var chemical = SavedChemical(name: "Operational product", entrySource: isCatalogue ? "catalogue" : "manual")
            if isCatalogue { chemical.chemicalV3RevisionId = UUID() }
            chemical.vineyardPreferredRate = VineyardPreferredRate(amount: 2, unit: "L", basis: .perHectare)
            let restored = try JSONDecoder().decode(SavedChemical.self, from: JSONEncoder().encode(chemical))
            #expect(restored.vineyardPreferredRate == chemical.vineyardPreferredRate)
            #expect(restored.defaultRates == nil && restored.rates.isEmpty && restored.ratePerHa == nil)
            #expect(OperationalRateResolver.resolve(chemical: restored)?.rate.amount == 2)
        }
    }
    @Test func registeredRatesRemainUnchangedAlongsidePreference() {
        let use = ChemicalRegisteredUse(crop: "Grapes", targetRaw: "Powdery mildew", rates: [ChemicalLabelRate(basis: .rangePerHectare, minValue: 1, maxValue: 2, unit: "L")])
        var chemical = SavedChemical(name: "Registered", chemicalIntelligence: ChemicalIntelligence(registeredUses: [use]))
        let original = chemical.chemicalIntelligence
        chemical.vineyardPreferredRate = VineyardPreferredRate(amount: 1.5, unit: "L", basis: .perHectare)
        var product = SprayProgramProductDraft()
        product.replaceProduct(with: chemical, seedRate: nil)
        #expect(product.rate == 1.5)
        #expect(product.rateSource == .vineyardPreferred)
        #expect(chemical.chemicalIntelligence == original && chemical.defaultRates == nil)
        #expect(OperationalRateResolver.warning(chemical.vineyardPreferredRate!, chemical: chemical) == nil)
        #expect(OperationalRateResolver.warning(VineyardPreferredRate(amount: 3, unit: "L", basis: .perHectare), chemical: chemical) != nil)
    }
    @Test func programPrefillAndStepEditDoNotChangeChemicalPreference() {
        var chemical = SavedChemical(name: "Custom")
        chemical.vineyardPreferredRate = VineyardPreferredRate(amount: 2, unit: "L", basis: .perHectare)
        var product = SprayProgramProductDraft()
        product.replaceProduct(with: chemical, seedRate: nil)
        #expect(product.rate == 2 && product.unit == .litres && product.basis == .wholeBlockArea)
        product.rate = 1.5
        #expect(chemical.vineyardPreferredRate?.amount == 2)
        #expect(OperationalRateResolver.rateFromProgram(product.toSprayChemical())?.amount == 1.5)
    }
    @Test func localProgramRoundTripKeepsPlanned100LRate() throws {
        let record = SprayRecord(isTemplate: true)
        var draft = SprayProgramStepDraft(step: SprayProgramStep(record: record, source: .local))
        draft.products = [SprayProgramProductDraft(name: "Product", rate: 150, unit: .millilitres, basis: .per100Litres)]
        let saved = draft.applied(to: record)
        let reopenedRecord = try JSONDecoder().decode(SprayRecord.self, from: JSONEncoder().encode(saved))
        let reopened = SprayProgramStepDraft(step: SprayProgramStep(record: reopenedRecord, source: .local))
        #expect(reopened.products.first?.rate == 150)
        #expect(reopened.products.first?.basis == .per100Litres)
        #expect(reopened.products.first?.unit == .millilitres)
        let wire = reopened.chemicalLines().first
        #expect(wire?.rate == 150 && wire?.unit == "mL/100L")
    }
    @Test func planningUsesProgramBeforeVineyardBeforeDefault() {
        var chemical = SavedChemical(name: "Product", defaultRates: StoredChemicalDefaultRates(perHectare: .manual(basis: .perHectare, unit: "L", value: 1)))
        chemical.vineyardPreferredRate = VineyardPreferredRate(amount: 2, unit: "L", basis: .perHectare)
        let planned = VineyardPreferredRate(amount: 1.5, unit: "L", basis: .perHectare)
        let line = SprayConfirmedRateSeeding.plannedLine(for: chemical, program: planned, preferring: [.per100Litres], fallbackBasis: .per100Litres)
        #expect(line.overrideRate == 1500 && line.basis == .perHectare && line.operationalRateSource == .programStep)
        #expect(OperationalRateResolver.resolve(chemical: chemical)?.source == .vineyardPreferred)
        chemical.vineyardPreferredRate = nil
        #expect(OperationalRateResolver.resolve(chemical: chemical)?.source == .confirmedDefault)
        #expect(OperationalRateResolver.resolve(chemical: chemical)?.rate.amount == 1)
        chemical.defaultRates = nil
        #expect(OperationalRateResolver.resolve(chemical: chemical) == nil)
    }
    @Test func per100LPreferenceNeverConvertsIntoPerHectare() {
        var chemical = SavedChemical(name: "Product", defaultRates: StoredChemicalDefaultRates(perHectare: .manual(basis: .perHectare, unit: "L", value: 2)))
        chemical.vineyardPreferredRate = VineyardPreferredRate(amount: 150, unit: "mL", basis: .per100Litres)
        let line = SprayConfirmedRateSeeding.seededLine(for: chemical, preferring: [.perHectare], fallbackBasis: .perHectare)
        #expect(line.basis == .per100Litres && line.overrideRate == 150 && line.operationalRateUnit == "mL")
        #expect(chemical.defaultRates?.perHectare?.value == 2)
    }
    @Test func missingProgramRateUsesPreferenceAndReplacementClearsOldRate() {
        var chemical = SavedChemical(name: "New")
        chemical.vineyardPreferredRate = VineyardPreferredRate(amount: 2, unit: "L", basis: .perHectare)
        #expect(OperationalRateResolver.resolve(program: OperationalRateResolver.rateFromProgram(SprayChemical()), chemical: chemical)?.source == .vineyardPreferred)
        var product = SprayProgramProductDraft(name: "Old", rate: 99)
        chemical.vineyardPreferredRate = nil
        product.replaceProduct(with: chemical, seedRate: nil)
        #expect(product.rate == 0)
    }
    @Test func clearHasExplicitWireNullAndUnrelatedEditOmitsPreference() throws {
        var chemical = SavedChemical(name: "Custom")
        let unchanged = BackendSavedChemical.upsert(from: chemical, createdBy: nil, clientUpdatedAt: Date())
        let before = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(unchanged)) as? [String: Any])
        #expect(before["vineyard_preferred_rate"] == nil)
        chemical.vineyardPreferredRatePending = true
        chemical.vineyardPreferredRateOnly = true
        let clear = BackendSavedChemical.upsert(from: chemical, createdBy: nil, clientUpdatedAt: Date())
        let after = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(clear)) as? [String: Any])
        #expect(after["vineyard_preferred_rate"] is NSNull)
        #expect(clear.preferredRateOnly)
    }
    @Test func offlinePreferenceAndClearSurviveCacheRestartWithoutRegisteredMutation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory), vineyard = UUID()
        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = vineyard
        let chemical = SavedChemical(vineyardId: vineyard, name: "Manual")
        store.sprayRepo.replaceChemicals([chemical], for: vineyard)
        store.savedChemicals = [chemical]
        store.setVineyardPreferredRate(VineyardPreferredRate(amount: 2, unit: "L", basis: .perHectare), chemicalId: chemical.id)
        let restored = store.sprayRepo.loadChemicals(for: vineyard).first
        #expect(restored?.vineyardPreferredRate?.amount == 2 && restored?.vineyardPreferredRatePending == true)
        #expect(restored?.chemicalIntelligence == nil && restored?.defaultRates == nil)
        store.setVineyardPreferredRate(nil, chemicalId: chemical.id)
        let cleared = store.sprayRepo.loadChemicals(for: vineyard).first
        #expect(cleared?.vineyardPreferredRate == nil && cleared?.vineyardPreferredRatePending == true)
        #expect(cleared?.vineyardPreferredRateOnly == true)
    }
    @Test func exactCatalogueRevisionWarningDoesNotClampOrCrossBasis() throws {
        let revision = try JSONDecoder().decode(CatalogueWire.self, from: Data(#"{"default_rate_options":{"per_hectare":[{"min_value":1,"max_value":2,"unit":"L"}]}}"#.utf8))
        let rate = VineyardPreferredRate(amount: 2500, unit: "mL", basis: .perHectare)
        #expect(OperationalRateResolver.warning(rate, revision: revision) != nil)
        #expect(rate.amount == 2500)
        #expect(OperationalRateResolver.warning(VineyardPreferredRate(amount: 1500, unit: "mL", basis: .perHectare), revision: revision) == nil)
        #expect(OperationalRateResolver.warning(VineyardPreferredRate(amount: 2500, unit: "g", basis: .perHectare), revision: revision) == nil)
        #expect(OperationalRateResolver.warning(VineyardPreferredRate(amount: 2500, unit: "mL", basis: .per100Litres), revision: revision) == nil)
    }
    @Test func invalidRatesDoNotResolveOrCompareAcrossBasisAndDimension() {
        var chemical = SavedChemical(name: "Product", chemicalIntelligence: ChemicalIntelligence(registeredUses: [ChemicalRegisteredUse(crop: "Grapes", targetRaw: "Mildew", rates: [ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")])]))
        chemical.vineyardPreferredRate = VineyardPreferredRate(amount: .nan, unit: "L", basis: .perHectare)
        #expect(OperationalRateResolver.resolve(chemical: chemical) == nil)
        #expect(OperationalRateResolver.warning(VineyardPreferredRate(amount: 150, unit: "mL", basis: .per100Litres), chemical: chemical) == nil)
        #expect(OperationalRateResolver.warning(VineyardPreferredRate(amount: 150, unit: "g", basis: .perHectare), chemical: chemical) == nil)
    }
}
