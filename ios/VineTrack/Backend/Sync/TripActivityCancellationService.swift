import Foundation
import Observation
import Supabase

/// P0 Phase A (Issue #40) iOS production adapters for `cancel_trip_activity_v1` (sql/281).
/// Same RPC, request body, receipt contract and error codes as Android `TripRepository.cancelTripActivity`.
@MainActor
final class SupabaseTripCancellationRemote: TripCancellationRemote {
    typealias C = TripActivityCancellation
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    private struct AccountChanged: Error {}

    /// The signed-in account must equal the intent owner before and after the request.
    private func token(owner: String) async throws -> String {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let session = try await provider.client.auth.session
        guard session.user.id.uuidString.lowercased() == owner.lowercased() else { throw AccountChanged() }
        return session.accessToken
    }

    private func stillOwner(_ owner: String) -> Bool {
        provider.client.auth.currentUser?.id.uuidString.lowercased() == owner.lowercased()
    }

    func cancel(_ intent: C.Intent) async throws -> C.JSON {
        for id in [intent.operationId, intent.tripId, intent.vineyardId] where UUID(uuidString: id) == nil { throw AccountChanged() }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: intent.vineyardId)
        let accessToken = try await token(owner: intent.ownerId)
        let body: C.JSON = .object([
            "p_operation_id": .string(intent.operationId),
            "p_trip_id": .string(intent.tripId),
            "p_vineyard_id": .string(intent.vineyardId),
            "p_application": .string(intent.classification),
            "p_client_baseline": intent.baseline,
            "p_compliance_facts": intent.complianceFacts ?? .null,
        ])
        var request = URLRequest(url: provider.supabaseURL.appendingPathComponent("rest/v1/rpc/cancel_trip_activity_v1"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard stillOwner(intent.ownerId) else { throw AccountChanged() }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)
            if VineyardWriteAuthority.shared.handleServerCode((try? JSONDecoder().decode(PostgrestError.self, from: data))?.code,
                                                             vineyardId: intent.vineyardId) {
                throw VineyardWriteAuthority.Restricted(reason: "VT_READ_ONLY")
            }
            throw TripCancellationServerRefusal(status: http.statusCode, code: C.serverCode(text))
        }
        return try JSONDecoder().decode(C.JSON.self, from: data)
    }

    func readReceipt(tripId: String, vineyardId: String) async throws -> C.JSON? {
        guard let trip = UUID(uuidString: tripId), let vineyard = UUID(uuidString: vineyardId),
              let owner = provider.client.auth.currentUser?.id.uuidString else { throw AccountChanged() }
        let accessToken = try await token(owner: owner)
        var components = URLComponents(url: provider.supabaseURL.appendingPathComponent("rest/v1/trip_activity_cancellation_receipts"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "trip_id", value: "eq.\(trip.uuidString.lowercased())"),
            URLQueryItem(name: "vineyard_id", value: "eq.\(vineyard.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: "*"),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard stillOwner(owner) else { throw AccountChanged() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard case .array(let rows) = try JSONDecoder().decode(C.JSON.self, from: data) else { throw URLError(.cannotParseResponse) }
        guard rows.count <= 1 else { throw URLError(.cannotParseResponse) }
        return rows.first
    }
}

/// Local queues, actuals, journal and claim for exactly one Trip. Never clears by count.
@MainActor
final class LiveTripCancellationLocal: TripCancellationLocal {
    typealias C = TripActivityCancellation
    private let tripSync: TripSyncService
    private let spraySync: SprayRecordSyncService
    private let actuals: SprayTankActualStore
    private let claims: TripLocalEndClaimStore

    init(tripSync: TripSyncService, spraySync: SprayRecordSyncService,
         actuals: SprayTankActualStore = .shared, claims: TripLocalEndClaimStore = .shared) {
        self.tripSync = tripSync; self.spraySync = spraySync; self.actuals = actuals; self.claims = claims
    }

    var writeInFlight: Bool { tripSync.isSyncing || spraySync.isSyncing }

    /// The canonical occurrence journal path for this Trip. More than one scope is ambiguous and holds.
    static func journalURL(tripId: String) throws -> URL? {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("TripOccurrenceJournals", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CocoaError(.fileReadUnknown)
        }
        let name = tripId.lowercased() + ".json"
        var matches: [URL] = []
        for case let url as URL in files where url.lastPathComponent.lowercased() == name { matches.append(url) }
        guard matches.count <= 1 else { throw CocoaError(.fileReadCorruptFile) }
        return matches.first
    }

    func queueEntries(tripId: String, sprayRecordIds: [String]) throws -> [C.QueueEntry] {
        guard let trip = UUID(uuidString: tripId) else { throw CocoaError(.fileReadCorruptFile) }
        var entries = tripSync.cancellationQueueEntries(trip)
        for raw in sprayRecordIds {
            guard let id = UUID(uuidString: raw) else { throw CocoaError(.fileReadCorruptFile) }
            if spraySync.isPendingUpsert(id) { entries.append(.init(kind: C.QueueEntry.sprayRecordUpsert, id: raw.lowercased())) }
            if spraySync.isPendingDelete(id) { entries.append(.init(kind: C.QueueEntry.sprayRecordDelete, id: raw.lowercased())) }
        }
        for actual in actuals.records where actual.tripId == trip && actuals.pendingIds.contains(actual.id) {
            entries.append(.init(kind: C.QueueEntry.tankActualPending, id: actual.id.uuidString.lowercased()))
        }
        for draft in actuals.initialMixDrafts where draft.tripId == trip {
            entries.append(.init(kind: C.QueueEntry.initialMixDraft, id: draft.sprayRecordId.uuidString.lowercased()))
        }
        if let url = try Self.journalURL(tripId: tripId) {
            let snapshot = try JSONDecoder().decode(TripOccurrenceJournal.Snapshot.self, from: Data(contentsOf: url))
            guard snapshot.scope.tripId == tripId.lowercased() else { throw CocoaError(.fileReadCorruptFile) }
            for op in snapshot.pending { entries.append(.init(kind: C.QueueEntry.occurrencePending, id: op.id)) }
        }
        return entries
    }

    func removeQueueEntry(_ entry: C.QueueEntry, tripId: String) -> Bool {
        guard let trip = UUID(uuidString: tripId) else { return false }
        switch entry.kind {
        case C.QueueEntry.tripUpsert:
            guard entry.id == tripId.lowercased() else { return false }
            tripSync.clearCancelledTripQueue(trip, workTaskClear: false)
            return !tripSync.isPendingUpsert(trip)
        case C.QueueEntry.tripWorkTaskClear:
            guard entry.id == tripId.lowercased() else { return false }
            tripSync.clearCancelledTripQueue(trip, workTaskClear: true)
            return true
        case C.QueueEntry.sprayRecordUpsert, C.QueueEntry.sprayRecordDelete:
            guard let id = UUID(uuidString: entry.id) else { return false }
            let delete = entry.kind == C.QueueEntry.sprayRecordDelete
            spraySync.clearCancelledTripRecordQueue(id, delete: delete)
            return delete ? !spraySync.isPendingDelete(id) : !spraySync.isPendingUpsert(id)
        case C.QueueEntry.tankActualPending:
            return removeActual(id: entry.id)
        case C.QueueEntry.initialMixDraft:
            for vineyard in Set(actuals.initialMixDrafts.filter { $0.tripId == trip }.map(\.vineyardId)) {
                do { try actuals.removeInitialMixDrafts(tripId: trip, vineyardId: vineyard) } catch { return false }
            }
            return true
        case C.QueueEntry.occurrencePending:
            // Pending occurrence operations live in the journal; the whole journal is removed below.
            return true
        default:
            return false
        }
    }

    func localActuals(tripId: String) throws -> [SprayTankActual] {
        guard let trip = UUID(uuidString: tripId) else { throw CocoaError(.fileReadCorruptFile) }
        return actuals.records.filter { $0.tripId == trip }
    }

    func removeActual(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        do { try actuals.removeLocal(id: uuid); return true } catch { return false }
    }

    func rawJournal(ownerId: String, vineyardId: String, tripId: String) throws -> Data? {
        guard let url = try Self.journalURL(tripId: tripId) else { return nil }
        return try Data(contentsOf: url)
    }

    func removeJournal(ownerId: String, vineyardId: String, tripId: String) -> Bool {
        do {
            guard let url = try Self.journalURL(tripId: tripId) else { return true }
            try FileManager.default.removeItem(at: url)
            return (try? Self.journalURL(tripId: tripId)) == .some(nil)
        } catch { return false }
    }

    func rawClaim(tripId: String) throws -> Data? { try claims.raw(tripId: tripId) }

    func clearClaim(tripId: String) -> Bool { claims.remove(tripId: tripId) }
}

/// Observable façade used by Trip detail and the sync sweep. Configured from `NewMainTabView`.
@Observable
@MainActor
final class TripActivityCancellationService {
    typealias C = TripActivityCancellation
    static let shared = TripActivityCancellationService()

    private(set) var isWorking = false
    private(set) var lastOutcomeByTrip: [UUID: TripActivityCancellationCoordinator.Outcome] = [:]
    /// Bumped after every durable change so views re-read intent state.
    private(set) var revision = 0

    @ObservationIgnored private var coordinator: TripActivityCancellationCoordinator?
    @ObservationIgnored private var tripSync: TripSyncService?
    @ObservationIgnored private var spraySync: SprayRecordSyncService?

    func configure(tripSync: TripSyncService, spraySync: SprayRecordSyncService) {
        guard coordinator == nil else { return }
        self.tripSync = tripSync; self.spraySync = spraySync
        coordinator = TripActivityCancellationCoordinator(
            intents: .shared,
            evidence: TripCancellationEvidenceWriter(directory: nil),
            remote: SupabaseTripCancellationRemote(),
            local: LiveTripCancellationLocal(tripSync: tripSync, spraySync: spraySync))
    }

    func intent(for tripId: UUID) -> Result<C.Intent?, Error> {
        _ = revision
        return Result { try TripCancellationIntentStore.shared.find(tripId: tripId.uuidString) }
    }

    /// iOS LOCAL_END_PENDING: ended on this device, not active, final stage still awaiting upload,
    /// and not under a separate deletion intent.
    func isLocalEndPending(_ trip: Trip, store: MigratedDataStore) -> Bool {
        guard trip.endTime != nil, !trip.isActive, let tripSync else { return false }
        if (try? store.tripDeletionJournal.isCancelled(trip.id)) != false { return false }
        if tripSync.isPendingUpsert(trip.id) { return true }
        guard let url = try? LiveTripCancellationLocal.journalURL(tripId: trip.id.uuidString.lowercased()),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(TripOccurrenceJournal.Snapshot.self, from: data) else { return false }
        return snapshot.pending.contains { $0.action[occurrence: "kind"]?.occurrenceString == "finalize" }
    }

    /// The durable original-device proof: the claim recorded at End, or for Trips ended before this
    /// build, the account/vineyard scope of this installation's own occurrence journal.
    func localEndClaim(for trip: Trip) -> C.LocalEndClaim? {
        let key = trip.id.uuidString.lowercased()
        if let claim = try? TripLocalEndClaimStore.shared.find(tripId: key) { return claim }
        if let (scope, _) = try? TripOccurrenceJournal.originalDeletionEvidence(tripId: trip.id) {
            return .init(tripId: key, ownerId: scope.account.uuidString.lowercased(),
                         vineyardId: scope.vineyard.uuidString.lowercased(),
                         endedAt: trip.endTime ?? Date(), source: "occurrence_journal_scope")
        }
        return nil
    }

    func eligibility(trip: Trip, role: String?, userId: UUID?, store: MigratedDataStore) -> C.Eligibility {
        _ = revision
        return C.eligibility(role: role, signedInUserId: userId?.uuidString.lowercased(), claim: localEndClaim(for: trip),
                             tripId: trip.id.uuidString, vineyardId: trip.vineyardId.uuidString,
                             localEndPending: isLocalEndPending(trip, store: store))
    }

    func localActualCount(tripId: UUID) -> Int { SprayTankActualStore.shared.records.filter { $0.tripId == tripId }.count }

    func cancel(trip: Trip, classification: C.Classification, confirmedNotApplied: Bool,
                userId: UUID, sprayRecordIds: [UUID]) async -> TripActivityCancellationCoordinator.Outcome {
        guard let coordinator else { return .refused("TRIP_CANCEL_AUTH_REQUIRED") }
        isWorking = true
        defer { isWorking = false; revision += 1 }
        let request = C.Request(ownerId: userId.uuidString.lowercased(), vineyardId: trip.vineyardId.uuidString.lowercased(),
                                tripId: trip.id.uuidString.lowercased(), classification: classification,
                                confirmedRecordedActualsWereNotApplied: confirmedNotApplied)
        let outcome = await coordinator.cancel(request, sprayRecordIds: sprayRecordIds.map { $0.uuidString.lowercased() })
        lastOutcomeByTrip[trip.id] = outcome
        return outcome
    }

    /// Sync sweep: resolve lost responses by readback, then idempotent replay; finish cleanup.
    func reconcileAll() async {
        guard let coordinator, !isWorking else { return }
        isWorking = true
        defer { isWorking = false; revision += 1 }
        for (trip, outcome) in await coordinator.reconcileAll() {
            if let id = UUID(uuidString: trip) { lastOutcomeByTrip[id] = outcome }
        }
    }
}

// MARK: - P0 Phase C: CLOSED_SYNCED (Issue #40)

extension TripActivityCancellationService {
    /// Read-only closure evidence. `fresh` is a fresh server read (`.success(nil)` = absent);
    /// nil uses the acknowledged local row. Never writes queues, journals or stores.
    func closureInput(trip: Trip, store: MigratedDataStore, fresh: Swift.Result<BackendTrip?, Error>?) -> TripClosureStatus.Input {
        _ = revision
        let key = trip.id.uuidString.lowercased()
        var evidence = TripClosureStatus.ServerEvidence.ackedLocalRow
        var isActive = trip.isActive
        var endTime = trip.endTime
        var serverSessions: Set<String>? = TankDependencyVerification.ids(trip.tankSessions)
        if let fresh {
            switch fresh {
            case .failure:
                evidence = .readFailed; serverSessions = nil
            case .success(let row?) where row.deletedAt == nil && row.vineyardId == trip.vineyardId:
                evidence = .freshRead
                isActive = row.isActive ?? true
                endTime = row.endTime
                serverSessions = TankDependencyVerification.ids(row.tankSessions ?? [])
            case .success:
                evidence = .absent; serverSessions = nil
            }
        }
        var markers: [TripClosureStatus.Marker] = []
        if let tripSync, tripSync.isPendingUpsert(trip.id) {
            markers.append(.init(entityType: "trip", status: tripSync.hasFailure(trip.id) ? "failed" : "pending"))
        }
        let actualStore = SprayTankActualStore.shared
        let actuals = actualStore.records.filter { $0.tripId == trip.id }
        let sprayIds = Set(actuals.map(\.sprayRecordId) + store.sprayRecords.filter { $0.tripId == trip.id }.map(\.id))
        if let spraySync {
            for id in sprayIds where spraySync.isPendingUpsert(id) {
                markers.append(.init(entityType: "spray_record", status: spraySync.hasFailure(id) ? "failed" : "pending"))
            }
        }
        var occurrencePending: Int? = 0
        var occurrenceHeld: String?
        do {
            if let url = try LiveTripCancellationLocal.journalURL(tripId: key) {
                let snapshot = try JSONDecoder().decode(TripOccurrenceJournal.Snapshot.self, from: Data(contentsOf: url))
                occurrencePending = snapshot.pending.count
                occurrenceHeld = snapshot.heldReason
            }
        } catch {
            occurrencePending = nil
        }
        var holds: [String] = []
        if let code = tripSync?.tankDependencyHolds[trip.id] { holds.append(code) }
        for a in actuals { if let code = actualStore.dependencyHolds[a.id] { holds.append(code) } }
        let pendingActuals = actuals.filter { actualStore.pendingIds.contains($0.id) }.map { $0.id.uuidString.lowercased() }
            + Array(repeating: "initial_mix_draft", count: max(0, actualStore.pendingCount(tripId: trip.id) - actuals.filter { actualStore.pendingIds.contains($0.id) }.count))
        var linkedIssue = TrackedSprayCompletionSync.completionIssue(trip: trip,
            sprays: store.sprayRecords.filter { $0.canonicalTripId == trip.id },
            expectedIds: Set(actuals.map(\.sprayRecordId)))
        _ = TrackedSprayCompletionSync.shared.revision
        let completionIntents = try? TrackedSprayCompletionSync.shared.intents()
        if completionIntents == nil { linkedIssue = "TRACKED_SPRAY_COMPLETION_JOURNAL_UNREADABLE" }
        return TripClosureStatus.Input(
            tripId: key, evidence: evidence, serverIsActive: isActive, serverEndTime: endTime,
            serverSessionIds: serverSessions,
            locallyEnded: isLocalEndPending(trip, store: store),
            unresolvedMarkers: markers.sorted { ($0.entityType, $0.status) < ($1.entityType, $1.status) }, occurrencePending: occurrencePending, occurrenceHeldReason: occurrenceHeld,
            actualSessionIds: Set(actuals.map { TankDependencyVerification.normalized($0.tankSessionId) }),
            pendingActualIds: pendingActuals.sorted(), holdCodes: holds.sorted(), linkedSprayIssue: linkedIssue,
            completionIntentPending: completionIntents?.contains(where: { $0.tripId == trip.id }) ?? true,
            ownerScope: store.currentUserIdProvider?()?.uuidString ?? "signed_out",
            selectedVineyardScope: store.selectedVineyardId?.uuidString ?? "none")
    }

    /// Closure state from acknowledged local evidence (no network).
    func closureStatus(trip: Trip, store: MigratedDataStore) -> TripClosureStatus.Result {
        TripClosureStatus.evaluate(closureInput(trip: trip, store: store, fresh: nil))
    }

    /// Confirms closure against a fresh server read; only this may report a verified CLOSED_SYNCED.
    func verifyClosure(trip: Trip, store: MigratedDataStore) async -> (TripClosureStatus.Input, TripClosureStatus.Result) {
        let owner = store.currentUserIdProvider?()
        let fresh: Swift.Result<BackendTrip?, Error>
        do {
            fresh = .success(try await SupabaseTripSyncRepository().fetchTripForOccurrenceStart(tripId: trip.id, vineyardId: trip.vineyardId))
        } catch {
            fresh = .failure(error)
        }
        var input = closureInput(trip: trip, store: store, fresh: fresh)
        if trip.tripFunction == TripFunction.spraying.rawValue {
            do {
                let linked = try await SprayCompletionRepository().fetchLinked(tripId: trip.id)
                guard let owner, owner == store.currentUserIdProvider?(),
                      SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
                      store.selectedVineyardId == trip.vineyardId,
                      case .success(let serverTrip?) = fresh, serverTrip.deletedAt == nil,
                      serverTrip.id == trip.id, serverTrip.vineyardId == trip.vineyardId else {
                    throw TrackedSprayCompletionSync.Failure.held
                }
                let actualIds = Set(SprayTankActualStore.shared.records.filter { $0.tripId == trip.id }.map(\.sprayRecordId))
                    .union(store.sprayRecords.filter { $0.canonicalTripId == trip.id }.map(\.id))
                input = closureInput(trip: trip, store: store, fresh: fresh)
                input.linkedSprayIssue = TrackedSprayCompletionSync.completionIssue(trip: serverTrip.toTrip(),
                    sprays: linked.map { $0.toSprayRecord() }, expectedIds: actualIds)
                if serverTrip.endTime != trip.endTime { input.linkedSprayIssue = "TRIP_ORIGINAL_END_TIME_MISMATCH" }
            } catch { input.linkedSprayIssue = "LINKED_SPRAY_SERVER_READ_UNCONFIRMED" }
        }
        return (input, TripClosureStatus.evaluate(input))
    }
}
