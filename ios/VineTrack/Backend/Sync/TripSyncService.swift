import Foundation
import Observation
import Supabase

/// Local-first sync service for Trip records.
/// Tracks dirty/deleted trips locally and pushes/pulls them against Supabase
/// using `SupabaseTripSyncRepository`. Conflict resolution is last-write-wins
/// based on `client_updated_at`/`updated_at`.
@Observable
@MainActor
final class TripSyncService {

    enum Status: Equatable, Sendable {
        case idle
        case syncing
        case success
        case held(Int)
        case failure(String)
    }

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    /// Read-back freshness, never a queue upload acknowledgement.
    private(set) var lastSelectedVineyardDownloadAt: Date?
    var errorMessage: String?
    /// Per-Trip original-evidence hold after an exact server read. This is a
    /// transient explanation, not a receipt or authority to replay anything.
    private(set) var receiptReconciliationHolds: [UUID: String] = [:]
    /// Optional, explicit server inspection only. Not a sync receipt and never
    /// persisted as upload authority or mixed with the global queue totals.
    private(set) var lastTripServerReadbackV3: String?

    private func isHeld(_ id: UUID) -> Bool {
        guard let store else { return false }
        return (try? store.isLegacySpraySyncHeld(trip: id)) ?? true
    }
    var pendingUpsertCount: Int { metadata.pendingUpserts.keys.filter { !isHeld($0) }.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }
    /// Number of trips with a queued explicit `work_task_id = null` clear that
    /// has not yet been confirmed by the server.
    var pendingWorkTaskClearCount: Int { metadata.pendingWorkTaskClears.count }

    /// Whether a specific trip has local changes queued for upload.
    func isPendingUpsert(_ id: UUID) -> Bool { metadata.pendingUpserts[id] != nil }

    /// Whether the parent trip row is known to exist on the server (uploaded or
    /// pulled at least once). Deliberately separate from `isPendingUpsert`: a
    /// trip can be queued purely because its FINAL ended state is held back
    /// while its actual-use rows upload, and that must never block its own
    /// children.
    func isParentEstablished(_ id: UUID) -> Bool {
        !isHeld(id) && metadata.pendingDeletes[id] == nil &&
            (try? store?.tripDeletionJournal.isCancelled(id)) != true && metadata.isParentEstablished(id)
    }

    /// True only when the parent row has never reached the server. This is the
    /// one legitimate reason to defer a child upload.
    func isPendingParentCreation(_ id: UUID) -> Bool {
        TripCancellationIntentStore.shared.blocksReplay(tripId: id) ||
            metadata.pendingDeletes[id] != nil || (try? store?.tripDeletionJournal.isCancelled(id)) == true ||
            (metadata.pendingUpserts[id] != nil && !metadata.isParentEstablished(id))
    }

    /// True when the trip is queued ONLY because Phase 5 finalisation is held.
    func isPendingFinalisationOnly(_ id: UUID) -> Bool {
        metadata.pendingUpserts[id] != nil && metadata.isParentEstablished(id)
    }

    /// Lightweight, content-free finalisation diagnostics for recurrence checks.
    nonisolated struct FinalisationDiagnostic: Sendable, Equatable {
        let tripId: UUID
        let pendingActualCount: Int
        let isPhase5Held: Bool
        let parentEstablished: Bool
        let isPendingUpsert: Bool
        let isActive: Bool
        let hasEndTime: Bool

        var summary: String {
            "trip \(tripId) pendingActuals=\(pendingActualCount) held=\(isPhase5Held) parentOnServer=\(parentEstablished) queued=\(isPendingUpsert) active=\(isActive) endTime=\(hasEndTime)"
        }
    }

    /// Snapshot of the finalisation state for one trip.
    func finalisationDiagnostic(for id: UUID, pendingActualCount: Int) -> FinalisationDiagnostic {
        let trip = store?.trips.first { $0.id == id }
        return FinalisationDiagnostic(
            tripId: id,
            pendingActualCount: pendingActualCount,
            isPhase5Held: shouldDeferEndedTrip(id),
            parentEstablished: metadata.isParentEstablished(id),
            isPendingUpsert: metadata.pendingUpserts[id] != nil,
            isActive: trip?.isActive ?? false,
            hasEndTime: trip?.endTime != nil
        )
    }

    /// Whether a specific trip is queued for a remote delete.
    func isPendingDelete(_ id: UUID) -> Bool { metadata.pendingDeletes[id] != nil }

    /// P0 Phase A: this Trip's own durable upload-queue identities (not counts).
    func cancellationQueueEntries(_ id: UUID) -> [TripActivityCancellation.QueueEntry] {
        var entries: [TripActivityCancellation.QueueEntry] = []
        let key = id.uuidString.lowercased()
        if metadata.pendingUpserts[id] != nil { entries.append(.init(kind: TripActivityCancellation.QueueEntry.tripUpsert, id: key)) }
        if metadata.pendingWorkTaskClears[id] != nil { entries.append(.init(kind: TripActivityCancellation.QueueEntry.tripWorkTaskClear, id: key)) }
        return entries
    }

    /// P0 Phase A: removes exactly one entry after a verified, durably acknowledged cancellation receipt.
    func clearCancelledTripQueue(_ id: UUID, workTaskClear: Bool) {
        if workTaskClear { metadata.clearWorkTaskClears([id]) } else { metadata.clearDirty([id]) }
    }

    /// Read-only, account/vineyard-scoped issue discovery for Settings.
    /// Legacy metadata is global; an ID with no original scoped evidence must
    /// be displayed for private review, never offered a destructive repair.
    nonisolated struct GuidedQueueItem: Identifiable, Sendable {
        let id: UUID
        let pendingUpload: Bool
        let pendingDeletion: Bool
        let failed: Bool
        let belongsToCurrentVineyard: Bool
        let originalTripPresent: Bool
        /// Set only for a protected entry whose saved Trip belongs to another
        /// vineyard of this account. Names where to resume; never uploads.
        var resumeTarget: TripResumeTarget? = nil
    }

    func guidedQueueItems(vineyardId: UUID) -> [GuidedQueueItem] {
        guard let store, let auth, auth.isSignedIn,
              auth.userId == store.currentUserIdProvider?(),
              store.selectedVineyardId == vineyardId else { return [] }
        let currentTrips = Dictionary(
            store.trips.filter { $0.vineyardId == vineyardId }.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current })
        let originals = (try? store.tripDeletionJournal.load().intents) ?? [:]
        let allIds = Set(metadata.pendingUpserts.keys)
            .union(metadata.pendingDeletes.keys)
            .union(originals.values.filter {
                $0.acknowledgement == nil && $0.scope?.account == auth.userId &&
                    $0.scope?.vineyard == vineyardId
            }.map(\.trip))
        // Read-only ownership lookup for entries outside the selected vineyard.
        let savedSnapshots = (store.trips + store.tripRepo.loadAll())
            .map { (tripId: $0.id, vineyardId: $0.vineyardId) }
        let accountVineyards = store.vineyards.map { (id: $0.id, name: $0.name) }
        return allIds.sorted { $0.uuidString < $1.uuidString }.map { id in
            let scopedDeletion = originals[id].map {
                $0.scope?.account == auth.userId && $0.scope?.vineyard == vineyardId &&
                    $0.scope?.trip == id
            } ?? false
            let belongs = currentTrips[id] != nil || scopedDeletion
            return GuidedQueueItem(
                id: id,
                pendingUpload: metadata.pendingUpserts[id] != nil,
                pendingDeletion: metadata.pendingDeletes[id] != nil || scopedDeletion,
                failed: metadata.isUpsertFailed(id) || metadata.isDeleteFailed(id),
                belongsToCurrentVineyard: belongs,
                originalTripPresent: currentTrips[id] != nil,
                resumeTarget: belongs ? nil : TripResumeTarget.resolve(
                    tripId: id, selectedVineyardId: vineyardId,
                    persistedSnapshots: savedSnapshots, accountVineyards: accountVineyards))
        }
    }

    /// Explicit human-verified replacement for a missing tank start. The
    /// original tank ID and Actual Use still come from independently retained
    /// evidence; only the timestamp is operator supplied and audit-labelled.
    nonisolated struct GuidedTankStartOverride: Sendable {
        let sessionId: UUID
        let startAt: Date
        let evidenceNote: String
    }

    /// Selected, operator-confirmed repair option: recover ONLY the original
    /// tank start recorded in the same durable confirmed Actual Use. No guessed
    /// chemical amounts, GPS, rows or tank-end events. It never acknowledges a
    /// network operation; the normal ordered sync must prove receipt later.
    func guidedRestoreConfirmedTankStart(
        tripId: UUID, vineyardId: UUID, manual: GuidedTankStartOverride? = nil
    ) async throws -> String {
        struct NotAdmitted: LocalizedError {
            let explanation: String
            var errorDescription: String? { explanation }
        }
        guard !isSyncing, let store, let auth, auth.isSignedIn,
              let owner = auth.userId, store.currentUserIdProvider?() == owner,
              store.selectedVineyardId == vineyardId,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
              let local = store.trips.first(where: { $0.id == tripId && $0.vineyardId == vineyardId }),
              !local.isActive, local.endTime != nil, local.coverageBasis == .occurrence,
              metadata.pendingUpserts[tripId] != nil,
              metadata.pendingDeletes[tripId] == nil,
              (try? store.tripDeletionJournal.isCancelled(tripId)) == false,
              !TripCancellationIntentStore.shared.blocksReplay(tripId: tripId)
        else {
            throw NotAdmitted(explanation: "This original Trip is not eligible for a local evidence repair. Its retained work was not changed.")
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyardId.uuidString)
        let scope = TripOccurrenceJournal.Scope(ownerId: owner.uuidString.lowercased(),
            vineyardId: vineyardId.uuidString.lowercased(), tripId: tripId.uuidString.lowercased())
        let journal = try TripOccurrenceJournal(scope: scope)
        guard let retained = try journal.load(), retained.heldReason == nil,
              retained.pending.contains(where: { $0.rpc == "finalize_trip_occurrences_v1" })
        else {
            throw NotAdmitted(explanation: "The original finalisation journal is unavailable or held. No tank evidence was changed.")
        }
        // A server tombstone is a deliberate cancellation, never a reason to
        // resurrect or overwrite the Trip. NULL/ambiguous visibility is not proof.
        let remote = try await SupabaseTripSyncRepository()
            .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyardId)
        guard let remote, remote.id == tripId, remote.vineyardId == vineyardId,
              remote.deletedAt == nil, remote.endTime == nil, remote.isActive == true,
              store.selectedVineyardId == vineyardId, store.currentUserIdProvider?() == owner,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
              (try? store.tripDeletionJournal.isCancelled(tripId)) == false
        else {
            throw NotAdmitted(explanation: "The server Trip is deleted, completed, or cannot be verified. Original data was retained; nothing was recreated.")
        }
        let required = requiredTankSessions(tripId)
        let missing = TankDependencyVerification.missing(
            required: required, in: TankDependencyVerification.ids(local.tankSessions))
        guard !missing.isEmpty else {
            throw NotAdmitted(explanation: "No missing original tank session with a matching confirmed actual was found.")
        }
        let linked = Set(store.sprayRecords.filter {
            $0.canonicalTripId == tripId && $0.vineyardId == vineyardId && !$0.isTemplate
        }.map(\.id))
        let actuals = confirmedTankActuals(tripId).filter {
            $0.tripId == tripId && $0.vineyardId == vineyardId
        }
        guard var corrected = ConfirmedTankStartRecovery.restore(
            trip: local, missingSessionIds: missing,
            confirmedActuals: actuals, linkedSprayIds: linked, ownerId: owner)
        else {
            throw NotAdmitted(explanation: "The retained Actual Use does not uniquely prove the original tank identity and time. Owner review is required; no fields were invented.")
        }
        if let manual {
            let sessionKey = TankDependencyVerification.normalized(manual.sessionId.uuidString)
            let confirmed = actuals.filter {
                TankDependencyVerification.normalized($0.tankSessionId) == sessionKey &&
                $0.confirmedBy == owner && linked.contains($0.sprayRecordId)
            }
            guard missing.contains(sessionKey), confirmed.count == 1,
                  let original = confirmed.first,
                  remote.tankSessions?.contains(where: { $0.id == manual.sessionId }) != true,
                  let index = corrected.tankSessions.firstIndex(where: { $0.id == manual.sessionId }),
                  let localEnd = local.endTime,
                  GuidedRepairFieldValidation.manualTankTime(
                    manual.startAt, tripStart: local.startTime, tripEnd: localEnd,
                    originalConfirmedAt: original.confirmedAt,
                    reason: manual.evidenceNote) == nil else {
                throw NotAdmitted(explanation: "The operator-entered start time conflicts with the original confirmed tank ID, Trip interval or existing server evidence. Nothing was corrected.")
            }
            corrected.tankSessions[index].startTime = manual.startAt
            let evidence = manual.evidenceNote.trimmingCharacters(in: .whitespacesAndNewlines)
            corrected.manualCorrectionEvents.append(
                "\(Date().ISO8601Format()) guided_verified_tank_start operator=\(owner.uuidString.lowercased()) " +
                "session=\(sessionKey) actual=\(original.id.uuidString.lowercased()) " +
                "entered_utc=\(manual.startAt.ISO8601Format()) source=\(evidence)")
        }
        // A same-account deletion or selection change after the remote read
        // invalidates this repair before the first persistent write.
        guard store.selectedVineyardId == vineyardId,
              store.currentUserIdProvider?() == owner,
              (try? store.tripDeletionJournal.isCancelled(tripId)) == false,
              metadata.pendingDeletes[tripId] == nil
        else {
            throw NotAdmitted(explanation: "The original Trip scope changed. No changes were written.")
        }
        try store.updateTripOrThrow(corrected)
        return manual == nil
            ? "The original confirmed tank start was saved with an audit entry. Its linked work still needs independent server receipts."
            : "The operator-verified tank time was saved with its original session ID and evidence note. Run the full sync and verify dependent receipts."
    }

    /// Only called by the reviewed legacy deletion coordinator after a server
    /// cancellation receipt, linked tombstones and a locally persisted original
    /// evidence archive are independently verified. No generic "clear errors".
    func guidedRetireReviewedDeletedQueue(
        tripId: UUID, vineyardId: UUID, ownerId: UUID,
        operationId: UUID
    ) throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "Original deletion review did not meet the receipt, archive and account gates." }
        }
        guard !isSyncing, let store, let auth, auth.isSignedIn,
              auth.userId == ownerId,
              store.currentUserIdProvider?() == ownerId,
              store.selectedVineyardId == vineyardId,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == ownerId,
              store.tripRepo.loadAll().filter({ $0.id == tripId })
                .allSatisfy({ $0.vineyardId == vineyardId }),
              GuidedLegacyDeletedTripRepair.archiveConfirmed(
                operationId: operationId, tripId: tripId,
                vineyard: vineyardId, owner: ownerId),
              try GuidedRepairAuditLedger.shared.history(
                account: ownerId, vineyard: vineyardId, record: tripId)
                .contains(where: { $0.id == operationId &&
                    $0.stages.contains(where: { $0.code == "SERVER_CANCEL_RECEIPT_AND_ARCHIVE_VERIFIED" })
                })
        else { throw Refused() }

        // Preserve the old deletion intent/review history but note explicitly
        // that this was an owner-reviewed LEGACY tombstone, not an original
        // on-device cancellation operation receipt.
        if let originalIntent = try store.tripDeletionJournal.load().intents[tripId] {
            try store.tripDeletionJournal.acknowledgeReviewedLegacy(
                originalIntent, owner: ownerId, vineyard: vineyardId,
                operationId: operationId)
        }
        try metadata.acknowledgeVerifiedCancellation(tripId)
        SyncIssueCenter.shared.clearIssues([tripId])
        SyncIssueCenter.shared.notePending(entity: "Trips", count: metadata.pendingUpserts.count)
    }

    /// True while a full sweep is actively pushing/pulling trips.
    var isSyncing: Bool { syncStatus == .syncing }

    /// True if the last sweep failed.
    var hasFailure: Bool { if case .failure = syncStatus { return true }; return false }

    /// Whether a specific trip's last push failed while still pending. Used for
    /// per-record error isolation so one failed trip never makes others look
    /// failed.
    func hasFailure(_ id: UUID) -> Bool { !isHeld(id) && (metadata.isUpsertFailed(id) || metadata.isDeleteFailed(id)) }

    /// Trips whose last upsert push failed while still pending.
    var failedUpsertIds: Set<UUID> { Set(metadata.failedUpsertIds.filter { !isHeld($0) }) }
    /// Trips whose last remote delete failed while still pending.
    var failedDeleteIds: Set<UUID> { Set(metadata.failedDeleteIds.filter { !isHeld($0) }) }

    var retainedState: TripRetainedState {
        guard let store, let vineyard = store.selectedVineyardId else { return TripRetainedState() }
        return store.tripRetainedState(vineyard: vineyard, pendingDeletes: Set(metadata.pendingDeletes.keys))
    }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any TripSyncRepositoryProtocol
    private let metadata: TripSyncMetadata
    private var isConfigured: Bool = false
    private var shouldDeferEndedTrip: (UUID) -> Bool = { _ in false }

    init(
        repository: (any TripSyncRepositoryProtocol)? = nil,
        metadata: TripSyncMetadata? = nil
    ) {
        self.repository = repository ?? SupabaseTripSyncRepository()
        self.metadata = metadata ?? TripSyncMetadata()
    }

    // MARK: - Configuration

    func configure(store: MigratedDataStore, auth: NewBackendAuthService) {
        self.store = store
        self.auth = auth
        store.legacySprayScopeProvider = { [weak store, weak auth] in
            guard let vineyard = store?.selectedVineyardId else { return nil }
            return auth?.legacySprayScope(vineyard: vineyard)
        }
        guard !isConfigured else { return }
        isConfigured = true
        store.onTripChanged = { [weak self] id in
            self?.markTripDirty(id)
        }
        store.onTripDeleted = { [weak self] id in
            self?.markTripDeleted(id)
        }
    }

    /// Holds final ended state locally until this trip's actual-use queue clears.
    func configurePhase5EndGate(_ gate: @escaping (UUID) -> Bool) {
        shouldDeferEndedTrip = gate
    }

    /// P0 3.1.9 Phase B: tank session IDs referenced by local Tank actuals for a Trip.
    private var requiredTankSessions: (UUID) -> Set<String> = { _ in [] }
    /// Source of independently confirmed original Actual Use. Injectable only
    /// for native tests; production always reads the durable Actual store.
    private var confirmedTankActuals: (UUID) -> [SprayTankActual] = { tripId in
        SprayTankActualStore.shared.records.filter { $0.tripId == tripId }
    }
    /// Last fixed Phase B hold code per Trip; diagnostics only, never quantities.
    private(set) var tankDependencyHolds: [UUID: String] = [:]

    func configureTankDependencies(_ provider: @escaping (UUID) -> Set<String>) {
        requiredTankSessions = provider
    }

    func configureConfirmedTankActuals(_ provider: @escaping (UUID) -> [SprayTankActual]) {
        confirmedTankActuals = provider
    }

    // MARK: - Deterministic-failure cooldown

    /// In memory ON PURPOSE: a relaunch or an explicit "Sync now" is always one
    /// fresh attempt, which is how a Trip heals after a server repair without
    /// any local state being edited. Only deterministic server answers
    /// (`nonRetryable` / `held`) are recorded; see `TripSyncRetryThrottle`.
    private var retryThrottle = TripSyncRetryThrottle()

    /// An explicit user Sync re-checks every Trip immediately.
    func clearRetryCooldowns() { retryThrottle.clearAll() }

    /// Trips currently waiting out a cooldown after a deterministic answer.
    func coolingDownTripIds(now: Date = Date()) -> Set<UUID> {
        Set(retryThrottle.entries.keys.filter { retryThrottle.isCoolingDown($0, now: now) })
    }

    // MARK: - Dirty tracking

    func markTripDirty(_ id: UUID) {
        metadata.markDirty(id, at: Date())
        // A new local edit is new evidence (for example the operator reviewed
        // an unfinished tank), so the next sweep re-checks this Trip instead of
        // waiting out a cooldown that was earned by the older data. Only this
        // device's own edits arrive here: a remote pull never calls it.
        retryThrottle.clear(id)
    }

    func markTripDeleted(_ id: UUID) {
        let intent = try? store?.tripDeletionJournal.load().intents[id]
        metadata.markDeleted(id, at: intent?.queuedAt ?? Date())
    }

    /// Identifies uploads independently from deletion intents; no item is inferred from counts.
    var deletionRecoveryDiagnostics: String {
        guard let store else { return "Trip deletion evidence unavailable" }
        do {
            let intents = try store.tripDeletionJournal.load().intents.values.sorted { $0.trip.uuidString < $1.trip.uuidString }
            let knownTripIds = Set((store.trips + store.tripRepo.loadAll()).map(\.id))
            let uploads = metadata.pendingUpserts.sorted { $0.key.uuidString < $1.key.uuidString }.map {
                "upload trip=\($0.key) revision=\($0.value.timeIntervalSince1970) cancelled=\((try? store.tripDeletionJournal.isCancelled($0.key)) ?? true) review=\(knownTripIds.contains($0.key) ? "inspect upload independently" : "TRIP_UPLOAD_ORIGINAL_SNAPSHOT_UNAVAILABLE")"
            }
            let deletes = intents.map { "delete trip=\($0.trip) account=\($0.scope?.account.uuidString ?? "unresolved") vineyard=\($0.scope?.vineyard.uuidString ?? "unresolved") revision=\($0.revision) creation=\($0.creationOutcome) review=\($0.reviewReason ?? "none") acknowledgement=\($0.acknowledgement ?? "none")" }
            let retained = retainedState
            let sprays = retained.sprays.map { "held spray record=\($0.record) trip=\($0.trip) review=\($0.reason)" }
            var lines: [String] = [
                "Current-scope spray jobs held locally: \(retained.sprays.count)",
                retained.inspectionError ?? "Retained inspection complete"
            ]
            lines.append(contentsOf: sprays)
            lines.append("Trip uploads (separate from deletion): \(uploads.count)")
            lines.append(contentsOf: uploads)
            lines.append(contentsOf: deletes)
            return lines.joined(separator: "\n")
        } catch { return "Trip deletion evidence unreadable: \(error.localizedDescription)" }
    }

    /// Inspect the pending upload queue independently of the transient HTTP-error
    /// registry. Counts and fixed stage codes only: no IDs, names, coordinates,
    /// recipe amounts or raw parser/server messages are copied. Never replay here.
    var pendingUploadDiagnostics: String {
        let pending = metadata.pendingUpserts
        var reasons: [String: Int] = [:]
        for id in pending.keys {
            let reason = pendingUploadDiagnosticReason(id)
            reasons[reason, default: 0] += 1
        }
        // Legacy pending IDs do NOT carry a vineyard/account scope. This is
        // a *read-only* cache classification, never upload authority or an ACK.
        var scopeLines: [String] = ["scope_classification: unavailable_account_not_verified"]
        if let store, let owner = auth?.userId, auth?.isSignedIn == true,
           store.currentUserIdProvider?() == owner, let vineyard = store.selectedVineyardId {
            let selected = Dictionary(store.trips.map { ($0.id, $0.vineyardId) },
                                      uniquingKeysWith: { _, latest in latest })
            let persisted = Dictionary(store.tripRepo.loadAll().map { ($0.id, $0.vineyardId) },
                                       uniquingKeysWith: { _, latest in latest })
            var scopes: [TripQueuedUploadScope: Int] = [:]
            for id in pending.keys {
                let scope = TripQueuedUploadScope.classify(tripId: id, selectedVineyardId: vineyard,
                    selectedTrips: selected, persistedTrips: persisted)
                scopes[scope, default: 0] += 1
            }
            scopeLines = [
                "selected_slice_queued_uploads: \(scopes[.selectedSlice, default: 0])",
                "same_vineyard_snapshot_not_loaded: \(scopes[.persistedCurrentVineyardNotLoaded, default: 0])",
                "other_locally_cached_vineyard_protected: \(scopes[.persistedOtherVineyard, default: 0])",
                "original_snapshot_unavailable: \(scopes[.noLocalSnapshot, default: 0])",
                "scope_classification: cached_local_only_not_server_ack_or_owner_attestation"
            ]
        }
        return ([
            "VineTrack pending Trip upload inspection v2",
            "queued_trip_uploads_global_legacy: \(pending.count)",
            "queue_marked_failed_global_legacy: \(pending.keys.filter { metadata.isUpsertFailed($0) }.count)",
            "Global metadata includes other vineyards; held IDs are preserved, not replayed or cleared.",
            "These are local queue stages, not proof of server acceptance or of data loss."
        ] + scopeLines + reasons.sorted { $0.key < $1.key }.map { "  \($0.key): \($0.value)" }).joined(separator: "\n")
    }

    private func pendingUploadDiagnosticReason(_ id: UUID) -> String {
        guard let store else { return "TRIP_STORE_UNAVAILABLE" }
        guard let account = auth?.userId, auth?.isSignedIn == true,
              store.currentUserIdProvider?() == account else { return "TRIP_ACCOUNT_NOT_VERIFIED" }
        guard let vineyard = store.selectedVineyardId else { return "TRIP_VINEYARD_NOT_SELECTED" }
        // A normal historical Trip is NOT an upload-pending Trip merely
        // because it uses the legacy coverage format.
        guard metadata.pendingUpserts[id] != nil else {
            return "TRIP_NOT_QUEUED_SERVER_RECEIPT_NOT_PERSISTED"
        }
        // Do not infer that a different vineyard's cached record is an orphan,
        // and do not search another account's retained files for diagnostics.
        guard let trip = store.trips.first(where: { $0.id == id }) else {
            return "TRIP_SNAPSHOT_NOT_IN_SELECTED_SLICE"
        }
        guard trip.vineyardId == vineyard else { return "TRIP_NOT_IN_SELECTED_VINEYARD" }
        do {
            // Inspect metadata only; operational recovery/deletion readers may write
            // decode evidence or create directories and must not run in an export.
            if metadata.pendingDeletes[id] != nil { return "TRIP_CANCELLATION_HELD" }
            if !VineyardWriteAuthority.shared.canWrite(vineyardId: vineyard.uuidString) { return "TRIP_WRITE_ACCESS_HELD" }
            if trip.coverageBasis == .legacy { return "LEGACY_TRIP_UPLOAD_PENDING" }
            let journal = try TripOccurrenceJournal(scope: .init(
                ownerId: account.uuidString.lowercased(), vineyardId: vineyard.uuidString.lowercased(),
                tripId: id.uuidString.lowercased()), createDirectoryIfMissing: false)
            guard let snapshot = try journal.inspectionSnapshot() else { return "OCCURRENCE_JOURNAL_NOT_FOUND" }
            return TripOccurrenceJournal.syncDiagnosticReason(snapshot)
        } catch { return "TRIP_EVIDENCE_INSPECTION_HELD" }
    }

    /// Local metadata dependency only, not a fresh server-existence check.
    func inspectionParentPending(_ id: UUID) -> Bool {
        metadata.pendingDeletes[id] != nil || !metadata.isParentEstablished(id)
    }

    var verifiedDiagnosticsOwner: UUID? {
        guard let store, let account = auth?.userId, auth?.isSignedIn == true,
              store.currentUserIdProvider?() == account, let vineyard = store.selectedVineyardId,
              VineyardWriteAuthority.shared.canWrite(vineyardId: vineyard.uuidString) else { return nil }
        return account
    }

    /// Explicitly scoped, read-only P0 evidence. Cached existence and queued work
    /// are not server receipts. Foreign/unverified slices never expose record IDs.
    var retainedOperationDiagnostics: String {
        let bundle = Bundle.main
        var lines = ["VineTrack retained operation inspection v2", "platform: iOS",
            "version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
            "build: \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")",
            "source_revision: \(bundle.object(forInfoDictionaryKey: "VineTrackSourceRevision") as? String ?? "unknown_no_verified_build_receipt")",
            "source_revision_attestation: compare_embedded_sha_with_signed_archive_build_receipt",
            // This code marker proves the installed build includes the new
            // Issue #43 UI/admission logic, not its exact signed Git SHA.
            "issue43_feature_marker: separate_spray_confirmation_scoped_trip_history_auto_end_readback_v1",
            "issue43_receipt_reconciliation: server_terminal_exact_route_spray_actuals_durable_v2",
            "last_trip_sync_local: \(lastSyncDate?.ISO8601Format() ?? "unknown")",
            "last_selected_vineyard_download: \(lastSelectedVineyardDownloadAt?.ISO8601Format() ?? "unknown")",
            "last_full_sync: unknown_no_durable_full_sweep_receipt",
            "upload_cleared_acknowledgement: unknown_not_persisted",
            "inspection: local_read_only_no_network_no_retry"]
        guard let store, let account = auth?.userId, auth?.isSignedIn == true,
              store.currentUserIdProvider?() == account, let vineyard = store.selectedVineyardId else {
            return (lines + ["scope: ACCOUNT_OR_VINEYARD_NOT_VERIFIED; identifiers protected"]).joined(separator: "\n")
        }
        guard VineyardWriteAuthority.shared.canWrite(vineyardId: vineyard.uuidString) else {
            return (lines + ["scope: CURRENT_WRITE_ACCESS_NOT_VERIFIED; identifiers protected"]).joined(separator: "\n")
        }
        let trips = store.trips.filter { $0.vineyardId == vineyard }
        let visiblePending = Set(trips.filter { metadata.pendingUpserts[$0.id] != nil }.map(\.id))
        lines += ["account: matches_current_store", "vineyard_id: \(vineyard.uuidString.lowercased())",
            "unique_visible_queued_trips: \(visiblePending.count)",
            "unattributed_queue_entries: \(metadata.pendingUpserts.count - visiblePending.count)",
            "counts: queue_records_not_issue_count; journals_and_tanks_may_share_a_trip; no_global_total_inferred"]
        for trip in trips.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            lines += ["", "trip_id: \(trip.id.uuidString.lowercased())",
                "metadata_upload_pending: \(metadata.pendingUpserts[trip.id] != nil)",
                "parent_previously_established_local_evidence: \(metadata.isParentEstablished(trip.id))",
                "pending_reason: \(pendingUploadDiagnosticReason(trip.id))"]
            if trip.coverageBasis == .occurrence {
                do {
                    let journal = try TripOccurrenceJournal(scope: .init(ownerId: account.uuidString.lowercased(),
                        vineyardId: vineyard.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()), createDirectoryIfMissing: false)
                    if let state = try journal.inspectionSnapshot() { lines += TripOccurrenceJournal.inspectionLines(state) }
                    else { lines.append("occurrence_journal: absent; server_outcome: unknown") }
                } catch { lines.append("failure_code: OCCURRENCE_EVIDENCE_UNREADABLE; original evidence retained") }
            }
            for session in trip.tankSessions {
                lines += ["tank_session_id: \(session.id.uuidString.lowercased()); parent_trip: \(trip.id.uuidString.lowercased()); local: retained; server_ack: unknown_not_independently_persisted"]
            }
        }
        for spray in store.sprayRecords.filter({ $0.vineyardId == vineyard }) {
            lines += ["spray_record_id: \(spray.id.uuidString.lowercased()); parent_trip: \(spray.tripId.uuidString.lowercased()); server_ack: unknown_requires_spray_queue_and_server_read"]
        }
        // P0 3.1.9: name each queued upload whose Trip snapshot is outside the
        // visible slice. Read-only: no directory creation, replay or clearing.
        for id in metadata.pendingUpserts.keys.filter({ !visiblePending.contains($0) }).sorted(by: { $0.uuidString < $1.uuidString }) {
            let journalState: String
            do {
                let journal = try TripOccurrenceJournal(scope: .init(ownerId: account.uuidString.lowercased(),
                    vineyardId: vineyard.uuidString.lowercased(), tripId: id.uuidString.lowercased()), createDirectoryIfMissing: false)
                journalState = try journal.inspectionSnapshot().map { TripOccurrenceJournal.syncDiagnosticReason($0) } ?? "absent_in_selected_vineyard"
            } catch { journalState = "OCCURRENCE_EVIDENCE_UNREADABLE" }
            let linkedSpray = store.sprayRecords.contains(where: { $0.tripId == id }) ? "present_locally" : "absent_locally_server_state_unknown"
            lines += ["", "unattributed_queue_entry: trip=\(id.uuidString.lowercased()); reason=\(pendingUploadDiagnosticReason(id)); queue_marked_failed=\(metadata.isUpsertFailed(id)); occurrence_journal_selected_vineyard=\(journalState); linked_spray=\(linkedSpray); action: individual_reconciliation_required_no_clear"]
        }
        return lines.joined(separator: "\n")
    }

    /// iOS P0 v3. User-requested, authenticated and vineyard-scoped read-only
    /// evidence. No journal.load(), queue mutation, RPC write, retry or ACK.
    /// Original receipt proof remains exclusively in normal sync admission.
    func inspectTripServerReadbackV3() async -> String {
        let bundle = Bundle.main
        var lines = [
            "VineTrack Trip Sync Recovery v3 — server read-only",
            "platform: iOS",
            "version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")",
            "build: \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")",
            "source_revision: \(bundle.object(forInfoDictionaryKey: "VineTrackSourceRevision") as? String ?? "unknown_unverified_build")",
            "no_server_write_no_queue_mutation_no_replay_no_ack: true",
            "server_receipts: inspected_only_not_persisted",
            "source_revision_attestation: compare_embedded_sha_with_signed_archive_build_receipt"
        ]
        guard !isSyncing else {
            return (lines + ["status: SYNC_ALREADY_IN_PROGRESS; no inspection performed"]).joined(separator: "\n")
        }
        guard let store, let account = auth?.userId, auth?.isSignedIn == true,
              store.currentUserIdProvider?() == account,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == account,
              let vineyard = store.selectedVineyardId else {
            return (lines + ["status: ACCOUNT_OR_VINEYARD_NOT_VERIFIED"]).joined(separator: "\n")
        }
        let selected = store.trips.filter { $0.vineyardId == vineyard }
        let pending = selected.filter { metadata.pendingUpserts[$0.id] != nil }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        lines += ["vineyard_id: \(vineyard.uuidString.lowercased())",
                  "global_legacy_pending: \(metadata.pendingUpserts.count)",
                  "selected_vineyard_pending: \(pending.count)",
                  "other_or_unattributed_queue_ids: \(metadata.pendingUpserts.count - pending.count)",
                  "other_vineyard_records: PROTECTED_NOT_INSPECTED"]
        // The four lines above are different projections of the same queue. This
        // splits every queued ID into exactly one explained bucket (read-only).
        let recordedCancellations = Set(((try? store.tripDeletionJournal.load().intents) ?? [:]).keys)
            .union(metadata.pendingDeletes.keys)
        lines += TripQueueScopeBreakdown.evaluate(
            queuedIds: Set(metadata.pendingUpserts.keys),
            selectedVineyardId: vineyard,
            snapshots: (store.trips + store.tripRepo.loadAll()).map { (tripId: $0.id, vineyardId: $0.vineyardId) },
            cancelledIds: recordedCancellations).lines
        let reader = SupabaseTripSyncRepository()
        for local in pending.prefix(25) {
            guard store.currentUserIdProvider?() == account,
                  store.selectedVineyardId == vineyard,
                  SupabaseClientProvider.shared.client.auth.currentUser?.id == account else {
                lines.append("status: SCOPE_CHANGED_INSPECTION_STOPPED")
                break
            }
            let tripId = local.id
            lines += ["", "trip_id: \(tripId.uuidString.lowercased())",
                      "queue_failed: \(metadata.isUpsertFailed(tripId))",
                      "local_is_active: \(local.isActive)",
                      "local_is_ended: \(local.endTime != nil)",
                      "local_tank_count: \(local.tankSessions.count)",
                      "local_spray_count: \(store.sprayRecords.filter { $0.canonicalTripId == tripId }.count)",
                      "local_actual_pending: \(SprayTankActualStore.shared.pendingCount(tripId: tripId))",
                      "queue_stage: \(pendingUploadDiagnosticReason(tripId))"]
            var journalSnapshot: TripOccurrenceJournal.Snapshot? = nil
            if local.coverageBasis == .occurrence {
                do {
                    let journal = try TripOccurrenceJournal(scope: .init(
                        ownerId: account.uuidString.lowercased(),
                        vineyardId: vineyard.uuidString.lowercased(),
                        tripId: tripId.uuidString.lowercased()), createDirectoryIfMissing: false)
                    journalSnapshot = try journal.inspectionSnapshot()
                    if let journalSnapshot {
                        lines += TripOccurrenceJournal.inspectionLines(journalSnapshot)
                    } else {
                        lines.append("original_journal: ABSENT_OR_UNAVAILABLE_NO_REPLAY")
                    }
                } catch { lines.append("original_journal: UNREADABLE_NO_REPLAY") }
            }
            do {
                let row = try await reader.fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard)
                guard store.currentUserIdProvider?() == account,
                      store.selectedVineyardId == vineyard,
                      SupabaseClientProvider.shared.client.auth.currentUser?.id == account else {
                    lines.append("server_result: SCOPE_CHANGED_DISCARDED")
                    break
                }
                guard let row else {
                    lines += ["server_trip: NOT_VISIBLE_IN_AUTHENTICATED_SCOPED_READ",
                              "recovery_class: ORIGINAL_ID_OPERATION_RECONCILIATION_REQUIRED"]
                    continue
                }
                let remote = row.toTrip()
                lines += ["server_trip: PRESENT_EXACT_ID",
                          "server_ended: \(row.endTime != nil)",
                          "server_active: \(row.isActive ?? false)",
                          "server_tank_count: \(remote.tankSessions.count)",
                          "terminal_trip_hold_code: \(CompletedTripReceiptAdmission.holdReason(local: local, remote: remote) ?? "none")",
                          TripRecoveryTimeEvidence.compare(field: "trip_end", local: local.endTime, remote: remote.endTime)]
                for tank in local.tankSessions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                    lines.append("tank_session_id: \(tank.id.uuidString.lowercased())")
                    guard let serverTank = remote.tankSessions.first(where: { $0.id == tank.id }) else {
                        lines.append("tank_server: SESSION_ID_NOT_FOUND")
                        continue
                    }
                    lines.append("tank_discrepancy: \(TankSessionReceiptMatch.discrepancy(local: tank, remote: serverTank) ?? "none")")
                    lines += [
                        TripRecoveryTimeEvidence.compare(field: "tank_start", local: tank.startTime, remote: serverTank.startTime),
                        TripRecoveryTimeEvidence.compare(field: "tank_end", local: tank.endTime, remote: serverTank.endTime),
                        TripRecoveryTimeEvidence.compare(field: "tank_fill_start", local: tank.fillStartTime, remote: serverTank.fillStartTime),
                        TripRecoveryTimeEvidence.compare(field: "tank_fill_end", local: tank.fillEndTime, remote: serverTank.fillEndTime)
                    ]
                }
                if local.tripFunction == TripFunction.spraying.rawValue {
                    do {
                        let linked = try await SprayCompletionRepository().fetchLinked(tripId: tripId)
                        let localSprays = store.sprayRecords.filter { $0.canonicalTripId == tripId }
                        lines += ["server_linked_sprays: \(linked.count)",
                                  "local_server_spray_ids_match: \(Set(linked.map(\.id)) == Set(localSprays.map(\.id)))"]
                    } catch { lines.append("server_linked_sprays: READ_FAILED_NO_ASSUMPTION") }
                    let localActuals = SprayTankActualStore.shared.records.filter { $0.tripId == tripId }
                    for actual in localActuals {
                        do {
                            let remoteActual = try await SprayTankActualStore.shared.actualReader(actual)
                            lines.append("actual_id: \(actual.id.uuidString.lowercased()); server_matches: \(TankDependencyVerification.actualMatches(local: actual, server: remoteActual))")
                        } catch {
                            lines.append("actual_id: \(actual.id.uuidString.lowercased()); server_read: FAILED")
                        }
                    }
                }
                if let journalSnapshot, !journalSnapshot.pending.isEmpty {
                    do {
                        let recovery = try await reader.fetchOccurrenceRecovery(
                            tripId: tripId, operationIds: journalSnapshot.pending.map(\.id))
                        if case .array(let receipts) = recovery[occurrence: "receipts"] {
                            lines.append("original_operation_server_receipts_visible: \(receipts.count)")
                        } else {
                            lines.append("original_operation_server_receipts: RESPONSE_SHAPE_NOT_VERIFIED")
                        }
                    } catch { lines.append("original_operation_server_receipts: READ_FAILED_NO_ASSUMPTION") }
                }
            } catch {
                lines.append("server_trip: READ_FAILED_NO_ASSUMPTION")
            }
        }
        if pending.count > 25 { lines.append("remaining_selected_pending: \(pending.count - 25); not_inspected") }
        lines.append("inspected_at_utc: \(Date().ISO8601Format())")
        let report = lines.joined(separator: "\n")
        // In-memory convenience for the Copy Sync diagnostics action. It is
        // neither a durable accepted receipt nor a permitted replay authority.
        lastTripServerReadbackV3 = report
        return report
    }

    // MARK: - Work Task link

    /// Link or unlink a trip to a Work Task. Updates the local store immediately
    /// (so the UI reflects the change at once) and propagates the change to the
    /// server via an explicit `work_task_id` patch. The explicit patch is needed
    /// for unlinking because the bulk upsert omits nil optionals and would never
    /// clear the server value. On success the pending dirty flag is cleared so a
    /// later bulk upsert does not re-process the record. If the network call
    /// fails the trip stays dirty; a later online sync re-propagates a link
    /// (non-nil), while a full unlink requires connectivity to clear.
    func setWorkTaskLink(tripId: UUID, workTaskId: UUID?) async {
        guard let store else { return }
        guard !isHeld(tripId), (try? store.tripDeletionJournal.isCancelled(tripId)) == false else { return }
        guard var trip = store.trips.first(where: { $0.id == tripId }) else { return }
        trip.workTaskId = workTaskId
        store.updateTrip(trip)

        // A non-nil link supersedes any queued clear: the newer link wins and the
        // bulk upsert (marked dirty by store.updateTrip) carries it to the server.
        if workTaskId != nil {
            metadata.clearWorkTaskClears([tripId])
        }

        guard SupabaseClientProvider.shared.isConfigured else {
            // Offline. An unlink cannot reach the server now and the bulk upsert
            // omits nil optionals, so persist a pending clear to retry the
            // explicit null patch on the next successful sync.
            if workTaskId == nil {
                metadata.markWorkTaskClearPending(tripId, at: Date())
            }
            return
        }
        do {
            try await repository.updateTripWorkTaskLink(id: tripId, workTaskId: workTaskId)
            metadata.clearDirty([tripId])
            if workTaskId == nil {
                metadata.clearWorkTaskClears([tripId])
            }
        } catch {
            // Network/server unavailable — durably queue the explicit clear so a
            // later sync re-sends the null patch. A failed link stays dirty and
            // re-propagates its non-nil value through the normal upsert path.
            if workTaskId == nil {
                metadata.markWorkTaskClearPending(tripId, at: Date())
            }
            #if DEBUG
            print("[TripSync] setWorkTaskLink failed for \(tripId): \(error.localizedDescription)")
            #endif
        }
    }

    // MARK: - Public sync entry points

    func syncTripsForSelectedVineyard() async {
        guard let store, let auth, auth.isSignedIn,
              let vineyardId = store.selectedVineyardId else { return }
        await sync(vineyardId: vineyardId)
    }

    func sync(vineyardId: UUID) async {
        guard !isSyncing else { return }
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        syncStatus = .syncing
        // Retry is not an acknowledgement. Retain the last failure until the
        // complete pass succeeds, or replace it with a current failure/hold.
        // No early return, cancellation or retained hold may leave a permanent spinner.
        defer {
            if syncStatus == .syncing { syncStatus = .failure("Trip sync interrupted. Retained work is unchanged; retry Sync Trips.") }
        }
        let current = store?.remoteApplicationCurrentCheck() ?? { true }
        do {
            try await pushLocalTrips(vineyardId: vineyardId)
            await TripLabourSnapshotJournal.shared.replay(trips: store?.trips ?? [])
            try await pullRemoteTrips(vineyardId: vineyardId)
            guard current() else { throw CancellationError() }
            lastSelectedVineyardDownloadAt = Date()
            let retained = retainedState
            if let issue = retained.inspectionError { throw TripDeletionJournal.Held(reason: issue) }
            // Legacy upload metadata is GLOBAL. A failed Trip from a different
            // vineyard must not mark this vineyard's entire sync as failed;
            // equally, its original queue must not disappear behind SUCCESS.
            let visibleTripVineyards = Dictionary((store?.trips ?? []).map { ($0.id, $0.vineyardId) },
                                                  uniquingKeysWith: { _, latest in latest })
            let scoped = TripQueuedScopeSummary.evaluate(
                queuedIds: Set(metadata.pendingUpserts.keys), failedIds: failedUpsertIds,
                selectedVineyardId: vineyardId, visibleTripVineyards: visibleTripVineyards)
            let held = max(retained.total, metadata.pendingDeletes.count)
            let unresolved = max(held, scoped.unresolvedCount)
            if scoped.selectedFailedCount > 0 {
                errorMessage = "This vineyard has \(scoped.selectedFailedCount) failed Trip upload(s). Original evidence is retained; finished Trips will not be reopened."
                syncStatus = .failure(errorMessage ?? "Current-vineyard Trip upload held.")
                return
            }
            metadata.setLastSync(Date(), for: vineyardId)
            if unresolved > 0 {
                let queueText = "\(scoped.selectedQueuedCount) Trip upload(s) in this vineyard, \(scoped.outsideSelectedQueuedCount) in other or unidentified original scopes"
                if TripSyncHoldPresentation.needsCurrentVineyardAttention(
                    selectedQueuedCount: scoped.selectedQueuedCount, currentRetainedCount: retained.total
                ) {
                    errorMessage = "Trip reconciliation remains held (\(queueText)). A completed download is not an upload acknowledgement. \(retained.summary ?? "Original Trip operations are retained for individual review.")"
                } else {
                    // Protected foreign/unattributed legacy IDs still prevent a
                    // GLOBAL upload-cleared receipt and keep status .held.
                    // They are not a failed write for this selected vineyard.
                    errorMessage = nil
                }
                syncStatus = .held(unresolved)
            } else {
                lastSyncDate = Date()
                errorMessage = nil
                syncStatus = .success
            }
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
        }
    }

    /// Exact-ID, selected-vineyard readback for an ended Trip shown on the
    /// device. Safe to call from the closure screen: no server write, no
    /// generic Retry All, no global metadata cleanup. applyRemote only
    /// acknowledges the original pending ID after dependent proof matches.
    func reconcileServerEndedTrip(_ id: UUID) async -> Bool {
        guard !isSyncing, let store, let auth, auth.isSignedIn,
              let selected = store.selectedVineyardId,
              let owner = store.currentUserIdProvider?(), owner == auth.userId,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
              let local = store.trips.first(where: { $0.id == id && $0.vineyardId == selected }),
              !local.isActive, local.endTime != nil,
              metadata.pendingUpserts[id] != nil, metadata.pendingDeletes[id] == nil,
              (try? store.tripDeletionJournal.isCancelled(id)) == false,
              !TripCancellationIntentStore.shared.blocksReplay(tripId: id) else { return false }
        do {
            guard let row = try await SupabaseTripSyncRepository().fetchTripForOccurrenceStart(tripId: id, vineyardId: selected),
                  row.id == id, row.vineyardId == selected, row.deletedAt == nil,
                  TankSessionReceiptMatch.sameTime(row.endTime, local.endTime),
                  row.isActive == false,
                  store.currentUserIdProvider?() == owner,
                  store.selectedVineyardId == selected,
                  SupabaseClientProvider.shared.client.auth.currentUser?.id == owner else { return false }
            await applyRemote(row, vineyardId: selected, store: store)
            let settled = metadata.pendingUpserts[id] == nil
            SyncIssueCenter.shared.notePending(entity: "Trips", count: metadata.pendingUpserts.count)
            return settled
        } catch {
            // A failed independent read is not proof of upload success.
            return false
        }
    }

    // MARK: - Repair

    nonisolated struct RepairResult: Sendable {
        var scanned: Int = 0
        var repaired: Int = 0
        var alreadyCorrect: Int = 0
        var pushed: Int = 0
        var skipped: [(tripId: UUID, reason: String)] = []
        var syncError: String?
    }

    nonisolated struct LocalTripDetail: Sendable, Identifiable {
        var id: UUID
        var title: String?
        var function: String?
        var startTime: Date?
        var paddockName: String?
        var paddockIds: [UUID]
        var localVineyardId: UUID
        var inferredVineyardId: UUID?
        var inferredFromPaddocks: Bool
        var matchesSelectedVineyard: Bool
    }

    nonisolated struct AuditResult: Sendable {
        var ranAt: Date?
        var localTotal: Int = 0
        var localAcrossAllVineyards: Int = 0
        var localForVineyard: Int = 0
        var remoteForVineyard: Int = 0
        var remoteSoftDeleted: Int = 0
        var localOnlyIds: [UUID] = []
        var localOnlyMissingFunction: [UUID] = []
        var localVineyardMismatch: [UUID] = []
        var localOnlyDetails: [LocalTripDetail] = []
        var orphanLocalDetails: [LocalTripDetail] = []
        var pendingUpsertIds: [UUID] = []
        var pendingDeleteIds: [UUID] = []
        var remoteMissingFunction: Int = 0
        /// Counts of `tripFunction` raw values across all locally persisted trips.
        /// Includes a `(none)` bucket for trips with no function set, and an
        /// `(unknown:<raw>)` bucket for raw values not in the canonical list.
        var localFunctionCounts: [String: Int] = [:]
        /// Counts of `trip_function` values across non-deleted remote trips for
        /// the selected vineyard. Same bucket conventions as `localFunctionCounts`.
        var remoteFunctionCounts: [String: Int] = [:]
        var error: String?
    }

    var lastAuditResult: AuditResult = AuditResult()

    /// Build a function-distribution dictionary from a sequence of optional raw
    /// `tripFunction` strings. Canonical `TripFunction` raw values are used as
    /// keys; missing/empty values bucket under `(none)` and unrecognised raw
    /// values bucket under `(unknown:<raw>)`.
    nonisolated static func functionDistribution(rawValues: [String?]) -> [String: Int] {
        let canonical = Set(TripFunction.allCases.map { $0.rawValue })
        var counts: [String: Int] = [:]
        for raw in rawValues {
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key: String
            if trimmed.isEmpty {
                key = "(none)"
            } else if canonical.contains(trimmed) {
                key = trimmed
            } else {
                key = "(unknown:\(trimmed))"
            }
            counts[key, default: 0] += 1
        }
        return counts
    }

    nonisolated struct RepushNamesResult: Sendable {
        var ranAt: Date?
        var scanned: Int = 0
        var withFunctionOrTitle: Int = 0
        var alreadyAssigned: Int = 0
        var repairedFromPaddocks: Int = 0
        var markedForUpload: Int = 0
        var pushed: Int = 0
        var skipped: [(tripId: UUID, reason: String)] = []
        var error: String?
    }

    var lastRepushNamesResult: RepushNamesResult = RepushNamesResult()

    /// Scan **all** locally persisted trips (not just the selected vineyard
    /// slice) that carry a `tripFunction` or `tripTitle`, attempt to assign
    /// them to the currently selected vineyard, mark them dirty and push.
    ///
    /// Behaviour:
    /// - Trips already assigned to `vineyardId` are marked dirty and pushed.
    /// - Trips with a different/missing `vineyardId` are repaired only when
    ///   every paddock on the trip resolves to the selected vineyard.
    /// - Trips that cannot be safely assigned are listed in `skipped`.
    ///
    /// Used after running `sql/023_trips_function_title.sql` so existing rows
    /// can have their trip name backfilled, and as a recovery path for older
    /// local trips with stale vineyardId that never reached Supabase.
    func repushTripNames(vineyardId: UUID) async -> RepushNamesResult {
        var result = RepushNamesResult()
        result.ranAt = Date()
        guard let store else { return result }
        guard SupabaseClientProvider.shared.isConfigured else {
            result.error = "Supabase not configured"
            lastRepushNamesResult = result
            return result
        }

        // Scan ALL persisted trips, not just the selected-vineyard slice.
        let allTrips = store.tripRepo.loadAll()
        result.scanned = allTrips.count

        let paddockVineyard = Dictionary(
            store.paddocks.map { ($0.id, $0.vineyardId) },
            uniquingKeysWith: { first, _ in first }
        )

        var idsToPush: [UUID] = []
        let now = Date()
        for trip in allTrips {
            let hasFn = !(trip.tripFunction?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            let hasTitle = !(trip.tripTitle?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            guard hasFn || hasTitle else { continue }
            result.withFunctionOrTitle += 1

            if trip.vineyardId == vineyardId {
                result.alreadyAssigned += 1
                metadata.markDirty(trip.id, at: now)
                idsToPush.append(trip.id)
                continue
            }

            // Try to repair from paddock ownership.
            if trip.paddockIds.isEmpty {
                result.skipped.append((trip.id, "no paddocks — cannot infer vineyard"))
                continue
            }
            let resolved = trip.paddockIds.compactMap { paddockVineyard[$0] }
            if resolved.count != trip.paddockIds.count {
                result.skipped.append((trip.id, "paddock(s) missing locally — cannot infer vineyard"))
                continue
            }
            let unique = Set(resolved)
            if unique.count > 1 {
                result.skipped.append((trip.id, "paddocks span multiple vineyards"))
                continue
            }
            guard let only = unique.first else {
                result.skipped.append((trip.id, "could not resolve vineyard"))
                continue
            }
            if only != vineyardId {
                result.skipped.append((trip.id, "paddocks belong to another vineyard (\(only))"))
                continue
            }
            // Safe to repair: rewrite vineyardId and persist via store.
            var repaired = trip
            repaired.vineyardId = vineyardId
            store.applyRemoteTripUpsert(repaired)
            result.repairedFromPaddocks += 1
            metadata.markDirty(trip.id, at: now)
            idsToPush.append(trip.id)
        }
        result.markedForUpload = idsToPush.count

        if !idsToPush.isEmpty {
            let pendingBefore = metadata.pendingUpserts.keys.filter { idsToPush.contains($0) }.count
            await sync(vineyardId: vineyardId)
            let pendingAfter = metadata.pendingUpserts.keys.filter { idsToPush.contains($0) }.count
            result.pushed = max(0, pendingBefore - pendingAfter)
            if case let .failure(message) = syncStatus {
                result.error = message
            }
        }

        lastRepushNamesResult = result
        return result
    }

    /// Compare local trips against Supabase for the selected vineyard so the
    /// user can see whether locally-visible trips (e.g. "Harrowing") have
    /// reached the backend. Read-only — does not push or repair.
    ///
    /// Scans **every** persisted local trip (not just the selected slice) so
    /// trips with stale or missing vineyardId are surfaced as orphans.
    func auditTripSync(vineyardId: UUID) async -> AuditResult {
        var result = AuditResult()
        result.ranAt = Date()
        guard let store else { return result }
        guard SupabaseClientProvider.shared.isConfigured else {
            result.error = "Supabase not configured"
            lastAuditResult = result
            return result
        }

        let allLocal = store.tripRepo.loadAll()
        let local = store.trips // selected-vineyard slice
        result.localTotal = local.count
        result.localAcrossAllVineyards = allLocal.count

        let paddockVineyard = Dictionary(
            store.paddocks.map { ($0.id, $0.vineyardId) },
            uniquingKeysWith: { first, _ in first }
        )
        let paddockNames = Dictionary(
            store.paddocks.map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )

        let localForVineyard = allLocal.filter { $0.vineyardId == vineyardId }
        result.localForVineyard = localForVineyard.count
        result.localVineyardMismatch = allLocal
            .filter { $0.vineyardId != vineyardId }
            .map { $0.id }
        result.localOnlyMissingFunction = localForVineyard
            .filter { ($0.tripFunction?.isEmpty ?? true) && ($0.tripTitle?.isEmpty ?? true) }
            .map { $0.id }
        result.localFunctionCounts = Self.functionDistribution(
            rawValues: localForVineyard.map { $0.tripFunction }
        )
        result.pendingUpsertIds = Array(metadata.pendingUpserts.keys)
        result.pendingDeleteIds = Array(metadata.pendingDeletes.keys)

        func detail(for trip: Trip) -> LocalTripDetail {
            let resolved = trip.paddockIds.compactMap { paddockVineyard[$0] }
            let unique = Set(resolved)
            let inferred: UUID? = (resolved.count == trip.paddockIds.count && unique.count == 1) ? unique.first : nil
            let names: String? = {
                let n = trip.paddockIds.compactMap { paddockNames[$0] }
                if n.isEmpty { return trip.paddockName.isEmpty ? nil : trip.paddockName }
                return n.joined(separator: ", ")
            }()
            return LocalTripDetail(
                id: trip.id,
                title: trip.tripTitle,
                function: trip.tripFunction,
                startTime: trip.startTime,
                paddockName: names,
                paddockIds: trip.paddockIds,
                localVineyardId: trip.vineyardId,
                inferredVineyardId: inferred,
                inferredFromPaddocks: inferred != nil,
                matchesSelectedVineyard: trip.vineyardId == vineyardId
            )
        }

        // Orphans: local trips with vineyardId that doesn't match selected.
        result.orphanLocalDetails = allLocal
            .filter { $0.vineyardId != vineyardId }
            .sorted { ($0.startTime) > ($1.startTime) }
            .prefix(50)
            .map { detail(for: $0) }

        do {
            let remote = try await repository.fetchAllTrips(vineyardId: vineyardId)
            let active = remote.filter { $0.deletedAt == nil }
            result.remoteForVineyard = active.count
            result.remoteSoftDeleted = remote.count - active.count
            let remoteIds = Set(active.map { $0.id })
            let localOnly = localForVineyard.filter { !remoteIds.contains($0.id) }
            result.localOnlyIds = localOnly.map { $0.id }
            result.localOnlyDetails = localOnly
                .sorted { ($0.startTime) > ($1.startTime) }
                .prefix(50)
                .map { detail(for: $0) }
            result.remoteMissingFunction = active.reduce(0) { acc, t in
                let hasFn = !(t.tripFunction?.isEmpty ?? true) || !(t.tripTitle?.isEmpty ?? true)
                return acc + (hasFn ? 0 : 1)
            }
            result.remoteFunctionCounts = Self.functionDistribution(
                rawValues: active.map { $0.tripFunction }
            )
        } catch {
            result.error = error.localizedDescription
        }

        lastAuditResult = result
        return result
    }

    /// Scan local trips and force-repair any whose `vineyardId` is missing or
    /// mismatched, when all paddocks resolve to `selectedVineyardId`. Then runs
    /// a normal sync so repaired trips are pushed to Supabase.
    /// - Returns: A summary of what was scanned/repaired/pushed/skipped.
    func repairVineyardIds(selectedVineyardId: UUID) async -> RepairResult {
        var result = RepairResult()
        guard let store else { return result }

        let paddockVineyard = Dictionary(
            store.paddocks.map { ($0.id, $0.vineyardId) },
            uniquingKeysWith: { first, _ in first }
        )

        let snapshot = store.trips
        result.scanned = snapshot.count

        var repairedIds: [UUID] = []
        for trip in snapshot {
            if trip.vineyardId == selectedVineyardId {
                result.alreadyCorrect += 1
                continue
            }
            if trip.paddockIds.isEmpty {
                result.skipped.append((trip.id, "no paddocks on trip"))
                continue
            }
            let resolved = trip.paddockIds.compactMap { paddockVineyard[$0] }
            if resolved.count != trip.paddockIds.count {
                result.skipped.append((trip.id, "paddock(s) missing locally — cannot infer vineyard"))
                continue
            }
            let uniqueVineyards = Set(resolved)
            if uniqueVineyards.count > 1 {
                result.skipped.append((trip.id, "paddocks span multiple vineyards"))
                continue
            }
            guard let onlyVineyard = uniqueVineyards.first else {
                result.skipped.append((trip.id, "could not resolve vineyard"))
                continue
            }
            if onlyVineyard != selectedVineyardId {
                result.skipped.append((trip.id, "paddocks belong to another vineyard (\(onlyVineyard))"))
                continue
            }
            var repaired = trip
            repaired.vineyardId = selectedVineyardId
            store.applyRemoteTripUpsert(repaired)
            markTripDirty(trip.id)
            repairedIds.append(trip.id)
        }
        result.repaired = repairedIds.count

        if !repairedIds.isEmpty {
            let pendingBefore = metadata.pendingUpserts.keys.filter { repairedIds.contains($0) }.count
            await sync(vineyardId: selectedVineyardId)
            let pendingAfter = metadata.pendingUpserts.keys.filter { repairedIds.contains($0) }.count
            result.pushed = max(0, pendingBefore - pendingAfter)
            if case let .failure(message) = syncStatus {
                result.syncError = message
            }
        }
        return result
    }

    // MARK: - Push

    func pushLocalTrips(vineyardId: UUID) async throws {
        guard let store else { return }
        // Refresh even when a preflight throws or all work is held/reconciled.
        // An old count must not survive merely because no payload was sent.
        defer { SyncIssueCenter.shared.notePending(entity: "Trips", count: metadata.pendingUpserts.count) }
        // Import ID-only legacy deletes before ANY retained creation recovery runs.
        for (id, timestamp) in metadata.pendingDeletes {
            _ = try store.recoverTripDeletionIntent(id: id, queuedAt: timestamp, established: metadata.isParentEstablished(id))
        }
        // Journal-first deletion survives a crash before legacy metadata publication.
        for intent in try store.tripDeletionJournal.load().intents.values where intent.acknowledgement == nil {
            if metadata.pendingDeletes[intent.trip] == nil { metadata.markDeleted(intent.trip, at: intent.queuedAt) }
        }
        await store.recoverLegacySprayReceipts()
        let accepted = try store.unchangedAcceptedLegacySprays().map { $0.trip.id }
        metadata.clearDirty(accepted)
        SyncIssueCenter.shared.clearIssues(accepted)
        metadata.markParentsEstablished(accepted)
        try store.reconcileLegacySpraySaves(isolatingHeldFailures: true)
        let createdBy = auth?.userId
        var firstUploadError: Error?
        // Global legacy metadata is not scoped to account/vineyard. Never
        // attempt an upload, mark failed, or infer a deletion for IDs that
        // are not in the current selected-vineyard Trip snapshot. In
        // particular this protects other-vineyard and tombstoned history.
        // This filter is a temporary upload *eligibility* projection only:
        // metadata.pendingUpserts and all original evidence stay intact.
        let selectedTrips = Dictionary(store.trips.map { ($0.id, $0.vineyardId) },
                                       uniquingKeysWith: { _, latest in latest })
        var dirty = metadata.pendingUpserts.filter { id, _ in
            TripQueuedUploadScope.classify(
                tripId: id, selectedVineyardId: vineyardId,
                selectedTrips: selectedTrips, persistedTrips: [:]
            ).eligibleForCurrentVineyardUpload
        }
        for id in Array(dirty.keys) where try store.tripDeletionJournal.isCancelled(id) || store.isLegacySpraySyncHeld(trip: id)
            || TripCancellationIntentStore.shared.blocksReplay(tripId: id) {
            dirty.removeValue(forKey: id)
        }
        // A deterministic server answer is not re-sent on every sweep. The
        // Trip, its tank sessions and its saved actions stay exactly as they
        // are and its reason stays on screen; only the network attempt waits.
        let sweepStartedAt = Date()
        for id in Array(dirty.keys) where retryThrottle.isCoolingDown(id, now: sweepStartedAt) {
            dirty.removeValue(forKey: id)
        }
        // The original queued revision is immutable evidence. If an independent
        // server Tank End is incorporated before uploading, use the NEW durable
        // local revision for that projection, not the stale preflight timestamp.
        var uploadRevisions = dirty
        if !dirty.isEmpty {
            // An admin end wins over an offline active snapshot regardless of its
            // client timestamp. Read before replay; do not upload that snapshot.
            let serverTrips = try await repository.fetchAllTrips(vineyardId: vineyardId)
            let serverIds = Set(serverTrips.map { $0.id })
            let acceptedIds = Set(try store.acceptedLegacySprayPairs(vineyard: vineyardId).map { $0.trip.id })
            for id in Array(dirty.keys) where acceptedIds.contains(id) && !serverIds.contains(id) {
                dirty.removeValue(forKey: id)
                metadata.markUpsertsFailed([id])
            }
            let endedOnServer = serverTrips.filter {
                dirty[$0.id] != nil && $0.endTime != nil && $0.deletedAt == nil
            }
            let endedIds = Set(endedOnServer.map(\.id))
            for ended in endedOnServer {
                await applyRemote(ended, vineyardId: vineyardId, store: store)
            }
            let byId = Dictionary(store.trips.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            // Build a paddockId -> vineyardId lookup for repair inference.
            let paddockVineyard = Dictionary(
                store.paddocks.map { ($0.id, $0.vineyardId) },
                uniquingKeysWith: { first, _ in first }
            )
            var payloads: [BackendTripUpsert] = []
            var pushedIds: [UUID] = []
            var skipped: [(UUID, String)] = []
            var deferredEndIds: Set<UUID> = []
            for (tripId, ts) in dirty {
                if try store.tripDeletionJournal.isCancelled(tripId) { continue }
                // A snapshot disappearing after the initial scope projection
                // must remain in the original global queue. Never convert
                // its absence into a failed request or reconstruct another
                // vineyard's Trip from a guessed owner.
                guard var trip = byId[tripId] else { continue }
                try store.requireLegacySpraySyncAdmission(trip: tripId)
                if endedIds.contains(tripId) { continue }
                if trip.vineyardId != vineyardId {
                    // Try to repair: only if every paddock on the trip resolves to the
                    // currently selected vineyard. Never guess across vineyards.
                    let resolved = trip.paddockIds.compactMap { paddockVineyard[$0] }
                    let allMatch = !resolved.isEmpty
                        && resolved.count == trip.paddockIds.count
                        && resolved.allSatisfy { $0 == vineyardId }
                    if allMatch {
                        trip.vineyardId = vineyardId
                        store.applyRemoteTripUpsert(trip)
                        #if DEBUG
                        print("[TripSync] repaired trip \(tripId) vineyard_id from paddockIds")
                        #endif
                    } else {
                        skipped.append((tripId, "vineyard mismatch (trip=\(trip.vineyardId), selected=\(vineyardId))"))
                        continue
                    }
                }
                if !trip.isActive && shouldDeferEndedTrip(tripId) {
                    // Phase 5 hold. The trip is uploaded with its TRUE ended
                    // state. Reactivating it here (is_active = true while the
                    // payload omits the nil end_time) left the server showing an
                    // ended trip as active and deadlocked the actual-use queue.
                    // The hold now only keeps the trip queued locally until its
                    // actuals clear; it never falsifies server state.
                    deferredEndIds.insert(tripId)
                    if trip.coverageBasis != .legacy {
                        // Phase 5 dependency order for occurrence Trips:
                        // 1. Verify original tank sessions in the local Trip;
                        // 2. Upload/read back ONLY those sessions on the existing parent;
                        // 3. Let Tank Actual Use upload in the sweep coordinator;
                        // 4. Replay the original immutable finalise operation
                        //    on the next Trip pass, then complete linked Spray.
                        // Previously step 2 was skipped, causing the Trip/Actual
                        // and Spray completion to wait on one another forever.
                        let required = requiredTankSessions(tripId)
                        var missing = TankDependencyVerification.missing(
                            required: required, in: TankDependencyVerification.ids(trip.tankSessions))
                        if !missing.isEmpty, let actor = store.currentUserIdProvider?() {
                            // Build 210 recovery: the original Start Tank code
                            // assigned the exact same timestamp to the original
                            // tank start and the confirmed Actual Use. The local
                            // Actual is retained even if an old server pull
                            // replaced the Trip snapshot with zero sessions.
                            // Restore only those independently recorded facts.
                            let scope = TripOccurrenceJournal.Scope(
                                ownerId: actor.uuidString.lowercased(),
                                vineyardId: vineyardId.uuidString.lowercased(),
                                tripId: tripId.uuidString.lowercased())
                            if let journal = try? TripOccurrenceJournal(scope: scope),
                               let state = try? journal.load(),
                               state.heldReason == nil,
                               state.pending.contains(where: {
                                   $0.rpc == "finalize_trip_occurrences_v1"
                               }) {
                                let linked = Set(store.sprayRecords.filter {
                                    $0.canonicalTripId == tripId &&
                                    $0.vineyardId == vineyardId &&
                                    !$0.isTemplate
                                }.map(\.id))
                                let actuals = confirmedTankActuals(tripId).filter {
                                    $0.tripId == tripId && $0.vineyardId == vineyardId
                                }
                                if let recovered = ConfirmedTankStartRecovery.restore(
                                    trip: trip, missingSessionIds: missing,
                                    confirmedActuals: actuals,
                                    linkedSprayIds: linked, ownerId: actor
                                ) {
                                    // This local disk write must succeed BEFORE any
                                    // parent/session/actual network replay. If not,
                                    // the original actual and End WAL remain held.
                                    try store.updateTripOrThrow(recovered)
                                    trip = recovered
                                    missing = TankDependencyVerification.missing(
                                        required: required,
                                        in: TankDependencyVerification.ids(trip.tankSessions))
                                }
                            }
                        }
                        if !missing.isEmpty {
                            tankDependencyHolds[tripId] = TankDependencyVerification.requiredSessionMissing
                            metadata.markUpsertsFailed([tripId])
                            SyncIssueCenter.shared.recordFailure(
                                id: tripId, entity: "Trips",
                                detail: SyncFailureDetail(
                                    kind: .permanent,
                                    reasonCode: TankDependencyVerification.requiredSessionMissing,
                                    friendlyMessage: "This Trip is missing the original tank session recorded with its actual mix. The exact actual amounts are retained; no session was invented.",
                                    technicalDetail: "code: original occurrence tank session absent from local Trip; individual evidence recovery required"),
                                queuedAt: ts, payloadKeys: [], vineyardId: vineyardId)
                            continue
                        }
                        if !required.isEmpty {
                            do {
                                try await repository.establishOccurrenceTankSessions(
                                    BackendTrip.upsert(from: trip, createdBy: createdBy, clientUpdatedAt: ts),
                                    required: required)
                                // The server has independently confirmed the original parent
                                // with its required tank sessions. Actual Use can now upload,
                                // but original Trip finalisation is still unacknowledged.
                                metadata.markParentsEstablished([tripId])
                                tankDependencyHolds.removeValue(forKey: tripId)
                                retryThrottle.clear(tripId)
                                // Clearing an obsolete error is NOT a Trip completion
                                // receipt: the original finalise journal stays queued.
                                SyncIssueCenter.shared.clearIssues([tripId])
                            } catch let failure as TripSyncStageFailure {
                                // The stage that stopped, the request, the HTTP status
                                // and the server's own code are kept. Evidence is not
                                // touched: the original Trip, sessions and journal stay.
                                tankDependencyHolds[tripId] = TankDependencyVerification.patchReadbackMismatch
                                metadata.markUpsertsFailed([tripId])
                                retryThrottle.record(failure, now: Date())
                                SyncIssueCenter.shared.recordFailure(
                                    id: tripId, entity: "Trips", detail: failure.syncFailureDetail,
                                    queuedAt: ts, payloadKeys: [], vineyardId: vineyardId)
                            } catch {
                                tankDependencyHolds[tripId] = TankDependencyVerification.patchReadbackMismatch
                                metadata.markUpsertsFailed([tripId])
                                SyncIssueCenter.shared.recordFailure(
                                    id: tripId, entity: "Trips",
                                    detail: SyncFailureDetail(
                                        kind: .retryable,
                                        reasonCode: TankDependencyVerification.patchReadbackMismatch,
                                        friendlyMessage: "Original tank-session upload has not been verified; its actual mix and Trip end are retained for retry.",
                                        technicalDetail: "code: occurrence parent tank stage not independently acknowledged"),
                                    queuedAt: ts, payloadKeys: [], vineyardId: vineyardId)
                            }
                        }
                        continue
                    }
                }
                if let remote = serverTrips.first(where: { $0.id == tripId })?.toTrip(), trip.isActive {
                    // A Portal administrator may have ended the current tank
                    // while this phone was offline. Accept the server End on the
                    // SAME session before any queued active snapshot is replayed.
                    // A mismatch is protected, never silently overwritten.
                    guard let accepted = TankPathAttribution.adoptingServerTankEnds(
                        local: trip, remote: remote
                    ), let preserved = TankPathAttribution.mergingRecordedPaths(
                        local: accepted, remote: remote
                    ) else {
                        skipped.append((tripId, "Server tank end differs from the retained device session; upload held for review."))
                        metadata.markUpsertsFailed([tripId])
                        continue
                    }
                    if preserved != trip {
                        // This is a durable local state change, not an upload ACK.
                        // The source GPS, actual chemicals and pending queue
                        // remain intact. Future UI sees the server-ended tank.
                        try store.updateTripOrThrow(preserved)
                        uploadRevisions[tripId] = metadata.pendingUpserts[tripId] ?? Date()
                    }
                    trip = preserved
                }
                // Phase B: never acknowledge tank progress that lacks a session an actual depends on.
                let required = requiredTankSessions(tripId)
                if !TankDependencyVerification.missing(required: required, in: TankDependencyVerification.ids(trip.tankSessions)).isEmpty {
                    tankDependencyHolds[tripId] = TankDependencyVerification.requiredSessionMissing
                    metadata.markUpsertsFailed([tripId])
                    SyncIssueCenter.shared.recordFailure(id: tripId, entity: "Trips",
                        detail: SyncFailureDetail(kind: .permanent, reasonCode: TankDependencyVerification.requiredSessionMissing,
                            friendlyMessage: "A Tank actual's tank session is missing from this Trip. Evidence is retained for review.",
                            technicalDetail: "code: \(TankDependencyVerification.requiredSessionMissing); trip retained locally"),
                        queuedAt: ts, payloadKeys: [], vineyardId: vineyardId)
                    skipped.append((tripId, TankDependencyVerification.requiredSessionMissing))
                    continue
                }
                payloads.append(BackendTrip.upsert(
                    from: trip, createdBy: createdBy, clientUpdatedAt: uploadRevisions[tripId] ?? ts
                ))
                pushedIds.append(tripId)
            }
            let result = await SyncQueuePush.run(
                entity: "Trips",
                ids: pushedIds,
                payloads: payloads,
                queuedAt: uploadRevisions,
                vineyardId: vineyardId
            ) { payloads in
                do { try await repository.upsertTrips(payloads) }
                catch let failure as TripSyncStageFailure {
                    // Remember a deterministic answer so the next sweep does
                    // not send the identical request again.
                    retryThrottle.record(failure, now: Date())
                    throw failure
                }
            }
            // The parent row demonstrably exists for everything uploaded, so
            // children may upload even while finalisation stays queued.
            metadata.markParentsEstablished(result.uploaded)
            for id in result.uploaded { retryThrottle.clear(id) }
            // Phase B: a Trip whose actuals depend on tank sessions stays queued until an exact
            // server readback contains every required session.
            var unverifiedTank: Set<UUID> = []
            for id in result.uploaded {
                let required = requiredTankSessions(id)
                guard !required.isEmpty else { continue }
                do {
                    let serverIds = try await repository.fetchTankSessionIds(tripId: id, vineyardId: vineyardId)
                    if let serverIds, TankDependencyVerification.missing(required: required, in: serverIds).isEmpty {
                        tankDependencyHolds.removeValue(forKey: id)
                    } else {
                        unverifiedTank.insert(id)
                        tankDependencyHolds[id] = TankDependencyVerification.patchReadbackMismatch
                    }
                } catch is TankSessionReadbackUnsupported {
                    // Test transports only; the payload pre-check above still applied.
                } catch {
                    unverifiedTank.insert(id)
                    tankDependencyHolds[id] = TankDependencyVerification.patchReadbackMismatch
                }
            }
            metadata.clearDirty(result.uploaded.filter { !unverifiedTank.contains($0) && (try? store.tripDeletionJournal.isCancelled($0)) == false })
            for id in result.uploaded where deferredEndIds.contains(id) && shouldDeferEndedTrip(id) {
                // Still waiting on actual-use rows: keep the trip queued so the
                // finalisation stage re-runs once they clear.
                metadata.markDirty(id, at: Date())
            }
            metadata.markUpsertsFailed(result.failed)
            firstUploadError = result.firstRetryableError
            #if DEBUG
            if !skipped.isEmpty {
                for (id, reason) in skipped {
                    print("[TripSync] skipped trip \(id): \(reason)")
                }
            }
            #endif
        }

        // Pending explicit work-task-link clears (offline/failed unlinks). The
        // bulk upsert above omits nil optionals (partial-sync guardrail), so an
        // unlink only reaches the server through this dedicated null patch.
        let clears = metadata.pendingWorkTaskClears
        if !clears.isEmpty {
            let byIdNow = Dictionary(store.trips.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            for (tripId, _) in clears {
                if try store.tripDeletionJournal.isCancelled(tripId) || store.isLegacySpraySyncHeld(trip: tripId)
                    || TripCancellationIntentStore.shared.blocksReplay(tripId: tripId) { continue }
                // Conflict guard: if the user re-linked this trip locally before
                // the sync, the newer link wins — drop the stale clear and let the
                // upsert carry the link instead of wiping it.
                if let current = byIdNow[tripId], current.workTaskId != nil {
                    metadata.clearWorkTaskClears([tripId])
                    continue
                }
                do {
                    try await repository.updateTripWorkTaskLink(id: tripId, workTaskId: nil)
                    metadata.clearWorkTaskClears([tripId])
                } catch {
                    if Self.isMissingRowError(error) {
                        // Row no longer exists remotely — nothing left to clear.
                        metadata.clearWorkTaskClears([tripId])
                    }
                    #if DEBUG
                    print("[TripSync] work-task clear failed for \(tripId): \(error.localizedDescription)")
                    #endif
                    // Otherwise keep the pending clear for the next sync.
                }
            }
        }

        let deletes = metadata.pendingDeletes
        var deleteFailures: [String] = []
        let account = store.currentUserIdProvider?()
        let current = store.remoteApplicationCurrentCheck()
        for (tripId, timestamp) in deletes {
            guard let intent = try store.tripDeletionJournal.load().intents[tripId] else { continue }
            do {
                let scopeCurrent = { current() && store.currentUserIdProvider?() == account && store.selectedVineyardId == vineyardId }
                if intent.scope?.account == account, intent.scope?.vineyard == vineyardId, scopeCurrent() {
                    try store.finishTripDeletionLocally(intent,
                        preserveLinkedRecords: TripDeletionJournal.canReverify(intent) || intent.acknowledgement != nil)
                }
                let acknowledged = try await store.tripDeletionJournal.replay(intent, account: account, vineyard: vineyardId,
                    isCurrent: scopeCurrent) { scope in
                        if TripDeletionJournal.canReverify(intent) {
                            return try await self.repository.reverifyDeletion(scope, isCurrent: scopeCurrent)
                        }
                        return try await self.repository.resolveDeletion(scope, isCurrent: scopeCurrent)
                    }
                if acknowledged {
                    // Journal proof is durable first; metadata cleanup must also succeed before reporting completion.
                    try metadata.clearDeletedRevision(tripId, at: timestamp)
                } else { deleteFailures.append(intent.reviewReason ?? "TRIP_DELETE_ORIGINAL_ACCOUNT_OR_VINEYARD_REQUIRED") }
            } catch let held as TripDeletionJournal.Held {
                try store.tripDeletionJournal.hold(intent, reason: held.reason)
                deleteFailures.append(held.reason)
            } catch is VineyardWriteAuthority.Restricted {
                try store.tripDeletionJournal.hold(intent, reason: "TRIP_DELETE_ACCESS_UNVERIFIED")
                deleteFailures.append("TRIP_DELETE_ACCESS_UNVERIFIED")
            } catch {
                metadata.markDeletesFailed([tripId])
                deleteFailures.append(error.localizedDescription)
            }
        }
        if !deleteFailures.isEmpty {
            errorMessage = "Trip deletions retained: \(deleteFailures.first ?? "unresolved")"
        }
        if let firstUploadError { throw firstUploadError }
    }

    private static func isMissingRowError(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        if message.contains("trip not found") { return true }
        if message.contains("not found") { return true }
        if message.contains("pgrst116") { return true }
        if message.contains("no rows") { return true }
        if message.contains("0 rows") { return true }
        return false
    }

    // MARK: - Pull

    func pullRemoteTrips(vineyardId: UUID) async throws {
        guard let store else { return }
        let isCurrent = store.remoteApplicationCurrentCheck()
        let lastSync = metadata.lastSync(for: vineyardId)
        let remote = try await repository.fetchTrips(vineyardId: vineyardId, since: lastSync)

        // Initial sync: if remote is empty AND we have local trips AND we have
        // never synced before, push them all up. Also include any trips whose
        // paddockIds all resolve to the selected vineyard (repair stale
        // vineyardId on legacy local trips).
        if remote.isEmpty, lastSync == nil {
            let paddockVineyard = Dictionary(
                store.paddocks.map { ($0.id, $0.vineyardId) },
                uniquingKeysWith: { first, _ in first }
            )
            var localForVineyard: [Trip] = []
            let acceptedOriginalIds = Set(try store.acceptedLegacySprayPairs(vineyard: vineyardId).map { $0.trip.id })
            for trip in store.trips {
                if try store.tripDeletionJournal.isCancelled(trip.id) { continue }
                // Immutable acceptance is not permission to recreate an absent/deleted row through initial fallback.
                if acceptedOriginalIds.contains(trip.id) { continue }
                if try store.isLegacySpraySyncHeld(trip: trip.id) { continue }
                if trip.vineyardId == vineyardId {
                    localForVineyard.append(trip)
                    continue
                }
                let resolved = trip.paddockIds.compactMap { paddockVineyard[$0] }
                let allMatch = !resolved.isEmpty
                    && resolved.count == trip.paddockIds.count
                    && resolved.allSatisfy { $0 == vineyardId }
                if allMatch {
                    var repaired = trip
                    repaired.vineyardId = vineyardId
                    store.applyRemoteTripUpsert(repaired)
                    localForVineyard.append(repaired)
                }
            }
            // An empty remote result is not evidence that an old active cache
            // is safe to recreate. New active trips use the explicit dirty queue.
            localForVineyard.removeAll(where: { $0.isActive || $0.endTime != nil })
            if !localForVineyard.isEmpty {
                let now = Date()
                let createdBy = auth?.userId
                let payloads = localForVineyard.map {
                    BackendTrip.upsert(from: $0, createdBy: createdBy, clientUpdatedAt: now)
                }
                try await repository.upsertTrips(payloads)
            }
            return
        }

        try await ResponsiveRemoteApplication.forEach(remote, isCurrent: isCurrent) { backendTrip in
            await store.prepareRemoteTripCache()
            guard isCurrent(), self.store === store else { throw CancellationError() }
            await applyRemote(backendTrip, vineyardId: vineyardId, store: store)
        }
    }

    private func applyRemote(_ backendTrip: BackendTrip, vineyardId: UUID, store: MigratedDataStore) async {
        // A pull cannot acknowledge a newer deletion or erase retained edits. Scoped
        // tombstone acknowledgement is owned solely by the deletion replay above.
        guard (try? store.tripDeletionJournal.isCancelled(backendTrip.id)) == false,
              metadata.pendingDeletes[backendTrip.id] == nil else { return }
        guard (try? store.isLegacySpraySyncHeld(trip: backendTrip.id)) == false else {
            metadata.markUpsertsFailed([backendTrip.id]); return
        }
        // P0 Phase A anti-resurrection: while a cancellation is open or acknowledged, only the
        // server tombstone may change this Trip locally; a live row never overwrites retained evidence.
        if backendTrip.deletedAt == nil, TripCancellationIntentStore.shared.blocksReplay(tripId: backendTrip.id) { return }
        // Soft-deleted remotely. A tombstone is NOT proof that an unrelated
        // original queued upload was accepted or may be thrown away. Deletion
        // acknowledgement belongs to the independent deletion journal.
        if backendTrip.deletedAt != nil {
            guard TripServerTombstonePolicy.mayApplyRemoteDeletion(
                hasOriginalPendingUpload: metadata.pendingUpserts[backendTrip.id] != nil
            ) else {
                syncStatus = .failure("A server Trip is deleted but the device retains original upload evidence. Reconciliation is required; nothing was deleted.")
                return
            }
            store.applyRemoteTripDelete(backendTrip.id)
            // No original upsert or local deletion exists here. Do not
            // acknowledge any write merely because this server ID exists.
            metadata.clearWorkTaskClears([backendTrip.id])
            return
        }

        // Occurrence journals own pending overlays independently of timestamp-based snapshot dirtiness.
        if TripOccurrenceCoverage.basis(backendTrip.occurrenceCoverage) != .legacy ||
            store.trips.first(where: { $0.id == backendTrip.id }).map({ $0.coverageBasis != .legacy }) == true {
            var mapped = backendTrip.toTrip()
            metadata.markParentsEstablished([backendTrip.id])
            do {
                guard let raw = backendTrip.occurrenceCoverage else { throw TripOccurrenceCoverage.Failure.updateRequired }
                _ = try TripOccurrenceCoverage.requireDocument(raw)
                guard let account = store.currentUserIdProvider?() else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                let journal = try TripOccurrenceJournal(scope: .init(ownerId: account.uuidString.lowercased(),
                    vineyardId: mapped.vineyardId.uuidString.lowercased(), tripId: mapped.id.uuidString.lowercased()))
                let saved = try journal.load()
                let recovery = try await repository.fetchOccurrenceRecovery(tripId: backendTrip.id, operationIds: saved?.pending.map(\.id) ?? [])
                guard store.currentUserIdProvider?() == account else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                try journal.recover(recovery)
                // P0 build 208: a server-active pull is NOT permission to reopen
                // an End already saved on this installation. The original
                // occurrence finalisation stays in its durable, scoped journal.
                let localBeforePull = store.trips.first {
                    $0.id == mapped.id && $0.vineyardId == mapped.vineyardId
                }
                let retainedAfterRecovery = try journal.load()
                var localEndEvidence = localBeforePull
                if mapped.endTime == nil, let local = localBeforePull,
                   local.isActive, local.endTime == nil,
                   let retained = retainedAfterRecovery,
                   let finalise = retained.pending.first(where: { $0.rpc == "finalize_trip_occurrences_v1" }),
                   let recorded = finalise.action[occurrence: "metadata"]?[occurrence: "endTime"]?.occurrenceString,
                   let endedAt = TankSessionDateParser.parse(recorded),
                   let claim = try TripLocalEndClaimStore.shared.find(tripId: mapped.id.uuidString.lowercased()),
                   claim.ownerId == account.uuidString.lowercased(),
                   claim.vineyardId == mapped.vineyardId.uuidString.lowercased(),
                   claim.tripId == mapped.id.uuidString.lowercased(),
                   TankSessionReceiptMatch.sameTime(claim.endedAt, endedAt) {
                    // Build 208 could replace the ended local cache with an
                    // earlier active server snapshot. Restore ONLY the exact
                    // original local end using independently retained claim +
                    // finalise operation; never fabricate route/tank contents.
                    var repaired = local
                    repaired.isActive = false
                    repaired.isPaused = false
                    repaired.endTime = endedAt
                    store.applyRemoteTripUpsert(repaired)
                    localEndEvidence = repaired
                }
                if TripPendingEndRemotePolicy.mustPreserve(local: localEndEvidence, remote: mapped) {
                    if retainedAfterRecovery?.pending.contains(where: {
                        $0.rpc == "finalize_trip_occurrences_v1"
                    }) == true && metadata.pendingUpserts[backendTrip.id] == nil {
                        // Re-admit only the exact retained journal, not a new
                        // Trip/operation or reconstructed record.
                        metadata.markDirty(backendTrip.id, at: Date())
                    }
                    if metadata.pendingUpserts[backendTrip.id] != nil {
                        metadata.markUpsertsFailed([backendTrip.id])
                    }
                    receiptReconciliationHolds[backendTrip.id] = "TRIP_LOCAL_END_AWAITING_ORIGINAL_FINALISE"
                    syncStatus = .failure("This Trip ended on the original device; its server finalisation is pending. The local record and operation IDs remain retained.")
                    return
                }
                // The server now carries the End (or the local Trip is no longer
                // ended-pending): retire ONLY this display hold. Any other hold
                // reason belongs to a different reconciliation path.
                if receiptReconciliationHolds[backendTrip.id] == "TRIP_LOCAL_END_AWAITING_ORIGINAL_FINALISE" {
                    receiptReconciliationHolds.removeValue(forKey: backendTrip.id)
                }
                if saved != nil {
                    if backendTrip.endTime != nil, try journal.load()?.pending.isEmpty == false {
                        try journal.hold("OCCURRENCE_TRIP_CLOSED")
                    }
                    guard let retained = try journal.load() else { throw TripOccurrenceCoverage.Failure.missing }
                    mapped = try mapped.withOccurrenceProjection(retained.projected)
                    // A server snapshot can lag the original iPhone's recorded
                    // tank starts and GPS. Never erase durable local tank evidence.
                    if let original = localBeforePull, original.isActive, mapped.isActive,
                       mapped.endTime == nil, retainedAfterRecovery != nil {
                        // The on-device owner-scoped journal is durable original
                        // evidence even when a process restart temporarily
                        // loses the in-memory active-device tracking claim.
                        guard let protected = OccurrenceActiveTripEvidence.merge(
                            local: original, remote: mapped
                        ) else {
                            receiptReconciliationHolds[backendTrip.id] = "TRIP_ACTIVE_EVIDENCE_CONFLICT_HELD"
                            metadata.markUpsertsFailed([backendTrip.id])
                            syncStatus = .failure("Original active Trip tank or GPS evidence conflicts with the server. Original data is retained.")
                            return
                        }
                        mapped = protected
                    }
                    store.applyRemoteTripUpsert(mapped)
                    if retained.pending.isEmpty, retained.heldReason == nil { metadata.clearDirty([backendTrip.id]) }
                    else { syncStatus = .failure("Occurrence reconciliation pending. Saved actions are retained.") }
                } else {
                    // A read never adopts historical numeric state or fabricates operation history.
                    store.applyRemoteTripUpsert(mapped)
                    metadata.clearDirty([backendTrip.id])
                }
            } catch {
                if mapped.coverageBasis == .updateRequired { store.applyRemoteTripUpsert(mapped) }
                syncStatus = .failure("Update or reconciliation required. Occurrence evidence was retained; numeric history was not used.")
            }
            return
        }
        // An inactive, unended saved parent is not completion or activation acknowledgement.
        if backendTrip.isActive == false, backendTrip.endTime == nil,
           store.deviceActiveTripId == backendTrip.id,
           store.deviceOwnedTrip?.isActive == true {
            return
        }
        // A recorded server end stops local operation, even when its active flag is contradictory.
        let serverCompleted = backendTrip.endTime != nil
        if !serverCompleted, let pendingDirtyAt = metadata.pendingUpserts[backendTrip.id] {
            let remoteAt = backendTrip.clientUpdatedAt ?? backendTrip.updatedAt ?? .distantPast
            if pendingDirtyAt > remoteAt { return }
        }

        metadata.markParentsEstablished([backendTrip.id])
        var mapped = backendTrip.toTrip()
        if serverCompleted { mapped.isActive = false }
        let local = store.trips.first { $0.id == mapped.id }
            ?? store.deviceOwnedTrip.flatMap { $0.id == mapped.id ? $0 : nil }
        var reconciled = ActiveTripPathReconciler.reconcile(local: local, remote: mapped)
        // When only End Tank happened on the Portal, the Trip stays active.
        // Adopt the server's ended timestamps without replacing live local GPS,
        // spray evidence or pending writes. This also works when the device had
        // no dirty Trip at the instant of the remote pull.
        if !serverCompleted, let local, local.isActive, mapped.isActive,
           let serverTankEnd = TankPathAttribution.adoptingServerTankEnds(
               local: local, remote: mapped
           ), serverTankEnd != local {
            guard let merged = TankPathAttribution.mergingRecordedPaths(
                local: serverTankEnd, remote: mapped
            ) else {
                receiptReconciliationHolds[backendTrip.id] = "TRIP_SERVER_TANK_END_IDENTITY_CONFLICT"
                metadata.markUpsertsFailed([backendTrip.id])
                syncStatus = .failure("A server-ended tank conflicts with retained local tank evidence. Original data is protected.")
                return
            }
            reconciled.tankSessions = merged.tankSessions
            reconciled.activeTankNumber = merged.activeTankNumber
            if !ActiveTripPathReconciler.containsRoute(local.pathPoints, in: mapped.pathPoints) {
                reconciled.pathPoints = local.pathPoints
                reconciled.totalDistance = local.totalDistance
            }
            if local.completedPaths.contains(where: { !mapped.completedPaths.contains($0) }) {
                reconciled.completedPaths = local.completedPaths
            }
            if local.skippedPaths.contains(where: { !mapped.skippedPaths.contains($0) }) {
                reconciled.skippedPaths = local.skippedPaths
            }
        }
        var retainedUnacknowledgedEvidence = false
        if serverCompleted, let local {
            // Count is not inclusion: retain an equal/shorter divergent local branch too.
            if !ActiveTripPathReconciler.containsRoute(local.pathPoints, in: mapped.pathPoints) {
                retainedUnacknowledgedEvidence = true
                reconciled.pathPoints = local.pathPoints
                reconciled.totalDistance = local.totalDistance
            }
            // A matching server End Tank is authoritative for its end time,
            // even when the offline phone still has that session open. Never
            // adopt an unverified session ID, number or start time.
            let deviceSessions = TankPathAttribution.adoptingServerTankEnds(
                local: local, remote: mapped
            )?.tankSessions ?? local.tankSessions
            for session in deviceSessions {
                if let index = reconciled.tankSessions.firstIndex(where: { $0.id == session.id }) {
                    let serverSession = reconciled.tankSessions[index]
                    let matches = local.coverageBasis == .legacy && mapped.coverageBasis == .legacy
                        ? TankSessionReceiptMatch.terminalLegacyEquivalent(local: session, remote: serverSession)
                        : TankSessionReceiptMatch.equivalent(local: session, remote: serverSession)
                    if !matches { retainedUnacknowledgedEvidence = true }
                    // Preserve the original device evidence even if the wire
                    // representation rounded a time by less than a millisecond.
                    // This is local-only; no terminal server Trip is rewritten.
                    reconciled.tankSessions[index] = session
                } else {
                    retainedUnacknowledgedEvidence = true
                    reconciled.tankSessions.append(session)
                }
            }
            if local.completedPaths.contains(where: { !mapped.completedPaths.contains($0) }) {
                retainedUnacknowledgedEvidence = true
                reconciled.completedPaths = local.completedPaths
            }
            if local.skippedPaths.contains(where: { !mapped.skippedPaths.contains($0) }) {
                retainedUnacknowledgedEvidence = true
                reconciled.skippedPaths = local.skippedPaths
            }
            let existingIds = Set(reconciled.paddockIds)
            let missingBlocks = local.paddockIds.filter { !existingIds.contains($0) }
            retainedUnacknowledgedEvidence = retainedUnacknowledgedEvidence || !missingBlocks.isEmpty
            reconciled.paddockIds.append(contentsOf: missingBlocks)
        }
        // A server terminal row is NOT by itself a receipt for a different
        // local upload. Verify the exact original end, GPS, tank sessions,
        // linked Spray Record and actual chemical quantities before retiring
        // one pending historical Trip entry. Never write or re-end the server
        // Trip, and never silently discard a divergent local branch.
        var reconciliationHold: String? = nil
        let wasQueued = metadata.pendingUpserts[backendTrip.id] != nil
        if serverCompleted, wasQueued {
            if let local {
                reconciliationHold = CompletedTripReceiptAdmission.holdReason(local: local, remote: mapped)
                if reconciliationHold == nil, !retainedUnacknowledgedEvidence {
                    reconciliationHold = await verifyCompletedTripDependents(local: local, remote: mapped, store: store)
                }
            } else {
                // A server Trip existing with the same UUID cannot attest to a
                // missing original phone snapshot. Keep the original queued
                // operation intact for scoped/manual reconciliation.
                reconciliationHold = "TRIP_ORIGINAL_LOCAL_SNAPSHOT_UNAVAILABLE"
            }
        }
        guard store.currentUserIdProvider?() == auth?.userId,
              store.selectedVineyardId == vineyardId,
              backendTrip.vineyardId == vineyardId else { return }
        store.applyRemoteTripUpsert(reconciled)
        if retainedUnacknowledgedEvidence || reconciliationHold != nil {
            receiptReconciliationHolds[backendTrip.id] = reconciliationHold ?? "TRIP_LOCAL_EVIDENCE_DIFFERS"
            if metadata.pendingUpserts[backendTrip.id] == nil { metadata.markDirty(backendTrip.id, at: Date()) }
            metadata.markUpsertsFailed([backendTrip.id])
            errorMessage = "Completed Trip is ended on the server, but original local evidence remains held (\(reconciliationHold ?? "TRIP_LOCAL_EVIDENCE_DIFFERS")). The Trip was not reopened or uploaded again."
            syncStatus = .failure(errorMessage ?? "Trip reconciliation held.")
        } else {
            // Clear only the *same* original queued Trip after independent
            // readback and a consistent scope. Unattributed/global queue IDs
            // and all local source journals remain untouched.
            if wasQueued {
                do {
                    try metadata.acknowledgeVerifiedCompleted(backendTrip.id)
                    receiptReconciliationHolds.removeValue(forKey: backendTrip.id)
                    SyncIssueCenter.shared.clearIssues([backendTrip.id])
                } catch {
                    // A server match without durable on-device acknowledgement
                    // is still pending. Keep the original failed queue and
                    // avoid a false green state or loss after cold restart.
                    receiptReconciliationHolds[backendTrip.id] = "TRIP_VERIFIED_END_RECEIPT_PERSIST_FAILED"
                    errorMessage = "TRIP_VERIFIED_END_RECEIPT_PERSIST_FAILED: original queue retained."
                    syncStatus = .failure(errorMessage ?? "Trip receipt could not be saved.")
                }
            } else {
                metadata.clearDirty([backendTrip.id])
                receiptReconciliationHolds.removeValue(forKey: backendTrip.id)
                SyncIssueCenter.shared.clearIssues([backendTrip.id])
            }
        }
    }

    /// Only consulted for a queued ended Trip whose parent was independently
    /// read from the original vineyard. This is a read-only acknowledgement
    /// gate; it NEVER submits, recreates, deletes or edits old spray records.
    private func verifyCompletedTripDependents(
        local: Trip, remote: Trip, store: MigratedDataStore
    ) async -> String? {
        guard store.currentUserIdProvider?() == auth?.userId,
              auth?.isSignedIn == true,
              SupabaseClientProvider.shared.client.auth.currentUser?.id == auth?.userId,
              store.selectedVineyardId == local.vineyardId else {
            return "TRIP_COMPLETION_SCOPE_CHANGED"
        }
        guard local.tripFunction == TripFunction.spraying.rawValue else { return nil }
        let linked = store.sprayRecords.filter { $0.canonicalTripId == local.id }
        guard linked.count == 1, let localSpray = linked.first,
              localSpray.vineyardId == local.vineyardId else {
            return "TRIP_LINKED_SPRAY_LOCAL_UNCONFIRMED"
        }
        let actualStore = SprayTankActualStore.shared
        guard !actualStore.hasPending(tripId: local.id) else { return "TRIP_ACTUAL_USE_STILL_PENDING" }
        let actuals = actualStore.records.filter { $0.tripId == local.id }
        guard actuals.allSatisfy({ $0.vineyardId == local.vineyardId &&
            $0.sprayRecordId == localSpray.id && actualStore.dependencyHolds[$0.id] == nil }) else {
            return "TRIP_ACTUAL_USE_IDENTITY_HELD"
        }
        let serverSessionIds = TankDependencyVerification.ids(remote.tankSessions)
        guard TankDependencyVerification.requiredSessions(tripId: local.id, actuals: actuals)
              .isSubset(of: serverSessionIds) else {
            return "TRIP_ACTUAL_SESSION_NOT_ON_SERVER"
        }
        do {
            let serverSprays = try await SprayCompletionRepository().fetchLinked(tripId: local.id)
                .map { $0.toSprayRecord() }
            guard serverSprays.count == 1, serverSprays[0].id == localSpray.id,
                  TrackedSprayCompletionSync.completionIssue(
                    trip: remote, sprays: serverSprays,
                    expectedIds: Set(actuals.map(\.sprayRecordId)).union([localSpray.id])
                  ) == nil else { return "TRIP_SERVER_SPRAY_COMPLETION_UNCONFIRMED" }
            guard let completionIntents = try? TrackedSprayCompletionSync.shared.intents(),
                  !completionIntents.contains(where: { $0.tripId == local.id }) else {
                return "TRIP_ORIGINAL_COMPLETION_INTENT_PENDING"
            }
            // The exact water volume and each recorded chemical amount must
            // match independent server readback, not just a session count.
            for actual in actuals {
                let serverActual = try await actualStore.actualReader(actual)
                guard TankDependencyVerification.actualMatches(local: actual, server: serverActual) else {
                    return "TRIP_ACTUAL_AMOUNT_READBACK_MISMATCH"
                }
            }
            guard store.currentUserIdProvider?() == auth?.userId,
                  store.selectedVineyardId == local.vineyardId,
                  SupabaseClientProvider.shared.client.auth.currentUser?.id == auth?.userId else {
                return "TRIP_COMPLETION_SCOPE_CHANGED"
            }
            return nil
        } catch {
            return "TRIP_COMPLETION_DEPENDENT_SERVER_READ_FAILED"
        }
    }
}

// MARK: - Metadata

@MainActor
final class TripSyncMetadata {
    private let persistence: PersistenceStore
    private let key: String = "vinetrack_trip_sync_metadata"
    private var state: State

    nonisolated struct State: Codable, Sendable {
        var lastSyncByVineyard: [UUID: Date] = [:]
        var pendingUpserts: [UUID: Date] = [:]
        var pendingDeletes: [UUID: Date] = [:]
        /// Records whose last upsert/delete push failed while still pending.
        var failedUpserts: Set<UUID> = []
        var failedDeletes: Set<UUID> = []
        /// Trips needing an explicit `work_task_id = null` patch (offline/failed
        /// unlinks). Keyed by trip id with the time the clear was enqueued.
        var pendingWorkTaskClears: [UUID: Date] = [:]
        /// Trips whose parent row is known to exist on the server. Separate from
        /// the pending queue so a trip held only for Phase 5 finalisation does
        /// not look like a missing parent to its children.
        var establishedParents: Set<UUID> = []

        init() {}

        enum CodingKeys: String, CodingKey {
            case lastSyncByVineyard, pendingUpserts, pendingDeletes
            case failedUpserts, failedDeletes, pendingWorkTaskClears
            case establishedParents
        }

        // Lenient decode so newly added fields don't wipe persisted pending
        // state when upgrading from an older on-disk format.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastSyncByVineyard = try c.decodeIfPresent([UUID: Date].self, forKey: .lastSyncByVineyard) ?? [:]
            pendingUpserts = try c.decodeIfPresent([UUID: Date].self, forKey: .pendingUpserts) ?? [:]
            pendingDeletes = try c.decodeIfPresent([UUID: Date].self, forKey: .pendingDeletes) ?? [:]
            failedUpserts = try c.decodeIfPresent(Set<UUID>.self, forKey: .failedUpserts) ?? []
            failedDeletes = try c.decodeIfPresent(Set<UUID>.self, forKey: .failedDeletes) ?? []
            pendingWorkTaskClears = try c.decodeIfPresent([UUID: Date].self, forKey: .pendingWorkTaskClears) ?? [:]
            establishedParents = try c.decodeIfPresent(Set<UUID>.self, forKey: .establishedParents) ?? []
        }
    }

    init(persistence: PersistenceStore = .shared) {
        self.persistence = persistence
        self.state = persistence.load(key: key) ?? State()
    }

    var pendingUpserts: [UUID: Date] { state.pendingUpserts }
    var pendingDeletes: [UUID: Date] { state.pendingDeletes }
    var pendingWorkTaskClears: [UUID: Date] { state.pendingWorkTaskClears }

    var failedUpsertIds: Set<UUID> { state.failedUpserts }
    var failedDeleteIds: Set<UUID> { state.failedDeletes }
    func isUpsertFailed(_ id: UUID) -> Bool { state.failedUpserts.contains(id) }

    var establishedParentIds: Set<UUID> { state.establishedParents }
    func isParentEstablished(_ id: UUID) -> Bool { state.establishedParents.contains(id) }

    /// Record that these trip rows demonstrably exist on the server.
    func markParentsEstablished(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let before = state.establishedParents.count
        for id in ids { state.establishedParents.insert(id) }
        if state.establishedParents.count != before { save() }
    }
    func isDeleteFailed(_ id: UUID) -> Bool { state.failedDeletes.contains(id) }

    func markUpsertsFailed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.failedUpserts.insert(id) }
        save()
    }
    func markDeletesFailed(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.failedDeletes.insert(id) }
        save()
    }
    func clearUpsertFailures(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let before = state.failedUpserts.count
        for id in ids { state.failedUpserts.remove(id) }
        if state.failedUpserts.count != before { save() }
    }
    func clearDeleteFailures(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let before = state.failedDeletes.count
        for id in ids { state.failedDeletes.remove(id) }
        if state.failedDeletes.count != before { save() }
    }

    func lastSync(for vineyardId: UUID) -> Date? {
        state.lastSyncByVineyard[vineyardId]
    }

    func setLastSync(_ date: Date, for vineyardId: UUID) {
        state.lastSyncByVineyard[vineyardId] = date
        save()
    }

    func markDirty(_ id: UUID, at date: Date) {
        state.pendingUpserts[id] = date
        // A fresh local edit supersedes any stale failure for this record.
        state.failedUpserts.remove(id)
        save()
    }

    func markDeleted(_ id: UUID, at date: Date) {
        // Preserve upload/link evidence independently. Cancellation fences replay;
        // deleting a row is not an acknowledgement of any queued edit.
        state.pendingDeletes[id] = date
        save()
    }

    /// Only for an independently verified and accepted terminal Trip.
    /// Persist the exact-ID acknowledgement before updating in-memory state;
    /// a disk-full/interrupted write must never pretend the old queue cleared.
    func acknowledgeVerifiedCompleted(_ id: UUID) throws {
        guard state.pendingUpserts[id] != nil else { return }
        var next = state
        next.pendingUpserts.removeValue(forKey: id)
        next.failedUpserts.remove(id)
        try persistence.saveOrThrow(next, key: key)
        state = next
    }

    func clearDirty(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingUpserts.removeValue(forKey: id); state.failedUpserts.remove(id) }
        save()
    }

    func clearDeletedRevision(_ id: UUID, at date: Date) throws {
        guard state.pendingDeletes[id] == date else { return }
        var next = state
        next.pendingDeletes.removeValue(forKey: id)
        next.failedDeletes.remove(id)
        try persistence.saveOrThrow(next, key: key)
        state = next
    }

    func clearDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingDeletes.removeValue(forKey: id); state.failedDeletes.remove(id) }
        save()
    }

    /// Exact-ID, all-related queue stages in one durable metadata write.
    /// Cannot be used without an independently verified cancellation receipt
    /// by the outer service. Disk errors leave the original queue intact.
    func acknowledgeVerifiedCancellation(_ id: UUID) throws {
        var next = state
        next.pendingUpserts.removeValue(forKey: id)
        next.failedUpserts.remove(id)
        next.pendingDeletes.removeValue(forKey: id)
        next.failedDeletes.remove(id)
        next.pendingWorkTaskClears.removeValue(forKey: id)
        try persistence.saveOrThrow(next, key: key)
        state = next
    }

    /// Queue an explicit `work_task_id = null` clear for a trip (offline/failed
    /// unlink). Idempotent — keeps the earliest enqueue time.
    func markWorkTaskClearPending(_ id: UUID, at date: Date) {
        if state.pendingWorkTaskClears[id] == nil {
            state.pendingWorkTaskClears[id] = date
            save()
        }
    }

    func clearWorkTaskClears(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let before = state.pendingWorkTaskClears.count
        for id in ids { state.pendingWorkTaskClears.removeValue(forKey: id) }
        if state.pendingWorkTaskClears.count != before { save() }
    }

    private func save() {
        persistence.save(state, key: key)
    }
}


/// Content-limited time evidence for one original session. No chemical
/// amounts, coordinates, credentials, names or server payloads are included.
nonisolated enum TripRecoveryTimeEvidence {
    static func compare(field: String, local: Date?, remote: Date?) -> String {
        func timestamp(_ date: Date?) -> String {
            guard let date else { return "missing" }
            return String(format: "%.6f", date.timeIntervalSince1970)
        }
        let delta: String
        if let local, let remote {
            delta = String(format: "%.3f", abs(local.timeIntervalSince(remote)) * 1_000)
        } else {
            delta = local == nil && remote == nil ? "both_missing" : "presence_mismatch"
        }
        return "\(field): local_epoch_s=\(timestamp(local)); server_epoch_s=\(timestamp(remote)); absolute_delta_ms=\(delta)"
    }
}

/// Historical legacy server tank JSON can round timestamps to 3 decimal
/// places. A difference no greater than 1ms is ONLY a wire precision match,
/// not authority to alter, re-end, or replay a completed Trip. Every other
/// tank field and linked spray/actual-use receipt is still checked separately.
nonisolated enum TankSessionReceiptMatch {
    private static let maximumWireRoundoffSeconds: TimeInterval = 0.001

    static func sameTime(_ local: Date?, _ remote: Date?) -> Bool {
        switch (local, remote) {
        case (nil, nil): return true
        case let (.some(l), .some(r)):
            return abs(l.timeIntervalSince(r)) <= maximumWireRoundoffSeconds
        default: return false
        }
    }

    static func equivalent(local: TankSession, remote: TankSession) -> Bool {
        discrepancy(local: local, remote: remote) == nil
    }

    /// Stage only original progress that preserves already recorded server evidence.
    static func canStage(local: TankSession, remote: TankSession) -> Bool {
        local.id == remote.id && local.tankNumber == remote.tankNumber &&
        sameTime(local.startTime, remote.startTime) &&
        (remote.endTime == nil || sameTime(local.endTime, remote.endTime)) &&
        remote.pathsCovered.allSatisfy({ local.pathsCovered.contains($0) }) &&
        (remote.startRow == nil || local.startRow == remote.startRow) &&
        (remote.endRow == nil || local.endRow == remote.endRow) &&
        (remote.fillStartTime == nil || sameTime(local.fillStartTime, remote.fillStartTime)) &&
        (remote.fillEndTime == nil || sameTime(local.fillEndTime, remote.fillEndTime))
    }

    /// Only field and magnitude buckets are emitted; never copy private tank
    /// dates, raw JSON or recorded chemical amounts into sync diagnostics.
    private static func differenceBucket(_ local: Date?, _ remote: Date?) -> String {
        guard let local, let remote else { return "PRESENCE" }
        let delta = abs(local.timeIntervalSince(remote))
        if delta < 1 { return "SUBSECOND" }
        if delta < 60 { return "SECONDS" }
        if delta < 3600 { return "MINUTES" }
        return "HOURS"
    }

    /// The old iOS PersistenceStore encoded Dates using JSONEncoder.iso8601,
    /// which writes whole seconds. Its locally retained tank timestamp can
    /// therefore be .000 while the independently read server JSON preserves
    /// the original fractional second. This is NOT a general time tolerance.
    /// It is only usable for the complete, linked, legacy terminal receipt.
    private static func archivedSecondMatches(_ local: Date?, _ remote: Date?) -> Bool {
        if sameTime(local, remote) { return true }
        guard let local, let remote else { return false }
        let original = local.timeIntervalSince1970
        let server = remote.timeIntervalSince1970
        return original == floor(original) && floor(server) == original
    }

    static func terminalLegacyEquivalent(local: TankSession, remote: TankSession) -> Bool {
        discrepancy(local: local, remote: remote, legacyArchiveSeconds: true) == nil
    }

    static func discrepancy(local: TankSession, remote: TankSession, legacyArchiveSeconds: Bool = false) -> String? {
        // Explicit closure: a ternary over two static function references crashes
        // the Swift compiler's diagnostic pass (PR #50 head 39bdc353 did not compile).
        let timeMatches: (Date?, Date?) -> Bool = { local, remote in
            legacyArchiveSeconds ? archivedSecondMatches(local, remote) : sameTime(local, remote)
        }
        guard local.id == remote.id else { return "TRIP_LOCAL_TANK_SESSION_ID_DIFFERS" }
        guard local.tankNumber == remote.tankNumber else { return "TRIP_LOCAL_TANK_NUMBER_DIFFERS" }
        if !timeMatches(local.startTime, remote.startTime) {
            return "TRIP_LOCAL_TANK_START_TIME_DIFFERS_\(differenceBucket(local.startTime, remote.startTime))"
        }
        if !timeMatches(local.endTime, remote.endTime) {
            return "TRIP_LOCAL_TANK_END_TIME_DIFFERS_\(differenceBucket(local.endTime, remote.endTime))"
        }
        guard local.pathsCovered == remote.pathsCovered, local.startRow == remote.startRow,
              local.endRow == remote.endRow else { return "TRIP_LOCAL_TANK_PATHS_DIFFER" }
        if !timeMatches(local.fillStartTime, remote.fillStartTime) {
            return "TRIP_LOCAL_TANK_FILL_START_DIFFERS_\(differenceBucket(local.fillStartTime, remote.fillStartTime))"
        }
        if !timeMatches(local.fillEndTime, remote.fillEndTime) {
            return "TRIP_LOCAL_TANK_FILL_END_DIFFERS_\(differenceBucket(local.fillEndTime, remote.fillEndTime))"
        }
        return nil
    }
}

/// A narrow recovery for build 210's "Actual exists, Trip has zero tank
/// sessions" condition. Production Start Tank assigns one immutable timestamp
/// to BOTH TankSession.startTime and SprayTankActual.confirmedAt. Therefore,
/// when the original owner/Trip/Spray/session identity all match, these facts
/// are already durable in the confirmed Actual: not guessed.
nonisolated enum ConfirmedTankStartRecovery {
    static func restore(
        trip: Trip, missingSessionIds: Set<String>,
        confirmedActuals: [SprayTankActual], linkedSprayIds: Set<UUID>,
        ownerId: UUID
    ) -> Trip? {
        guard trip.coverageBasis == .occurrence, !trip.isActive,
              let endedAt = trip.endTime, endedAt >= trip.startTime,
              !missingSessionIds.isEmpty, linkedSprayIds.count == 1,
              Set(trip.tankSessions.map(\.id)).count == trip.tankSessions.count,
              Set(trip.tankSessions.map(\.tankNumber)).count == trip.tankSessions.count
        else { return nil }
        var recovered = trip
        var events: [String] = []
        for requiredId in missingSessionIds.sorted() {
            guard let sessionId = UUID(uuidString: requiredId),
                  !recovered.tankSessions.contains(where: { $0.id == sessionId }) else {
                return nil
            }
            let matches = confirmedActuals.filter {
                $0.tripId == trip.id && $0.vineyardId == trip.vineyardId &&
                $0.confirmedBy == ownerId && linkedSprayIds.contains($0.sprayRecordId) &&
                TankDependencyVerification.normalized($0.tankSessionId) == requiredId
            }
            // A conflicting correction, alternative identity, invalid time or
            // reused tank number must remain a protected hold.
            guard matches.count == 1, let actual = matches.first,
                  actual.tankNumber >= 1,
                  actual.confirmedAt >= trip.startTime,
                  actual.confirmedAt <= endedAt,
                  !recovered.tankSessions.contains(where: { $0.tankNumber == actual.tankNumber })
            else { return nil }
            recovered.tankSessions.append(TankSession(
                id: sessionId, tankNumber: actual.tankNumber,
                startTime: actual.confirmedAt
            ))
            recovered.totalTanks = max(recovered.totalTanks, actual.tankNumber)
            // End time, row start/end, fill times and paths are NOT present
            // in the immutable Actual; leave them absent, never infer.
            events.append("tank=\(sessionId.uuidString.lowercased()) actual=\(actual.id.uuidString.lowercased())")
        }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        for event in events {
            recovered.manualCorrectionEvents.append(
                "\(timestamp) recovered_original_tank_start_from_confirmed_actual \(event) unverified_fields=tank_end,rows,fill,paths")
        }
        return recovered
    }
}

/// Protect an original-device active occurrence Trip against an older server
/// snapshot. Recorded tank sessions and GPS are never inferred from Actual Use.
nonisolated enum OccurrenceActiveTripEvidence {
    static func merge(local: Trip, remote: Trip) -> Trip? {
        // The shared legacy merge starts from local sessions and does not
        // copy startRow. Preserve a remotely recorded boundary when local
        // lacks it; two different recorded values must stay held, not win
        // arbitrarily. Keep this stricter policy scoped to occurrence pulls.
        var original = local
        for index in original.tankSessions.indices {
            guard let server = remote.tankSessions.first(where: { $0.id == original.tankSessions[index].id }) else { continue }
            let session = original.tankSessions[index]
            if let row = session.startRow, let remoteRow = server.startRow, row != remoteRow { return nil }
            if let row = session.endRow, let remoteRow = server.endRow, row != remoteRow { return nil }
            original.tankSessions[index].startRow = session.startRow ?? server.startRow
        }
        guard local.id == remote.id, local.vineyardId == remote.vineyardId,
              local.coverageBasis == .occurrence, remote.coverageBasis == .occurrence,
              local.isActive, remote.isActive, local.endTime == nil, remote.endTime == nil,
              Set(local.tankSessions.map(\.id)).count == local.tankSessions.count,
              Set(remote.tankSessions.map(\.id)).count == remote.tankSessions.count,
              ActiveTripPathReconciler.containsRoute(remote.pathPoints, in: local.pathPoints)
                 || ActiveTripPathReconciler.containsRoute(local.pathPoints, in: remote.pathPoints),
              let combined = TankPathAttribution.mergingRecordedPaths(local: original, remote: remote)
        else { return nil }
        var result = remote
        result.tankSessions = combined.tankSessions
        result.totalTanks = max(local.totalTanks, remote.totalTanks, combined.tankSessions.count)
        if ActiveTripPathReconciler.containsRoute(remote.pathPoints, in: local.pathPoints) {
            result.pathPoints = local.pathPoints
            result.totalDistance = local.totalDistance
            result.currentPathDistance = local.currentPathDistance
        }
        // Only the original active-device owner calls this merge.
        result.activeTankNumber = local.activeTankNumber
        result.isFillingTank = local.isFillingTank
        result.fillingTankNumber = local.fillingTankNumber
        return result
    }
}

/// Preserve a locally ended occurrence Trip when a delayed active server pull
/// arrives. The server still needs the original finalise RPC; the UI must not
/// silently revive the trip or give it an invented foreign-device claim.
nonisolated enum TripPendingEndRemotePolicy {
    static func mustPreserve(local: Trip?, remote: Trip) -> Bool {
        guard let local, local.id == remote.id, local.vineyardId == remote.vineyardId,
              !local.isActive, local.endTime != nil, remote.endTime == nil else { return false }
        return true
    }
}

/// Exact readback admission for a historically ended Trip. A fresh server
/// parent alone cannot acknowledge the old device upload: disjoint GPS,
/// changed tank contents, unacknowledged paths and different end-times stay
/// recoverable without changing server history.
nonisolated enum CompletedTripReceiptAdmission {
    static func holdReason(local: Trip, remote: Trip) -> String? {
        guard local.id == remote.id, local.vineyardId == remote.vineyardId,
              local.tripFunction == remote.tripFunction else { return "TRIP_ORIGINAL_IDENTITY_MISMATCH" }
        guard !local.isActive, !remote.isActive,
              let localEnd = local.endTime, let remoteEnd = remote.endTime,
              TankSessionReceiptMatch.sameTime(localEnd, remoteEnd) else {
            return "TRIP_ORIGINAL_END_TIME_MISMATCH"
        }
        guard ActiveTripPathReconciler.containsRoute(local.pathPoints, in: remote.pathPoints) else {
            return "TRIP_LOCAL_GPS_NOT_ON_SERVER"
        }
        // A server ID alone is not a receipt: require unique original tank
        // identities plus every field, allowing ONLY <=1ms wire precision loss.
        guard Set(local.tankSessions.map(\.id)).count == local.tankSessions.count,
              Set(remote.tankSessions.map(\.id)).count == remote.tankSessions.count else {
            return "TRIP_LOCAL_TANK_DUPLICATE_SESSION_ID"
        }
        for localSession in local.tankSessions {
            guard let remoteSession = remote.tankSessions.first(where: { $0.id == localSession.id }) else {
                return "TRIP_LOCAL_TANK_SESSION_NOT_ON_SERVER"
            }
            let legacyArchive = local.coverageBasis == .legacy && remote.coverageBasis == .legacy
            if let reason = TankSessionReceiptMatch.discrepancy(
                local: localSession, remote: remoteSession, legacyArchiveSeconds: legacyArchive
            ) {
                return reason
            }
        }
        guard local.completedPaths.allSatisfy(remote.completedPaths.contains),
              local.skippedPaths.allSatisfy(remote.skippedPaths.contains),
              Set(local.paddockIds).isSubset(of: Set(remote.paddockIds)) else {
            return "TRIP_LOCAL_ROUTE_PROGRESS_DIFFERS"
        }
        return nil
    }
}
