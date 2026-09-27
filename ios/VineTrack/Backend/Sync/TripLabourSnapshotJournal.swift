import Foundation
import Supabase

/// Original start-time financial facts live outside the operational Trip model.
/// The journal is written atomically before the trip starts and survives offline replay.
@MainActor
final class TripLabourSnapshotJournal {
    static let shared = TripLabourSnapshotJournal()

    nonisolated struct Snapshot: Codable, Sendable {
        let tripId: UUID
        let workerUserId: UUID?
        let workerTypeId: UUID?
        let workerTypeName: String?
        let hourlyRate: Double?
        let capturedAt: Date
    }

    private nonisolated struct CaptureRequest: Encodable, Sendable {
        let tripId: UUID
        let workerUserId: UUID?
        let workerTypeId: UUID?
        let workerTypeName: String?
        let hourlyRate: Double?
        let capturedAt: Date

        enum CodingKeys: String, CodingKey {
            case tripId = "p_trip_id"
            case workerUserId = "p_worker_user_id"
            case workerTypeId = "p_worker_type_id"
            case workerTypeName = "p_worker_type_name"
            case hourlyRate = "p_hourly_rate"
            case capturedAt = "p_captured_at"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(tripId, forKey: .tripId)
            if let workerUserId { try c.encode(workerUserId, forKey: .workerUserId) }
            else { try c.encodeNil(forKey: .workerUserId) }
            if let workerTypeId { try c.encode(workerTypeId, forKey: .workerTypeId) }
            else { try c.encodeNil(forKey: .workerTypeId) }
            if let workerTypeName { try c.encode(workerTypeName, forKey: .workerTypeName) }
            else { try c.encodeNil(forKey: .workerTypeName) }
            if let hourlyRate { try c.encode(hourlyRate, forKey: .hourlyRate) }
            else { try c.encodeNil(forKey: .hourlyRate) }
            try c.encode(capturedAt, forKey: .capturedAt)
        }
    }

    private nonisolated struct FinaliseRequest: Encodable, Sendable {
        let tripId: UUID
        enum CodingKeys: String, CodingKey { case tripId = "p_trip_id" }
    }

    private enum JournalError: Error { case unreadable }
    private let persistence: PersistenceStore
    private let key = "vinetrack_trip_labour_original_facts"

    init(persistence: PersistenceStore = .shared) { self.persistence = persistence }

    func record(_ snapshot: Snapshot) throws {
        let savedOutcome: PersistenceStore.LoadOutcome<[UUID: Snapshot]> = persistence.loadOutcome(key: key)
        var saved: [UUID: Snapshot]
        switch savedOutcome {
        case .decoded(let rows): saved = rows
        case .missing: saved = [:]
        case .failed: throw JournalError.unreadable
        }
        guard saved[snapshot.tripId] == nil else { return }
        saved[snapshot.tripId] = snapshot
        try persistence.saveOrThrow(saved, key: key)
    }

    func contains(tripId: UUID) -> Bool {
        let savedOutcome: PersistenceStore.LoadOutcome<[UUID: Snapshot]> = persistence.loadOutcome(key: key)
        switch savedOutcome {
        case .decoded(let rows): return rows[tripId] != nil
        case .missing: return false
        case .failed: return true // Block destructive rebuild until corrupt facts are recovered.
        }
    }

    /// No lookup of current membership or today's catalogue occurs during replay.
    func replay(trips: [Trip]) async {
        guard SupabaseClientProvider.shared.isConfigured else { return }
        let savedOutcome: PersistenceStore.LoadOutcome<[UUID: Snapshot]> = persistence.loadOutcome(key: key)
        guard case .decoded(var saved) = savedOutcome else { return }
        for (tripId, snapshot) in saved {
            guard let trip = trips.first(where: { $0.id == tripId }) else { continue }
            do {
                try await SupabaseClientProvider.shared.client.rpc(
                    "capture_trip_labour_start_v1",
                    params: CaptureRequest(tripId: tripId, workerUserId: snapshot.workerUserId,
                                           workerTypeId: snapshot.workerTypeId,
                                           workerTypeName: snapshot.workerTypeName,
                                           hourlyRate: snapshot.hourlyRate, capturedAt: snapshot.capturedAt)
                ).execute()
                guard !trip.isActive, trip.endTime != nil else { continue }
                try await SupabaseClientProvider.shared.client.rpc(
                    "finalise_trip_labour_v1", params: FinaliseRequest(tripId: tripId)
                ).execute()
                var updated = saved
                updated.removeValue(forKey: tripId)
                try persistence.saveOrThrow(updated, key: key)
                saved = updated
            } catch {
                // Retain the exact original snapshot for the next authenticated sync.
                continue
            }
        }
    }
}
