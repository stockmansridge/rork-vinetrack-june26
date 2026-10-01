import Foundation
import XCTest
@testable import VineTrack

final class ChemicalSearchMVPTests: XCTestCase {
    @MainActor func testCanonicalSelectionSurvivesSavedRecordReopen() throws {
        let option = ChemicalServerDefaultRateOption(
            optionKey: "default_option_v1_5f58b1d9f422213e1ecf8632036c1356",
            rateIds: ["rate_v1_4efec198ead373a3286939ced245fadf"], basis: "per_100_litres", unit: "mL",
            minValue: 500, maxValue: 1000, targets: ["Phalaris"], conditions: ["Handgun"], crops: ["Vineyards"])
        let defaults = ChemicalSearchV2OperationalDefaults.storedDefaults(
            rates: [option.toLabelRate()], selectedAt: "2026-10-01T00:00:00Z", selectedOption: option)
        let masterID = UUID(uuidString: "03dfb9e8-6592-4746-a3bc-295890d32cd1")!
        let saved = SavedChemical(name: "Weedmaster DUO", notes: "Candidate — not approved", masterChemicalId: masterID, masterSourceRevision: 2, defaultRates: defaults)
        let reopened = try JSONDecoder().decode(SavedChemical.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(reopened.masterChemicalId, masterID)
        XCTAssertEqual(reopened.masterSourceRevision, 2)
        XCTAssertEqual(reopened.defaultRates, defaults)
        XCTAssertEqual(reopened.defaultRates?.per100Litres?.optionKey, option.optionKey)
        XCTAssertEqual(reopened.defaultRates?.per100Litres?.rateIds, option.rateIds)
        XCTAssertEqual(reopened.defaultRates?.per100Litres?.minValue, 500)
        XCTAssertEqual(reopened.defaultRates?.per100Litres?.maxValue, 1000)
        XCTAssertEqual(reopened.defaultRates?.per100Litres?.entryMethod, "canonical")
    }

    @MainActor func testFoundAndManualProductsWithoutRegistrationSaveAndReopenManualRate() throws {
        for source in ["label_lookup", "customer_entered"] {
            for country in ["AU", "NZ", "FR", "US", "ZA", ""] {
                let rate = ChemicalLabelRate(basis: .perHectare, value: 2, unit: "L")
                XCTAssertTrue(ChemicalSaveContract.evaluateMinimumOperational(productName: "Seaweed", productUnit: "Litres", rates: [rate]).isSatisfied)
                let defaults = ChemicalSearchV2OperationalDefaults.storedDefaults(rates: [rate], selectedAt: "2026-10-01T00:00:00Z")
                let intelligence = ChemicalIntelligence(registration: ChemicalRegistration(countryCode: country, registrant: "Supplier"), productCategory: "biostimulant")
                let saved = SavedChemical(name: "Seaweed", manufacturer: "Supplier", productCategory: "biostimulant", chemicalIntelligence: intelligence, defaultRates: defaults, entrySource: source)
                let reopened = try JSONDecoder().decode(SavedChemical.self, from: JSONEncoder().encode(saved))
                XCTAssertNil(reopened.masterChemicalId)
                XCTAssertEqual(reopened.resolvedIntelligence.registration?.countryCode, country)
                XCTAssertEqual(reopened.defaultRates?.perHectare?.value, 2)
                XCTAssertEqual(reopened.defaultRates?.perHectare?.entryMethod, "manual")
                XCTAssertEqual(reopened.defaultRates?.perHectare?.rateIds, [])
                XCTAssertEqual(reopened.defaultRates?.perHectare?.optionKey, "")
                XCTAssertEqual(reopened.entrySource, source)
            }
        }
    }

    @MainActor func testEditedCatalogueAmountIsManualWithoutFakeIdentity() throws {
        let option = ChemicalServerDefaultRateOption(optionKey: "default_option_v1_test", rateIds: ["rate_v1_test"], basis: "per_hectare", unit: "L", value: 2)
        let edited = ChemicalLabelRate(basis: .perHectare, value: 3, unit: "L")
        let defaults = ChemicalSearchV2OperationalDefaults.storedDefaults(rates: [edited], selectedAt: "2026-10-01T00:00:00Z", selectedOption: option)
        XCTAssertEqual(defaults?.perHectare?.entryMethod, "manual")
        XCTAssertEqual(defaults?.perHectare?.rateIds, [])
        XCTAssertEqual(defaults?.perHectare?.value, 3)
    }

    @MainActor func testNoSyntheticEnvelopeAndInternationalSchemeRoundTrip() throws {
        let rates = ViticultureRates(perHectare: [ChemicalLabelRate(basis: .perHectare, value: 1, unit: "L"), ChemicalLabelRate(basis: .perHectare, value: 5, unit: "L")], per100Litres: [])
        XCTAssertNil(ChemicalSearchV2OperationalDefaults.manufacturerEnvelope(from: rates)[.perHectare])
        let registration = try JSONDecoder().decode(ChemicalRegistration.self, from: Data(#"{"country_code":"US","scheme":"epa","registration_number":"123-456"}"#.utf8))
        let reopened = try JSONDecoder().decode(ChemicalRegistration.self, from: JSONEncoder().encode(registration))
        XCTAssertEqual(reopened.rawScheme, "epa")
        XCTAssertEqual(reopened.registrationNumber, "123-456")
        XCTAssertEqual(reopened.countryCode, "US")
    }
}
