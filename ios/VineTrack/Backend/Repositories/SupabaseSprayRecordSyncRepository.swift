import Foundation
import Supabase

/// Structural evidence for linking an existing unlinked server spray to its
/// EXACT saved occurrence trip. No matching by names or area alone.
nonisolated enum VerifiedOrphanSprayRecovery {
    struct Evidence: Sendable {
        let vineyardId: UUID
        let tripId: UUID?
        let createdBy: UUID?
        let startTime: Date?
        let date: Date?
        let blockIds: Set<UUID>
        let tankCount: Int
        let tanksValid: Bool
        let isTemplate: Bool
        let endTime: Date?
        let deletedAt: Date?
    }

    static func evidence(_ record: BackendSprayRecord) -> Evidence {
        Evidence(
            vineyardId: record.vineyardId,
            tripId: record.tripId,
            createdBy: record.createdBy,
            startTime: record.startTime,
            date: record.date,
            blockIds: Set(record.blockIds ?? []),
            tankCount: record.tanks?.count ?? 0,
            // Identification needs a real frozen tank mix, not a verdict on
            // chemical label compliance. Full start admission rechecks rates
            // AFTER the user reviews the recovered original details.
            tanksValid: record.tanks.map { tanks in
                !tanks.isEmpty && tanks.allSatisfy {
                    $0.waterVolume.isFinite && $0.waterVolume > 0 && !$0.chemicals.isEmpty
                }
            } ?? false,
            isTemplate: record.isTemplate ?? false,
            endTime: record.endTime,
            deletedAt: record.deletedAt
        )
    }

    static func matches(_ candidate: Evidence, original: Trip, actorId: UUID) -> Bool {
        guard original.coverageBasis == .occurrence,
              original.tripFunction == TripFunction.spraying.rawValue,
              !original.rowSequence.isEmpty,
              let document = TripOccurrenceCoverage.read(original.occurrenceCoverage),
              document.activeOrder.count == original.rowSequence.count,
              document.count("done") == 0, document.count("skipped") == 0,
              candidate.tripId == nil, candidate.createdBy == actorId,
              candidate.vineyardId == original.vineyardId,
              !candidate.isTemplate, candidate.endTime == nil, candidate.deletedAt == nil,
              candidate.tankCount > 0, candidate.tanksValid,
              (original.totalTanks == 0 || candidate.tankCount == original.totalTanks),
              let started = candidate.startTime,
              abs(started.timeIntervalSince(original.startTime)) <= 60,
              candidate.date.map({ abs($0.timeIntervalSince(started)) <= 60 }) ?? true else {
            return false
        }
        let occurrenceBlocks = Set(document.items.compactMap { UUID(uuidString: $0.blockId) })
        let tripBlocks = Set(original.paddockIds + (original.paddockId.map { [$0] } ?? []))
        return !occurrenceBlocks.isEmpty
            && occurrenceBlocks == tripBlocks
            && candidate.blockIds == occurrenceBlocks
    }

    static func unique(_ candidates: [BackendSprayRecord], original: Trip, actorId: UUID) -> BackendSprayRecord? {
        let matched = candidates.filter { matches(evidence($0), original: original, actorId: actorId) }
        return matched.count == 1 ? matched[0] : nil
    }
}

final class SupabaseSprayRecordSyncRepository: SprayRecordSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("spray_records")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
        if let since {
            return try await query
                .gte("updated_at", value: ISO8601DateFormatter().string(from: since))
                .order("updated_at", ascending: true)
                .execute()
                .value
        } else {
            return try await query
                .order("updated_at", ascending: true)
                .execute()
                .value
        }
    }

    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord] {
        try await fetchSprayRecords(vineyardId: vineyardId, since: nil)
    }

    /// Read-only recovery search; capped, vineyard/actor scoped and limited to
    /// the saved trip's original minute. A full or ambiguous result fails closed.
    func fetchQueuedOrphanCandidates(
        vineyardId: UUID, createdBy actorId: UUID, originalStart: Date
    ) async throws -> [BackendSprayRecord] {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard provider.client.auth.currentUser?.id == actorId else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        let start = originalStart.addingTimeInterval(-60).ISO8601Format(.init(includingFractionalSeconds: true))
        let end = originalStart.addingTimeInterval(60).ISO8601Format(.init(includingFractionalSeconds: true))
        let rows: [BackendSprayRecord] = try await provider.client.from("spray_records")
            .select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("created_by", value: actorId.uuidString)
            .is("trip_id", value: nil)
            .is("deleted_at", value: nil)
            .eq("is_template", value: false)
            .gte("start_time", value: start)
            .lte("start_time", value: end)
            .limit(25)
            .execute().value
        guard provider.client.auth.currentUser?.id == actorId else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        guard rows.count < 25 else { throw TripOccurrenceCoverage.Failure.reconciliation }
        return rows
    }

    /// The trip creation/activation RPC must already have accepted the original
    /// parent. Ordinary spray form upserts intentionally cannot change trip_id.
    /// This single-column CAS is the only repair for an exact orphan link.
    /// Zero remote rows is valid for a genuinely new spray (its normal sync is
    /// still pending), but NEVER for a recipe recovered from a server orphan.
    func linkVerifiedOrphanAfterParentAcceptance(
        local: SprayRecord, originalTrip: Trip, actorId: UUID
    ) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard provider.client.auth.currentUser?.id == actorId else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        guard local.canonicalTripId == originalTrip.id,
              local.vineyardId == originalTrip.vineyardId else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: originalTrip.vineyardId.uuidString)
        let existing: [BackendSprayRecord] = try await provider.client.from("spray_records")
            .select()
            .eq("id", value: local.id.uuidString)
            .eq("vineyard_id", value: originalTrip.vineyardId.uuidString)
            .limit(2)
            .execute().value
        guard provider.client.auth.currentUser?.id == actorId else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        if existing.isEmpty && !local.recoveredFromServerOrphan {
            // A newly created spray has not been uploaded yet. But a saved job
            // from earlier today may already have an unlinked ORIGINAL server
            // recipe under a different ID. Never manufacture a duplicate.
            if Date().timeIntervalSince(originalTrip.startTime) > 300 {
                let candidates = try await fetchQueuedOrphanCandidates(
                    vineyardId: originalTrip.vineyardId,
                    createdBy: actorId, originalStart: originalTrip.startTime
                )
                guard !candidates.contains(where: {
                    VerifiedOrphanSprayRecovery.matches(
                        VerifiedOrphanSprayRecovery.evidence($0),
                        original: originalTrip, actorId: actorId
                    )
                }) else {
                    throw TripOccurrenceCoverage.Failure.reconciliation
                }
            }
            return
        }
        guard existing.count == 1, let remote = existing.first,
              remote.createdBy == actorId,
              remote.tanks == local.tanks,
              remote.deletedAt == nil, remote.endTime == nil else {
            throw TripOccurrenceCoverage.Failure.reconciliation
        }
        if remote.tripId == originalTrip.id { return } // idempotent already-linked receipt
        guard VerifiedOrphanSprayRecovery.matches(
            VerifiedOrphanSprayRecovery.evidence(remote), original: originalTrip, actorId: actorId
        ), let version = remote.syncVersion else {
            throw TripOccurrenceCoverage.Failure.reconciliation
        }
        let update: [BackendSprayRecord] = try await provider.client.from("spray_records")
            .update(["trip_id": originalTrip.id.uuidString.lowercased()])
            .eq("id", value: local.id.uuidString)
            .eq("vineyard_id", value: originalTrip.vineyardId.uuidString)
            .eq("created_by", value: actorId.uuidString)
            .eq("sync_version", value: version)
            .is("trip_id", value: nil)
            .select()
            .execute().value
        guard provider.client.auth.currentUser?.id == actorId else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        if update.count == 1, update[0].tripId == originalTrip.id,
           update[0].tanks == local.tanks { return }
        // Another writer might have installed the same link meanwhile; accept
        // only the identical confirmed result. No overwrite or second attempt.
        let reread: [BackendSprayRecord] = try await provider.client.from("spray_records")
            .select()
            .eq("id", value: local.id.uuidString)
            .eq("vineyard_id", value: originalTrip.vineyardId.uuidString)
            .limit(2)
            .execute().value
        guard reread.count == 1, reread[0].tripId == originalTrip.id,
              reread[0].tanks == local.tanks, reread[0].createdBy == actorId else {
            throw TripOccurrenceCoverage.Failure.reconciliation
        }
    }

    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws {
        if let blocker = record.operationalPlanningBlocker { throw SprayPlanningAdmissionError(message: blocker) }
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let existing: [BackendSprayRecord] = try await provider.client.from("spray_records")
            .select().eq("id", value: record.id.uuidString).execute().value
        if let server = existing.first {
            // Never regress server completion, including confirmation between
            // this read and the write. Keep every unrelated queued form field.
            let fields = try Self.editableFieldsPreservingCompletion(record)
            if server.endTime == nil, let end = record.endTime {
                var completingFields = fields
                completingFields["end_time"] = .string(end.ISO8601Format(.init(includingFractionalSeconds: true)))
                let updated: [BackendSprayRecord] = try await provider.client.from("spray_records")
                    .update(completingFields).eq("id", value: record.id.uuidString)
                    .is("end_time", value: nil).select().execute().value
                if updated.count == 1 { return }
                // A concurrent server completion won: replay only form edits.
            }
            let updated: [BackendSprayRecord] = try await provider.client.from("spray_records")
                .update(fields).eq("id", value: record.id.uuidString).select().execute().value
            guard updated.count == 1 else { throw BackendRepositoryError.emptyResponse }
        } else {
            try await provider.client.from("spray_records").upsert(record, onConflict: "id").execute()
        }
    }

    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !records.isEmpty else { return }
        for record in records { try await upsertSprayRecord(record) }
    }

    nonisolated static func editableFieldsPreservingCompletion(_ record: BackendSprayRecordUpsert) throws -> [String: SprayReportPayloadV1.JSONValue] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.ISO8601Format(.init(includingFractionalSeconds: true)))
        }
        var fields = try JSONDecoder().decode([String: SprayReportPayloadV1.JSONValue].self, from: encoder.encode(record))
        // Ordinary edits cannot relink a spray or write a UUID from an older local cache.
        fields.removeValue(forKey: "trip_id")
        fields.removeValue(forKey: "end_time")
        fields.removeValue(forKey: "created_by")
        return fields
    }

    func softDeleteSprayRecord(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        try await provider.client
            .rpc("soft_delete_spray_record", params: SoftDeleteSprayRecordRequest(sprayRecordId: id))
            .execute()
    }
}

nonisolated private struct SoftDeleteSprayRecordRequest: Encodable, Sendable {
    let sprayRecordId: UUID

    enum CodingKeys: String, CodingKey {
        case sprayRecordId = "p_spray_record_id"
    }
}
