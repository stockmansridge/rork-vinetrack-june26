import Foundation
import Testing
import PDFKit
@testable import VineTrack

@MainActor
struct TripRegionPDFTests {
    @Test func auAndUsTripReportsUseRegionalDepthRatesDatesAndMoney() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-03-06T01:00:00Z"))
        let trip = Trip(startTime: start, endTime: start.addingTimeInterval(3600), isActive: false,
            totalDistance: 1000, tripFunction: "seeding",
            seedingDetails: SeedingDetails(frontBox: SeedingBox(mixName: "Ryecorn", ratePerHa: 24.71053814672, seedVolumeKg: 40), sowingDepthCm: 2.54))
        let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", currencyCode: "USD", timezone: "America/Los_Angeles",
            areaUnit: AreaUnit.acres.rawValue, distanceUnit: DistanceSystem.imperial.rawValue, dateFormat: RegionDateFormat.monthDayYear.rawValue))
        let cost = TripCostService.Result(activeHours: 1,
            labour: .init(categoryName: "Operator", costPerHour: 0, hours: 1, cost: 0, warning: nil),
            fuel: .init(machineName: "Tractor", fuelUsageLPerHour: 10, costPerLitre: 1.234, litres: 10, cost: 12.34, warning: nil,
                basis: .duration, fuelHours: 1, engineHourDelta: nil),
            chemical: nil, seeding: nil, totalCost: 12.34, completeness: .complete, warnings: [],
            treatedAreaHa: 1, costPerHa: 12.34, yieldTonnes: 2, costPerTonne: 6.17, areaWarning: nil, yieldWarning: nil)
        for fmt in [RegionFormatter.australian, us] {
            let data = TripPDFService.generatePDF(trip: trip, vineyardName: "Fixture vineyard", paddockName: "North", pinCount: 0, mapSnapshot: nil,
                timeZone: fmt.settings.resolvedTimeZone, tripCostResult: cost, formatter: fmt)
            let document = try #require(PDFDocument(data: data))
            let text = try #require(document.string)
            #expect(text.contains(fmt.formatDate(start)))
            #expect(text.contains(fmt.formatYieldPerArea(perHectare: 24.71053814672, unitLabel: "kg")))
            #expect(text.contains("40"))
            #expect(text.contains("kg"))
            #expect(!text.contains("lb"))
            #expect(text.contains(fmt.smallLengthUnitAbbreviation))
            #expect(text.contains(fmt.formatCurrency(12.34)))
            if fmt.settings.countryCode == "US" {
                #expect(text.contains("03/05/2026"))
                #expect(text.contains("1 in"))
                #expect(text.contains("10.00 kg/ac"))
            }
        }
    }
}
