import Foundation

/// Current account/vineyard projection only; it never mutates receipt or cancellation evidence.
nonisolated struct TripRetainedState: Equatable {
    struct Spray: Equatable {
        let trip: UUID
        let record: UUID
        let reason: String
    }
    var sprays: [Spray] = []
    var deletions: [UUID] = []
    var inspectionError: String?
    var total: Int { sprays.count + deletions.count }
    var summary: String? {
        if let inspectionError { return "Retained evidence needs review: \(inspectionError). Open Sync diagnostics; no evidence was cleared." }
        guard total > 0 else { return nil }
        var parts: [String] = []
        if !sprays.isEmpty { parts.append("\(sprays.count) saved spray job(s) awaiting a verified receipt") }
        if !deletions.isEmpty { parts.append("\(deletions.count) Trip deletion(s) awaiting verification") }
        return parts.joined(separator: "; ") + ". Other sync areas can continue. Use Sync Trips to recheck eligible deletions; open diagnostics for retained identities."
    }
}
