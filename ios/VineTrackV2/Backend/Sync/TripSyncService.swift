import Foundation
import Observation

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
        case failure(String)
    }

    var syncStatus: Status = .idle
    var lastSyncDate: Date?
    var errorMessage: String?

    var pendingUpsertCount: Int { metadata.pendingUpserts.count }
    var pendingDeleteCount: Int { metadata.pendingDeletes.count }
    /// Number of trips with a queued explicit `work_task_id = null` clear that
    /// has not yet been confirmed by the server.
    var pendingWorkTaskClearCount: Int { metadata.pendingWorkTaskClears.count }

    /// Whether a specific trip has local changes queued for upload.
    func isPendingUpsert(_ id: UUID) -> Bool { metadata.pendingUpserts[id] != nil }

    /// Whether a specific trip is queued for a remote delete.
    func isPendingDelete(_ id: UUID) -> Bool { metadata.pendingDeletes[id] != nil }

    /// True while a full sweep is actively pushing/pulling trips.
    var isSyncing: Bool { syncStatus == .syncing }

    /// True if the last sweep failed.
    var hasFailure: Bool { if case .failure = syncStatus { return true }; return false }

    /// Whether a specific trip's last push failed while still pending. Used for
    /// per-record error isolation so one failed trip never makes others look
    /// failed.
    func hasFailure(_ id: UUID) -> Bool { metadata.isUpsertFailed(id) || metadata.isDeleteFailed(id) }

    /// Trips whose last upsert push failed while still pending.
    var failedUpsertIds: Set<UUID> { metadata.failedUpsertIds }
    /// Trips whose last remote delete failed while still pending.
    var failedDeleteIds: Set<UUID> { metadata.failedDeleteIds }

    private weak var store: MigratedDataStore?
    private weak var auth: NewBackendAuthService?
    private let repository: any TripSyncRepositoryProtocol
    private let metadata: TripSyncMetadata
    private var isConfigured: Bool = false

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
        guard !isConfigured else { return }
        isConfigured = true
        store.onTripChanged = { [weak self] id in
            self?.markTripDirty(id)
        }
        store.onTripDeleted = { [weak self] id in
            self?.markTripDeleted(id)
        }
    }

    // MARK: - Dirty tracking

    func markTripDirty(_ id: UUID) {
        metadata.markDirty(id, at: Date())
    }

    func markTripDeleted(_ id: UUID) {
        metadata.markDeleted(id, at: Date())
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
        guard SupabaseClientProvider.shared.isConfigured else {
            errorMessage = "Supabase not configured"
            syncStatus = .failure("Supabase not configured")
            return
        }
        syncStatus = .syncing
        errorMessage = nil
        do {
            try await pushLocalTrips(vineyardId: vineyardId)
            try await pullRemoteTrips(vineyardId: vineyardId)
            metadata.setLastSync(Date(), for: vineyardId)
            lastSyncDate = Date()
            syncStatus = .success
        } catch {
            errorMessage = error.localizedDescription
            syncStatus = .failure(error.localizedDescription)
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
        let createdBy = auth?.userId
        let dirty = metadata.pendingUpserts
        if !dirty.isEmpty {
            let byId = Dictionary(store.trips.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            // Build a paddockId -> vineyardId lookup for repair inference.
            let paddockVineyard = Dictionary(
                store.paddocks.map { ($0.id, $0.vineyardId) },
                uniquingKeysWith: { first, _ in first }
            )
            var payloads: [BackendTripUpsert] = []
            var pushedIds: [UUID] = []
            var skipped: [(UUID, String)] = []
            for (tripId, ts) in dirty {
                guard var trip = byId[tripId] else { continue }
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
                payloads.append(BackendTrip.upsert(from: trip, createdBy: createdBy, clientUpdatedAt: ts))
                pushedIds.append(tripId)
            }
            if !payloads.isEmpty {
                do {
                    try await repository.upsertTrips(payloads)
                    metadata.clearDirty(pushedIds)
                } catch {
                    // Isolate the failure to exactly the trips in this batch.
                    metadata.markUpsertsFailed(pushedIds)
                    throw error
                }
            }
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
        for (tripId, _) in deletes {
            do {
                try await repository.softDeleteTrip(id: tripId)
                metadata.clearDeleted([tripId])
            } catch {
                if Self.isMissingRowError(error) {
                    metadata.clearDeleted([tripId])
                    #if DEBUG
                    print("[TripSync] soft delete: remote trip \(tripId) already missing — clearing pending delete")
                    #endif
                } else {
                    #if DEBUG
                    print("[TripSync] soft delete failed for \(tripId): \(error.localizedDescription)")
                    #endif
                    metadata.markDeletesFailed([tripId])
                    deleteFailures.append(error.localizedDescription)
                    continue
                }
            }
        }
        if !deleteFailures.isEmpty {
            errorMessage = "Some trip deletes failed: \(deleteFailures.first ?? "unknown")"
        }
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
            for trip in store.trips {
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

        for backendTrip in remote {
            applyRemote(backendTrip, vineyardId: vineyardId, store: store)
        }
    }

    private func applyRemote(_ backendTrip: BackendTrip, vineyardId: UUID, store: MigratedDataStore) {
        // Soft-deleted remotely.
        if backendTrip.deletedAt != nil {
            store.applyRemoteTripDelete(backendTrip.id)
            metadata.clearDirty([backendTrip.id])
            metadata.clearDeleted([backendTrip.id])
            metadata.clearWorkTaskClears([backendTrip.id])
            return
        }

        // Last-write-wins: only apply remote if it's newer than the local pending change.
        if let pendingDirtyAt = metadata.pendingUpserts[backendTrip.id] {
            let remoteAt = backendTrip.clientUpdatedAt ?? backendTrip.updatedAt ?? .distantPast
            if pendingDirtyAt > remoteAt { return }
        }

        let mapped = backendTrip.toTrip()
        store.applyRemoteTripUpsert(mapped)
        metadata.clearDirty([backendTrip.id])
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

        init() {}

        enum CodingKeys: String, CodingKey {
            case lastSyncByVineyard, pendingUpserts, pendingDeletes
            case failedUpserts, failedDeletes, pendingWorkTaskClears
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
        state.pendingUpserts.removeValue(forKey: id)
        state.failedUpserts.remove(id)
        // A deleted trip needs no link clear — the soft-delete subsumes it.
        state.pendingWorkTaskClears.removeValue(forKey: id)
        state.pendingDeletes[id] = date
        save()
    }

    func clearDirty(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { state.pendingUpserts.removeValue(forKey: id); state.failedUpserts.remove(id) }
        save()
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
