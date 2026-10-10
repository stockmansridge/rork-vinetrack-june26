import Foundation

/// Main-actor coordination of overlapping, account-scoped reference reads only.
/// Completed results are removed; uploads and permission checks never use this helper.
@MainActor
final class CatalogReadSingleFlight<Value: Sendable> {
    private var flights: [UUID: (id: UUID, task: Task<Value, Error>)] = [:]

    func read(account: UUID, request: @escaping @MainActor @Sendable () async throws -> Value) async throws -> Value {
        if let existing = flights[account] {
            let value = try await existing.task.value
            try Task.checkCancellation()
            return value
        }
        let id = UUID()
        let task: Task<Value, Error> = Task { [weak self] in
            defer {
                if self?.flights[account]?.id == id { self?.flights.removeValue(forKey: account) }
            }
            return try await request()
        }
        flights[account] = (id, task)
        defer {
            if flights[account]?.id == id { flights.removeValue(forKey: account) }
        }
        let value = try await task.value
        try Task.checkCancellation()
        return value
    }
}
