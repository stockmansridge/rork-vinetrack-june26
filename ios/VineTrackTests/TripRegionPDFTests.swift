import Foundation
import Testing
import PDFKit
@testable import VineTrack

@MainActor
struct TripRegionPDFTests {
    @Test func sprayProgramCustomerCSVAndPDFSeparateCarrierFromChemicalBases() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-03-06T01:00:00Z"))
        let tank = SprayTank(tankNumber: 1, waterVolume: 1500, sprayRatePerHa: 500, concentrationFactor: 1, chemicals: [
            SprayChemical(name: "Area product", ratePerHa: 2000, unit: .litres, rateBasis: .wholeBlockArea),
            SprayChemical(name: "Dilute product", ratePer100L: 150, unit: .millilitres, rateBasis: .per100Litres)
        ])
        let record = SprayRecord(date: date, temperature: 20, windSpeed: 16.09344, sprayReference: "Regional spray", tanks: [tank])
        let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", timezone: "America/Los_Angeles", areaUnit: AreaUnit.acres.rawValue, volumeUnit: VolumeUnit.gallons.rawValue, distanceUnit: DistanceSystem.imperial.rawValue, sprayRateAreaUnit: SprayRateAreaUnit.acre.rawValue, dateFormat: RegionDateFormat.monthDayYear.rawValue))
        for formatter in [RegionFormatter.australian, us] {
            let url = SprayProgramExportService.generateProgramCSV(records: [record], trips: [], vineyardName: "Regional fixture", formatter: formatter)
            defer { try? FileManager.default.removeItem(at: url) }
            let csv = try String(contentsOf: url, encoding: .utf8)
            #expect(csv.contains("Avg Rate (\(formatter.volumePerAreaUnit))"))
            #expect(csv.contains("Temp (\(formatter.temperatureUnitAbbreviation))"))
            #expect(csv.contains("Wind (\(formatter.speedUnitAbbreviation))"))
            #expect(csv.contains(formatter.formatDate(date)))
            #expect(csv.contains(String(format: "%.1f", formatter.volumePerAreaValue(litresPerHectare: 500))))
            #expect(csv.contains(tank.chemicals[0].reportedRateText(formatter: .australian)))
            #expect(csv.contains(tank.chemicals[1].reportedRateText(formatter: .australian)))
            let pdfURL = SprayProgramExportService.generateProgramPDF(records: [record], trips: [], paddocks: [], vineyardName: "Regional fixture", includeCostings: false, formatter: formatter)
            defer { try? FileManager.default.removeItem(at: pdfURL) }
            let text = try #require(PDFDocument(url: pdfURL)?.string)
            #expect(text.contains(formatter.volumePerAreaUnit))
            #expect(text.contains(formatter.formatTemperature(celsius: 20, fractionDigits: 0)))
            #expect(text.contains(formatter.formatSpeed(kmh: 16.09344, fractionDigits: 0)))
        }
        #expect(tank.waterVolume == 1500)
        #expect(tank.sprayRatePerHa == 500)
        #expect(tank.chemicals[0].ratePerHa == 2000)
        #expect(SprayProgramCSVService.templateHeaders.contains("Water Volume (L)"))
        #expect(SprayProgramCSVService.templateHeaders.contains("Temperature (°C)"))
    }

    @Test func auAndUsTripReportsUseRegionalDepthRatesDatesAndMoney() throws {
        let start = try #require(ISO8601DateFormatter().date(from: "2026-03-06T01:00:00Z"))
        let trip = Trip(startTime: start, endTime: start.addingTimeInterval(3600), isActive: false,
            totalDistance: 1000, tripFunction: "seeding",
            seedingDetails: SeedingDetails(frontBox: SeedingBox(mixName: "Ryecorn", ratePerHa: 24.71053814672, seedVolumeKg: 40), sowingDepthCm: 2.54))
        let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", currencyCode: "USD", timezone: "America/Los_Angeles",
            areaUnit: AreaUnit.acres.rawValue, distanceUnit: DistanceSystem.imperial.rawValue, fuelUnit: FuelUnit.gallons.rawValue, dateFormat: RegionDateFormat.monthDayYear.rawValue))
        let gb = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "GB", currencyCode: "GBP", timezone: "Europe/London", areaUnit: AreaUnit.acres.rawValue, distanceUnit: DistanceSystem.imperial.rawValue, fuelUnit: FuelUnit.gallons.rawValue))
        let cost = TripCostService.Result(activeHours: 1,
            labour: .init(categoryName: "Operator", costPerHour: 0, hours: 1, cost: 0, warning: nil),
            fuel: .init(machineName: "Tractor", fuelUsageLPerHour: 10, costPerLitre: 1.234, litres: 10, cost: 12.34, warning: nil,
                basis: .duration, fuelHours: 1, engineHourDelta: nil),
            chemical: nil, seeding: nil, totalCost: 12.34, completeness: .complete, warnings: [],
            treatedAreaHa: 1, costPerHa: 12.34, yieldTonnes: 2, costPerTonne: 6.17, areaWarning: nil, yieldWarning: nil)
        for fmt in [RegionFormatter.australian, us, gb] {
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
            #expect(text.contains(fmt.formatFuel(litres: 10)))
            #expect(text.contains(fmt.formatFuelCostPerUnit(perLitre: 1.234)))
            #expect(text.contains(fmt.formatCostPerArea(12.34)))
            if fmt.settings.countryCode == "US" {
                #expect(text.contains("03/05/2026"))
                #expect(text.contains("1 in"))
                #expect(text.contains("10.00 kg/ac"))
            }
        }
    }
}
