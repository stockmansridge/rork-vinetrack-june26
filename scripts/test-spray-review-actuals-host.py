#!/usr/bin/env python3
"""Compile/run production spray actual-entry models/store on a Swift Linux host.

This is not an iOS build or UI test. SwiftUI is excluded by the source's own
canImport guard. Explicit boundary doubles replace Trip/chemical transport
containers, PersistenceStore I/O, permission admission and the Supabase SDK.
Production input parsing, regional conversion, actual validation/resolution,
cache methods and StartTankCommitCoordinator are compiled without editing.
No network calls, device data, release settings or dependency installs occur.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--swiftc', default=shutil.which('swiftc'))
parser.add_argument('--output-dir', type=Path)
args = parser.parse_args()
if not args.swiftc:
    raise SystemExit('NOT RUN: Swift compiler unavailable; run the native XCTest selection in Rork.')
OUT = args.output_dir or Path(tempfile.mkdtemp(prefix='vinetrack-spray-actuals-host-'))
OUT.mkdir(parents=True, exist_ok=True)

SOURCES = [
    'ios/VineTrack/LegacyImported/Models/SprayInitialTankAmounts.swift',
    'ios/VineTrack/LegacyImported/Models/SprayTankActual.swift',
    'ios/VineTrack/Backend/Sync/SprayTankActualStore.swift',
    'ios/VineTrack/LegacyImported/Services/StartTankCommitCoordinator.swift',
    'ios/VineTrack/App/SprayStartRateReview.swift',
    'ios/VineTrack/App/SprayEngine/SprayControllerRateEntry.swift',
    'ios/VineTrack/App/SprayEngine/SprayPlanningDraftTransition.swift',
    'ios/VineTrack/LegacyImported/Utilities/RegionalInput.swift',
    'ios/VineTrack/LegacyImported/Utilities/RegionFormatter.swift',
    'ios/VineTrack/LegacyImported/Models/OrganizationRegionSettings.swift',
]

# Reuse the exact production unit and rate-basis declarations. Their larger
# source files also contain unrelated application models, so the bounded
# prefixes below are copied verbatim, with marker checks preventing drift.
prefixes = [
    ('ios/VineTrack/LegacyImported/Models/SavedChemical.swift',
     'nonisolated enum ChemicalRateBasis:', 'ChemicalUnit.swift'),
    ('ios/VineTrack/App/SprayEngine/SprayProductRateBasis.swift',
     '/// The measured application a product quantity is calculated against.', 'SprayProductRateBasis.swift'),
]
for relative, marker, filename in prefixes:
    source = (ROOT / relative).read_text()
    assert source.count(marker) == 1, f'Production extraction marker changed: {relative}'
    (OUT / filename).write_text(source.split(marker, 1)[0])

(OUT / 'Supabase.swift').write_text('public enum SupabaseHostBoundary {}\n')

STUBS = r'''
import Foundation

// Transport-only models. Calculation and validation under test are production.
enum SprayCarrierBasis { case litresPerHectare, litresPer100Metres }
struct SprayPassConfiguration { var rowEquivalents: Double = 1 }
struct TankRowApplication: Codable, Hashable, Sendable { var startRow: Double; var endRow: Double }
struct ChemicalLineSnapshot: Codable, Hashable, Sendable {
    var capturedAt: Date?
    static let capturedAtFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static func parseCapturedAt(_ raw: String) -> Date? { capturedAtFormatter.date(from: raw) }
}
struct SprayChemical: Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var volumePerTank: Double
    var ratePerHa: Double = 1000
    var ratePer100L: Double = 0
    var chemicalSnapshot: ChemicalLineSnapshot? = nil
    var quantityBasis: String? = nil
    var unit: ChemicalUnit
    var rateBasis: SprayProductRateBasis = .wholeBlockArea
    var savedChemicalId: UUID? = nil
    var reportedRateBasis: SprayProductRateBasis { rateBasis }
    var reportedRateBaseValue: Double { rateBasis == .per100Litres ? ratePer100L : ratePerHa }
    var displayReportedRate: Double { unit.fromBase(reportedRateBaseValue) }
    var displayVolume: Double { unit.fromBase(volumePerTank) }
    var unitLabel: String { unit.rawValue }
}
struct SprayTank: Codable, Hashable, Sendable {
    var id = UUID()
    var tankNumber: Int = 1
    var waterVolume: Double = 294.7
    var sprayRatePerHa: Double = 600
    var concentrationFactor: Double = 1
    var rowApplications: [TankRowApplication] = []
    var chemicals: [SprayChemical]
}
struct TankSession: Codable, Hashable, Sendable {
    var id = UUID()
    var tankNumber: Int = 1
    var startTime: Date
    var endTime: Date? = nil
    var startRow: Double? = nil
    var endRow: Double? = nil
    var fillStartTime: Date? = nil
    var fillEndTime: Date? = nil
}
struct Trip: Codable, Hashable, Sendable {
    var id = UUID()
    var vineyardId: UUID
    var isActive = true
    var endTime: Date? = nil
    var tankSessions: [TankSession] = []
    var activeTankNumber: Int? = nil
    var isFillingTank = false
    var fillingTankNumber: Int? = nil
    var completionNotes: String? = nil
}
struct SprayRecord {
    var id: UUID
    var tripId: UUID
    var vineyardId: UUID
    var operationalPlanningBlocker: String? = nil
}
struct SprayPlanningAdmissionError: Error { var message: String }
enum RecoveredSprayApplicationSafety {
    static func blocker(_ record: SprayRecord) -> String? { nil }
}

// JSON I/O double retains the real production store/coordinator transitions,
// including read-back, relaunch and durable write failures.
@MainActor final class PersistenceStore {
    static let shared = PersistenceStore()
    var bytes: [String: Data] = [:]
    var failWrites = false
    func saveOrThrow<T: Encodable>(_ value: T, key: String) throws {
        if failWrites { throw SprayTankActualValidationError.localSaveFailed }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        bytes[key] = try encoder.encode(value)
    }
    func load<T: Decodable>(key: String) -> T? {
        guard let data = bytes[key] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }
    func removeOrThrow(key: String) throws {
        if failWrites { throw SprayTankActualValidationError.localSaveFailed }
        bytes.removeValue(forKey: key)
    }
}
@MainActor final class HostWriteAuthority {
    var allowed = true
    func requireWrite(vineyardId: String) throws {
        if !allowed { throw SprayPlanningAdmissionError(message: "held") }
    }
}
@MainActor final class MigratedDataStore {
    var selectedVineyardId: UUID?
    var trips: [Trip] = []
    var sprayRecords: [SprayRecord] = []
    var onTripChanged: ((UUID) -> Void)?
    let operationalWriteAuthority = HostWriteAuthority()
    let persistence: PersistenceStore
    init(persistence: PersistenceStore) { self.persistence = persistence }
    func updateTripOrThrow(_ trip: Trip) throws {
        let next = trips.map { $0.id == trip.id ? trip : $0 }
        try persistence.saveOrThrow(next, key: "host_trips")
        trips = next
        onTripChanged?(trip.id)
    }
}

// Deterministic SDK double exercises real pull/sync cache writes without HTTP.
@MainActor final class HostTransport {
    var responseData = Data("[]".utf8)
    var error: Error?
    var requests = 0
    func from(_ table: String) -> HostQuery { HostQuery(transport: self) }
    func rpc<T: Encodable>(_ name: String, params: T) -> HostQuery { HostQuery(transport: self) }
}
struct HostResponse<T> { let value: T }
@MainActor struct HostQuery {
    let transport: HostTransport
    func select() -> Self { self }
    func eq<T>(_: String, value: T) -> Self { self }
    func `is`(_: String, value: String?) -> Self { self }
    func execute<T: Decodable>() async throws -> HostResponse<T> {
        if let error = transport.error { throw error }
        transport.requests += 1
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return HostResponse(value: try decoder.decode(T.self, from: transport.responseData))
    }
    @discardableResult func execute() async throws -> Int {
        if let error = transport.error { throw error }
        transport.requests += 1
        return 1
    }
}
@MainActor final class SupabaseClientProvider {
    static let shared = SupabaseClientProvider()
    var isConfigured = true
    let client = HostTransport()
}
@MainActor final class TripSyncService {
    var isSyncing = false
    var blocked = false
    func isPendingParentCreation(_ tripId: UUID) -> Bool { blocked }
}
@MainActor final class SprayRecordSyncService {
    var isSyncing = false
    var blocked = false
    func isPendingUpsert(_ recordId: UUID) -> Bool { blocked }
}
enum SprayTankActualUploadGate {
    enum Decision { case upload, held
        var skipReason: String? { self == .held ? "dependency" : nil }
    }
    static func decide(parentTripBlocked: Bool, sprayRecordPending: Bool) -> Decision {
        parentTripBlocked || sprayRecordPending ? .held : .upload
    }
}
'''
(OUT / 'BoundaryStubs.swift').write_text(STUBS)

HARNESS = r'''
import Foundation

struct HostFailure: Error { let message: String }
@main struct HostChecks {
    @MainActor static var passed = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw HostFailure(message: message) }
        passed += 1
    }
    @MainActor static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { passed += 1; return }
        throw HostFailure(message: message)
    }
    @MainActor static func main() async throws {
        let owner = UUID(), vineyard = UUID(), recordId = UUID()
        let solid = SprayChemical(name: "Solid", volumePerTank: 700, unit: .kilograms)
        let liquid = SprayChemical(name: "Liquid", volumePerTank: 2000, unit: .litres)
        let tank = SprayTank(chemicals: [solid, liquid])
        var preciseTank = tank
        preciseTank.chemicals[0].chemicalSnapshot = ChemicalLineSnapshot(capturedAt: Date(timeIntervalSince1970: 1790000000.123456))
        var millisecondTank = preciseTank
        millisecondTank.chemicals[0].chemicalSnapshot?.capturedAt = ChemicalLineSnapshot.parseCapturedAt(ChemicalLineSnapshot.capturedAtFormatter.string(from: preciseTank.chemicals[0].chemicalSnapshot!.capturedAt!))
        try check(preciseTank != millisecondTank, "snapshot date precision reproduces old equality rejection")
        try check(SprayInitialTankAmounts.samePersistedRecipe(preciseTank, millisecondTank), "persisted timestamp precision does not create a different recipe")
        millisecondTank.chemicals[0].volumePerTank += 0.001
        try check(!SprayInitialTankAmounts.samePersistedRecipe(preciseTank, millisecondTank), "real quantity differences remain blocked")
        let originalTank = tank
        var secondTank = tank; secondTank.id = UUID(); secondTank.tankNumber = 2
        try check(SprayInitialTankAmounts.firstTank(in: [secondTank, tank]) == tank, "first tank follows lifecycle order")
        try check(SprayInitialTankAmounts.firstTank(in: [tank, tank]) == nil, "duplicate tank identity")
        secondTank.tankNumber = 1
        try check(SprayInitialTankAmounts.firstTank(in: [tank, secondTank]) == nil, "duplicate tank number")
        var input = SprayInitialTankInput()
        try check(input.resolved(tank: tank, formatter: .australian) == nil, "blank actual fields must not use plan")
        input.waterText = "300"
        input.chemicalTexts = [solid.id: "0.75", liquid.id: "0"]
        guard let entered = input.resolved(tank: tank, formatter: .australian) else { throw HostFailure(message: "valid explicit input rejected") }
        try check(entered.waterLitres == 300 && entered.chemicalBaseAmounts[solid.id] == 750 && entered.chemicalBaseAmounts[liquid.id] == 0,
                  "canonical actuals / explicit zero")
        try check(tank == originalTank && tank.waterVolume == 294.7 && tank.chemicals[0].volumePerTank == 700, "plan is immutable")
        for invalid in ["", "3.", "3,", "-1", "nan", "infinity", "3kg"] {
            var bad = input; bad.chemicalTexts[solid.id] = invalid
            try check(bad.resolved(tank: tank, formatter: .australian) == nil, "invalid chemical text: \(invalid)")
        }
        for invalid in ["", "0", "-1", "300.", "nan", "infinity"] {
            var bad = input; bad.waterText = invalid
            try check(bad.resolved(tank: tank, formatter: .australian) == nil, "invalid water text: \(invalid)")
        }
        var extra = input; extra.chemicalTexts[UUID()] = "1"
        try check(extra.resolved(tank: tank, formatter: .australian) == nil, "stale chemical key cannot enter a new recipe")
        var missing = input; missing.chemicalTexts.removeValue(forKey: solid.id)
        try check(missing.resolved(tank: tank, formatter: .australian) == nil, "missing chemical cannot become planned actual")
        var comma = input; comma.chemicalTexts[solid.id] = "0,75"
        try check(comma.resolved(tank: tank, formatter: .australian) == entered, "decimal comma")
        var usSettings = OrganizationRegionSettings.australianDefaults
        usSettings.countryCode = "US"; usSettings.volumeUnit = "gallons"
        let us = RegionFormatter(settings: usSettings)
        var gallon = input; gallon.waterText = "10"
        guard let gallonsEntered = gallon.resolved(tank: tank, formatter: us) else { throw HostFailure(message: "regional input") }
        try check(abs(gallonsEntered.waterLitres - us.volumeToCanonical(10)) < 0.0000001, "regional water conversion")
        var imported = solid; imported.quantityBasis = "display"; imported.volumePerTank = 0.7
        try check(SprayInitialTankInput.plannedDisplayAmount(imported) == 0.7, "legacy display-basis guide")
        try check(SprayInitialTankInput.plannedDisplayAmount(solid) == 0.7, "canonical guide")
        var wrongTank = tank; wrongTank.id = UUID()
        try check(!entered.isValid(for: wrongTank), "wrong tank identity")
        var duplicate = tank; duplicate.chemicals.append(solid)
        try check(!entered.isValid(for: duplicate), "duplicate planned chemical")
        let infinite = SprayInitialTankAmounts(tankId: tank.id, tankNumber: 1, waterLitres: .infinity,
            chemicalBaseAmounts: entered.chemicalBaseAmounts)
        try check(!infinite.isValid(for: tank), "nonfinite canonical water")

        let source = Trip(vineyardId: vineyard)
        let draft = SprayInitialTankDraft(ownerId: owner, vineyardId: vineyard, tripId: source.id,
            sprayRecordId: recordId, tank: tank, amounts: entered)
        let time = Date(timeIntervalSince1970: 1790000000.25)
        let session = TankSession(startTime: time)
        var started = source; started.tankSessions = [session]; started.activeTankNumber = 1
        let actual = try SprayTankActual(vineyardId: vineyard, sprayRecordId: recordId, tripId: source.id,
            tankSessionId: session.id.uuidString, tankNumber: 1, waterVolumeL: entered.waterLitres,
            chemicals: tank.chemicals.map { product in
                try SprayTankActualChemical(plannedChemicalId: product.id, savedChemicalId: product.savedChemicalId,
                    name: product.name, actualAmountBase: entered.chemicalBaseAmounts[product.id]!, unit: product.unit)
            }, confirmedAt: time, confirmedBy: owner)
        try check(draft.isRecorded(in: [actual], trip: started), "exact recorded actual")
        try check(!draft.isRecorded(in: [actual], trip: source), "actual row alone is insufficient")
        var wrongSession = started; wrongSession.tankSessions = [TankSession(startTime: time)]
        try check(!draft.isRecorded(in: [actual], trip: wrongSession), "another tank session cannot consume draft")
        let foreign = SprayInitialTankDraft(ownerId: UUID(), vineyardId: vineyard, tripId: source.id,
            sprayRecordId: recordId, tank: tank, amounts: entered)
        try check(!foreign.isRecorded(in: [actual], trip: started), "another owner cannot consume draft")
        var roundedSession = started; roundedSession.tankSessions[0].startTime = Date(timeIntervalSince1970: 1790000000)
        try check(draft.isRecorded(in: [actual], trip: roundedSession), "timestamp codec precision preserves session identity")

        let disk = PersistenceStore()
        struct LegacyCache: Encodable { let records: [SprayTankActual]; let pendingIds: Set<UUID> }
        try disk.saveOrThrow(LegacyCache(records: [actual], pendingIds: [actual.id]), key: "vinetrack_spray_tank_actuals_v1")
        let legacy = SprayTankActualStore(persistence: disk)
        try check(legacy.records.first?.id == actual.id && legacy.pendingIds == [actual.id] && legacy.initialMixDrafts.isEmpty,
                  "legacy actual cache reads without new optional field")
        let store = SprayTankActualStore(persistence: PersistenceStore())
        try store.stageInitialMix(draft); try store.stageInitialMix(draft)
        try check(store.initialMixDrafts == [draft] && store.pendingCount(tripId: source.id) == 1, "idempotent stage blocks finalisation")
        let changed = SprayInitialTankDraft(ownerId: owner, vineyardId: vineyard, tripId: source.id,
            sprayRecordId: UUID(), tank: tank, amounts: entered)
        try rejects("conflicting record must retain original") { try store.stageInitialMix(changed) }
        try check(store.initialMix(tripId: source.id) == draft, "original kept after conflicting retry")
        let failDisk = PersistenceStore(); failDisk.failWrites = true
        let failed = SprayTankActualStore(persistence: failDisk)
        try rejects("stage write failure") { try failed.stageInitialMix(draft) }
        try check(failed.initialMixDrafts.isEmpty, "failed stage not published")

        let retentionDisk = PersistenceStore()
        let retained = SprayTankActualStore(persistence: retentionDisk)
        try retained.stageInitialMix(draft)
        try retained.saveLocally(actual)
        let reopened = SprayTankActualStore(persistence: retentionDisk)
        try check(reopened.initialMix(tripId: source.id) == draft && reopened.records.first?.id == actual.id,
                  "actual save preserves staged mix across reopen")
        try rejects("actual alone cannot clear") { try reopened.clearInitialMix(draft, trip: source) }
        await reopened.pull(vineyardId: vineyard)
        try check(SprayTankActualStore(persistence: retentionDisk).initialMix(tripId: source.id) == draft, "pull preserves retained actual input")
        await reopened.syncPending(tripSync: nil, spraySync: nil, vineyardId: vineyard)
        try check(reopened.pendingIds.isEmpty && reopened.hasPending(tripId: source.id), "server acknowledgement cannot consume retained input")
        try check(SprayTankActualStore(persistence: retentionDisk).initialMix(tripId: source.id) == draft, "sync cache write preserves input")
        retentionDisk.failWrites = true
        try rejects("failed clear retains evidence") { try reopened.clearInitialMix(draft, trip: started) }
        try check(reopened.initialMix(tripId: source.id) == draft, "failed clear not published")
        retentionDisk.failWrites = false
        try reopened.clearInitialMix(draft, trip: started)
        try check(!reopened.hasPending(tripId: source.id) && reopened.records.count == 1, "exact confirmed clear retains actual and releases finalisation")
        try reopened.clearInitialMix(draft, trip: started)
        try check(reopened.initialMixDrafts.isEmpty, "repeat clear is idempotent")
        try reopened.stageInitialMix(draft)
        try reopened.removeLocal(id: actual.id)
        try check(SprayTankActualStore(persistence: retentionDisk).initialMix(tripId: source.id) == draft, "remove actual preserves input")

        // Run the real coordinator through all four interruption boundaries.
        // The production store, IDs, quantity payload and recovery code remain unchanged.
        for point in [StartTankCommitCoordinator.FailurePoint.beforeActual, .afterActual, .afterTrip, .beforeClear] {
            let journalDisk = PersistenceStore()
            let actuals = SprayTankActualStore(persistence: journalDisk)
            let trips = MigratedDataStore(persistence: journalDisk)
            trips.selectedVineyardId = vineyard; trips.trips = [source]
            trips.sprayRecords = [SprayRecord(id: recordId, tripId: source.id, vineyardId: vineyard)]
            try actuals.stageInitialMix(draft)
            let interrupted = StartTankCommitCoordinator(persistence: journalDisk, actualStore: actuals, failurePoint: point)
            try rejects("coordinator fault must interrupt") {
                try interrupted.commit(sourceTrip: source, updatedTrip: started, actual: actual, store: trips)
            }
            // Simulate a real process reopen, including persisted timestamp precision.
            let restartedActuals = SprayTankActualStore(persistence: journalDisk)
            if let durable: [Trip] = journalDisk.load(key: "host_trips") { trips.trips = durable }
            let recovery = StartTankCommitCoordinator(persistence: journalDisk, actualStore: restartedActuals)
            try check(recovery.recover(store: trips), "coordinator exact recovery")
            try check(!recovery.recover(store: trips), "coordinator repeat recovery idempotent")
            try check(restartedActuals.records.map(\.id) == [actual.id] && trips.trips[0].tankSessions.map(\.id) == [session.id],
                      "recovery keeps original actual/session IDs")
            try check(draft.isRecorded(in: restartedActuals.records, trip: trips.trips[0]), "recovered actual still matches entered quantities")
            try restartedActuals.clearInitialMix(draft, trip: trips.trips[0])
            try check(restartedActuals.initialMixDrafts.isEmpty, "clear after stable-id recovery")
        }
        let sameProcessDisk = PersistenceStore()
        let sameProcessActuals = SprayTankActualStore(persistence: sameProcessDisk)
        let sameProcessTrips = MigratedDataStore(persistence: sameProcessDisk)
        sameProcessTrips.selectedVineyardId = vineyard; sameProcessTrips.trips = [source]
        sameProcessTrips.sprayRecords = [SprayRecord(id: recordId, tripId: source.id, vineyardId: vineyard)]
        try sameProcessActuals.stageInitialMix(draft)
        let sameProcessInterrupted = StartTankCommitCoordinator(persistence: sameProcessDisk,
            actualStore: sameProcessActuals, failurePoint: .afterActual)
        try rejects("same-process actual save interruption") {
            try sameProcessInterrupted.commit(sourceTrip: source, updatedTrip: started, actual: actual, store: sameProcessTrips)
        }
        let sameProcessRecovery = StartTankCommitCoordinator(persistence: sameProcessDisk, actualStore: sameProcessActuals)
        try check(sameProcessRecovery.recover(store: sameProcessTrips), "same-process recovery with journal precision")
        try sameProcessActuals.clearInitialMix(draft, trip: sameProcessTrips.trips[0])
        try check(sameProcessActuals.initialMixDrafts.isEmpty, "in-memory actual and journal session acknowledge exact same operation")
        print("HOST_CHECKS passed=\(passed) failed=0")
        print("Boundary doubles: platform transport containers, JSON I/O, write admission and Supabase. SwiftUI/device/native builds not exercised.")
    }
}
'''
(OUT / 'HostChecks.swift').write_text(HARNESS)

def run(command, log_name):
    result = subprocess.run(command, capture_output=True, text=True, env=os.environ.copy())
    (OUT / log_name).write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout + result.stderr)
        raise SystemExit(result.returncode)
    return result.stdout

version = run([args.swiftc, '--version'], 'swift-version.log').strip()
run([args.swiftc, '-module-cache-path', str(OUT / 'module-cache'), '-emit-module', '-module-name', 'Supabase', str(OUT / 'Supabase.swift'),
     '-emit-module-path', str(OUT / 'Supabase.swiftmodule')], 'boundary-module.log')
binary = OUT / 'spray-review-actuals-checks'
run([args.swiftc, '-module-cache-path', str(OUT / 'module-cache'), '-D', 'DEBUG', '-parse-as-library', '-I', str(OUT),
     *[str(ROOT / path) for path in SOURCES],
     *[str(OUT / item[2]) for item in prefixes], str(OUT / 'BoundaryStubs.swift'),
     str(OUT / 'HostChecks.swift'), '-o', str(binary)], 'compile.log')
output = run([str(binary)], 'checks.log')
evidence = {
    'compiler': version,
    'result': output.strip(),
    'production_sources': {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in SOURCES},
    'production_prefix_sources': {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path, _, _ in prefixes},
    'limitations': 'Host logic only; explicit platform/transport/I/O doubles; no SwiftUI, Xcode, simulator or handset validation.',
}
(OUT / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
print(output, end='')
print(f'Evidence: {OUT / "evidence.json"}')
