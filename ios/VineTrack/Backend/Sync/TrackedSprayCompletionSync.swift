import Foundation
import Observation

/// Only an explicit new End can create an intent. Never discovers historical work.
@MainActor @Observable
final class TrackedSprayCompletionSync {
    static let shared = TrackedSprayCompletionSync(persistence: .shared)
    static let persistenceKey = "vinetrack_tracked_spray_completion_v1"

    struct Intent: Codable, Equatable, Sendable {
        let ownerId: UUID
        let vineyardId: UUID
        let tripId: UUID
        let sprayRecordId: UUID
        let endTime: Date
    }
    struct Receipt: Codable, Sendable {
        let intent: Intent
        let independentlyReadAt: Date
        let spraySyncVersion: Int?
    }
    private struct Snapshot: Codable {
        var pending: [Intent] = []
        var acknowledged: [Receipt] = []
    }
    enum Failure: Error, LocalizedError {
        case held
        var errorDescription: String? { "Original linked Spray completion could not be verified. Nothing was discarded; retain this Trip for review." }
    }
    @ObservationIgnored private let persistence: PersistenceStore
    private(set) var revision = 0
    private(set) var isReplaying = false

    init(persistence: PersistenceStore) { self.persistence = persistence }

    private func load() throws -> Snapshot {
        let outcome: PersistenceStore.LoadOutcome<Snapshot> = persistence.loadOutcome(key: Self.persistenceKey)
        switch outcome {
        case .missing: return Snapshot()
        case .failed: throw Failure.held
        case .decoded(let state):
            guard Set(state.pending.map(\.tripId)).count == state.pending.count else { throw Failure.held }
            return state
        }
    }

    func intents() throws -> [Intent] { try load().pending }

    /// Save before Trip End. A partial write on the Trip side retries with the first time.
    func prepare(ownerId: UUID, trip: Trip, sprays: [SprayRecord], proposed: Date) throws -> Date {
        guard trip.tripFunction == TripFunction.spraying.rawValue else { return proposed }
        let linked = sprays.filter { $0.canonicalTripId == trip.id }
        guard linked.count == 1, let spray = linked.first,
              spray.vineyardId == trip.vineyardId, !spray.isTemplate,
              spray.entrySource != "manual", spray.manualEntryId == nil else { throw Failure.held }
        var state = try load()
        if let original = state.pending.first(where: { $0.tripId == trip.id }) {
            guard original.ownerId == ownerId, original.vineyardId == trip.vineyardId,
                  original.sprayRecordId == spray.id else { throw Failure.held }
            return original.endTime
        }
        guard trip.isActive, trip.endTime == nil else { throw Failure.held }
        // Match the existing occurrence wire format without allowing replay-time drift.
        let end = Date(timeIntervalSince1970: floor(proposed.timeIntervalSince1970))
        guard !state.acknowledged.contains(where: { $0.intent.tripId == trip.id }) else { throw Failure.held }
        state.pending.append(Intent(ownerId: ownerId, vineyardId: trip.vineyardId, tripId: trip.id,
                           sprayRecordId: spray.id, endTime: end))
        try persistence.saveOrThrow(state, key: Self.persistenceKey)
        revision += 1
        return end
    }

    static func completionIssue(trip: Trip, sprays: [SprayRecord], expectedIds: Set<UUID> = []) -> String? {
        guard trip.tripFunction == TripFunction.spraying.rawValue else { return nil }
        guard sprays.count == 1, let spray = sprays.first else { return "LINKED_SPRAY_UNAVAILABLE_OR_AMBIGUOUS" }
        guard spray.canonicalTripId == trip.id, spray.vineyardId == trip.vineyardId,
              !spray.isTemplate, spray.entrySource != "manual", spray.manualEntryId == nil,
              expectedIds.isSubset(of: [spray.id]) else { return "LINKED_SPRAY_IDENTITY_UNVERIFIED" }
        guard let end = spray.endTime else { return "LINKED_SPRAY_COMPLETION_PENDING" }
        guard !trip.isActive, trip.endTime == end else { return "LINKED_SPRAY_END_TIME_MISMATCH" }
        return nil
    }

    /// All remote calls are supplied by the authenticated production adapter. Kept
    /// injectable so native regression exercises this exact durable replay loop.
    func replay(ownerId: UUID, vineyardId: UUID, isCurrent: () -> Bool,
                fetchTrip: (UUID) async throws -> Trip?,
                fetchSprays: (UUID) async throws -> [SprayRecord],
                dependenciesReady: (Trip) -> Bool,
                expectedSprayIds: (Trip) -> Set<UUID>,
                complete: (UUID) async throws -> SprayCompletionResponse,
                onVerified: (SprayRecord) -> Void) async {
        guard !isReplaying else { return }
        isReplaying = true
        defer { isReplaying = false }
        guard let snapshot = try? intents() else { return }
        for intent in snapshot where intent.ownerId == ownerId && intent.vineyardId == vineyardId {
            func current() -> Bool { isCurrent() && ((try? intents().contains(intent)) == true) }
            func matches(_ trip: Trip) -> Bool {
                trip.id == intent.tripId && trip.vineyardId == vineyardId &&
                trip.tripFunction == TripFunction.spraying.rawValue && !trip.isActive && trip.endTime == intent.endTime
            }
            do {
                guard current(), let trip = try await fetchTrip(intent.tripId), current(), matches(trip),
                      dependenciesReady(trip) else { continue }
                let before = try await fetchSprays(trip.id)
                guard current(), before.count == 1, var spray = before.first,
                      spray.id == intent.sprayRecordId else { continue }
                // Check identity/provenance even before completion exists.
                spray.endTime = trip.endTime
                guard Self.completionIssue(trip: trip, sprays: [spray], expectedIds: expectedSprayIds(trip)) == nil else { continue }
                if before.first?.endTime == nil {
                    guard current(), dependenciesReady(trip) else { continue }
                    let response = try await complete(intent.sprayRecordId)
                    guard current(), response.serverConfirmed, response.sprayRecordId == intent.sprayRecordId,
                          ["trip_end", "existing"].contains(response.completionSource), response.endTime == intent.endTime else { continue }
                }
                let afterTrip = try await fetchTrip(trip.id)
                let after = try await fetchSprays(trip.id)
                guard current(), let afterTrip, matches(afterTrip), dependenciesReady(afterTrip),
                      after.first?.id == intent.sprayRecordId,
                      Self.completionIssue(trip: afterTrip, sprays: after, expectedIds: expectedSprayIds(afterTrip)) == nil else { continue }
                var state = try load()
                guard current(), state.pending.contains(intent), let verified = after.first else { continue }
                state.pending.removeAll { $0 == intent }
                state.acknowledged.append(Receipt(intent: intent, independentlyReadAt: Date(), spraySyncVersion: verified.syncVersion))
                // Receipt and retirement are one durable write. Failure retains the intent.
                try persistence.saveOrThrow(state, key: Self.persistenceKey)
                revision += 1
                onVerified(verified)
            } catch {
                // Offline, lost response, scope switch, unreadable state and failed
                // writes all retain the original operation; never mint a new End.
                continue
            }
        }
    }
}
