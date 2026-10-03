import Foundation
import Testing
@testable import VineTrack

@MainActor
struct ChemicalStorePresentationTests {
    @Test func archiveImmediatelyHidesButRetainsPersistedHistoryAndCost() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        let vineyard = UUID()
        store.selectedVineyardId = vineyard
        let chemical = SavedChemical(vineyardId: vineyard, name: "Historical product", purchase: ChemicalPurchase(costDollars: 200, containerSizeML: 20, containerUnit: .litres))
        store.addSavedChemical(chemical)
        #expect(ChemicalStorePresentation.active(store.savedChemicals).map(\.id) == [chemical.id])
        store.archiveSavedChemicalLocallyOnly(chemical.id)
        #expect(ChemicalStorePresentation.active(store.savedChemicals).isEmpty)
        let retained = try #require(store.savedChemicals.first { $0.id == chemical.id })
        #expect(!retained.isActive)
        #expect(retained.purchase == chemical.purchase)
        #expect(retained.purchase?.costPerBaseUnit == 0.01)
        let reloaded = SprayRepository(persistence: persistence).loadChemicals(for: vineyard)
        #expect(reloaded.first { $0.id == chemical.id } == retained)
    }

    @Test func deletedAtMapsToInactiveEvenWhenServerIsActive() throws {
        let id = UUID(), vineyard = UUID()
        let data = Data("{\"id\":\"\(id)\",\"vineyard_id\":\"\(vineyard)\",\"is_active\":true,\"deleted_at\":\"2026-10-03T00:00:00Z\"}".utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let row = try decoder.decode(BackendSavedChemical.self, from: data).toSavedChemical()
        #expect(!row.isActive)
        #expect(ChemicalStorePresentation.active([row]).isEmpty)
    }

    @Test(arguments: ["NOT_APPLICABLE", "not_applicable", "UNRESOLVED", "CLASSIFIED"])
    func internalSchemesAreNeverCustomerGroups(_ scheme: String) {
        let row = CatalogueWire(fields: ["activity_group_scheme": .string(scheme), "activity_groups": .array([.string("CLASSIFIED")])])
        #expect(row.groupText.isEmpty)
        #expect(ChemicalStorePresentation.safeLegacyGroup(scheme).isEmpty)
        #expect(row.text("activity_group_scheme") == scheme)
    }

    @Test func classifiedGroupAndUnresolvedWarningHaveDistinctPresentation() {
        #expect(CatalogueWire.resistanceText(scheme: "frac", codes: ["3", "11"]) == "FRAC 3 + 11")
        #expect(CatalogueWire.resistanceText(scheme: "hrac", codes: ["10"]) == "HRAC 10")
        let unresolved = CatalogueWire(fields: ["resistance_classification_state": .string("UNRESOLVED")])
        #expect(unresolved.groupText.isEmpty)
        #expect(unresolved.resistanceWarning == "Resistance group unknown")
        let notApplicable = CatalogueWire(fields: ["resistance_classification_state": .string("not_applicable"), "activity_group_scheme": .string("frac"), "activity_groups": .array([.string("3")])])
        #expect(notApplicable.groupText.isEmpty && notApplicable.resistanceWarning == nil)
    }

    @Test func exactRateRangesAndBasisRemainIntact() {
        let row = CatalogueWire(fields: ["default_rate_options": .object([
            "per_hectare": .array([.object(["min_value": .number(560), "max_value": .number(700), "unit": .string("g/ha"), "condition": .string("Early growth")])]),
            "per_100_litres": .array([.object(["value": .number(100), "unit": .string("mL/100L")])])
        ])])
        #expect(row.registeredRateLines("per_hectare") == ["560–700 g/ha · Early growth"])
        #expect(row.registeredRateLines("per_100_litres") == ["100 mL/100L"])
        #expect(row.rateRows("per_hectare").first?.number("min_value") == 560)
        #expect(row.rateRows("per_hectare").first?.number("max_value") == 700)
    }

    @Test func legacyNotesEditPreservesAllHistoricalValuesAndCost() throws {
        let chemical = SavedChemical(name: "Old chemical", ratePerHa: 1.23456789, chemicalGroup: "Old group", use: "Old use", manufacturer: "Old manufacturer", activeIngredient: "Old ingredient", rates: [ChemicalRate(label: "Original condition", value: 1234.56789)], purchase: ChemicalPurchase(costDollars: 200, containerSizeML: 20), modeOfAction: "Old mode", packSize: 17.125, packUnit: "mL", inventoryQuantity: 7.12345, inventoryUnit: "bottles")
        let initial = ChemicalReviewSession.make(chemical: chemical, prefill: nil, fallbackCountry: "")
        var edited = initial
        edited.notes = "Operator note"
        let saved = try #require(ChemicalStorePresentation.notesOnlyEdit(chemical, session: edited, initialSession: initial))
        var expected = chemical
        expected.notes = "Operator note"
        #expect(saved == expected)
        #expect(saved.purchase?.costPerBaseUnit == chemical.purchase?.costPerBaseUnit)
        #expect(ChemicalStorePresentation.editorKind(chemical) == .legacyRepair)
        #expect(ChemicalStorePresentation.notesPatch(saved.notes).keys.sorted() == ["notes"])
    }

    @Test func catalogueRoutesAwayFromChemistryReconstruction() {
        var chemical = SavedChemical(name: "Catalogue product")
        chemical.chemicalV3RevisionId = UUID()
        #expect(ChemicalStorePresentation.editorKind(chemical) == .catalogue)
        #expect(ChemicalStorePresentation.editorKind(nil) == .manual)
    }
}
