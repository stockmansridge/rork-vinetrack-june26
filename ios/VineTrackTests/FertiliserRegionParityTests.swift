import Foundation
import Testing
@testable import VineTrack

@MainActor
struct FertiliserRegionParityTests {
    @Test func actualAndAssumedMultiBlockTotals() {
        let a = Paddock(name: "A", vineSpacing: 2, vineCountOverride: 4200, rowLengthOverride: 10000)
        let b = Paddock(name: "B", vineSpacing: 2, vineCountOverride: 3600, rowLengthOverride: 8000)
        #expect(FertiliserVineCounts.total([a, b], basis: "actual") == 7800)
        #expect(FertiliserVineCounts.total([a, b], basis: "assumed_full") == 9000)
        #expect(FertiliserCalculator.totalForPerVine(vineCount: 7800, ratePerVine: 10) == 78)
        #expect(FertiliserVineCounts.shares(total: 78, weights: [4200, 3600]) == [42, 36])
        #expect(FertiliserVineCounts.shares(total: 90, weights: [5000, 4000]) == [50, 40])
    }

    @Test func geometryOnlyIsNotActualAndBadGeometryNeverInventsCounts() {
        var block = Paddock(name: "A", vineSpacing: 2, rowLengthOverride: 10001)
        #expect(FertiliserVineCounts.count(block, basis: "actual") == nil)
        #expect(FertiliserVineCounts.count(block, basis: "assumed_full") == 5000)
        for spacing in [0.0, -1.0, Double.nan, Double.infinity] {
            block.vineSpacing = spacing
            #expect(FertiliserVineCounts.count(block, basis: "assumed_full") == nil)
        }
        block.vineSpacing = 2
        block.vineSpacingIsKnown = false
        #expect(FertiliserVineCounts.count(block, basis: "assumed_full") == nil)
        block.vineCountOverride = 4200
        #expect(FertiliserVineCounts.count(block, basis: "actual") == 4200)
    }

    @Test func actualRowsRequireOverrideAndEveryRowToResolve() {
        let row = PaddockRow(number: 1, startPoint: CoordinatePoint(latitude: 0, longitude: 0), endPoint: CoordinatePoint(latitude: 100.0 / 111320, longitude: 0), vineCountOverride: 42)
        var automatic = row
        automatic.vineCountOverride = nil
        var block = Paddock(name: "A", rows: [row, automatic], vineSpacing: 2)
        #expect(FertiliserVineCounts.count(block, basis: "actual") == 92)
        block.vineSpacing = 0
        #expect(FertiliserVineCounts.count(block, basis: "actual") == nil)
        block.rows = [row]
        #expect(FertiliserVineCounts.count(block, basis: "actual") == 42)
        block.vineCountOverride = 4200
        #expect(FertiliserVineCounts.count(block, basis: "actual") == 4200)
    }

    @Test func residualsAndOverflowAreSafe() {
        #expect(FertiliserVineCounts.shares(total: 0.7, weights: [1, 2, 3]).reduce(0, +) == 0.7)
        let block = Paddock(name: "A", vineCountOverride: Int(Int32.max))
        #expect(FertiliserVineCounts.total([block, block], basis: "actual") == nil)
    }

    @Test func legacyAndNewSnapshotsRoundTripWithoutInference() throws {
        let original = FertiliserRecord(vineyardId: UUID(), status: .planned, mode: .perVine, productName: "Snapshot", form: .solid, paddockIds: [], blockNames: [], areaHectares: 0, vineCount: 7800, rate: 10, totalProduct: 78)
        var completed = original
        completed.status = .completed
        #expect(completed.vineCount == 7800)
        #expect(completed.totalProduct == 78)
        for basis in [nil, "", "actual", "assumed_full", "manual"] as [String?] {
            var record = original
            record.vineCountBasis = basis
            let encoded = try JSONEncoder().encode(record)
            #expect(try JSONDecoder().decode(FertiliserRecord.self, from: encoded) == record)
        }
        let legacy = try JSONDecoder().decode(FertiliserRecord.self, from: JSONEncoder().encode(original))
        #expect(legacy.vineCountBasis == nil)
        let upsert = BackendFertiliserRecord.upsert(from: completed, createdBy: nil, clientUpdatedAt: Date())
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(upsert)) as? [String: Any]
        #expect(payload?["vine_count_basis"] == nil)
        #expect(payload?["total_vines"] as? Int == 7800)
    }

    @Test func commonAuUsGbpForwardInverseFixtures() {
        let settings = [OrganizationRegionSettings(), OrganizationRegionSettings(countryCode: "US", currencyCode: "USD", areaUnit: "acres", volumeUnit: "gallons", distanceUnit: "imperial", fuelUnit: "gallons", sprayRateAreaUnit: "acre"), OrganizationRegionSettings(countryCode: "GB", currencyCode: "GBP", areaUnit: "acres", volumeUnit: "gallons", distanceUnit: "imperial", fuelUnit: "gallons", sprayRateAreaUnit: "acre")]
        for settings in settings {
            let f = RegionFormatter(settings: settings)
            #expect(abs(f.areaToCanonical(f.areaValue(hectares: 12.5)) - 12.5) < 1e-9)
            #expect(abs(f.volumeToCanonical(f.volumeValue(litres: 100)) - 100) < 1e-9)
            #expect(abs(f.fuelToCanonical(f.fuelValue(litres: 100)) - 100) < 1e-9)
            #expect(abs(f.volumePerAreaToCanonical(f.volumePerAreaValue(litresPerHectare: 1200)) - 1200) < 1e-9)
            #expect(abs(f.fuelCostToCanonical(f.fuelCostValue(perLitre: 1.89)) - 1.89) < 1e-9)
            #expect(abs(f.lengthToCanonical(f.lengthValue(metres: 2)) - 2) < 1e-9)
            #expect(abs(f.smallLengthToCanonical(f.smallLengthValue(centimetres: 2.54)) - 2.54) < 1e-9)
            #expect(abs(f.perAreaToCanonical(f.perAreaValue(perHectare: 2000)) - 2000) < 1e-9)
        }
    }

    @Test func independentUnitsAndGallons() {
        let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", areaUnit: "acres", volumeUnit: "gallons", fuelUnit: "litres", sprayRateAreaUnit: "hectare"))
        #expect(us.formatVolumePerArea(litresPerHectare: 1000) == "264.17 gal/ha")
        #expect(us.fuelValue(litres: 1000) == 1000)
        #expect(abs(us.volumeValue(litres: 1000) - 264.172052) < 1e-9)
        let gb = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "GB", currencyCode: "GBP", volumeUnit: "gallons"))
        #expect(abs(gb.volumeValue(litres: 1000) - 219.969157) < 1e-9)
        #expect(gb.formatCurrency(12.5).contains("£"))
    }

    @Test func irrigationMixedUnitsUseIndependentAreaVolumeAndDepth() {
        let acresLitres = RegionFormatter(settings: OrganizationRegionSettings(areaUnit: "acres", volumeUnit: "litres", distanceUnit: "metric"))
        #expect(IrrigationFormat.perHectare(1000, formatter: acresLitres) == "405 L/ac")
        #expect(IrrigationFormat.depth(25.4, formatter: acresLitres) == "25.40 mm")
        let hectaresGallons = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", volumeUnit: "gallons", distanceUnit: "imperial"))
        #expect(IrrigationFormat.perHectare(1000, formatter: hectaresGallons) == "264 gal/ha")
        #expect(IrrigationFormat.depth(25.4, formatter: hectaresGallons) == "1.000 in")
        #expect(hectaresGallons.formatDate("2026-10-05") == "05/10/2026")
    }

    @Test func vineyardTimezoneBoundary() throws {
        let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", currencyCode: "USD", timezone: "America/Los_Angeles", dateFormat: "MM/DD/YYYY"))
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-05T01:00:00Z"))
        #expect(us.formatDate(date) == "10/04/2026")
    }
}
