import Foundation
import Testing
@testable import VineTrack

@MainActor
struct ChemicalSeasonPricingTests {
    @Test func canonicalPriceOverridesLegacyAndSupportsFreePurchases() throws {
        let vineyard = UUID(), chemical = UUID()
        let trip = Trip(vineyardId: vineyard)
        let line = SprayChemical(name: "Product", volumePerTank: 1000, costPerUnit: 9, unit: .litres, savedChemicalId: chemical)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, chemicals: [line])])
        for cpu in [0.006, 0.0] {
            let price = ChemicalSeasonPrice(savedChemicalId: chemical, vintage: 2027, weightedCostPerBaseUnit: cpu, baseUnit: "mL", currency: "AUD", purchaseCount: 2, totalQuantityBase: 30000, totalPurchaseCost: cpu * 30000, pricingBasis: "season_weighted_purchase_average", warning: nil)
            let result = TripCostService.estimate(trip: trip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record, chemicalPrices: .init(vineyardId: vineyard, vintage: 2027, prices: [price]))
            #expect(result.chemical?.cost == cpu * 1000)
            #expect(result.chemical?.warning == nil)
            #expect(result.chemical?.pricingBases == ["season_weighted_purchase_average"])
        }
    }

    @Test func completeActualsUseActualAndIncompleteUsePlanned() throws {
        let vineyard = UUID(), chemical = UUID(), session = UUID()
        var trip = Trip(vineyardId: vineyard)
        trip.tankSessions = [TankSession(id: session, tankNumber: 1, startTime: Date())]
        let line = SprayChemical(name: "Product", volumePerTank: 1000, unit: .litres, savedChemicalId: chemical)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, chemicals: [line])])
        let usage = try SprayTankActualChemical(plannedChemicalId: line.id, savedChemicalId: chemical, name: "Product", actualAmountBase: 500, unit: .litres)
        let price = ChemicalSeasonPrice(savedChemicalId: chemical, vintage: 2027, weightedCostPerBaseUnit: 0.006, baseUnit: "mL", currency: "AUD", purchaseCount: 2, totalQuantityBase: 30000, totalPurchaseCost: 180, pricingBasis: "season_weighted_purchase_average", warning: nil)
        for water in [100.0, nil] as [Double?] {
            let actual = try SprayTankActual(vineyardId: vineyard, sprayRecordId: record.id, tripId: trip.id, tankSessionId: session.uuidString, tankNumber: 1, waterVolumeL: water, chemicals: [usage], confirmedAt: Date(), confirmedBy: UUID())
            let result = TripCostService.estimate(trip: trip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record, tankActuals: [actual], chemicalPrices: .init(vineyardId: vineyard, vintage: 2027, prices: [price]))
            #expect(result.chemical?.cost == (water == nil ? 6 : 3))
            #expect(result.chemical?.basis == (water == nil ? .estimated : .actual))
        }
    }

    @Test func substitutionAndAdditionalUseOwnIdentityAndMissingIdentityIsIncomplete() throws {
        let vineyard = UUID(), original = UUID(), substitute = UUID(), extra = UUID(), session = UUID()
        var trip = Trip(vineyardId: vineyard)
        trip.tankSessions = [TankSession(id: session, tankNumber: 1, startTime: Date())]
        let planned = SprayChemical(name: "Original", volumePerTank: 1000, costPerUnit: 99, savedChemicalId: original)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, chemicals: [planned])])
        let replacement = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: substitute, replacesPlannedChemicalId: planned.id, usageKind: "substitution", name: "Replacement", actualAmountBase: 500, unit: .litres)
        let addition = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: extra, usageKind: "additional", name: "Extra", actualAmountBase: 250, unit: .litres)
        let prices = [ChemicalSeasonPrice(savedChemicalId: substitute, vintage: 2027, weightedCostPerBaseUnit: 0.01, baseUnit: "mL", currency: "AUD", purchaseCount: 1, totalQuantityBase: 1000, totalPurchaseCost: 10, pricingBasis: "season_weighted_purchase_average", warning: nil), ChemicalSeasonPrice(savedChemicalId: extra, vintage: 2027, weightedCostPerBaseUnit: 0.02, baseUnit: "mL", currency: "AUD", purchaseCount: 1, totalQuantityBase: 1000, totalPurchaseCost: 20, pricingBasis: "season_weighted_purchase_average", warning: nil)]
        let actual = try SprayTankActual(vineyardId: vineyard, sprayRecordId: record.id, tripId: trip.id, tankSessionId: session.uuidString, tankNumber: 1, waterVolumeL: 100, chemicals: [replacement, addition], confirmedAt: Date(), confirmedBy: UUID())
        let result = TripCostService.estimate(trip: trip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record, tankActuals: [actual], chemicalPrices: .init(vineyardId: vineyard, vintage: 2027, prices: prices))
        #expect(result.chemical?.cost == 10)
        #expect(result.chemical?.warning == nil)
        let unlinked = try SprayTankActualChemical(plannedChemicalId: nil, savedChemicalId: nil, replacesPlannedChemicalId: planned.id, usageKind: "substitution", name: "Original", actualAmountBase: 500, unit: .litres)
        let unknown = try SprayTankActual(vineyardId: vineyard, sprayRecordId: record.id, tripId: trip.id, tankSessionId: session.uuidString, tankNumber: 1, waterVolumeL: 100, chemicals: [unlinked], confirmedAt: Date(), confirmedBy: UUID())
        let missing = TripCostService.estimate(trip: trip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record, tankActuals: [unknown], chemicalPrices: .init(vineyardId: vineyard, vintage: 2027, prices: prices))
        #expect(missing.chemical?.cost == 0)
        #expect(missing.chemical?.warning != nil)
    }

    @Test func legacySnapshotReadableButEditorPurchaseNeverUsed() throws {
        let vineyard = UUID()
        let saved = SavedChemical(vineyardId: vineyard, name: "Old", purchase: ChemicalPurchase(costDollars: 500, containerSizeML: 1, containerUnit: .litres))
        var line = SprayChemical(name: "Old", volumePerTank: 1000, costPerUnit: 0.02, savedChemicalId: saved.id)
        let decoded = try JSONDecoder().decode(SprayChemical.self, from: JSONEncoder().encode(line))
        #expect(decoded.costPerUnit == 0.02)
        #expect(TripCostService.resolveCostPerUnit(decoded, savedChemicals: [saved]) == 0.02)
        line.costPerUnit = 0
        #expect(TripCostService.resolveCostPerUnit(line, savedChemicals: [saved]) == nil)
        let trip = Trip(vineyardId: vineyard)
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, chemicals: [decoded])])
        let result = TripCostService.estimate(trip: trip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record)
        #expect(result.chemical?.pricingBases == ["legacy_stored_spray_snapshot"])
    }

    @Test func androidDisplayQuantityCostsInCanonicalBaseUnits() throws {
        let vineyard = UUID(), chemical = UUID()
        let trip = Trip(vineyardId: vineyard)
        var line = SprayChemical(volumePerTank: 1, unit: .litres, savedChemicalId: chemical)
        line.quantityBasis = "display"
        let roundTrip = try JSONDecoder().decode(SprayChemical.self, from: JSONEncoder().encode(line))
        let record = SprayRecord(tripId: trip.id, vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, chemicals: [roundTrip])])
        let price = ChemicalSeasonPrice(savedChemicalId: chemical, vintage: 2027, weightedCostPerBaseUnit: 0.006, baseUnit: "mL", currency: "AUD", purchaseCount: 2, totalQuantityBase: 30000, totalPurchaseCost: 180, pricingBasis: "season_weighted_purchase_average", warning: nil)
        let result = TripCostService.estimate(trip: trip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record, chemicalPrices: .init(vineyardId: vineyard, vintage: 2027, prices: [price]))
        #expect(result.chemical?.cost == 6)
        #expect(roundTrip.volumePerTank == 1)
    }

    @Test func writePayloadOmitsLegacyPricingButLocalDataSurvives() throws {
        let chemical = SavedChemical(vineyardId: UUID(), name: "Old", purchase: ChemicalPurchase(costDollars: 10, containerSizeML: 1), packSize: 10, packUnit: "L", pricePerPack: 10)
        let payload = BackendSavedChemical.upsert(from: chemical, createdBy: nil, clientUpdatedAt: Date())
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        for key in ["purchase", "pack_size", "pack_unit", "price_per_pack"] { #expect(json[key] == nil) }
        #expect(chemical.purchase?.costDollars == 10)
        #expect(json["product_form"] != nil && json["inventory_unit"] != nil)
    }

    @Test func currencyConflictAndDimensionMismatchNeverUseLegacy() throws {
        let vineyard = UUID(), chemical = UUID()
        let price = ChemicalSeasonPrice(savedChemicalId: chemical, vintage: 2027, weightedCostPerBaseUnit: nil, baseUnit: "mL", currency: nil, purchaseCount: 2, totalQuantityBase: 2000, totalPurchaseCost: nil, pricingBasis: "currency_conflict", warning: "Multiple currencies")
        #expect(price.price(for: .litres) == nil)
        let mass = ChemicalSeasonPrice(savedChemicalId: chemical, vintage: 2027, weightedCostPerBaseUnit: 0.01, baseUnit: "g", currency: "AUD", purchaseCount: 1, totalQuantityBase: 1000, totalPurchaseCost: 10, pricingBasis: "season_weighted_purchase_average", warning: nil)
        #expect(mass.price(for: .litres) == nil)
        #expect(mass.price(for: .kilograms) == 0.01)
        let scopedTrip = Trip(vineyardId: vineyard)
        let record = SprayRecord(tripId: scopedTrip.id, vineyardId: vineyard, tanks: [SprayTank(tankNumber: 1, chemicals: [SprayChemical(volumePerTank: 1000, costPerUnit: 99, savedChemicalId: chemical)])])
        let result = TripCostService.estimate(trip: scopedTrip, operatorCategory: nil, tractor: nil, fuelPurchases: [], sprayRecord: record, chemicalPrices: .init(vineyardId: vineyard, vintage: 2027, prices: [price]))
        #expect(result.chemical?.cost == 0)
        #expect(result.chemical?.pricingBases == ["currency_conflict"])
    }
}
