#if DEBUG
import SwiftUI

/// Isolated app-process restart fixture; uses production store/WAL with no network or authentication bypass.
struct LegacySprayRecoveryValidationView: View {
    @State private var result: String = "Loading"
    private static let actor = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private static let session = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private static let vineyard = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    var body: some View {
        Text(result).accessibilityIdentifier("legacy.recovery.result").task { await execute() }
    }
    private func execute() async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--legacy-recovery-case"), args.count > i + 2,
              UUID(uuidString: args[i + 1]) != nil else { result = "Invalid fixture"; return }
        let mode = args[i + 2]
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("legacy-save-tests/\(args[i + 1])")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let p = PersistenceStore(directory: root)
            let scope = LegacySpraySaveRecovery.Scope(actor: Self.actor, session: Self.session, vineyard: Self.vineyard)
            let store = MigratedDataStore(persistence: p)
            store.selectedVineyardId = Self.vineyard; store.legacySprayScopeProvider = { scope }
            if mode == "rpcRecover" {
                store.reloadCurrentVineyardData()
                let journal = LegacySpraySaveRecovery(persistence: p)
                guard let original = try journal.attempts().first, let rpc = original.rpc, original.rpcClaimed,
                      try journal.contains(trip: original.trip.id) else { result = "RPC evidence missing"; return }
                let response = try JSONSerialization.data(withJSONObject: ["version": 1, "status": "accepted",
                    "operation_id": rpc.operation.uuidString.lowercased(), "vineyard_id": Self.vineyard.uuidString.lowercased(),
                    "trip_id": original.trip.id.uuidString.lowercased(), "spray_record_id": original.record.id.uuidString.lowercased(),
                    "request_sha256": String(repeating: "a", count: 64), "committed_at": "2026-10-15T03:00:01Z"])
                try await journal.replay(scope: scope, isCurrent: { true }) { endpoint, body in
                    guard endpoint == "recover_legacy_spray_pair_v1", body == (try rpc.body()) else { throw LegacySprayPairReceipt.failure }
                    return response // Explicit synthetic transport, not authenticated backend acceptance.
                }
                guard try !journal.contains(trip: original.trip.id), try journal.attempts()[0].rpc == rpc,
                      store.deviceActiveTripId == nil else { result = "RPC recovery mismatch"; return }
                result = "Recovered exact RPC request after termination; synthetic receipt only"
            } else if mode == "recover" {
                store.reloadCurrentVineyardData()
                try store.reconcileLegacySpraySaves()
                let original = try LegacySpraySaveRecovery(persistence: p).attempts().first
                guard let original, store.trips.count == 1, store.sprayRecords.count == 1,
                      try LegacySpraySaveRecovery.sameProjection(store.trips[0], original.trip),
                      try LegacySpraySaveRecovery.sameProjection(store.sprayRecords[0], original.record),
                      store.deviceActiveTripId == nil else { result = "Recovery mismatch"; return }
                result = "Recovered exact original pair; no active tracking"
            } else if mode == "cleanup" {
                try FileManager.default.removeItem(at: root)
                result = "Cleaned isolated fixture"
            } else {
                let trip = Trip(vineyardId: Self.vineyard, paddockName: "Original frozen route", isActive: false)
                let record = SprayRecord(tripId: trip.id, vineyardId: Self.vineyard, notes: "Original frozen recipe")
                var journalWrites = 0
                p.durableSaveFailureForTesting = { key in
                    if key == LegacySpraySaveRecovery.key { journalWrites += 1 }
                    let fail = (mode == "prepared" && key == SprayRepository.recordsKey) ||
                        (mode == "recipe" && key == TripRepository.storageKey) ||
                        (mode == "trip" && key == LegacySpraySaveRecovery.key && journalWrites == 2)
                    return fail ? SprayTankActualValidationError.localSaveFailed : nil
                }
                do { try store.saveSprayForLater(record: record, trip: trip) }
                catch { }
                guard (try LegacySpraySaveRecovery(persistence: p).attempts()).count == 1 else { result = "Intent missing"; return }
                if mode == "rpcLost" {
                    let journal = LegacySpraySaveRecovery(persistence: p)
                    do { try await journal.replay(scope: scope, isCurrent: { true }) { _, _ in throw URLError(.timedOut) } } catch { }
                    guard try journal.attempts()[0].rpcClaimed, try journal.contains(trip: trip.id) else { result = "RPC claim missing"; return }
                }
                result = "Original intent retained at \(mode)"
            }
        } catch { result = "Fixture failed safely" }
    }
}
#endif
