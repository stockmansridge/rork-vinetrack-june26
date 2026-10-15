import Foundation
import Testing
import PDFKit
@testable import VineTrack

@MainActor
@Suite("MVP spray defect regression")
struct SprayMVPDefectTests {
    @Test("Same configured By Area mix reaches receipt v1 and round-trips pass and controller setup")
    func configuredLegacyStart() throws {
        for configuration in SprayPassConfiguration.allCases {
            let intent = SprayPlanningIntent(configuration: configuration, method: .byArea,
                calibratedLitresPerHectare: 600)
            let resolved = try #require(intent.resolve(selectedAreaHa: 1, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 612))
            #expect(abs((resolved.physicalRowLitresPer100m ?? 0) - 16.8) < 1e-10)
            #expect(abs((resolved.controllerLitresPer100mTravel ?? 0) - 16.8 * configuration.rowEquivalents) < 1e-10)
            #expect(resolved.concentrationFactor == 1.02)
            var geometry = SprayApplicationSnapshot(grossAreaHa: 1, rowSpacingMetres: 2.8,
                totalCarrierLitres: 600, carrierLitresPerHectare: 600, appliedLitresPer100m: resolved.physicalRowLitresPer100m,
                concentrationFactor: 1.02, targets: [.powderyMildew], sprayHeadTarget: .fullCanopy)
            geometry.planningIntent = intent; geometry.planningResolution = resolved
            let scope = LegacySpraySaveRecovery.Scope(actor: UUID(), session: UUID(), vineyard: UUID())
            let trip = Trip(vineyardId: scope.vineyard, isActive: false, tripFunction: "spraying")
            let chemicals = [SprayChemical(name: "Dilute", volumePerTank: 612, ratePer100L: 100, unit: .grams),
                             SprayChemical(name: "Area", volumePerTank: 200, ratePerHa: 200, unit: .grams)]
            let record = SprayRecord(tripId: trip.id, vineyardId: scope.vineyard,
                tanks: [SprayTank(tankNumber: 1, waterVolume: 600, concentrationFactor: 1.02, chemicals: chemicals)],
                notes: "Keep operator notes", applicationGeometry: geometry)
            #expect(record.operationalPlanningBlocker == nil)
            #expect(SprayTripStartAdmission.blocker(isSpray: true, vineyardId: scope.vineyard, record: record) == nil)
            let request = try LegacySprayPairReceipt.prepare(scope: scope, record: record, trip: trip)
            let json = try #require(JSONSerialization.jsonObject(with: request.record) as? [String: Any])
            #expect(Set(json.keys).isSubset(of: LegacySprayPairReceipt.recordKeys))
            #expect(json["sprayer_configuration"] == nil)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let remote = try decoder.decode(BackendSprayRecord.self, from: request.record).toSprayRecord()
            #expect(remote.applicationGeometry?.planningIntent == intent)
            #expect(remote.applicationGeometry?.planningResolution == resolved)
            #expect(remote.tanks == record.tanks)
            #expect(remote.notes.hasPrefix("Keep operator notes"))
            #expect(remote.operationalPlanningBlocker == nil)
            let encodedAgain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(BackendSprayRecord.upsert(from: remote, createdBy: scope.actor, clientUpdatedAt: Date()))) as? [String: Any]
            #expect(encodedAgain?["notes"] as? String == remote.notes)
            #expect(trip.completedPaths.isEmpty && trip.tankSessions.isEmpty)
            for factor in [0.99, Double.nan, Double.infinity] {
                #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: factor, hasDiluteRateProducts: true) != nil)
            }
            var invalid = record
            invalid.tanks[0].chemicals[0].ratePer100L = 0
            #expect(SprayStartRecipeValidation.blocker(invalid.tanks) != nil)
        }
    }

    @Test("Full Tank remains exact and editable but cannot be silently downgraded")
    func fullTankRequiresExactPersistence() throws {
        let intent = SprayPlanningIntent(configuration: .overRow, method: .fullTank,
            fullTankSpecification: .targetArea, intendedTankLitres: 600, targetAreaHa: 1)
        let resolved = try #require(intent.resolve(selectedAreaHa: 2, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 612))
        #expect(LegacySpraySetup.blocker(intent: intent, resolution: resolved) == LegacySpraySetup.fullTankMessage)
        let fields = SprayPlanningWireFields(intent: intent, resolution: resolved)
        #expect(!LegacySpraySetup.canCarry(fields))
        #expect(try LegacySpraySetup.notes("Keep", fields: fields) == "Keep")
        var modified = intent
        modified.method = .byArea
        modified.calibratedLitresPerHectare = 600
        let supported = try #require(modified.resolve(selectedAreaHa: 2, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 612))
        #expect(LegacySpraySetup.blocker(intent: modified, resolution: supported) == nil)
        #expect(intent.method == .fullTank && intent.intendedTankLitres == 600)
    }

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
        for entry in ["Powdery Mildew", "Downy Mildew", "historical_unknown_target", "Full Canopy"] {
            #expect(programText.filter { !$0.isWhitespace }.contains(entry.filter { !$0.isWhitespace }))
        }
        for document in [try #require(PDFDocument(data: pdf)), try #require(PDFDocument(url: programURL))] {
            let targets = document.findString("Powdery Mildew", withOptions: []) + document.findString("Downy Mildew", withOptions: [])
            let locations = document.findString("Full Canopy", withOptions: [])
            #expect(!targets.isEmpty && !locations.isEmpty)
            for selection in targets + locations {
                for page in selection.pages {
                    #expect(page.bounds(for: .mediaBox).contains(selection.bounds(for: page)))
                }
            }
            for target in targets {
                for location in locations {
                    for page in target.pages where location.pages.contains(page) {
                        #expect(!target.bounds(for: page).intersects(location.bounds(for: page)))
                    }
                }
            }
        }
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
