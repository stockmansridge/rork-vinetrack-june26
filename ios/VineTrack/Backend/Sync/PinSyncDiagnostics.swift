import Foundation
import Observation

/// Diagnostics-only store for the most recent pin push payload + result.
/// Used by `BackendDiagnosticView` so we can verify pin sync (especially
/// `created_by`) without needing Xcode console logs.
@Observable
@MainActor
final class PinSyncDiagnostics {
    static let shared = PinSyncDiagnostics()

    struct Snapshot: Sendable {
        var pinId: UUID
        var title: String?
        var createdByText: String?
        var createdByUserId: UUID?
        var authUserId: UUID?
        var payloadCreatedBy: UUID?
        var completedByUserId: UUID?
        var pushedAt: Date
        var success: Bool
        var errorMessage: String?
    }

    private(set) var last: Snapshot?
    private(set) var lastBatchSize: Int = 0
    private(set) var lastBatchAt: Date?
    private(set) var lastBatchSuccess: Bool = false
    private(set) var lastBatchError: String?

    private init() {}

    func recordPush(
        pin: VinePin,
        payload: BackendPinUpsert,
        authUserId: UUID?
    ) {
        last = Snapshot(
            pinId: pin.id,
            title: pin.buttonName,
            createdByText: pin.createdBy,
            createdByUserId: pin.createdByUserId,
            authUserId: authUserId,
            payloadCreatedBy: payload.createdBy,
            completedByUserId: payload.completedByUserId,
            pushedAt: Date(),
            success: false,
            errorMessage: nil
        )
    }

    func recordBatchResult(count: Int, success: Bool, errorMessage: String?) {
        lastBatchSize = count
        lastBatchAt = Date()
        lastBatchSuccess = success
        lastBatchError = errorMessage
        if var snap = last {
            snap.success = success
            snap.errorMessage = errorMessage
            last = snap
        }
    }

    var formattedReport: String {
        guard let last else {
            return "No pin push has been recorded in this session yet."
        }
        let timestamp = last.pushedAt.formatted(.iso8601)
        var lines: [String] = []
        lines.append("Last pin push diagnostics")
        lines.append("Pushed at: \(timestamp)")
        lines.append("Pin id: \(last.pinId.uuidString)")
        lines.append("Title: \(last.title ?? "nil")")
        lines.append("createdBy (text): \(last.createdByText ?? "nil")")
        lines.append("createdByUserId: \(last.createdByUserId?.uuidString ?? "nil")")
        lines.append("auth.userId: \(last.authUserId?.uuidString ?? "nil")")
        lines.append("payload.created_by: \(last.payloadCreatedBy?.uuidString ?? "nil")")
        lines.append("payload.completed_by_user_id: \(last.completedByUserId?.uuidString ?? "nil")")
        lines.append("Result: \(last.success ? "success" : "failed")")
        if let err = last.errorMessage, !err.isEmpty {
            lines.append("Error: \(err)")
        }
        if let batchAt = lastBatchAt {
            lines.append("Batch size: \(lastBatchSize) at \(batchAt.formatted(.iso8601))")
        }
        return lines.joined(separator: "\n")
    }
}
