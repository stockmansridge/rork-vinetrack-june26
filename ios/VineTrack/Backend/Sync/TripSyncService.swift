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
    var errorMessage: String?

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
    /// Last fixed Phase B hold code per Trip; diagnostics only, never quantities.
    private(set) var tankDependencyHolds: [UUID: String] = [:]

    func configureTankDependencies(_ provider: @escaping (UUID) -> Set<String>) {
        requiredTankSessions = provider
    }

    // MARK: - Dirty tracking

    func markTripDirty(_ id: UUID) {
        metadata.markDirty(id, at: Date())
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
            "source_revision: unknown_no_verified_build_receipt",
            // This code marker proves the installed build includes the new
            // Issue #43 UI/admission logic, not its exact signed Git SHA.
            "issue43_feature_marker: separate_spray_confirmation_scoped_trip_history_auto_end_readback_v1",
            "issue43_receipt_reconciliation: server_terminal_exact_route_spray_actuals_durable_v2",
            "last_trip_sync_local: \(lastSyncDate?.ISO8601Format() ?? "unknown")",
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
                syncStatus = .failure("This vineyard has \(scoped.selectedFailedCount) failed Trip upload(s). Original evidence is retained; finished Trips will not be reopened.")
                return
            }
            metadata.setLastSync(Date(), for: vineyardId)
            if unresolved > 0 {
                let queueText = "\(scoped.selectedQueuedCount) Trip upload(s) in this vineyard, \(scoped.outsideSelectedQueuedCount) in other or unidentified original scopes"
                errorMessage = "Trip reconciliation remains held (\(queueText)). A completed download is not an upload acknowledgement. \(retained.summary ?? "Original Trip operations are retained for individual review.")"
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
                  row.endTime == local.endTime, row.isActive == false,
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
                    if trip.coverageBasis != .legacy { continue }
                }
                if let remote = serverTrips.first(where: { $0.id == tripId })?.toTrip(), trip.isActive {
                    guard let preserved = TankPathAttribution.mergingRecordedPaths(local: trip, remote: remote) else {
                        skipped.append((tripId, "Tank session identity conflicts; retained for review."))
                        continue
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
                payloads.append(BackendTrip.upsert(from: trip, createdBy: createdBy, clientUpdatedAt: ts))
                pushedIds.append(tripId)
            }
            let result = await SyncQueuePush.run(
                entity: "Trips",
                ids: pushedIds,
                payloads: payloads,
                queuedAt: dirty,
                vineyardId: vineyardId
            ) { try await repository.upsertTrips($0) }
            // The parent row demonstrably exists for everything uploaded, so
            // children may upload even while finalisation stays queued.
            metadata.markParentsEstablished(result.uploaded)
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
                if saved != nil {
                    if backendTrip.endTime != nil, try journal.load()?.pending.isEmpty == false {
                        try journal.hold("OCCURRENCE_TRIP_CLOSED")
                    }
                    guard let retained = try journal.load() else { throw TripOccurrenceCoverage.Failure.missing }
                    mapped = try mapped.withOccurrenceProjection(retained.projected)
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
        var retainedUnacknowledgedEvidence = false
        if serverCompleted, let local {
            // Count is not inclusion: retain an equal/shorter divergent local branch too.
            if !ActiveTripPathReconciler.containsRoute(local.pathPoints, in: mapped.pathPoints) {
                retainedUnacknowledgedEvidence = true
                reconciled.pathPoints = local.pathPoints
                reconciled.totalDistance = local.totalDistance
            }
            for session in local.tankSessions {
                if let index = reconciled.tankSessions.firstIndex(where: { $0.id == session.id }) {
                    if reconciled.tankSessions[index] != session {
                        retainedUnacknowledgedEvidence = true
                        reconciled.tankSessions[index] = session
                    }
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
                    SyncIssueCenter.shared.clearIssues([backendTrip.id])
                } catch {
                    // A server match without durable on-device acknowledgement
                    // is still pending. Keep the original failed queue and
                    // avoid a false green state or loss after cold restart.
                    errorMessage = "TRIP_VERIFIED_END_RECEIPT_PERSIST_FAILED: original queue retained."
                    syncStatus = .failure(errorMessage ?? "Trip receipt could not be saved.")
                }
            } else {
                metadata.clearDirty([backendTrip.id])
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
              localEnd == remoteEnd else { return "TRIP_ORIGINAL_END_TIME_MISMATCH" }
        guard ActiveTripPathReconciler.containsRoute(local.pathPoints, in: remote.pathPoints) else {
            return "TRIP_LOCAL_GPS_NOT_ON_SERVER"
        }
        guard local.tankSessions.allSatisfy({ session in
            remote.tankSessions.contains { $0.id == session.id && $0 == session }
        }) else { return "TRIP_LOCAL_TANK_SESSION_DIFFERS" }
        guard local.completedPaths.allSatisfy(remote.completedPaths.contains),
              local.skippedPaths.allSatisfy(remote.skippedPaths.contains),
              Set(local.paddockIds).isSubset(of: Set(remote.paddockIds)) else {
            return "TRIP_LOCAL_ROUTE_PROGRESS_DIFFERS"
        }
        return nil
    }
}
