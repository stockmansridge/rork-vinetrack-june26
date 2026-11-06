import Foundation
import Supabase

/// An exceptional, owner-reviewed repair for an OLD unscoped legacy queue ID
/// whose exact Trip is independently confirmed soft-deleted on the selected
/// vineyard's server. This is distinct from an ordinary "delete" action:
/// it may NEVER undelete, reopen, finalise, mint replacement IDs, or assume
/// that absence of a local snapshot means a successful upload.
@MainActor
enum GuidedLegacyDeletedTripRepair {
    struct Refused: LocalizedError {
        let explanation: String
        var errorDescription: String? { explanation }
    }
    private struct OriginalArchive: Codable {
        let operationId: UUID
        let owner: UUID
        let vineyard: UUID
        let tripId: UUID
        let retainedTrip: Trip?
        let linkedSprays: [SprayRecord]
        let retainedActuals: [SprayTankActual]
        var retainedInitialMixDrafts: [SprayInitialTankDraft]? = nil
        var clientEvidence: TripActivityCancellation.JSON? = nil
        let originalOccurrenceJournal: Data?
        let originalDeletionIntent: TripDeletionJournal.Intent?
        let originalSprayCompletionIntents: [TrackedSprayCompletionSync.Intent]
        let queuedTripUpload: Bool
        let queuedTripDelete: Bool
        let archivedAt: Date
        let operatorClassification: String
        let operatorReason: String
        let recordedActualsNotAppliedAttested: Bool
    }
    private struct Request: Encodable, Sendable {
        let p_operation_id: UUID
        let p_trip_id: UUID
        let p_vineyard_id: UUID
        let p_application: String
        let p_attestation: String
        let p_client_evidence: TripActivityCancellation.JSON
    }

    /// Independently re-read the exact pre-repair local evidence archive.
    /// Only the operation that created this archive may retire its queued ID.
    static func archiveConfirmed(operationId: UUID, tripId: UUID,
                                 vineyard: UUID, owner: UUID) -> Bool {
        let key = "guided_legacy_trip_review_archive_v1_" +
            operationId.uuidString.lowercased()
        let outcome: PersistenceStore.LoadOutcome<OriginalArchive> =
            PersistenceStore.shared.loadOutcome(key: key)
        guard case .decoded(let saved) = outcome,
              saved.operationId == operationId, saved.tripId == tripId,
              saved.vineyard == vineyard, saved.owner == owner,
              !saved.operatorReason.isEmpty else { return false }
        return true
    }

    /// Archives persist dates as whole-second ISO8601, while live records
    /// (for example Actual Use merged from the server) keep fractional
    /// seconds, so plain equality never matched and every reconcile was
    /// refused. Compare at the precision the archive actually stores.
    private static func atStoredPrecision<T: Encodable>(_ values: [T]) throws -> Set<Data> {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return Set(try values.map { try encoder.encode($0) })
    }

    static func reconcile(
        tripId: UUID, vineyard: UUID, owner: UUID,
        applied: Bool, reason: String, operationId: UUID,
        confirmedRecordedActualsNotApplied: Bool,
        store: MigratedDataStore, tripSync: TripSyncService,
        spraySync: SprayRecordSyncService
    ) async throws -> String {
        guard GuidedRepairFieldValidation.note(reason) != nil,
              store.currentUserIdProvider?() == owner,
              store.selectedVineyardId == vineyard,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
              !tripSync.isSyncing, !spraySync.isSyncing else {
            throw Refused(explanation: "An authorised original-vineyard review and evidence note are required. Nothing was changed.")
        }
        func requireContext() throws {
            try Task.checkCancellation()
            guard store.currentUserIdProvider?() == owner,
                  store.selectedVineyardId == vineyard,
                  SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
                  !tripSync.isSyncing, !spraySync.isSyncing else {
                throw Refused(explanation: "The original account/vineyard or sync state changed. Original evidence remains retained.")
            }
            try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyard.uuidString)
        }
        try requireContext()

        // A same-ID local Trip belonging to a different vineyard/account
        // is never relocated or retired merely because a selected-vineyard
        // server tombstone happens to be visible.
        let local = store.tripRepo.loadAll().filter { $0.id == tripId }
        guard local.allSatisfy({ $0.vineyardId == vineyard }) else {
            throw Refused(explanation: "A different locally cached vineyard owns this Trip ID. Its queue is protected.")
        }
        let existingIntent = try TripCancellationIntentStore.shared.find(
            tripId: tripId.uuidString.lowercased())
        if let intent = existingIntent, intent.isOpen {
            guard intent.ownerId == owner.uuidString.lowercased(),
                  intent.vineyardId == vineyard.uuidString.lowercased(),
                  intent.classification == (applied ? "applied" : "not_applied"),
                  intent.operationId == operationId.uuidString.lowercased() else {
                throw Refused(explanation: "An original cancellation is already pending with another owner, classification or operation ID. It cannot be replaced.")
            }
            // Replay exactly the recorded original cancellation UUID against
            // the already-deleted Trip; the reviewed RPC will archive evidence
            // without resurrecting the Trip or minting a replacement.
        }
        let journalIntent = try store.tripDeletionJournal.load().intents[tripId]
        if let scope = journalIntent?.scope,
           (scope.account != owner || scope.vineyard != vineyard) {
            throw Refused(explanation: "The saved deletion belongs to a different account/vineyard. No action allowed.")
        }
        // An original occurrence journal from another account has priority.
        var rawJournal: Data?
        if let url = try LiveTripCancellationLocal.journalURL(tripId: tripId.uuidString.lowercased()) {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(TripOccurrenceJournal.Snapshot.self, from: data)
            guard snapshot.scope.ownerId == owner.uuidString.lowercased(),
                  snapshot.scope.vineyardId == vineyard.uuidString.lowercased(),
                  snapshot.scope.tripId == tripId.uuidString.lowercased() else {
                throw Refused(explanation: "The original Trip journal does not belong to the signed-in account/vineyard.")
            }
            rawJournal = data
        }
        let actuals = SprayTankActualStore.shared.records.filter {
            $0.tripId == tripId && $0.vineyardId == vineyard
        }
        guard actuals.allSatisfy({ $0.confirmedBy == owner }) else {
            throw Refused(explanation: "Retained Actual Use belongs to another original operator. Nothing was changed.")
        }
        if !applied && !actuals.isEmpty &&
           !confirmedRecordedActualsNotApplied {
            throw Refused(explanation: "Original tank contents were confirmed on this device. Attest explicitly that none were actually sprayed, or select Applied. All amounts remain archived.")
        }
        let sprouts = store.sprayRecords.filter {
            $0.vineyardId == vineyard && $0.canonicalTripId == tripId
        }
        let completionIntents = try TrackedSprayCompletionSync.shared.intents().filter {
            $0.tripId == tripId
        }
        guard completionIntents.allSatisfy({ $0.ownerId == owner && $0.vineyardId == vineyard }) else {
            throw Refused(explanation: "A linked Spray completion intent belongs to another original account.")
        }
        let drafts = SprayTankActualStore.shared.initialMixDrafts.filter {
            $0.tripId == tripId && $0.vineyardId == vineyard
        }
        guard drafts.allSatisfy({ $0.ownerId == owner }) else {
            throw Refused(explanation: "A retained first-tank handoff belongs to another account. Nothing was changed.")
        }
        let rawFacts = TripActivityCancellation.complianceFacts(
            tripId: tripId.uuidString.lowercased(),
            vineyardId: vineyard.uuidString.lowercased(), actuals: actuals)
        guard case .object(var contents) = rawFacts else {
            throw Refused(explanation: "Recorded original compliance facts could not be encoded.")
        }
        contents["confirmed_recorded_actuals_not_applied"] = .bool(!applied && confirmedRecordedActualsNotApplied)
        contents["retained_initial_mix_drafts"] = try JSONDecoder().decode(
            TripActivityCancellation.JSON.self, from: JSONEncoder().encode(drafts))
        var original = OriginalArchive(
            operationId: operationId, owner: owner, vineyard: vineyard, tripId: tripId,
            retainedTrip: local.first, linkedSprays: sprouts, retainedActuals: actuals,
            originalOccurrenceJournal: rawJournal,
            originalDeletionIntent: journalIntent,
            originalSprayCompletionIntents: completionIntents,
            queuedTripUpload: tripSync.isPendingUpsert(tripId),
            queuedTripDelete: tripSync.isPendingDelete(tripId),
            archivedAt: Date(),
            operatorClassification: applied ? "applied" : "not_applied",
            operatorReason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
            recordedActualsNotAppliedAttested:
                !applied && confirmedRecordedActualsNotApplied)
        original.retainedInitialMixDrafts = drafts
        original.clientEvidence = .object(contents)
        var frozen = original
        let key = "guided_legacy_trip_review_archive_v1_" + operationId.uuidString.lowercased()
        let existing: PersistenceStore.LoadOutcome<OriginalArchive> =
            PersistenceStore.shared.loadOutcome(key: key)
        switch existing {
        case .failed:
            throw Refused(explanation: "Original evidence archive is corrupt/unreadable. No server request was sent.")
        case .decoded(let saved):
            guard saved.owner == owner && saved.vineyard == vineyard &&
                  saved.tripId == tripId && saved.operationId == operationId &&
                  saved.operatorClassification == original.operatorClassification &&
                  saved.recordedActualsNotAppliedAttested ==
                    original.recordedActualsNotAppliedAttested else {
                throw Refused(explanation: "The original idempotent operation has different evidence. Review rather than replace it.")
            }
            frozen = saved
        case .missing:
            try PersistenceStore.shared.saveOrThrow(original, key: key)
        }

        let readback: PersistenceStore.LoadOutcome<OriginalArchive> = PersistenceStore.shared.loadOutcome(key: key)
        guard case .decoded(let savedArchive) = readback,
              savedArchive.clientEvidence == frozen.clientEvidence,
              Set(savedArchive.retainedInitialMixDrafts ?? []) == Set(frozen.retainedInitialMixDrafts ?? []),
              try atStoredPrecision(savedArchive.retainedActuals) == atStoredPrecision(frozen.retainedActuals),
              savedArchive.originalOccurrenceJournal == frozen.originalOccurrenceJournal,
              archiveConfirmed(operationId: operationId, tripId: tripId, vineyard: vineyard, owner: owner),
              let evidence = frozen.clientEvidence,
              Set(drafts).isSubset(of: Set(frozen.retainedInitialMixDrafts ?? [])),
              try atStoredPrecision(actuals).isSubset(of: atStoredPrecision(frozen.retainedActuals)) else {
            throw Refused(explanation: "Current original tank evidence is not fully present in the frozen archive. No request or cleanup is permitted.")
        }

        // Exact authenticated tombstone before any server write. A fresh,
        // differently-owned server Trip or a live Trip is never a candidate.
        let remote = try await SupabaseTripSyncRepository()
            .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard)
        guard let remote, remote.id == tripId, remote.vineyardId == vineyard,
              remote.deletedAt != nil, store.selectedVineyardId == vineyard,
              store.currentUserIdProvider?() == owner,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner else {
            throw Refused(explanation: "The exact original server tombstone was not verified. No repair was sent.")
        }
        try requireContext()
        let request = Request(
            p_operation_id: operationId, p_trip_id: tripId,
            p_vineyard_id: vineyard, p_application: applied ? "applied" : "not_applied",
            p_attestation: frozen.operatorReason, p_client_evidence: evidence)
        // Additive, owner/manager-only SQL 282. The RPC archives original server
        // and device facts first, marks linked records deleted, and emits a
        // durable cancellation receipt. It cannot resurrect a Trip.
        try await SupabaseClientProvider.shared.client
            .rpc("reconcile_deleted_trip_activity_v1", params: request).execute()

        try requireContext()
        let receipt = try await SupabaseTripCancellationRemote()
            .readReceipt(tripId: tripId.uuidString.lowercased(),
                         vineyardId: vineyard.uuidString.lowercased())
        try requireContext()
        guard let receipt,
              TripActivityCancellation.string(receipt, "operation_id") ==
                  operationId.uuidString.lowercased(),
              TripActivityCancellation.string(receipt, "trip_id") ==
                  tripId.uuidString.lowercased(),
              TripActivityCancellation.string(receipt, "vineyard_id") ==
                  vineyard.uuidString.lowercased(),
              TripActivityCancellation.string(receipt, "status") == "CANCELLED_ACKED",
              TripActivityCancellation.string(receipt, "application_classification") ==
                  (applied ? "applied" : "not_applied"),
              TripActivityCancellation.revision(receipt) != nil else {
            throw Refused(explanation: "The backend response was not matched to an independent exact cancellation receipt. Original queues remain unchanged.")
        }
        // A receipt's archive UUID is not proof that its original facts were retained.
        guard let archiveText = TripActivityCancellation.string(receipt, "compliance_archive_id"),
              let archiveId = UUID(uuidString: archiveText) else {
            throw Refused(explanation: "Cancellation has no compliance archive identity. Local evidence remains retained.")
        }
        struct ComplianceRow: Decodable {
            let id: UUID
            let operation_id: UUID
            let trip_id: UUID
            let vineyard_id: UUID
            let created_by: UUID
            let source: String
            let facts: TripActivityCancellation.JSON
        }
        let archives: [ComplianceRow] = try await SupabaseClientProvider.shared.client
            .from("trip_compliance_archive").select("id,operation_id,trip_id,vineyard_id,created_by,source,facts")
            .eq("id", value: archiveId.uuidString)
            .eq("operation_id", value: operationId.uuidString)
            .eq("trip_id", value: tripId.uuidString)
            .eq("vineyard_id", value: vineyard.uuidString).limit(1).execute().value
        try requireContext()
        guard archives.count == 1, let archived = archives.first,
              archived.id == archiveId, archived.operation_id == operationId,
              archived.trip_id == tripId, archived.vineyard_id == vineyard,
              archived.created_by == owner, archived.source == "reviewed_legacy_trip_deletion",
              case .object(let facts) = archived.facts,
              facts["client_original_evidence"] == evidence else {
            throw Refused(explanation: "Exact original compliance archive facts were not independently verified. No local queue was retired.")
        }
        let verifiedTrip = try await SupabaseTripSyncRepository()
            .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard)
        try requireContext()
        let liveSprays = try await SprayCompletionRepository().fetchLinked(tripId: tripId)
        try requireContext()
        struct Row: Decodable { let id: UUID }
        let liveActuals: [Row] = try await SupabaseClientProvider.shared.client
            .from("spray_tank_actuals").select("id")
            .eq("trip_id", value: tripId.uuidString)
            .eq("vineyard_id", value: vineyard.uuidString)
            .is("deleted_at", value: nil).limit(1).execute().value
        try requireContext()
        guard let verifiedTrip, verifiedTrip.deletedAt != nil,
              verifiedTrip.vineyardId == vineyard,
              liveSprays.isEmpty, liveActuals.isEmpty,
              store.selectedVineyardId == vineyard,
              store.currentUserIdProvider?() == owner,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner else {
            throw Refused(explanation: "A dependent Spray/Actual row is still active or scope changed. Nothing was retired from the device.")
        }

        let currentActuals = SprayTankActualStore.shared.records.filter {
            $0.tripId == tripId && $0.vineyardId == vineyard
        }
        let currentDrafts = SprayTankActualStore.shared.initialMixDrafts.filter {
            $0.tripId == tripId && $0.vineyardId == vineyard
        }
        var currentJournal: Data?
        if let url = try LiveTripCancellationLocal.journalURL(tripId: tripId.uuidString.lowercased()) {
            currentJournal = try Data(contentsOf: url)
        }
        let currentCompletionIntents = try TrackedSprayCompletionSync.shared.intents().filter { $0.tripId == tripId }
        guard currentActuals.allSatisfy({ $0.confirmedBy == owner }),
              try atStoredPrecision(currentActuals).isSubset(of: atStoredPrecision(frozen.retainedActuals)),
              currentDrafts.allSatisfy({ $0.ownerId == owner }),
              Set(currentDrafts).isSubset(of: Set(frozen.retainedInitialMixDrafts ?? [])),
              try atStoredPrecision(store.sprayRecords.filter { $0.canonicalTripId == tripId })
                .isSubset(of: atStoredPrecision(frozen.linkedSprays)),
              store.tripRepo.loadAll().filter({ $0.id == tripId }).allSatisfy({ $0 == frozen.retainedTrip }),
              currentJournal == nil || currentJournal == frozen.originalOccurrenceJournal,
              currentCompletionIntents.allSatisfy({ frozen.originalSprayCompletionIntents.contains($0) }),
              try store.tripDeletionJournal.load().intents[tripId] == frozen.originalDeletionIntent else {
            throw Refused(explanation: "Original Trip, tank, Spray or journal evidence changed after archival. No local cleanup is permitted.")
        }
        try GuidedRepairAuditLedger.shared.stage(
            id: operationId, account: owner, vineyard: vineyard,
            code: "SERVER_CANCEL_RECEIPT_AND_ARCHIVE_VERIFIED",
            explanation: "Original server tombstone, linked Spray/Actual deletion, compliance archive and operation receipt verified.")

        // Exactly this Trip's old queues. A second pass is safe/idempotent; a
        // crash after server success but before local ACK can replay the same
        // operation UUID, preserving the pre-repair archive.
        for spray in sprouts {
            if spraySync.isPendingUpsert(spray.id) {
                spraySync.clearCancelledTripRecordQueue(spray.id, delete: false)
            }
            if spraySync.isPendingDelete(spray.id) {
                spraySync.clearCancelledTripRecordQueue(spray.id, delete: true)
            }
        }
        for actual in actuals where SprayTankActualStore.shared.pendingIds.contains(actual.id) {
            try SprayTankActualStore.shared.removeLocal(id: actual.id)
        }
        // The original first-tank handoff was archived above. A confirmed
        // cancellation is the only other permitted retirement besides a
        // fully recorded tank/actual confirmation.
        if SprayTankActualStore.shared.initialMixDrafts.contains(where: {
            $0.tripId == tripId && $0.vineyardId == vineyard && $0.ownerId == owner
        }) {
            try SprayTankActualStore.shared.removeInitialMixDrafts(
                tripId: tripId, vineyardId: vineyard)
        }
        try TrackedSprayCompletionSync.shared.retireCancelled(
            tripId: tripId, ownerId: owner, vineyardId: vineyard,
            receiptOperationId: operationId)
        // The archive preserves the original occurrence journal before any
        // deletion. Do not remove it until its original scope is confirmed.
        if rawJournal != nil {
            let helper = LiveTripCancellationLocal(tripSync: tripSync, spraySync: spraySync)
            guard helper.removeJournal(
                ownerId: owner.uuidString.lowercased(),
                vineyardId: vineyard.uuidString.lowercased(),
                tripId: tripId.uuidString.lowercased()) else {
                throw Refused(explanation: "Server cancellation is verified, but original journal retirement failed. The evidence archive and retry record are retained.")
            }
        }
        // An earlier version may already hold an original cancellation
        // operation. Mark THAT exact durable ID cleaned after the independently
        // verified receipt; do not invent a second operation or turn it into
        // a Spray completion receipt.
        if let originalIntent = existingIntent, originalIntent.isOpen {
            var completed = originalIntent
            completed.receipt = receipt
            completed.state = .CLEANED
            completed.lastCode = "REVIEWED_LEGACY_SERVER_TOMBSTONE"
            guard TripCancellationIntentStore.shared.commit(completed) else {
                throw Refused(explanation: "The exact original cancellation state could not be saved locally. The old Trip queue remains for another review.")
            }
        }

        // Keep the Trip queue entry until every dependent local retirement
        // and durable evidence operation has finished. An interrupted cleanup
        // remains discoverable through this same original Trip ID.
        try tripSync.guidedRetireReviewedDeletedQueue(
            tripId: tripId, vineyardId: vineyard, ownerId: owner,
            operationId: operationId)
        try GuidedRepairAuditLedger.shared.stage(
            id: operationId, account: owner, vineyard: vineyard,
            code: "LOCAL_ORIGINAL_QUEUES_RETIRED",
            explanation: "Only the matching Trip, Spray, Actual and End intents were retired after a verified server cancellation archive.")
        return "Original deleted Trip and linked records reconciled with server cancellation receipt. Original compliance and local evidence were archived. No Trip was recreated."
    }
}
