import Foundation
import Testing
@testable import VineTrack

@MainActor
@Suite("Program prefill and prospective tank evidence")
struct SprayProgramTankFollowupTests {
    @Test func programInputsSurviveRowCacheAndSelectedStep() throws {
        let raw = #"{"id":"10000000-0000-4000-8000-000000000001","vineyard_id":"10000000-0000-4000-8000-000000000002","name":"Configured step","is_template":true,"vsp_canopy_size":"Large","vsp_canopy_density":"High","carrier_volume_basis":"l_per_100m","dilute_litres_per_100m":20.02,"applied_litres_per_100m":16.8,"water_volume":750,"spray_rate_per_ha":600,"equipment_id":"10000000-0000-4000-8000-000000000003","tractor_id":"10000000-0000-4000-8000-000000000004","chemical_lines":[{"name":"Configured product","rate":125,"unit":"g/100L"}],"targets":["botrytis"]}"#
        let row = try JSONDecoder().decode(BackendSprayJobTemplate.self, from: Data(raw.utf8))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = PersistenceStore(directory: directory)
        try cache.saveOrThrow([row], key: "program-fixture")
        let cachedRows: [BackendSprayJobTemplate] = try #require(PersistenceStore(directory: directory).load(key: "program-fixture"))
        let cached = try #require(cachedRows.first)
        let step = try #require(SprayProgramCatalog.steps(localRecords: [], portalRecords: [cached.toSprayRecord()], portalRows: [cached]).first)
        #expect(step.id == row.id)
        #expect(step.calculatorPrefill.calculatorInputs == row.calculatorInputs)
        #expect(step.calculatorPrefill.calculatorInputs?.canopy?.size == .large)
        #expect(step.calculatorPrefill.calculatorInputs?.canopy?.density == .high)
        #expect(step.calculatorPrefill.calculatorInputs?.canopy?.isConfirmed == false)
        #expect(step.record.tanks.first?.sprayRatePerHa == 600)
        #expect(step.record.tanks.first?.waterVolume == 750)
        #expect(step.record.tanks.first?.chemicals.first?.ratePer100L == 125)
        #expect(step.calculatorPrefill.equipmentId == row.equipmentId)
        #expect(step.calculatorPrefill.tractorId == row.tractorId)
        for settings in [OrganizationRegionSettings(countryCode: "NZ"), OrganizationRegionSettings(countryCode: "US", areaUnit: "acres", volumeUnit: "gallons", distanceUnit: "imperial", sprayRateAreaUnit: "acre")] {
            let fmt = RegionFormatter(settings: settings)
            #expect(abs(fmt.volumePer100LengthToCanonical(fmt.volumePer100LengthValue(16.8)) - 16.8) < 1e-9)
            #expect(abs(fmt.volumePerAreaToCanonical(fmt.volumePerAreaValue(litresPerHectare: 600)) - 600) < 1e-9)
        }
    }

    @Test func missingProgramValuesAreNotAnswersAndExplicitDiluteUsesExistingDecision() throws {
        let missing = try JSONDecoder().decode(SprayProgramCalculatorInputs.self, from: Data("{}".utf8))
        #expect(missing.canopy == nil)
        #expect(missing.carrierBasis == nil)
        let inputs = SprayProgramCalculatorInputs(canopySize: "Large", canopyDensity: "High", diluteLitresPer100m: 20.02)
        var canopy = try #require(inputs.canopy)
        let unreviewed = SprayVolumeDecisionResolver.decide(canopy: canopy, settings: .defaults,
            rowSpacingMetres: 2.8, choice: .useCustomSprayerRate, customRate: 600, customBasis: .litresPerHectare,
            explicitDiluteLitresPer100m: inputs.diluteLitresPer100m)
        #expect(unreviewed.recommendation == nil)
        canopy.confirm()
        let reviewed = SprayVolumeDecisionResolver.decide(canopy: canopy, settings: .defaults,
            rowSpacingMetres: 2.8, choice: .useCustomSprayerRate, customRate: 600, customBasis: .litresPerHectare,
            explicitDiluteLitresPer100m: inputs.diluteLitresPer100m)
        #expect(abs((reviewed.recommendedLitresPerHectare ?? 0) - 715) < 1e-9)
        #expect(abs(reviewed.concentrationFactor - 715.0 / 600) < 1e-9)
    }

    @Test func prospectiveTankCompletionPersistsIdentityWithoutRangeGuessing() throws {
        var trip = Trip(vineyardId: UUID(), paddockName: "Synthetic block", startTime: Date(timeIntervalSince1970: 100),
            isActive: true, rowSequence: [1.5, 2.5], totalTanks: 2)
        let first = try #require(TankSessionLifecycle.startResult(trip: trip, at: Date(timeIntervalSince1970: 200), currentRow: 1.5, plannedTankNumbers: [1, 2]))
        trip = first.trip
        TankPathAttribution.recordCompletion(1.5, in: &trip, at: Date(timeIntervalSince1970: 210))
        TankPathAttribution.recordCompletion(1.5, in: &trip, at: Date(timeIntervalSince1970: 211))
        trip = TankSessionLifecycle.end(trip: trip, at: Date(timeIntervalSince1970: 220), currentRow: 2.5)
        let second = try #require(TankSessionLifecycle.startResult(trip: trip, at: Date(timeIntervalSince1970: 230), currentRow: 2.5, plannedTankNumbers: [1, 2]))
        trip = second.trip
        TankPathAttribution.recordCompletion(2.5, in: &trip, at: Date(timeIntervalSince1970: 240))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let actualStore = SprayTankActualStore(persistence: persistence)
        for session in trip.tankSessions {
            try actualStore.saveLocally(SprayTankActual(vineyardId: trip.vineyardId, sprayRecordId: UUID(), tripId: trip.id,
                tankSessionId: session.id.uuidString, tankNumber: session.tankNumber, waterVolumeL: 750,
                chemicals: [], confirmedAt: session.startTime, confirmedBy: UUID()))
        }
        try persistence.saveOrThrow(trip, key: "tank-fixture")
        let recreated = PersistenceStore(directory: directory)
        let decoded: Trip = try #require(recreated.load(key: "tank-fixture"))
        let retainedActuals = SprayTankActualStore(persistence: recreated).records
        #expect(retainedActuals.count == 2)
        for session in decoded.tankSessions {
            #expect(retainedActuals.first { $0.tankSessionId == session.id.uuidString }?.tankNumber == session.tankNumber)
        }
        #expect(decoded.tankSessions.map(\.tankNumber) == [1, 2])
        #expect(decoded.tankSessions.map(\.id) == [first.tankSessionId, second.tankSessionId])
        #expect(decoded.tankSessions.map(\.pathsCovered) == [[1.5], [2.5]])
        var stale = decoded
        stale.tankSessions[0].pathsCovered = []
        let merged = try #require(TankPathAttribution.mergingRecordedPaths(local: stale, remote: decoded))
        #expect(merged.tankSessions[0].pathsCovered == [1.5])
        var repeated = decoded
        repeated.rowSequence = [2.5, 2.5]
        repeated.tankSessions[1].pathsCovered = []
        TankPathAttribution.recordCompletion(2.5, in: &repeated)
        #expect(repeated.tankSessions[1].pathsCovered.isEmpty)
    }

    @Test func endedFillUpgradeRetainsOriginalSessionDuringReplay() throws {
        let fillStart = Date(timeIntervalSince1970: 100)
        let fillEnd = Date(timeIntervalSince1970: 200)
        let session = TankSession(tankNumber: 1, startTime: fillStart, fillStartTime: fillStart, fillEndTime: fillEnd)
        let remote = Trip(vineyardId: UUID(), paddockName: "Synthetic", isActive: true, tankSessions: [session])
        let started = try #require(TankSessionLifecycle.startResult(trip: remote, at: Date(timeIntervalSince1970: 210), currentRow: 1.5))
        let ended = TankSessionLifecycle.end(trip: started.trip, at: Date(timeIntervalSince1970: 300), currentRow: 2.5)
        let merged = try #require(TankPathAttribution.mergingRecordedPaths(local: ended, remote: remote))
        #expect(merged.tankSessions == ended.tankSessions)
        #expect(merged.tankSessions.first?.id == session.id)
        #expect(merged.activeTankNumber == nil)
    }

    @Test func datedHistoricalShapesStayUnchangedAndNeverGainPlannedTankTwo() throws {
        // Structural reproductions of owner-reported cases, NOT original production bytes.
        for (day, count) in [("2026-10-14", 2), ("2026-09-04", 1), ("2026-09-23", 1)] {
            let start = try #require(ISO8601DateFormatter().date(from: day + "T00:00:00Z"))
            var trip = Trip(vineyardId: UUID(), paddockName: "Historical shape", startTime: start,
                endTime: start.addingTimeInterval(600), isActive: false, rowSequence: [1.5, 2.5], totalTanks: 2)
            trip.tankSessions = (1...count).map { TankSession(tankNumber: $0, startTime: start, endTime: start.addingTimeInterval(300), startRow: 1.5, endRow: 2.5) }
            let actuals = try trip.tankSessions.map { session in
                try SprayTankActual(vineyardId: trip.vineyardId, sprayRecordId: UUID(), tripId: trip.id,
                    tankSessionId: session.id.uuidString, tankNumber: session.tankNumber, waterVolumeL: 750,
                    chemicals: [], confirmedAt: start, confirmedBy: UUID())
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let original = try encoder.encode(trip)
            var reopened = try JSONDecoder().decode(Trip.self, from: original)
            TankPathAttribution.recordCompletion(1.5, in: &reopened)
            #expect(try encoder.encode(reopened) == original)
            #expect(reopened.tankSessions.count == count)
            #expect(actuals.map(\.tankNumber) == reopened.tankSessions.map(\.tankNumber))
            #expect(actuals.map(\.tankSessionId) == reopened.tankSessions.map { $0.id.uuidString })
            #expect(reopened.tankSessions.allSatisfy { $0.pathsCovered.isEmpty })
            let planned = SprayRecord(vineyardId: trip.vineyardId,
                tanks: [SprayTank(tankNumber: 1, waterVolume: 750), SprayTank(tankNumber: 2, waterVolume: 750)])
            let report = SprayReportPayloadV1.offlineProjection(trip: reopened, record: planned,
                vineyardName: "Synthetic", timeZone: TimeZone(secondsFromGMT: 0)!, paddocks: [],
                tractorName: "", sprayUnitName: "", tankActuals: actuals)
            #expect(report.rows.allSatisfy { $0.tank == nil })
        }
    }
}
