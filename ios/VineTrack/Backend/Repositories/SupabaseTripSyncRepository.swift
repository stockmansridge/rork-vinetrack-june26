import Foundation
import Supabase

/// Encode newly planned block UUIDs as canonical lower-case strings. A
/// persisted occurrence create is immutable and is never passed through this
/// function again after its journal has been committed.
nonisolated enum OccurrenceCreateBlockUUID {
    typealias JSON = TripOccurrenceCoverage.JSON

    static func canonicalize(_ original: [String: JSON]) -> [String: JSON] {
        var next = original
        if case .array(let blockIds) = original["paddock_ids"] {
            next["paddock_ids"] = .array(blockIds.map { value in
                guard case .string(let raw) = value, let uuid = UUID(uuidString: raw) else { return value }
                return .string(uuid.uuidString.lowercased())
            })
        }
        if case .string(let raw) = original["paddock_id"], let uuid = UUID(uuidString: raw) {
            next["paddock_id"] = .string(uuid.uuidString.lowercased())
        }
        return next
    }
}

/// The two Trip bodies the occurrence chain sends as JSON objects. They are built here, and only here, so the
/// native replay tests can feed the app's own output to the answers a real PostgREST gave.
nonisolated enum OccurrenceWirePayload {
    typealias JSON = TripOccurrenceCoverage.JSON

    /// Routine fields of the Trip. Authority, route identity and lifecycle can only go through their dedicated
    /// RPCs, so none of these keys may appear in the Trip details PATCH.
    static let authorityKeys: [String] = [
        "id", "vineyard_id", "created_by", "occurrence_coverage", "row_sequence", "completed_paths", "skipped_paths",
        "sequence_index", "current_row_number", "next_row_number", "paddock_id", "paddock_ids", "tracking_pattern",
        "start_time", "end_time", "is_active", "operator_user_id"]

    private static func encoded(_ trip: BackendTripUpsert) throws -> [String: JSON] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode([String: JSON].self, from: encoder.encode(trip))
    }

    /// `p_trip` of the create operation before block ids are canonicalised.
    static func tripMetadata(_ trip: BackendTripUpsert) throws -> [String: JSON] {
        var metadata = try encoded(trip)
        metadata.removeValue(forKey: "occurrence_coverage")
        return metadata
    }

    /// Body of the Trip details PATCH sent before the first action and again after finalise.
    static func nonAuthorityFields(_ trip: BackendTripUpsert) throws -> [String: JSON] {
        var fields = try encoded(trip)
        for key in authorityKeys { fields.removeValue(forKey: key) }
        return fields
    }
}

nonisolated enum OccurrenceParentBootstrapPolicy {
    static func mayReplay(_ rpc: String, parentOnly: Bool) -> Bool {
        !parentOnly || rpc == "create_trip_with_occurrences_v1" ||
            rpc == "activate_trip_occurrences_v1"
    }
    static func parentOperationsAcknowledged(_ pendingRPCs: [String]) -> Bool {
        !pendingRPCs.contains {
            $0 == "create_trip_with_occurrences_v1" ||
            $0 == "activate_trip_occurrences_v1"
        }
    }
    // A nil server state is not evidence of an active original Trip.
    static func isActiveOriginalServerParent(_ value: Bool?) -> Bool {
        value == true
    }
}

/// Exact PostgREST tank-session CAS URL. URLComponents leaves '+' in query
/// values unescaped; PostgREST form-decodes it as a space, turning a valid
/// timestamptz (+00:00) into an invalid filter and causing HTTP 400 retries.
/// Preserve the entire original microsecond timestamp and encode ONLY the
/// query delimiter-sensitive '+' as %2B. Never replace CAS with an unsafe
/// unconditional PATCH.
nonisolated enum TripTankCASRequestURL {
    static func make(baseURL: URL, tripId: UUID, vineyardId: UUID,
                     syncVersion: Int, rawUpdatedAt: String) -> URL? {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("rest/v1/trips"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(tripId.uuidString.lowercased())"),
            URLQueryItem(name: "vineyard_id", value: "eq.\(vineyardId.uuidString.lowercased())"),
            URLQueryItem(name: "sync_version", value: "eq.\(syncVersion)"),
            URLQueryItem(name: "updated_at", value: "eq.\(rawUpdatedAt)"),
            URLQueryItem(name: "deleted_at", value: "is.null"),
            URLQueryItem(name: "is_active", value: "eq.true"),
            URLQueryItem(name: "end_time", value: "is.null"),
            URLQueryItem(name: "select", value: "id")
        ]
        // URLComponents.queryItems percent-encodes ':' but NOT '+'. An
        // unescaped '+' is silently decoded to a space by PostgREST.
        if let rawQuery = components?.percentEncodedQuery {
            components?.percentEncodedQuery = rawQuery.replacingOccurrences(
                of: "+", with: "%2B")
        }
        return components?.url
    }
}

final class SupabaseTripSyncRepository: TripSyncRepositoryProtocol {
    private let provider: SupabaseClientProvider
    private let deletionAuthority: VineyardWriteAuthority
    struct DeletionSession {
        let actor: UUID
        let token: String
        let incarnation: UInt64
    }
    private let deletionSessionSource: (() async throws -> DeletionSession)?
    private let deletionTransport: (URLRequest) async throws -> (Data, URLResponse)

    init(provider: SupabaseClientProvider = .shared,
         deletionAuthority: VineyardWriteAuthority = .shared,
         deletionSession: (() async throws -> DeletionSession)? = nil,
         deletionTransport: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.provider = provider
        self.deletionAuthority = deletionAuthority
        self.deletionSessionSource = deletionSession
        self.deletionTransport = deletionTransport
    }

    private func deletionSession() async throws -> DeletionSession {
        if let deletionSessionSource { return try await deletionSessionSource() }
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let generation = deletionAuthority.accountGeneration
        let session = try await provider.client.auth.session
        guard generation == deletionAuthority.accountGeneration,
              provider.client.auth.currentUser?.id == session.user.id else {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ACCOUNT_CHANGED")
        }
        return DeletionSession(actor: session.user.id, token: session.accessToken, incarnation: generation)
    }

    func fetchTrips(vineyardId: UUID, since: Date?) async throws -> [BackendTrip] {
        do {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let query = provider.client
            .from("trips")
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
        } catch {
            RecoveryDecodeEvidence.record(error, source: "supabase_response", operation: "trips.fetchTrips")
            throw error
        }
    }

    func fetchAllTrips(vineyardId: UUID) async throws -> [BackendTrip] {
        try await fetchTrips(vineyardId: vineyardId, since: nil)
    }

    /// Exact scoped lookup: a capped vineyard list cannot establish absence.
    func fetchTripForOccurrenceStart(tripId: UUID, vineyardId: UUID) async throws -> BackendTrip? {
        do {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard let owner = provider.client.auth.currentUser?.id else { throw CancellationError() }
        let rows: [BackendTrip] = try await provider.client.from("trips").select()
            .eq("vineyard_id", value: vineyardId.uuidString)
            .eq("id", value: tripId.uuidString).limit(2).execute().value
        guard provider.client.auth.currentUser?.id == owner, rows.count <= 1 else {
            throw TripOccurrenceCoverage.Failure.scopeConflict
        }
        return rows.first
        } catch {
            RecoveryDecodeEvidence.record(error, source: "supabase_response", operation: "trips.fetchTripForOccurrenceStart")
            throw error
        }
    }

    func fetchTankSessionIds(tripId: UUID, vineyardId: UUID) async throws -> Set<String>? {
        guard let row = try await fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyardId),
              row.deletedAt == nil else { return nil }
        return TankDependencyVerification.ids(row.tankSessions ?? [])
    }

    /// P0 stage 1: establish ONLY originally recorded tank sessions before
    /// Actual Use upload. The occurrence finalise RPC remains in its immutable
    /// journal until Actual Use is independently accepted. No fabricated tank,
    /// changed quantity, Trip End, Spray completion or new identity is written.
    func establishOccurrenceTankSessions(_ trip: BackendTripUpsert, required: Set<String>) async throws {
        // Each local precondition stops with its OWN fixed code. They used to
        // share one generic reconciliation error, so a stopped Trip could not
        // say which check had stopped it.
        func admission(_ code: String, _ detail: String) -> TripSyncStageFailure {
            verificationFailure(.admission, trip, endpoint: "local/tank-staging", code: code, detail: detail)
        }
        guard !trip.isActive, trip.endTime != nil else {
            throw admission(TripSyncVerificationCode.tripNotEnded, "Trip is not ended locally")
        }
        guard !required.isEmpty else {
            throw admission(TripSyncVerificationCode.noRequiredSessions, "No tank session is required by a local Tank Actual")
        }
        guard let localCoverage = trip.occurrenceCoverage,
              let localDocument = TripOccurrenceCoverage.read(localCoverage) else {
            throw admission(TripSyncVerificationCode.coverageUnreadable, "Local occurrence coverage is missing or unreadable")
        }
        guard Set(trip.tankSessions.map(\.id)).count == trip.tankSessions.count else {
            throw admission(TripSyncVerificationCode.duplicateSession, "Two local tank sessions share one id")
        }
        guard Set(trip.tankSessions.map(\.tankNumber)).count == trip.tankSessions.count else {
            throw admission(TripSyncVerificationCode.duplicateTankNumber, "Two local tank sessions share one tank number")
        }
        guard required.isSubset(of: TankDependencyVerification.ids(trip.tankSessions)) else {
            throw admission(TripSyncVerificationCode.requiredNotLocal, "A tank session required by a local Tank Actual is not on the local Trip")
        }
        guard let account = provider.client.auth.currentUser?.id else {
            throw admission(TripSyncVerificationCode.noAccount, "No signed-in account")
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
        // End is retained in the original WAL. Create and activate the exact
        // original server parent first, without replaying the queued finalise.
        try await replayOccurrenceTrip(trip, parentOnly: true)
        // Keep the raw server timestamp from the SAME read as the tank array.
        // sync_version alone is not advanced by every existing Trip writer.
        // Re-encoding a Date would truncate PostgreSQL microseconds and make
        // a valid compare-and-swap fail, so retain the original text verbatim.
        let readEndpoint = "GET rest/v1/trips"
        func readFailure(_ code: String, _ detail: String) -> TripSyncStageFailure {
            verificationFailure(.tankStagingRead, trip, endpoint: readEndpoint, code: code, detail: detail)
        }
        let snapshot: PostgrestResponse<[BackendTrip]>
        do {
            snapshot = try await provider.client.from("trips").select()
                .eq("vineyard_id", value: trip.vineyardId.uuidString)
                .eq("id", value: trip.id.uuidString).limit(2).execute()
        } catch {
            throw stageError(error, .tankStagingRead, trip, endpoint: readEndpoint)
        }
        let rawRows = try JSONDecoder().decode([TripOccurrenceCoverage.JSON].self, from: snapshot.data)
        guard provider.client.auth.currentUser?.id == account else {
            throw readFailure(TripSyncVerificationCode.serverRowMismatch, "Signed-in account changed during the read")
        }
        guard snapshot.value.count == 1, rawRows.count == 1, let existing = snapshot.value.first else {
            throw readFailure(TripSyncVerificationCode.serverRowMismatch,
                              "Expected exactly one server Trip row, found \(snapshot.value.count)")
        }
        guard existing.deletedAt == nil, existing.endTime == nil, existing.isActive == true else {
            throw readFailure(TripSyncVerificationCode.serverRowMismatch,
                              "Server Trip is deleted, ended or inactive (deleted=\(existing.deletedAt != nil), ended=\(existing.endTime != nil), active=\(String(describing: existing.isActive)))")
        }
        guard let remoteDocument = TripOccurrenceCoverage.read(existing.occurrenceCoverage),
              localDocument.planId == remoteDocument.planId else {
            throw readFailure(TripSyncVerificationCode.serverRowMismatch,
                              "Server occurrence plan does not match the local original plan")
        }

        let serverSessions = existing.tankSessions ?? []
        let originalById = Dictionary(trip.tankSessions.map { ($0.id, $0) },
                                      uniquingKeysWith: { _, value in value })
        // An independently changed server session is never overwritten.
        // The original may advance the same session from open to ended,
        // but may not replace its start, tank identity or recorded paths.
        for server in serverSessions {
            guard let local = originalById[server.id],
                  TankSessionReceiptMatch.canStage(local: local, remote: server)
            else {
                throw readFailure(TripSyncVerificationCode.serverSessionConflict,
                                  "A server tank session conflicts with the original local session; nothing was overwritten")
            }
        }
        let serverIds = TankDependencyVerification.ids(serverSessions)
        if required.isSubset(of: serverIds),
           trip.tankSessions.allSatisfy({ local in
               serverSessions.contains(where: { server in
                   TankSessionReceiptMatch.equivalent(local: local, remote: server)
               })
           }) { return }
        // Optimistic concurrency is necessary: a new server revision between
        // the read and PATCH must leave the original local journal untouched.
        guard let revision = existing.syncVersion,
              let updatedAt = rawRows[0][occurrence: "updated_at"]?.occurrenceString,
              !updatedAt.isEmpty else {
            throw readFailure(TripSyncVerificationCode.revisionMissing, "Server Trip revision or updated_at is missing")
        }
        guard let url = TripTankCASRequestURL.make(
            baseURL: provider.supabaseURL, tripId: trip.id,
            vineyardId: trip.vineyardId, syncVersion: revision,
            rawUpdatedAt: updatedAt)
        else {
            throw readFailure(TripSyncVerificationCode.requestInvalid, "Could not build the compare-and-swap request")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"; request.timeoutInterval = 30
        let token = try await provider.client.auth.session
        guard token.user.id == account else { throw TripOccurrenceCoverage.Failure.scopeConflict }
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(["tank_sessions": trip.tankSessions])
        let patchEndpoint = "PATCH rest/v1/trips (tank_sessions, compare-and-swap)"
        let exchange: (Data, URLResponse)
        do { exchange = try await URLSession.shared.data(for: request) }
        catch { throw stageError(error, .tankStagingPatch, trip, endpoint: patchEndpoint) }
        let (bytes, response) = exchange
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // The body is the only evidence of WHY the server refused. Keep the
            // HTTP status and PostgREST code instead of flattening them away.
            if VineyardWriteAuthority.shared.handleServerCode(
                (try? JSONDecoder().decode(PostgrestError.self, from: bytes))?.code,
                vineyardId: trip.vineyardId.uuidString) {
                throw VineyardWriteAuthority.Restricted(reason: "VT_READ_ONLY")
            }
            throw stageFailure(.tankStagingPatch, trip, endpoint: patchEndpoint,
                               httpStatus: (response as? HTTPURLResponse)?.statusCode, body: bytes)
        }
        guard provider.client.auth.currentUser?.id == account else {
            throw verificationFailure(.tankStagingPatch, trip, endpoint: patchEndpoint,
                                      code: TripSyncVerificationCode.serverRowMismatch,
                                      detail: "Signed-in account changed during the update")
        }
        let accepted = try JSONDecoder().decode([TripOccurrenceCoverage.JSON].self, from: bytes)
        guard accepted.count == 1,
              accepted[0][occurrence: "id"]?.occurrenceString?.lowercased() == trip.id.uuidString.lowercased()
        else {
            // Zero rows means the server revision moved between the read and
            // this compare-and-swap. Nothing was written; the next pass re-reads.
            throw verificationFailure(.tankStagingPatch, trip, endpoint: patchEndpoint,
                                      code: TripSyncVerificationCode.casNoMatch,
                                      detail: "Compare-and-swap matched \(accepted.count) rows",
                                      httpStatus: http.statusCode)
        }
        let verified: BackendTrip?
        do { verified = try await fetchTripForOccurrenceStart(tripId: trip.id, vineyardId: trip.vineyardId) }
        catch { throw stageError(error, .tankStagingReadback, trip, endpoint: readEndpoint) }
        guard provider.client.auth.currentUser?.id == account,
              let verified, verified.deletedAt == nil,
              required.isSubset(of: TankDependencyVerification.ids(verified.tankSessions ?? [])),
              trip.tankSessions.allSatisfy({ local in
                  verified.tankSessions?.contains(where: { server in
                      TankSessionReceiptMatch.equivalent(local: local, remote: server)
                  }) == true
              })
        else {
            throw verificationFailure(.tankStagingReadback, trip, endpoint: readEndpoint,
                                      code: TripSyncVerificationCode.readbackMismatch,
                                      detail: "Independent read-back does not contain every original tank session")
        }
    }

    // MARK: Typed stage failures

    /// A local verification step stopped without an HTTP error. Retryable by
    /// default (it never was throttled before), `held` only when the immutable
    /// occurrence journal itself is held.
    private func verificationFailure(_ stage: TripSyncStageFailure.Stage, _ trip: BackendTripUpsert,
                                     endpoint: String, code: String, detail: String? = nil,
                                     operationId: String? = nil, httpStatus: Int? = nil,
                                     journalHeld: Bool = false) -> TripSyncStageFailure {
        TripSyncStageFailure(stage: stage, tripId: trip.id, operationId: operationId, endpoint: endpoint,
                             httpStatus: httpStatus, serverMessage: detail, verificationCode: code,
                             journalHeld: journalHeld, disposition: journalHeld ? .held : .retryable)
    }

    /// A raw `URLSession` request answered non-2xx. The server's own code and
    /// message are read from the body; nothing is guessed.
    private func stageFailure(_ stage: TripSyncStageFailure.Stage, _ trip: BackendTripUpsert,
                              endpoint: String, httpStatus: Int?, body: Data,
                              operationId: String? = nil) -> TripSyncStageFailure {
        TripSyncStageFailure(stage: stage, tripId: trip.id, endpoint: endpoint,
                             httpStatus: httpStatus, body: body, operationId: operationId)
    }

    /// An occurrence RPC rejection, with everything the server said.
    private func stageFailure(_ rejection: OccurrenceRPCFailure, rpc: String, trip: BackendTripUpsert,
                              operationId: String?, journalHeld: Bool) -> TripSyncStageFailure {
        TripSyncStageFailure(rejection: rejection, rpc: rpc, tripId: trip.id,
                             operationId: operationId, journalHeld: journalHeld)
    }

    /// The immutable occurrence journal is held; nothing is replayed.
    private func heldFailure(_ trip: BackendTripUpsert, stage: TripSyncStageFailure.Stage,
                             reason: String?, detail: String? = nil) -> TripSyncStageFailure {
        let text = [detail, reason].compactMap { $0 }.joined(separator: ": ")
        return verificationFailure(stage, trip, endpoint: "local/occurrence-journal",
                                   code: TripSyncVerificationCode.journalHeld,
                                   detail: text.isEmpty ? nil : text, journalHeld: true)
    }

    /// SDK and transport errors become typed failures; cancellation, write
    /// restriction, scope conflict and other typed errors flow unchanged.
    private func stageError(_ error: Error, _ stage: TripSyncStageFailure.Stage, _ trip: BackendTripUpsert,
                            endpoint: String, operationId: String? = nil) -> Error {
        TripSyncStageFailure.wrapping(error, stage: stage, tripId: trip.id,
                                      operationId: operationId, endpoint: endpoint) ?? error
    }

    private func requireTripWrite(_ id: UUID) async throws -> UUID {
        guard let owner = provider.client.auth.currentUser?.id else { throw CancellationError() }
        struct Row: Decodable { let vineyard_id: UUID }
        let rows: [Row] = try await provider.client.from("trips").select("vineyard_id")
            .eq("id", value: id.uuidString).limit(2).execute().value
        guard provider.client.auth.currentUser?.id == owner, rows.count == 1 else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: rows[0].vineyard_id.uuidString)
        return rows[0].vineyard_id
    }

    func upsertTrip(_ trip: BackendTripUpsert) async throws {
        try await upsertTrips([trip])
    }

    func upsertTrips(_ trips: [BackendTripUpsert]) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        guard !trips.isEmpty else { return }
        let occurrenceTrips = trips.filter { TripOccurrenceCoverage.basis($0.occurrenceCoverage) != .legacy }
        for trip in occurrenceTrips { try await replayOccurrenceTrip(trip) }
        let legacyTrips = trips.filter { TripOccurrenceCoverage.basis($0.occurrenceCoverage) == .legacy }
        guard !legacyTrips.isEmpty else { return }
        for trip in legacyTrips { try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString) }
        guard let account = provider.client.auth.currentUser?.id else { throw CancellationError() }
        let deletion = TripDeletionJournal()
        var claimed: [TripDeletionJournal.Scope] = []
        var established = false
        defer { for scope in claimed { try? deletion.endSend(scope, established: established) } }
        for trip in legacyTrips {
            let scope = TripDeletionJournal.Scope(account: account, vineyard: trip.vineyardId, trip: trip.id)
            try deletion.beginSend(scope)
            claimed.append(scope)
        }
        try await provider.client
            .from("trips")
            .upsert(legacyTrips, onConflict: "id")
            .execute()
        established = provider.client.auth.currentUser?.id == account
    }

    /// Called at the local creation commitment, before sync can observe a new occurrence trip.
    /// The ordinary native payload is retained verbatim; only the envelope is a separate RPC argument.
    func prepareOccurrenceCreation(_ trip: BackendTripUpsert, ownerId: UUID) throws {
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
        guard let coverage = trip.occurrenceCoverage else { throw TripOccurrenceCoverage.Failure.updateRequired }
        let metadata = try OccurrenceWirePayload.tripMetadata(trip)
        // Swift JSONEncoder serialises UUIDs in upper case, but the deployed
        // occurrence RPC checks JSON array membership using case-sensitive text.
        // Canonicalise only NEW requests. Never rewrite a durable original WAL.
        let canonicalMetadata = OccurrenceCreateBlockUUID.canonicalize(metadata)
        let journal = try TripOccurrenceJournal(scope: .init(ownerId: ownerId.uuidString.lowercased(),
            vineyardId: trip.vineyardId.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
        if let existing = try journal.load() {
            guard let creation = existing.history.first(where: { $0.rpc == "create_trip_with_occurrences_v1" }),
                  (creation.params[occurrence: "p_trip"] == .object(metadata) ||
                   creation.params[occurrence: "p_trip"] == .object(canonicalMetadata)),
                  creation.params[occurrence: "p_coverage"] == coverage else {
                throw TripOccurrenceCoverage.Failure.reconciliation
            }
            return
        }
        try TripDeletionJournal().registerCreation(.init(account: ownerId, vineyard: trip.vineyardId, trip: trip.id))
        try journal.prepareCreation(trip: .object(canonicalMetadata), coverage: coverage)
    }

    /// Serial durable action replay. Never converts an occurrence trip into a numeric full-snapshot write.
    private func replayOccurrenceTrip(_ trip: BackendTripUpsert, parentOnly: Bool = false) async throws {
        guard let raw = trip.occurrenceCoverage else { throw TripOccurrenceCoverage.Failure.updateRequired }
        let originalDocument = try TripOccurrenceCoverage.requireDocument(raw)
        let session = try await provider.client.auth.session
        let account = session.user.id
        let deletion = TripDeletionJournal()
        let sendScope = TripDeletionJournal.Scope(account: account, vineyard: trip.vineyardId, trip: trip.id)
        try deletion.beginSend(sendScope)
        var sendEstablished = false
        defer { try? deletion.endSend(sendScope, established: sendEstablished) }
        let journal = try TripOccurrenceJournal(scope: .init(ownerId: account.uuidString.lowercased(),
            vineyardId: trip.vineyardId.uuidString.lowercased(), tripId: trip.id.uuidString.lowercased()))
        guard let initial = try journal.load() else { throw TripOccurrenceCoverage.Failure.missing }
        // The existing Trip-details recovery could retry this exact two-op WAL
        // after the server's UUID comparison was fixed, but normal Sync could
        // leave it held indefinitely. A scoped, authenticated read-only check
        // now unlocks ONLY the original create+activate pair if the server row
        // is genuinely absent. Journal.release... validates both immutable IDs
        // and their saved payloads, with no remint, delete or guessed record.
        if TripOccurrenceJournal.needsOriginalCreationAbsenceCheck(initial) {
            try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
            try deletion.requireNotCancelled(trip.id)
            let remote: BackendTrip?
            do { remote = try await fetchTripForOccurrenceStart(tripId: trip.id, vineyardId: trip.vineyardId) }
            catch { throw stageError(error, .admission, trip, endpoint: "GET rest/v1/trips (creation absence check)") }
            let checkedSession = try await provider.client.auth.session
            guard checkedSession.user.id == account,
                  checkedSession.refreshToken == session.refreshToken else {
                throw TripOccurrenceCoverage.Failure.scopeConflict
            }
            // A row already on the server is NOT permission to re-create it.
            // It requires a separate accepted-operation receipt reconciliation.
            guard remote == nil else {
                throw heldFailure(trip, stage: .admission, reason: initial.heldReason,
                                  detail: "The Trip already exists on the server, so its original creation is not re-sent")
            }
            try deletion.requireNotCancelled(trip.id)
            try journal.releaseHeldOriginalCreationAfterVerifiedServerAbsence(
                expectedCoverage: initial.acknowledged)
        }
        if initial.creationConfirmed != false || !initial.pending.contains(where: { $0.rpc == "create_trip_with_occurrences_v1" }) {
            let recoveryRPC = "get_trip_occurrence_recovery_v1"
            let recovery: TripOccurrenceCoverage.JSON
            do {
                recovery = try await occurrenceRequest(rpc: recoveryRPC, params: .object([
                    "p_trip_id": .string(trip.id.uuidString.lowercased()),
                    "p_operation_ids": .array(initial.pending.prefix(256).map { .string($0.id) })]), accessToken: session.accessToken)
            } catch let rejection as OccurrenceRPCFailure {
                // A read-only recovery lookup never holds the journal.
                throw stageFailure(rejection, rpc: recoveryRPC, trip: trip, operationId: nil, journalHeld: false)
            } catch let urlError as URLError {
                throw stageError(urlError, .occurrenceRecovery, trip, endpoint: "rpc/\(recoveryRPC)")
            }
            let currentSession = try await provider.client.auth.session
            guard currentSession.user.id == account, currentSession.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
            try journal.recover(recovery)
        }
        if let held = try journal.load()?.heldReason {
            throw heldFailure(trip, stage: .occurrenceRecovery, reason: held)
        }
        // Existing trip data/session establishment must precede occurrence links and finalisation.
        var sessionsEstablished = false
        for _ in 0..<128 {
            // A journal that vanished mid-replay is a reconciliation fault; a
            // HELD journal is a named state with its own reason.
            guard let state = try journal.load() else { throw TripOccurrenceCoverage.Failure.reconciliation }
            if let held = state.heldReason { throw heldFailure(trip, stage: .occurrenceAction, reason: held) }
            guard let op = state.pending.first else { break }
            // Do not replay path edits or End before Actual Use has receipts.
            if !OccurrenceParentBootstrapPolicy.mayReplay(op.rpc, parentOnly: parentOnly) { break }
            try deletion.requireNotCancelled(trip.id)
            do {
                let beforeRequest = try await provider.client.auth.session
                guard beforeRequest.user.id == account, beforeRequest.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                if !sessionsEstablished && !["create_trip_with_occurrences_v1", "activate_trip_occurrences_v1"].contains(op.rpc) {
                    try await updateOccurrenceNonAuthorityFields(trip, accessToken: session.accessToken, operationId: op.id)
                    let establishedSession = try await provider.client.auth.session
                    guard establishedSession.user.id == account, establishedSession.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                    sessionsEstablished = true
                }
                try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
                try deletion.requireNotCancelled(trip.id)
                let result = try await occurrenceRequest(rpc: op.rpc, params: op.params, accessToken: session.accessToken, writeVineyard: trip.vineyardId)
                let currentSession = try await provider.client.auth.session
            guard currentSession.user.id == account, currentSession.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                try journal.acknowledge(result)
            } catch let rejection as OccurrenceRPCFailure {
                // The server answered and refused this exact operation. Whether
                // that HOLDS the immutable journal is a separate decision:
                // a tank-link or tank-review answer depends on server data that
                // can be repaired, so it is reported but never held.
                var held = false
                if let reason = OccurrenceHoldPolicy.holdReason(for: rejection) {
                    let current = try await provider.client.auth.session
                    guard current.user.id == account, current.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
                    try journal.hold(reason)
                    held = true
                }
                throw stageFailure(rejection, rpc: op.rpc, trip: trip, operationId: op.id, journalHeld: held)
            } catch let urlError as URLError {
                throw stageError(urlError, .forRPC(op.rpc), trip, endpoint: "rpc/\(op.rpc)", operationId: op.id)
            }
        }
        guard let state = try journal.load() else { throw TripOccurrenceCoverage.Failure.reconciliation }
        if let held = state.heldReason { throw heldFailure(trip, stage: .occurrenceAction, reason: held) }
        try deletion.requireNotCancelled(trip.id)
        if parentOnly {
            guard OccurrenceParentBootstrapPolicy.parentOperationsAcknowledged(state.pending.map(\.rpc)) else {
                throw verificationFailure(.parentActivate, trip, endpoint: "local/occurrence-journal",
                                          code: TripSyncVerificationCode.parentOperationsPending,
                                          detail: "The original create or activate operation is still pending")
            }
            // The exact original parent must exist independently on the server.
            let parentReadEndpoint = "GET rest/v1/trips (parent read-back)"
            let remote: BackendTrip?
            do { remote = try await fetchTripForOccurrenceStart(tripId: trip.id, vineyardId: trip.vineyardId) }
            catch { throw stageError(error, .parentActivate, trip, endpoint: parentReadEndpoint) }
            let checkedSession = try await provider.client.auth.session
            guard checkedSession.user.id == account,
                  checkedSession.refreshToken == session.refreshToken else {
                throw TripOccurrenceCoverage.Failure.scopeConflict
            }
            guard let remote, remote.deletedAt == nil,
                  OccurrenceParentBootstrapPolicy.isActiveOriginalServerParent(remote.isActive),
                  remote.endTime == nil,
                  TripOccurrenceCoverage.read(remote.occurrenceCoverage)?.planId == originalDocument.planId
            else {
                throw verificationFailure(.parentActivate, trip, endpoint: parentReadEndpoint,
                                          code: TripSyncVerificationCode.parentReadbackMismatch,
                                          detail: "The server Trip is missing, deleted, ended, inactive or from a different plan")
            }
            sendEstablished = true
            return
        }
        guard state.pending.isEmpty else {
            throw verificationFailure(.occurrenceAction, trip, endpoint: "local/occurrence-journal",
                                      code: TripSyncVerificationCode.operationsPending,
                                      detail: "\(state.pending.count) saved action(s) are still pending after replay")
        }
        try await updateOccurrenceNonAuthorityFields(trip, accessToken: session.accessToken)
        sendEstablished = true
    }

    private func updateOccurrenceNonAuthorityFields(_ trip: BackendTripUpsert, accessToken: String,
                                                    operationId: String? = nil) async throws {
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: trip.vineyardId.uuidString)
        // Authority, route identity and lifecycle can only go through their dedicated RPCs.
        let fields = try OccurrenceWirePayload.nonAuthorityFields(trip)
        var components = URLComponents(url: provider.supabaseURL.appendingPathComponent("rest/v1/trips"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(trip.id.uuidString.lowercased())"), URLQueryItem(name: "select", value: "id")]
        guard let url = components?.url else { throw TripOccurrenceCoverage.Failure.invalidAction }
        var request = URLRequest(url: url); request.httpMethod = "PATCH"; request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(fields)
        let patchEndpoint = "PATCH rest/v1/trips (non-authority fields)"
        let exchange: (Data, URLResponse)
        do { exchange = try await URLSession.shared.data(for: request) }
        catch { throw stageError(error, .nonAuthorityPatch, trip, endpoint: patchEndpoint, operationId: operationId) }
        let (data, response) = exchange
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(PostgrestError.self, from: data))?.code
            if VineyardWriteAuthority.shared.handleServerCode(code, vineyardId: trip.vineyardId.uuidString) {
                throw VineyardWriteAuthority.Restricted(reason: "VT_READ_ONLY")
            }
            throw stageFailure(.nonAuthorityPatch, trip, endpoint: patchEndpoint,
                               httpStatus: (response as? HTTPURLResponse)?.statusCode, body: data,
                               operationId: operationId)
        }
        let rows: [TripOccurrenceCoverage.JSON]
        do { rows = try JSONDecoder().decode([TripOccurrenceCoverage.JSON].self, from: data) }
        catch {
            RecoveryDecodeEvidence.record(error, source: "supabase_response", operation: "trips.patchNonAuthorityFields")
            throw error
        }
        guard rows.count == 1, rows.first?[occurrence: "id"]?.occurrenceString?.lowercased() == trip.id.uuidString.lowercased() else {
            throw verificationFailure(.nonAuthorityPatch, trip, endpoint: patchEndpoint,
                                      code: TripSyncVerificationCode.nonAuthorityNoRow,
                                      detail: "The Trip details update answered \(rows.count) rows instead of exactly the Trip",
                                      operationId: operationId, httpStatus: http.statusCode)
        }
    }

    func fetchOccurrenceRecovery(tripId: UUID, operationIds: [String] = []) async throws -> TripOccurrenceCoverage.JSON {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        let params: TripOccurrenceCoverage.JSON = .object(["p_trip_id": .string(tripId.uuidString.lowercased()),
            "p_operation_ids": .array(operationIds.prefix(256).map { .string($0) })])
        let session = try await provider.client.auth.session
        let result = try await occurrenceRequest(rpc: "get_trip_occurrence_recovery_v1", params: params, accessToken: session.accessToken)
        let current = try await provider.client.auth.session
        guard current.user.id == session.user.id, current.refreshToken == session.refreshToken else { throw TripOccurrenceCoverage.Failure.scopeConflict }
        return result
    }

    /// Captured credentials prevent a switched account being substituted mid-replay by an SDK refresh.
    private func occurrenceRequest(rpc: String, params: TripOccurrenceCoverage.JSON, accessToken: String, writeVineyard: UUID? = nil) async throws -> TripOccurrenceCoverage.JSON {
        if let writeVineyard { try VineyardWriteAuthority.shared.requireWrite(vineyardId: writeVineyard.uuidString) }
        guard ["create_trip_with_occurrences_v1", "activate_trip_occurrences_v1", "apply_trip_occurrence_action_v1",
               "finalize_trip_occurrences_v1", "get_trip_occurrence_recovery_v1"].contains(rpc) else { throw TripOccurrenceCoverage.Failure.invalidAction }
        var request = URLRequest(url: provider.supabaseURL.appendingPathComponent("rest/v1/rpc/\(rpc)"))
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(params)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if let writeVineyard, VineyardWriteAuthority.shared.handleServerCode((try? JSONDecoder().decode(PostgrestError.self, from: data))?.code, vineyardId: writeVineyard.uuidString) {
                throw VineyardWriteAuthority.Restricted(reason: "VT_READ_ONLY")
            }
            // Keep everything the server said. The token is read from the raw
            // body exactly as before; no body without a token is relabelled
            // as a synthetic "unavailable" any more.
            throw OccurrenceRPCFailure.from(
                httpStatus: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
        }
        do { return try JSONDecoder().decode(TripOccurrenceCoverage.JSON.self, from: data) }
        catch {
            RecoveryDecodeEvidence.record(error, source: "supabase_response", operation: "rpc.\(rpc)")
            throw error
        }
    }

    func fetchAllAccessibleTrips() async throws -> [BackendTrip] {
        do {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        return try await provider.client
            .from("trips")
            .select()
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .limit(10_000)
            .execute()
            .value
        } catch {
            RecoveryDecodeEvidence.record(error, source: "supabase_response", operation: "trips.fetchAllAccessibleTrips")
            throw error
        }
    }

    func updateTripVineyardAssignment(id: UUID, vineyardId: UUID, paddockId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        _ = try await requireTripWrite(id)
        try VineyardWriteAuthority.shared.requireWrite(vineyardId: vineyardId.uuidString)
        try await provider.client
            .from("trips")
            .update(TripVineyardAssignmentUpdate(
                vineyardId: vineyardId,
                paddockId: paddockId,
                clientUpdatedAt: Date()
            ))
            .eq("id", value: id.uuidString)
            .execute()
    }

    func updateTripWorkTaskLink(id: UUID, workTaskId: UUID?) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        _ = try await requireTripWrite(id)
        try await provider.client
            .from("trips")
            .update(TripWorkTaskLinkUpdate(
                workTaskId: workTaskId,
                clientUpdatedAt: Date()
            ))
            .eq("id", value: id.uuidString)
            .execute()
    }

    /// Active journal resolver: empty SELECTs require the existing authoritative read-only RPC.
    /// The returned receipt is durably acknowledged by the journal, never by a missing-row heuristic.
    func resolveDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String {
        try await resolveDeletion(scope, verificationOnly: false, isCurrent: isCurrent)
    }

    func reverifyDeletion(_ scope: TripDeletionJournal.Scope, isCurrent: () -> Bool) async throws -> String {
        try await resolveDeletion(scope, verificationOnly: true, isCurrent: isCurrent)
    }

    private func resolveDeletion(_ scope: TripDeletionJournal.Scope, verificationOnly: Bool, isCurrent: () -> Bool) async throws -> String {
        let session = try await deletionSession()
        try Task.checkCancellation()
        func current() -> Bool { isCurrent() && deletionAuthority.accountGeneration == session.incarnation }
        guard session.actor == scope.account, current() else {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ACCOUNT_CHANGED")
        }
        try deletionAuthority.requireWrite(vineyardId: scope.vineyard.uuidString)
        guard var components = URLComponents(url: provider.supabaseURL.appendingPathComponent("rest/v1/trips"), resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "select", value: "id,vineyard_id,deleted_at"),
            URLQueryItem(name: "id", value: "eq.\(scope.trip.uuidString.lowercased())"), URLQueryItem(name: "limit", value: "2")]
        guard let url = components.url else { throw URLError(.badURL) }
        let bytes = try await deletionRequest(url: url, token: session.token)
        let rows = try JSONDecoder().decode([TripDeletionJournal.RemoteRow].self, from: bytes)
        let afterLookup = try await deletionSession()
        try Task.checkCancellation()
        guard afterLookup.actor == scope.account, afterLookup.incarnation == session.incarnation, current() else {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ACCOUNT_CHANGED")
        }
        if rows.isEmpty {
            let proof = try await deletionRequest(url: provider.supabaseURL.appendingPathComponent("rest/v1/rpc/confirm_trip_absence_v1"),
                token: session.token, body: JSONEncoder().encode(SoftDeleteTripRequest(tripId: scope.trip)))
            let receipt = try JSONDecoder().decode(TripDeleteAbsenceReceipt.self, from: proof)
            let afterReceipt = try await deletionSession()
            try Task.checkCancellation()
            try deletionAuthority.requireWrite(vineyardId: scope.vineyard.uuidString)
            guard current() else { throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ACCOUNT_CHANGED") }
            try receipt.requireConfirmation(trip: scope.trip, owner: scope.account, generation: session.incarnation,
                currentOwner: afterReceipt.actor, currentGeneration: afterReceipt.incarnation)
            return "SERVER_ABSENCE_VERIFIED:" + proof.base64EncodedString()
        }
        let deleted = try TripDeletionJournal.hasServerTombstone(rows, scope: scope)
        try deletionAuthority.requireWrite(vineyardId: scope.vineyard.uuidString)
        if deleted { return "SERVER_TOMBSTONE_OBSERVED" }
        guard !verificationOnly else {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
        }
        do {
            _ = try await deletionRequest(url: provider.supabaseURL.appendingPathComponent("rest/v1/rpc/soft_delete_trip"),
                token: session.token, body: JSONEncoder().encode(SoftDeleteTripRequest(tripId: scope.trip)))
        } catch let error as PostgrestError where ["42501", "P0001", "PGRST116"].contains(error.code ?? "") {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_SERVER_REVIEW_REQUIRED_\(error.code ?? "UNKNOWN")")
        }
        let afterDelete = try await deletionSession()
        try Task.checkCancellation()
        try deletionAuthority.requireWrite(vineyardId: scope.vineyard.uuidString)
        guard afterDelete.actor == scope.account, afterDelete.incarnation == session.incarnation, current() else {
            throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ACCOUNT_CHANGED")
        }
        return "DELETE_RPC_ACKNOWLEDGED"
    }

    /// Immutable credentials prevent an SDK refresh from substituting another actor.
    private func deletionRequest(url: URL, token: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"; request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await deletionTransport(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            if (response as? HTTPURLResponse)?.statusCode == 403 {
                throw TripDeletionJournal.Held(reason: "TRIP_DELETE_ACCESS_UNVERIFIED")
            }
            if let error = try? JSONDecoder().decode(PostgrestError.self, from: data) { throw error }
            throw URLError(.badServerResponse)
        }
        return data
    }

    func softDeleteTrip(id: UUID) async throws {
        guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
        _ = try await requireTripWrite(id)
        try await provider.client
            .rpc("soft_delete_trip", params: SoftDeleteTripRequest(tripId: id))
            .execute()
    }
}

nonisolated private struct TripVineyardAssignmentUpdate: Encodable, Sendable {
    let vineyardId: UUID
    let paddockId: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case clientUpdatedAt = "client_updated_at"
    }
}

/// Explicit `work_task_id` patch. Unlike the synthesized bulk upsert, this
/// forces `encode` (not `encodeIfPresent`) so a nil `workTaskId` is written as
/// an explicit SQL null — required to actually unlink a trip on the server.
nonisolated private struct TripWorkTaskLinkUpdate: Encodable, Sendable {
    let workTaskId: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case workTaskId = "work_task_id"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(workTaskId, forKey: .workTaskId)
        try container.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

nonisolated private struct SoftDeleteTripRequest: Encodable, Sendable {
    let tripId: UUID

    enum CodingKeys: String, CodingKey {
        case tripId = "p_trip_id"
    }
}

// MARK: - Typed wrapping of SDK and transport errors

nonisolated extension TripSyncStageFailure {
    /// Turns an SDK or transport error into a typed stage failure.
    ///
    /// Returns nil when the error must flow unchanged:
    ///  * `VT_READ_ONLY` - `SyncQueuePush.hold` reads exactly this code from a
    ///    `PostgrestError` to stop writing for a read-only vineyard.
    ///  * cancellation (`CancellationError`, `URLError.cancelled`).
    ///  * scope, storage, restriction and decoding errors, which already have
    ///    their own meaning and handling.
    static func wrapping(_ error: Error, stage: Stage, tripId: UUID,
                         operationId: String?, endpoint: String) -> TripSyncStageFailure? {
        if let existing = error as? TripSyncStageFailure { return existing }
        if let postgrest = error as? PostgrestError {
            if postgrest.code == "VT_READ_ONLY" { return nil }
            let message: String? = postgrest.message
            return TripSyncStageFailure(
                stage: stage, tripId: tripId, operationId: operationId, endpoint: endpoint,
                postgrestCode: postgrest.code, serverMessage: message,
                occurrenceCode: PostgrestAnswer.occurrenceToken(in: message ?? ""))
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return nil }
            return TripSyncStageFailure(stage: stage, tripId: tripId, operationId: operationId,
                                        endpoint: endpoint, transportCode: urlError.errorCode)
        }
        return nil
    }
}
