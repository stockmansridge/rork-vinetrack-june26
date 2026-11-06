import Foundation
import Supabase

/// Owner-reviewed repairs for two kinds of leftover that the deleted-Trip
/// reconciliation cannot reach, because there is no server Trip to tombstone:
///
/// 1. A queued Trip that never reached the server. The phone no longer holds
///    the Trip itself, only its queue entry and scoped evidence (occurrence
///    journal and/or first-tank handoff) for this exact account and vineyard.
/// 2. A Spray Record recovered from a server orphan whose original Trip never
///    reached the server, so its "link to the original Trip" can never succeed.
///
/// Both repairs: verify scope locally, verify absence/state with authenticated
/// server reads, refuse whenever real work (tank Actual Use, completion
/// intents, another account's evidence, a live server Trip) is attached, write
/// a complete local evidence archive and read it back BEFORE retiring anything,
/// and retire only the exact queue entries for that one ID. Nothing is invented,
/// re-uploaded or restored.
@MainActor
enum GuidedNeverUploadedRepair {
    struct Refused: LocalizedError {
        let explanation: String
        var errorDescription: String? { explanation }
    }

    nonisolated private struct ServerIdRow: Decodable, Sendable {
        let id: UUID
        let vineyard_id: UUID?
        let deleted_at: String?
    }

    nonisolated struct NeverCreatedTripArchive: Codable, Sendable {
        let tripId: UUID
        let owner: UUID
        let vineyard: UUID
        let reason: String
        let archivedAt: Date
        let occurrenceJournal: Data?
        let initialMixDrafts: [SprayInitialTankDraft]
        let queuedUpload: Bool
        let queuedUploadFailed: Bool
        let linkedSprayIdsCheckedOnServer: [UUID]
        let serverTripRowsVisible: Int
        /// Encoded never-accepted paired Save-for-Later attempts for this Trip.
        var legacySpraySaveAttempts: Data? = nil
    }

    nonisolated struct UnlinkedSprayArchive: Codable, Sendable {
        let sprayRecord: SprayRecord
        let missingParentTripId: UUID?
        let owner: UUID
        let vineyard: UUID
        let reason: String
        let archivedAt: Date
        let queuedUpload: Bool
        let queuedDelete: Bool
        let serverRowWasLive: Bool
    }

    static func tripArchiveKey(_ tripId: UUID) -> String {
        "guided_never_created_trip_archive_v1_" + tripId.uuidString.lowercased()
    }
    static func sprayArchiveKey(_ recordId: UUID) -> String {
        "guided_unlinked_spray_archive_v1_" + recordId.uuidString.lowercased()
    }

    // MARK: - Local eligibility (pure reads; used to offer the option)

    /// Scoped local evidence that this queued Trip ID belongs to this account
    /// and vineyard although no Trip snapshot exists on the phone.
    static func neverCreatedTripLocalEvidence(
        tripId: UUID, vineyard: UUID, owner: UUID, store: MigratedDataStore
    ) -> Bool {
        guard !(store.trips + store.tripRepo.loadAll()).contains(where: { $0.id == tripId }) else { return false }
        // A deletion recorded on this phone for this exact account/vineyard is
        // itself scoped evidence (the Trip was deleted before it ever uploaded).
        if let intent = try? store.tripDeletionJournal.load().intents[tripId] {
            return intent.acknowledgement == nil && intent.scope?.account == owner &&
                intent.scope?.vineyard == vineyard && intent.scope?.trip == tripId
        }
        let drafts = SprayTankActualStore.shared.initialMixDrafts.filter { $0.tripId == tripId }
        if !drafts.isEmpty {
            return drafts.allSatisfy { $0.ownerId == owner && $0.vineyardId == vineyard }
        }
        return (try? journalScopeMatches(tripId: tripId, vineyard: vineyard, owner: owner)) == true
    }

    /// A recovered orphan Spray whose original Trip is absent from this phone.
    static func unlinkedSprayLocalEvidence(
        recordId: UUID, vineyard: UUID, store: MigratedDataStore
    ) -> Bool {
        guard let record = store.sprayRecords.first(where: { $0.id == recordId && $0.vineyardId == vineyard }),
              record.pendingOrphanLink else { return false }
        guard let parent = record.canonicalTripId else { return true }
        return !(store.trips + store.tripRepo.loadAll()).contains(where: { $0.id == parent })
    }

    /// nil = no journal; true = journal for this exact owner/vineyard/trip; throws on a foreign/unreadable journal.
    private static func journalScopeMatches(tripId: UUID, vineyard: UUID, owner: UUID) throws -> Bool? {
        guard let url = try LiveTripCancellationLocal.journalURL(tripId: tripId.uuidString.lowercased()) else { return nil }
        let snapshot = try JSONDecoder().decode(TripOccurrenceJournal.Snapshot.self, from: Data(contentsOf: url))
        return snapshot.scope.ownerId == owner.uuidString.lowercased()
            && snapshot.scope.vineyardId == vineyard.uuidString.lowercased()
            && snapshot.scope.tripId == tripId.uuidString.lowercased()
    }

    // MARK: - Shared guards

    private static func requireContext(owner: UUID, vineyard: UUID, store: MigratedDataStore,
                                       tripSync: TripSyncService, spraySync: SprayRecordSyncService) throws {
        try Task.checkCancellation()
        guard store.currentUserIdProvider?() == owner,
              store.selectedVineyardId == vineyard,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
              !tripSync.isSyncing, !spraySync.isSyncing else {
            throw Refused(explanation: "The account, vineyard or sync state changed. Nothing was changed.")
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyard.uuidString)
    }

    /// Every Trip row with this ID visible to the signed-in account (any vineyard).
    private static func visibleServerTrips(_ tripId: UUID) async throws -> [ServerIdRow] {
        try await SupabaseClientProvider.shared.client.from("trips")
            .select("id,vineyard_id,deleted_at")
            .eq("id", value: tripId.uuidString.lowercased())
            .execute().value
    }

    private static func visibleServerSprays(_ ids: [UUID]) async throws -> [ServerIdRow] {
        guard !ids.isEmpty else { return [] }
        return try await SupabaseClientProvider.shared.client.from("spray_records")
            .select("id,vineyard_id,deleted_at")
            .in("id", values: ids.map { $0.uuidString.lowercased() })
            .execute().value
    }

    /// Durable write, then an independent read-back that must decode and match
    /// the archived identity (stored dates are second-precision, so the whole
    /// value is not compared).
    private static func saveAndReadBack<T: Codable>(_ value: T, key: String, matches: (T) -> Bool) throws {
        try PersistenceStore.shared.saveOrThrow(value, key: key)
        let readback: PersistenceStore.LoadOutcome<T> = PersistenceStore.shared.loadOutcome(key: key)
        guard case .decoded(let saved) = readback, matches(saved) else {
            throw Refused(explanation: "The local evidence archive could not be verified. Nothing was retired.")
        }
    }

    // MARK: - Repair 1: queued Trip that never reached the server

    static func retireNeverCreatedTrip(
        tripId: UUID, vineyard: UUID, owner: UUID, reason: String,
        store: MigratedDataStore, tripSync: TripSyncService, spraySync: SprayRecordSyncService
    ) async throws -> String {
        guard let note = GuidedRepairFieldValidation.note(reason) else {
            throw Refused(explanation: "An evidence note (12–500 characters) is required. Nothing was changed.")
        }
        try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)

        guard !(store.trips + store.tripRepo.loadAll()).contains(where: { $0.id == tripId }) else {
            throw Refused(explanation: "A saved copy of this Trip exists on this phone. It must upload or be reviewed normally.")
        }
        let deletionIntent = try store.tripDeletionJournal.load().intents[tripId]
        guard tripSync.isPendingUpsert(tripId) || tripSync.isPendingDelete(tripId) || deletionIntent != nil else {
            throw Refused(explanation: "This Trip is not waiting to upload or delete. Nothing to retire.")
        }
        if let intent = deletionIntent {
            guard intent.acknowledgement == nil, intent.scope?.account == owner,
                  intent.scope?.vineyard == vineyard, intent.scope?.trip == tripId else {
                throw Refused(explanation: "The recorded deletion belongs to another account or vineyard, or is already confirmed. Nothing was changed.")
            }
        }
        if let open = try TripCancellationIntentStore.shared.find(tripId: tripId.uuidString.lowercased()), open.isOpen {
            throw Refused(explanation: "An original cancellation is still pending for this Trip. It must finish first.")
        }
        guard !SprayTankActualStore.shared.records.contains(where: { $0.tripId == tripId }) else {
            throw Refused(explanation: "Recorded tank Actual Use is linked to this Trip. It cannot be retired as never started.")
        }
        guard try !TrackedSprayCompletionSync.shared.intents().contains(where: { $0.tripId == tripId }) else {
            throw Refused(explanation: "A Spray completion is recorded for this Trip. It cannot be retired as never started.")
        }
        // A never-accepted paired Save for Later (Trip + Spray created together
        // on the server, atomically) is evidence to archive, not a blocker, once
        // the server proves the Trip absent and its Spray absent or deleted.
        let legacyRecovery = LegacySpraySaveRecovery(persistence: .shared)
        let legacyAttempts = try legacyRecovery.attempts(trip: tripId)
        guard legacyAttempts.allSatisfy({ $0.scope.actor == owner && $0.scope.vineyard == vineyard }) else {
            throw Refused(explanation: "An original spray save for this Trip belongs to another account or vineyard. Nothing was changed.")
        }
        guard !legacyAttempts.contains(where: { $0.verified?.status == "accepted" }) else {
            throw Refused(explanation: "The server accepted the original spray save for this Trip. It must be reconciled, not retired.")
        }
        let drafts = SprayTankActualStore.shared.initialMixDrafts.filter { $0.tripId == tripId }
        guard drafts.allSatisfy({ $0.ownerId == owner && $0.vineyardId == vineyard }) else {
            throw Refused(explanation: "Retained tank contents belong to another account or vineyard. Nothing was changed.")
        }
        let journalMatch = try journalScopeMatches(tripId: tripId, vineyard: vineyard, owner: owner)
        guard journalMatch != false else {
            throw Refused(explanation: "The saved Trip journal belongs to another account or vineyard. Nothing was changed.")
        }
        guard journalMatch == true || !drafts.isEmpty || deletionIntent != nil else {
            throw Refused(explanation: "No saved evidence ties this Trip to your account and this vineyard. Nothing was changed.")
        }

        // Authoritative reads: no Trip row with this ID is visible to this
        // account in any vineyard, and every linked Spray is absent or deleted.
        let serverTrips = try await visibleServerTrips(tripId)
        try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
        guard serverTrips.isEmpty else {
            throw Refused(explanation: serverTrips.contains(where: { $0.deleted_at != nil })
                ? "This Trip exists on the server as deleted. Use 'Reconcile deleted Trip and linked records' instead."
                : "This Trip exists on the server. It must upload or be reviewed normally.")
        }
        // For a recorded deletion, the server must also issue its authenticated
        // absence receipt (confirm_trip_absence_v1) for this exact account.
        var absenceEvidence: String?
        if let intent = deletionIntent, let scope = intent.scope {
            let evidence = try await SupabaseTripSyncRepository().reverifyDeletion(scope) {
                store.currentUserIdProvider?() == owner && store.selectedVineyardId == vineyard
            }
            guard evidence.hasPrefix("SERVER_ABSENCE_VERIFIED:") else {
                throw Refused(explanation: "The server did not confirm this Trip is absent. Nothing was changed.")
            }
            absenceEvidence = evidence
            try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
        }
        let linkedSprayIds = Array(Set(drafts.map(\.sprayRecordId) + legacyAttempts.map(\.record.id) +
            store.sprayRecords.filter { $0.canonicalTripId == tripId }.map(\.id)))
        let serverSprays = try await visibleServerSprays(linkedSprayIds)
        try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
        guard serverSprays.allSatisfy({ $0.deleted_at != nil }) else {
            throw Refused(explanation: "A linked Spray Record is still live on the server. Review or delete that Spray first.")
        }

        let journalData: Data? = try LiveTripCancellationLocal.journalURL(tripId: tripId.uuidString.lowercased())
            .map { try Data(contentsOf: $0) }
        let legacyData: Data? = try legacyAttempts.isEmpty ? nil : JSONEncoder().encode(legacyAttempts)
        let archive = NeverCreatedTripArchive(
            tripId: tripId, owner: owner, vineyard: vineyard, reason: note, archivedAt: Date(),
            occurrenceJournal: journalData, initialMixDrafts: drafts,
            queuedUpload: tripSync.isPendingUpsert(tripId), queuedUploadFailed: tripSync.isQueuedUploadMarkedFailed(tripId),
            linkedSprayIdsCheckedOnServer: linkedSprayIds.sorted { $0.uuidString < $1.uuidString },
            serverTripRowsVisible: serverTrips.count,
            legacySpraySaveAttempts: legacyData)
        try saveAndReadBack(archive, key: tripArchiveKey(tripId)) {
            $0.tripId == tripId && $0.owner == owner && $0.vineyard == vineyard &&
                $0.initialMixDrafts.count == drafts.count && $0.occurrenceJournal == journalData &&
                ($0.legacySpraySaveAttempts == nil) == legacyAttempts.isEmpty
        }

        // Retire only this ID's queue entry and handoff. The journal file is
        // kept (archived above) but marked held so it can never be replayed.
        try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
        if journalMatch == true {
            let journal = try TripOccurrenceJournal(scope: .init(
                ownerId: owner.uuidString.lowercased(),
                vineyardId: vineyard.uuidString.lowercased(),
                tripId: tripId.uuidString.lowercased()),
                createDirectoryIfMissing: false)
            if try journal.load()?.heldReason == nil { try journal.hold("RETIRED_NEVER_CREATED_REVIEWED") }
        }
        if let intent = deletionIntent, let evidence = absenceEvidence {
            try store.tripDeletionJournal.acknowledgeReviewedAbsence(
                intent, owner: owner, vineyard: vineyard, evidence: evidence)
        }
        if !legacyAttempts.isEmpty {
            try legacyRecovery.retireReviewedNeverCreated(trip: tripId, owner: owner, vineyard: vineyard)
        }
        try SprayTankActualStore.shared.removeInitialMixDrafts(tripId: tripId, vineyardId: vineyard)
        try tripSync.retireReviewedNeverCreatedTrip(tripId)
        return "Retired. This Trip never reached the server; its saved evidence is archived on this phone and it will no longer be queued."
    }

    // MARK: - Repair 2: recovered Spray Record whose original Trip never reached the server

    static func discardUnlinkedSpray(
        recordId: UUID, vineyard: UUID, owner: UUID, reason: String,
        store: MigratedDataStore, tripSync: TripSyncService, spraySync: SprayRecordSyncService
    ) async throws -> String {
        guard let note = GuidedRepairFieldValidation.note(reason) else {
            throw Refused(explanation: "An evidence note (12–500 characters) is required. Nothing was changed.")
        }
        try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
        guard let record = store.sprayRecords.first(where: { $0.id == recordId && $0.vineyardId == vineyard }),
              record.pendingOrphanLink else {
            throw Refused(explanation: "This Spray Record is not an unlinked recovered record in this vineyard.")
        }
        let parent = record.canonicalTripId
        if let parent, (store.trips + store.tripRepo.loadAll()).contains(where: { $0.id == parent }) {
            throw Refused(explanation: "Its original Trip is saved on this phone. Upload that Trip instead.")
        }
        guard try !store.isLegacySpraySyncHeld(record: recordId) else {
            throw Refused(explanation: "The original spray save is still held for its receipt.")
        }
        guard !SprayTankActualStore.shared.records.contains(where: {
            $0.sprayRecordId == recordId || (parent != nil && $0.tripId == parent)
        }) else {
            throw Refused(explanation: "Recorded tank Actual Use is linked to this Spray. It cannot be discarded.")
        }
        guard try !TrackedSprayCompletionSync.shared.intents().contains(where: {
            $0.sprayRecordId == recordId || (parent != nil && $0.tripId == parent)
        }) else {
            throw Refused(explanation: "A Spray completion is recorded for this Spray. It cannot be discarded.")
        }

        // Authoritative reads: the original Trip is not visible anywhere for
        // this account, and the Spray row (if any) belongs to this vineyard.
        if let parent {
            let trips = try await visibleServerTrips(parent)
            try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
            guard trips.isEmpty else {
                throw Refused(explanation: "Its original Trip exists on the server. Sync normally to link it.")
            }
        }
        let rows = try await visibleServerSprays([recordId])
        try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
        guard rows.allSatisfy({ $0.vineyard_id == vineyard }) else {
            throw Refused(explanation: "The server Spray Record belongs to a different vineyard. Nothing was changed.")
        }
        let serverLive = rows.contains { $0.deleted_at == nil }

        let archive = UnlinkedSprayArchive(
            sprayRecord: record, missingParentTripId: parent, owner: owner, vineyard: vineyard,
            reason: note, archivedAt: Date(),
            queuedUpload: spraySync.isPendingUpsert(recordId),
            queuedDelete: spraySync.isPendingDelete(recordId),
            serverRowWasLive: serverLive)
        try saveAndReadBack(archive, key: sprayArchiveKey(recordId)) {
            $0.sprayRecord.id == recordId && $0.owner == owner && $0.vineyard == vineyard
        }

        if serverLive {
            try await SupabaseSprayRecordSyncRepository().softDeleteSprayRecord(id: recordId)
            let after = try await visibleServerSprays([recordId])
            guard after.allSatisfy({ $0.deleted_at != nil }) else {
                throw Refused(explanation: "The server did not confirm the Spray Record deletion. The local record is kept.")
            }
        }
        try requireContext(owner: owner, vineyard: vineyard, store: store, tripSync: tripSync, spraySync: spraySync)
        try store.retireReviewedUnlinkedSpray(record)
        spraySync.retireReviewedQueue(recordId)
        return serverLive
            ? "Discarded. The Spray Record is deleted on the server, archived on this phone and no longer queued."
            : "Discarded. The Spray Record was not live on the server; it is archived on this phone and no longer queued."
    }
}
