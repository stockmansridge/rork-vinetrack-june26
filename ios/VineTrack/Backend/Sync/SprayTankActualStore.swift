import Foundation
import Observation
import Supabase

nonisolated private struct SprayTankActualCache: Codable, Sendable {
    var records: [SprayTankActual] = []
    var pendingIds: Set<UUID> = []
    // Optional so archives written before the Review actual-entry flow decode
    // unchanged. Every cache write preserves these exact activation handoffs.
    var initialMixDrafts: [SprayInitialTankDraft]? = nil
}

nonisolated private struct BackendSprayTankActual: Decodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let sprayRecordId: UUID
    let tripId: UUID
    let tankSessionId: String
    let tankNumber: Int
    let waterVolumeL: Double?
    let chemicals: [SprayTankActualChemical]
    let confirmedAt: Date
    let confirmedBy: UUID
    let clientUpdatedAt: Date
    let correctionVersion: Int?
    let lastCorrectedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, chemicals
        case vineyardId = "vineyard_id"
        case sprayRecordId = "spray_record_id"
        case tripId = "trip_id"
        case tankSessionId = "tank_session_id"
        case tankNumber = "tank_number"
        case waterVolumeL = "water_volume_l"
        case confirmedAt = "confirmed_at"
        case confirmedBy = "confirmed_by"
        case clientUpdatedAt = "client_updated_at"
        case correctionVersion = "correction_version"
        case lastCorrectedAt = "last_corrected_at"
    }

    func actual() throws -> SprayTankActual {
        try SprayTankActual(id: id, vineyardId: vineyardId, sprayRecordId: sprayRecordId,
            tripId: tripId, tankSessionId: tankSessionId, tankNumber: tankNumber,
            waterVolumeL: waterVolumeL, chemicals: chemicals, confirmedAt: confirmedAt,
            confirmedBy: confirmedBy, clientUpdatedAt: clientUpdatedAt,
            correctionVersion: correctionVersion, lastCorrectedAt: lastCorrectedAt)
    }
}

nonisolated struct SprayTankActualUpsertRequest: Encodable, Sendable {
    let actual: SprayTankActual

    enum CodingKeys: String, CodingKey {
        case id = "p_id", vineyardId = "p_vineyard_id", sprayRecordId = "p_spray_record_id"
        case tripId = "p_trip_id", tankSessionId = "p_tank_session_id", tankNumber = "p_tank_number"
        case waterVolumeL = "p_water_volume_l", chemicals = "p_chemicals"
        case confirmedAt = "p_confirmed_at", clientUpdatedAt = "p_client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actual.id, forKey: .id)
        try container.encode(actual.vineyardId, forKey: .vineyardId)
        try container.encode(actual.sprayRecordId, forKey: .sprayRecordId)
        try container.encode(actual.tripId, forKey: .tripId)
        try container.encode(actual.tankSessionId, forKey: .tankSessionId)
        try container.encode(actual.tankNumber, forKey: .tankNumber)
        // Required RPC argument; null means Not recorded, not an omitted parameter or zero.
        if let water = actual.waterVolumeL {
            try container.encode(water, forKey: .waterVolumeL)
        } else {
            try container.encodeNil(forKey: .waterVolumeL)
        }
        try container.encode(actual.chemicals, forKey: .chemicals)
        try container.encode(actual.confirmedAt, forKey: .confirmedAt)
        try container.encode(actual.clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

/// Durable local authority and retry queue for confirmed actual tank contents.
@Observable
@MainActor
final class SprayTankActualStore {
    static let shared = SprayTankActualStore()
    private static let persistenceKey = "vinetrack_spray_tank_actuals_v1"

    private(set) var records: [SprayTankActual]
    private(set) var pendingIds: Set<UUID>
    private(set) var initialMixDrafts: [SprayInitialTankDraft]
    private let persistence: PersistenceStore
    /// P0 3.1.9 Phase B: live Trip tank sessions (nil = Trip absent/deleted) and exact actual readback.
    var tankSessionReader: @MainActor (SprayTankActual) async throws -> Set<String>? = { try await SprayTankActualStore.liveTankSessionIds($0) }
    var actualReader: @MainActor (SprayTankActual) async throws -> SprayTankActual? = { try await SprayTankActualStore.liveReadBack($0) }
    /// Last fixed Phase B hold code per actual; diagnostics only, never quantities.
    private(set) var dependencyHolds: [UUID: String] = [:]

    convenience init() {
        self.init(persistence: .shared)
    }

    init(persistence: PersistenceStore) {
        self.persistence = persistence
        let cache: SprayTankActualCache? = persistence.load(key: Self.persistenceKey)
        records = cache?.records ?? []
        pendingIds = cache?.pendingIds ?? []
        initialMixDrafts = cache?.initialMixDrafts ?? []
    }

    func hasPending(tripId: UUID) -> Bool {
        records.contains { $0.tripId == tripId && pendingIds.contains($0.id) } ||
            initialMixDrafts.contains { $0.tripId == tripId }
    }

    /// Number of actual-use rows still queued for a trip. Used for finalisation
    /// diagnostics.
    func pendingCount(tripId: UUID) -> Int {
        records.filter { $0.tripId == tripId && pendingIds.contains($0.id) }.count +
            initialMixDrafts.filter { $0.tripId == tripId }.count
    }

    func actual(tripId: UUID, tankNumber: Int) -> SprayTankActual? {
        records.filter { $0.tripId == tripId && $0.tankNumber == tankNumber }
            .max { $0.clientUpdatedAt < $1.clientUpdatedAt }
    }

    func initialMix(tripId: UUID) -> SprayInitialTankDraft? {
        initialMixDrafts.first { $0.tripId == tripId }
    }

    /// Save operator input before async Trip activation. A retry can reuse the
    /// same evidence but cannot silently replace an uncertain first-tank mix.
    func stageInitialMix(_ draft: SprayInitialTankDraft) throws {
        guard draft.amounts.isValid(for: draft.tank) else { throw SprayInitialTankError.invalidAmounts }
        let retained = initialMixDrafts.filter { $0.tripId == draft.tripId }
        if !retained.isEmpty {
            guard retained.count == 1, retained.first?.matchesPersistedHandoff(draft) == true else { throw SprayInitialTankError.retainedMixConflict }
            return
        }
        let next = initialMixDrafts + [draft]
        try persistence.saveOrThrow(
            SprayTankActualCache(records: records, pendingIds: pendingIds, initialMixDrafts: next),
            key: Self.persistenceKey
        )
        initialMixDrafts = next
    }

    /// An upload, planned recipe or partial coordinator save cannot consume
    /// this draft. Require the corresponding actual and real Trip session.
    func clearInitialMix(_ draft: SprayInitialTankDraft, trip: Trip) throws {
        guard draft.isRecorded(in: records, trip: trip) else { throw SprayInitialTankError.actualNotRecorded }
        let retained = initialMixDrafts.filter { $0.tripId == draft.tripId }
        guard !retained.isEmpty else { return }
        guard retained.count == 1, retained.first?.matchesPersistedHandoff(draft) == true else { throw SprayInitialTankError.retainedMixConflict }
        let next = initialMixDrafts.filter { !$0.matchesPersistedHandoff(draft) }
        try persistence.saveOrThrow(
            SprayTankActualCache(records: records, pendingIds: pendingIds, initialMixDrafts: next),
            key: Self.persistenceKey
        )
        initialMixDrafts = next
    }

    /// Retry only the final local handoff acknowledgement after an interrupted Start.
    /// Never creates an actual, restarts a trip, or clears unmatched operator input.
    func reconcileRecordedInitialMixes(ownerId: UUID, vineyardId: UUID, trips: [Trip], sprays: [SprayRecord]) throws {
        for draft in initialMixDrafts where draft.ownerId == ownerId && draft.vineyardId == vineyardId {
            let matchingTrips = trips.filter { $0.id == draft.tripId && $0.vineyardId == vineyardId }
            let matchingSprays = sprays.filter {
                $0.id == draft.sprayRecordId && $0.tripId == draft.tripId && $0.vineyardId == vineyardId
            }
            guard matchingTrips.count == 1, let trip = matchingTrips.first,
                  matchingSprays.count == 1, let spray = matchingSprays.first,
                  SprayInitialTankAmounts.samePersistedRecipe(SprayInitialTankAmounts.firstTank(in: spray.tanks), draft.tank),
                  draft.isRecorded(in: records, trip: trip) else { continue }
            try clearInitialMix(draft, trip: trip)
        }
    }

    /// A response acknowledges the submitted revision, never a newer local edit.
    @discardableResult
    func acknowledgeUploaded(_ submitted: SprayTankActual) throws -> Bool {
        guard records.first(where: { $0.id == submitted.id }) == submitted else { return false }
        var pending = pendingIds
        pending.remove(submitted.id)
        try persistence.saveOrThrow(SprayTankActualCache(records: records, pendingIds: pending,
            initialMixDrafts: initialMixDrafts), key: Self.persistenceKey)
        pendingIds = pending
        SyncIssueCenter.shared.clearIssues([submitted.id])
        return true
    }

    /// Fixed stages/counts only. No recipe values, names, identifiers or server bodies.
    func pendingUploadDiagnostics(
        tripSync: TripSyncService?, spraySync: SprayRecordSyncService?, vineyardId: UUID?,
        ownerId: UUID? = nil, trips: [Trip] = [], sprays: [SprayRecord] = []
    ) -> String {
        guard let vineyardId else { return "VineTrack actual-use inspection v1\nACTUAL_USE_VINEYARD_NOT_SELECTED" }
        let queued = records.filter { $0.vineyardId == vineyardId && pendingIds.contains($0.id) }
        let drafts = initialMixDrafts.filter { $0.vineyardId == vineyardId }
        var reasons: [String: Int] = [:]
        var details: [String] = []
        for actual in queued {
            let decision = SprayTankActualUploadGate.decide(
                parentTripBlocked: tripSync?.inspectionParentPending(actual.tripId) ?? true,
                sprayRecordPending: spraySync?.isPendingUpsert(actual.sprayRecordId) ?? true)
            let reason = decision == .upload ? "ACTUAL_USE_READY_TO_UPLOAD" :
                (tripSync?.inspectionParentPending(actual.tripId) != false ? "ACTUAL_USE_WAITING_FOR_TRIP_PARENT" : "ACTUAL_USE_WAITING_FOR_SPRAY_RECORD")
            reasons[reason, default: 0] += 1
            if let ownerId, tripSync?.verifiedDiagnosticsOwner == ownerId, actual.confirmedBy == ownerId,
               trips.contains(where: { $0.id == actual.tripId && $0.vineyardId == vineyardId }) {
                details += ["actual_id: \(actual.id.uuidString.lowercased()); trip_id: \(actual.tripId.uuidString.lowercased()); spray_id: \(actual.sprayRecordId.uuidString.lowercased()); tank_session_id: \(UUID(uuidString: actual.tankSessionId)?.uuidString.lowercased() ?? "INVALID_ID_PROTECTED")",
                    "local_stage: queued; pending_reason: \(reason); account: original_confirmer_matches_correction_authority_not_inferred; vineyard: matches_selected",
                    "server_existence: unknown; server_ack: not_locally_acknowledged; retry: requires_original_authority_and_parents; last_attempted: unknown_not_persisted; last_acknowledged: unknown_not_persisted"]
            }
        }
        // Read-only triage of retained first-tank handoffs. A handoff is not
        // an actual-use record. These fixed codes reveal what proof is missing,
        // but never create a session, discard input or acknowledge a Trip.
        for draft in drafts {
            guard let ownerId else {
                reasons["HANDOFF_ACCOUNT_NOT_VERIFIED", default: 0] += 1
                continue
            }
            guard draft.ownerId == ownerId else {
                reasons["HANDOFF_OTHER_OWNER_PROTECTED", default: 0] += 1
                continue
            }
            if tripSync?.verifiedDiagnosticsOwner == ownerId {
                details.append("handoff_trip_id: \(draft.tripId.uuidString.lowercased()); spray_id: \(draft.sprayRecordId.uuidString.lowercased()); local_stage: retained_initial_mix; server_ack: unknown; retry: exact_original_session_and_amounts_required")
            }
            let matches = trips.filter { $0.id == draft.tripId && $0.vineyardId == vineyardId }
            guard matches.count == 1, let trip = matches.first else {
                reasons["HANDOFF_TRIP_SNAPSHOT_NOT_IN_SELECTED_SLICE", default: 0] += 1
                continue
            }
            let linked = sprays.filter {
                $0.id == draft.sprayRecordId && $0.tripId == draft.tripId && $0.vineyardId == vineyardId
            }
            guard linked.count == 1, let spray = linked.first else {
                reasons["HANDOFF_SPRAY_RECORD_NOT_IN_SELECTED_SLICE", default: 0] += 1
                continue
            }
            guard SprayInitialTankAmounts.samePersistedRecipe(
                SprayInitialTankAmounts.firstTank(in: spray.tanks), draft.tank
            ) else {
                reasons["HANDOFF_RECIPE_OR_IDENTITY_REVIEW_REQUIRED", default: 0] += 1
                continue
            }
            guard trip.tankSessions.filter({ $0.tankNumber == draft.tank.tankNumber }).count == 1 else {
                reasons["HANDOFF_REAL_TANK_SESSION_NOT_VERIFIED", default: 0] += 1
                continue
            }
            if draft.isRecorded(in: records, trip: trip) {
                reasons["HANDOFF_RECORDED_AWAITING_LOCAL_ACK", default: 0] += 1
            } else {
                reasons["HANDOFF_ACTUAL_AMOUNTS_NOT_VERIFIED", default: 0] += 1
            }
        }
        return (["VineTrack actual-use inspection v1", "pending_actual_rows: \(queued.count)",
                 "retained_initial_mix_handoffs: \(drafts.count)",
                 "Retained handoffs need an exact recorded tank session; retries never invent actual use."] +
            reasons.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" } +
            ["Counts distinguish actual rows from retained handoffs; a handoff and actual can share a Trip and are not two Trips."] + details).joined(separator: "\n")
    }

    /// Upserts by stable trip/session identity and durably queues before network activity.
    func saveLocally(_ actual: SprayTankActual) throws {
        var next = records
        if let index = next.firstIndex(where: { $0.tripId == actual.tripId && $0.tankSessionId == actual.tankSessionId }) {
            if next[index].clientUpdatedAt <= actual.clientUpdatedAt { next[index] = actual }
        } else {
            next.append(actual)
        }
        guard next.contains(where: { $0.id == actual.id }) else { return }
        var pending = Set(pendingIds.filter { id in next.contains(where: { $0.id == id }) })
        pending.insert(actual.id)
        try persistence.saveOrThrow(SprayTankActualCache(records: next, pendingIds: pending, initialMixDrafts: initialMixDrafts), key: Self.persistenceKey)
        records = next
        pendingIds = pending
    }

    /// P0 Phase A: removes only this Trip's initial-mix drafts, after a verified and durably
    /// acknowledged cancellation receipt (the evidence file already holds their content).
    func removeInitialMixDrafts(tripId: UUID, vineyardId: UUID) throws {
        let next = initialMixDrafts.filter { !($0.tripId == tripId && $0.vineyardId == vineyardId) }
        guard next.count != initialMixDrafts.count else { return }
        try persistence.saveOrThrow(SprayTankActualCache(records: records, pendingIds: pendingIds, initialMixDrafts: next), key: Self.persistenceKey)
        initialMixDrafts = next
    }

    func removeLocal(id: UUID) throws {
        let next = records.filter { $0.id != id }
        var pending = pendingIds
        pending.remove(id)
        try persistence.saveOrThrow(SprayTankActualCache(records: next, pendingIds: pending, initialMixDrafts: initialMixDrafts), key: Self.persistenceKey)
        records = next
        pendingIds = pending
    }

    /// Pulls permanent actual-use rows and merges by stable session identity; newer local confirmations win.
    func pull(vineyardId: UUID) async {
        guard SupabaseClientProvider.shared.isConfigured else { return }
        do {
            let rows: [BackendSprayTankActual] = try await SupabaseClientProvider.shared.client
                .from("spray_tank_actuals")
                .select()
                .eq("vineyard_id", value: vineyardId)
                .is("deleted_at", value: nil)
                .execute()
                .value
            var merged = records
            var pending = pendingIds
            for remote in try rows.map({ try $0.actual() }) {
                if let index = merged.firstIndex(where: { $0.tripId == remote.tripId && $0.tankSessionId == remote.tankSessionId }) {
                    let hasServerCorrection = (remote.correctionVersion ?? 0) > (merged[index].correctionVersion ?? 0)
                    if hasServerCorrection || (merged[index].clientUpdatedAt < remote.clientUpdatedAt && !pending.contains(merged[index].id)) {
                        pending.remove(merged[index].id)
                        merged[index] = remote
                    }
                } else {
                    merged.append(remote)
                }
            }
            try persistence.saveOrThrow(SprayTankActualCache(records: merged, pendingIds: pending, initialMixDrafts: initialMixDrafts), key: Self.persistenceKey)
            records = merged
            pendingIds = pending
        } catch {
            // Keep the durable local authority when offline or before migration deployment.
        }
    }

    static func liveTankSessionIds(_ actual: SprayTankActual) async throws -> Set<String>? {
        struct Row: Decodable { let tank_sessions: [TankSession]? }
        let rows: [Row] = try await SupabaseClientProvider.shared.client.from("trips")
            .select("tank_sessions")
            .eq("id", value: actual.tripId.uuidString)
            .eq("vineyard_id", value: actual.vineyardId.uuidString)
            .is("deleted_at", value: nil)
            .limit(2).execute().value
        guard rows.count <= 1 else { throw TankSessionReadbackUnsupported() }
        return rows.first.map { TankDependencyVerification.ids($0.tank_sessions ?? []) }
    }

    static func liveReadBack(_ actual: SprayTankActual) async throws -> SprayTankActual? {
        let rows: [BackendSprayTankActual] = try await SupabaseClientProvider.shared.client
            .from("spray_tank_actuals").select()
            .eq("id", value: actual.id.uuidString)
            .eq("vineyard_id", value: actual.vineyardId.uuidString)
            .is("deleted_at", value: nil)
            .limit(2).execute().value
        guard rows.count <= 1 else { return nil }
        return try rows.first?.actual()
    }

    /// Replays only after parent trip and spray-record sync have had an opportunity to run.
    func syncPending(tripSync: TripSyncService?, spraySync: SprayRecordSyncService?, vineyardId: UUID) async {
        defer {
            let count = records.filter { $0.vineyardId == vineyardId && pendingIds.contains($0.id) }.count
                + initialMixDrafts.filter { $0.vineyardId == vineyardId }.count
            SyncIssueCenter.shared.notePending(entity: "Tank actuals", count: count)
        }
        if tripSync?.isSyncing == true || spraySync?.isSyncing == true { return }
        guard SupabaseClientProvider.shared.isConfigured else { return }
        let queued = records
            .filter { pendingIds.contains($0.id) && $0.vineyardId == vineyardId }
            .sorted { $0.clientUpdatedAt < $1.clientUpdatedAt }
        for actual in queued {
            let id = actual.id
            // A trip queued ONLY because its final ended state is deferred must
            // not block its own actuals — that mutual wait was the Phase 5
            // deadlock (trip pending -> actual skipped -> gate never released).
            // Only a parent row that has never reached the server defers a child.
            let decision = SprayTankActualUploadGate.decide(
                parentTripBlocked: tripSync?.isPendingParentCreation(actual.tripId) ?? false,
                sprayRecordPending: spraySync?.isPendingUpsert(actual.sprayRecordId) ?? false
            )
            guard decision == .upload else {
                #if DEBUG
                print("[SprayTankActual] skipped \(id) for trip \(actual.tripId): \(decision.skipReason ?? "-")")
                #endif
                continue
            }
            do {
                // Phase B: the session this actual depends on must already be on the server Trip.
                let serverSessions = try await tankSessionReader(actual)
                guard let serverSessions,
                      serverSessions.contains(TankDependencyVerification.normalized(actual.tankSessionId)) else {
                    dependencyHolds[id] = TankDependencyVerification.actualSessionNotOnServer
                    continue
                }
                try await SupabaseClientProvider.shared.client
                    .rpc("upsert_spray_tank_actual", params: SprayTankActualUpsertRequest(actual: actual))
                    .execute()
                // Phase B: acknowledge only after the server returns the exact recorded evidence.
                guard TankDependencyVerification.actualMatches(local: actual, server: try await actualReader(actual)) else {
                    dependencyHolds[id] = TankDependencyVerification.actualReadbackMismatch
                    continue
                }
                dependencyHolds.removeValue(forKey: id)
                try acknowledgeUploaded(actual)
                // Releasing the Phase 5 gate is the caller's next stage: once
                // this trip has no pending actuals, `hasPending` returns false
                // and the queued final ended state uploads unchanged.
            } catch {
                // Preserve the pending record and expose the real child failure instead of
                // reporting only its parent Trip as waiting with failed_items = 0.
                let classified = BackendErrorDiagnostics.classify(error, endpoint: "upsert_spray_tank_actual")
                let safe = SyncFailureDetail(kind: classified.kind, reasonCode: classified.reasonCode,
                    friendlyMessage: classified.friendlyMessage,
                    technicalDetail: "endpoint: upsert_spray_tank_actual; code: \(classified.reasonCode); actual retained locally")
                SyncIssueCenter.shared.recordFailure(id: id, entity: "Tank actuals", detail: safe,
                    queuedAt: actual.clientUpdatedAt, payloadKeys: [], vineyardId: vineyardId)
            }
        }
    }
}
