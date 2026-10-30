import Foundation

/// Cancellation evidence is independent of both cache removal and queue acknowledgement.
/// Every mutation reloads disk: suspended writers cannot overwrite newer cancellation revisions.
@MainActor final class TripDeletionJournal {
    static let key = "vinetrack_trip_deletion_journal_v1"
    nonisolated struct Scope: Codable, Equatable, Sendable {
        let account: UUID
        let vineyard: UUID
        let trip: UUID
    }
    nonisolated struct Creation: Codable, Sendable {
        let scope: Scope
        var outcome: String // neverSent, uncertain, established
    }
    nonisolated struct Intent: Codable, Equatable, Sendable {
        let trip: UUID
        let revision: UUID
        let queuedAt: Date
        let scope: Scope?
        let originalEvidence: Data?
        let creationOutcome: String
        var reviewReason: String?
        var acknowledgement: String?
    }
    nonisolated struct State: Codable, Sendable {
        var creations: [UUID: Creation] = [:]
        var intents: [UUID: Intent] = [:]
        var history: [Intent] = []
    }
    nonisolated struct RemoteRow: Decodable, Sendable {
        let id: UUID
        let vineyard_id: UUID
        let deleted_at: String?
    }
    static func hasServerTombstone(_ rows: [RemoteRow], scope: Scope) throws -> Bool {
        guard rows.count == 1, let row = rows.first else {
            throw Held(reason: "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED")
        }
        guard row.id == scope.trip, row.vineyard_id == scope.vineyard else {
            throw Held(reason: "TRIP_DELETE_ORIGINAL_SCOPE_CONFLICT")
        }
        return row.deleted_at != nil
    }
    struct Held: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }
    private let persistence: PersistenceStore
    // Process-local admission supplements, never replaces, the durable uncertain marker.
    private static var inFlight: [UUID: Int] = [:]
    init(persistence: PersistenceStore? = nil) { self.persistence = persistence ?? .shared }
    func load() throws -> State {
        switch persistence.loadOutcome(key: Self.key) as PersistenceStore.LoadOutcome<State> {
        case .missing: return State()
        case .decoded(let state): return state
        case .failed: throw Held(reason: "TRIP_DELETE_EVIDENCE_UNREADABLE")
        }
    }
    func isCancelled(_ id: UUID) throws -> Bool {
        if try load().intents[id] != nil { return true }
        // Legacy ID-only cancellations must fence replay even before migration or
        // when a different writer (Sprays/occurrences) runs before Trip sync.
        struct LegacyQueue: Decodable { let pendingDeletes: [UUID: Date]? }
        switch persistence.loadOutcome(key: "vinetrack_trip_sync_metadata") as PersistenceStore.LoadOutcome<LegacyQueue> {
        case .missing: return false
        case .decoded(let queue): return queue.pendingDeletes?[id] != nil
        case .failed: throw Held(reason: "TRIP_DELETE_LEGACY_QUEUE_UNREADABLE")
        }
    }
    func requireNotCancelled(_ id: UUID) throws {
        if try isCancelled(id) { throw Held(reason: "TRIP_CANCELLED_CREATION_REPLAY_BLOCKED") }
    }
    /// Only a prospective creation commitment may establish never-sent evidence.
    /// Absence of historical upload metadata is deliberately NOT such evidence.
    func registerCreation(_ scope: Scope) throws {
        var state = try load()
        try requireNotCancelled(scope.trip)
        if let old = state.creations[scope.trip] {
            guard old.scope == scope else { throw Held(reason: "TRIP_DELETE_OWNERSHIP_CONFLICT") }
            return
        }
        state.creations[scope.trip] = Creation(scope: scope, outcome: "neverSent")
        try persistence.saveOrThrow(state, key: Self.key)
    }
    func beginSend(_ scope: Scope) throws {
        var state = try load()
        try requireNotCancelled(scope.trip)
        if let old = state.creations[scope.trip], old.scope != scope {
            throw Held(reason: "TRIP_DELETE_OWNERSHIP_CONFLICT")
        }
        state.creations[scope.trip] = Creation(scope: scope, outcome: "uncertain")
        try persistence.saveOrThrow(state, key: Self.key)
        Self.inFlight[scope.trip, default: 0] += 1
    }
    func endSend(_ scope: Scope, established: Bool) throws {
        Self.inFlight[scope.trip] = max(0, (Self.inFlight[scope.trip] ?? 1) - 1)
        guard established else { return }
        var state = try load()
        guard state.creations[scope.trip]?.scope == scope else { throw Held(reason: "TRIP_DELETE_OWNERSHIP_CONFLICT") }
        state.creations[scope.trip]?.outcome = "established"
        try persistence.saveOrThrow(state, key: Self.key)
    }
    @discardableResult func prepare(trip: UUID, queuedAt: Date, scope: Scope?, evidence: Data?, established: Bool = false, uncertainCreation: Bool = false) throws -> Intent {
        var state = try load()
        if let existing = state.intents[trip], existing.queuedAt == queuedAt { return existing }
        if let existing = state.intents[trip] { state.history.append(existing) }
        let creation = state.creations[trip]
        let conflict = scope != nil && creation != nil && scope != creation?.scope
        let uncertain = uncertainCreation && creation?.outcome != "neverSent"
        let outcome = established ? "established" : (uncertain ? "uncertain" : (creation?.outcome ?? "unknown"))
        let reason: String?
        if scope == nil { reason = "TRIP_DELETE_ORIGINAL_SCOPE_UNRESOLVED" }
        else if conflict { reason = "TRIP_DELETE_OWNERSHIP_CONFLICT" }
        else if Self.inFlight[trip, default: 0] > 0 { reason = "TRIP_DELETE_CREATE_IN_FLIGHT" }
        else if outcome == "uncertain" { reason = "TRIP_DELETE_CREATE_OUTCOME_UNKNOWN" }
        else { reason = nil }
        let intent = Intent(trip: trip, revision: UUID(), queuedAt: queuedAt, scope: scope,
            originalEvidence: evidence, creationOutcome: outcome, reviewReason: reason)
        state.intents[trip] = intent
        try persistence.saveOrThrow(state, key: Self.key)
        return intent
    }
    func hold(_ intent: Intent, reason: String) throws {
        var state = try load()
        guard state.intents[intent.trip]?.revision == intent.revision else { return }
        state.intents[intent.trip]?.reviewReason = reason
        try persistence.saveOrThrow(state, key: Self.key)
    }
    /// Only this historic ambiguity is eligible for read/verification again. Other holds stay closed.
    static func canReverify(_ intent: Intent) -> Bool {
        intent.reviewReason == "TRIP_DELETE_ABSENCE_OR_ACCESS_UNVERIFIED" && intent.scope != nil &&
            intent.creationOutcome != "uncertain" && intent.acknowledgement == nil
    }
    /// ISO8601 persistence drops subsecond dates; the durable UUID revision is
    /// the identity. Still compare every other retained evidence/state field so
    /// a newer hold or acknowledgement cannot be cleared by a suspended replay.
    private static func matches(_ current: Intent?, _ expected: Intent) -> Bool {
        guard let current else { return false }
        return current.trip == expected.trip && current.revision == expected.revision
            && current.scope == expected.scope && current.originalEvidence == expected.originalEvidence
            && current.creationOutcome == expected.creationOutcome
            && current.reviewReason == expected.reviewReason && current.acknowledgement == expected.acknowledgement
    }
    func acknowledge(_ intent: Intent, evidence: String) throws -> Bool {
        var state = try load()
        guard Self.matches(state.intents[intent.trip], intent),
              intent.reviewReason == nil || Self.canReverify(intent) else { return false }
        state.intents[intent.trip]?.acknowledgement = evidence
        state.intents[intent.trip]?.reviewReason = nil
        try persistence.saveOrThrow(state, key: Self.key)
        return true // Tombstone and original evidence deliberately remain after acknowledgement.
    }
    /// An acknowledgement only applies to this exact account, vineyard and deletion revision.
    func replay(_ intent: Intent, account: UUID?, vineyard: UUID,
                isCurrent: () -> Bool, remote: (Scope) async throws -> String) async throws -> Bool {
        let current = try load().intents[intent.trip]
        guard Self.matches(current, intent), intent.reviewReason == nil || Self.canReverify(intent) else { return false }
        guard let scope = intent.scope else { return false }
        guard account == scope.account, vineyard == scope.vineyard, isCurrent() else { return false }
        if intent.acknowledgement != nil { return true }
        guard Self.inFlight[intent.trip, default: 0] == 0 else {
            try hold(intent, reason: "TRIP_DELETE_CREATE_IN_FLIGHT"); return false
        }
        let evidence: String
        if intent.creationOutcome == "neverSent", intent.reviewReason == nil { evidence = "LOCAL_CREATION_NEVER_SENT_CANCELLED" }
        else { evidence = try await remote(scope) }
        guard isCurrent() else { return false }
        return try acknowledge(intent, evidence: evidence)
    }
}
