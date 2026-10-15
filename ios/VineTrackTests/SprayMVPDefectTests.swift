import Foundation
import Testing
import PDFKit
@testable import VineTrack

@MainActor
@Suite("MVP spray defect regression")
struct SprayMVPDefectTests {
    @Test("Recorded multi-target full canopy appears in PDF and CSV without inference")
    func recordedTargetsExport() throws {
        let snapshot = SprayApplicationSnapshot(applicationMode: .wholeBlock,
            targets: [.powderyMildew, .downyMildew], customTargets: ["historical_unknown_target"], sprayHeadTarget: .fullCanopy)
        let trip = Trip(vineyardId: UUID(), endTime: Date(), tripFunction: "spraying")
        let record = SprayRecord(tripId: trip.id, vineyardId: trip.vineyardId, applicationGeometry: snapshot)
        let before = try JSONEncoder().encode(record)
        let payload = SprayReportPayloadV1.offlineProjection(trip: trip, record: record, vineyardName: "Fixture", timeZone: .gmt,
            paddocks: [], tractorName: "", sprayUnitName: "", tankActuals: [])
        let pdf = SprayRecordPDFService.generatePDF(payload: payload, record: record, trip: trip, vineyardName: "Fixture", paddockName: "", personName: "", includeCostings: false, timeZone: .gmt)
        let text = try #require(PDFDocument(data: pdf)?.string)
        for entry in ["Powdery Mildew", "Downy Mildew", "historical_unknown_target", "Full Canopy", "Whole Block"] {
            #expect(text.filter { !$0.isWhitespace }.contains(entry.filter { !$0.isWhitespace }))
        }
        let url = SprayProgramCSVService.exportRecords(records: [record], trips: [trip], vineyardName: "MVPFixture", timeZone: .gmt)
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)
        #expect(csv.contains("Disease/pest targets"))
        #expect(csv.contains("Full Canopy"))
        #expect(csv.contains("Powdery Mildew; Downy Mildew; historical_unknown_target"))
        let programURL = SprayProgramExportService.generateProgramPDF(records: [record], trips: [trip], paddocks: [], vineyardName: "MVPFixture", includeCostings: false, timeZone: .gmt)
        defer { try? FileManager.default.removeItem(at: programURL) }
        let programText = try #require(PDFDocument(url: programURL)?.string)
        #expect(programText.contains("Full Canopy"))
        #expect(programText.contains("Powdery Mildew"))
        #expect(try JSONDecoder().decode(SprayRecord.self, from: before) == record)
    }

    @Test("Unknown historical intent stays unknown, ground location is recorded separately")
    func historicalAndGround() {
        #expect(SprayApplicationReportFields(snapshot: nil).values.allSatisfy { $0 == "Not recorded" })
        let ground = SprayApplicationReportFields(snapshot: SprayApplicationSnapshot(applicationMode: .banded, targets: [.weeds], groundTarget: .undervine))
        #expect(ground.ground == "Undervine")
        #expect(ground.sprayHead == "Not recorded")
    }

    @Test("Canopy confirmation remains explicit until materially changed")
    func explicitCanopy() {
        var canopy = SprayCanopySelection.unconfirmed
        canopy.choose(type: .vsp)
        canopy.choose(size: .medium)
        canopy.choose(density: .low)
        #expect(!canopy.isConfirmed)
        canopy.confirm()
        canopy.choose(size: .medium)
        canopy.choose(density: .low)
        canopy.choose(type: .vsp)
        #expect(canopy.isConfirmed)
        canopy.choose(type: .sprawl)
        #expect(!canopy.isConfirmed)
    }

    @Test("Invalid missing and nonfinite chemical rates cannot start a spray")
    func startRecipeAdmission() {
        let chemical = SprayChemical(name: "Fixture", volumePerTank: 1500, ratePerHa: 750, unit: .grams)
        let tank = SprayTank(tankNumber: 1, waterVolume: 420, chemicals: [chemical])
        #expect(SprayStartRecipeValidation.blocker([tank]) == nil)
        #expect(SprayStartRecipeValidation.blocker([]) != nil)
        for rate in [0, -1, Double.nan, Double.infinity] {
            var invalid = chemical
            invalid.ratePerHa = rate
            var invalidTank = tank
            invalidTank.chemicals = [invalid]
            #expect(SprayStartRecipeValidation.blocker([invalidTank]) != nil)
        }
        var inputs = SprayGuidedInputs()
        inputs.products = [SprayProductLineInput(productId: "p", name: "Fixture", unit: "g", basis: .wholeBlockArea, rate: 0)]
        #expect(SprayGuidedFlow(inputs: inputs).blocker(for: .products) != nil)
    }

    @Test("Applied CF is disclosed beside a dilute product quantity")
    func disclosedCF() {
        let line = SprayProductLineResult(productId: "p", name: "Fixture", unit: "g", basis: .per100Litres,
            rate: 100, totalQuantity: 2000, quantityPerFullTank: 2000, quantityInLastTank: nil, costPerUnit: nil, basisInput: 1000)
        #expect(SprayGuidedFormat.productCalculation(line, concentrationFactor: 2)?.contains("CF 2") == true)
        #expect(SprayGuidedFormat.productCalculation(line, concentrationFactor: 1)?.contains("CF") == false)
    }

    @Test("Regional equipment and canopy presentation leaves canonical litres unchanged")
    func regionalPresentation() {
        let metric = RegionFormatter.australian
        let us = RegionFormatter(settings: OrganizationRegionSettings(countryCode: "US", currencyCode: "USD", areaUnit: "acres", volumeUnit: "gallons", distanceUnit: "imperial", fuelUnit: "gallons", sprayRateAreaUnit: "acre"))
        #expect(metric.formatVolume(litres: 420).contains("420"))
        #expect(us.formatVolume(litres: 420).contains("gal"))
        #expect(us.formatFuelRatePerHour(litresPerHour: 10).contains("gal/hr"))
        #expect(metric.formatFuelRatePerHour(litresPerHour: 10).contains("L/hr"))
        #expect(us.formatVolumePer100Length(20).contains("gal/100 ft"))
        #expect(us.formatVolumePer100Length(40).contains("gal/100 ft"))
        #expect(abs(us.volumeToCanonical(us.volumeValue(litres: 420)) - 420) < 0.000001)
    }
}
