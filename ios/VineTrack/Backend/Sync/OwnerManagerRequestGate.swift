import Foundation

/// Request guards complement, never replace, the server's vineyard membership rules.
@MainActor
enum OwnerManagerRequestGate {
    static func allows(_ role: BackendRole?) -> Bool { role == .owner || role == .manager }

    static func financials<Row>(role: BackendRole?, request: () async throws -> [Row]) async throws -> [Row] {
        guard allows(role) else { return [] }
        return try await request()
    }

    static func deleteWorkerType(role: BackendRole?, request: () async throws -> Void) async throws {
        guard allows(role) else { throw WorkerTypeDeletePermissionError() }
        try await request()
    }

    static func isTerminalDeleteError(_ error: Error) -> Bool {
        if error is WorkerTypeDeletePermissionError { return true }
        let message = (String(describing: error) + " " + error.localizedDescription).lowercased()
        return message.contains("42501") || message.contains("insufficient permissions")
            || message.contains("permission denied") || message.contains("owner or manager")
            || (error as NSError).code == 403 || message.contains("worker type not found")
            || message.contains("worker type does not exist")
            || message.contains("already deleted") || message.contains("already absent")
    }
}

nonisolated struct WorkerTypeDeletePermissionError: LocalizedError {
    var errorDescription: String? { "Only the vineyard Owner or Manager can delete Worker Types." }
}
