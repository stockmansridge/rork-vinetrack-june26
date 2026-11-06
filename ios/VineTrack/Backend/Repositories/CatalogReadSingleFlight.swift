import Foundation

/// Main-actor coordination of overlapping, account-scoped reference reads only.
/// Completed results are removed; uploads and permission checks never use this helper.
@MainActor
final class CatalogReadSingleFlight<Value: Sendable> {
    private var flights: [UUID: (id: UUID, task: Task<Value, Error>)] = [:]

    // Non-isolated on purpose. An isolated deinit both trips the Swift 6.3 Release
    // inliner for generic classes (swiftlang/swift#90385, #90625) and aborts at
    // release on the iOS 18.x–26.3 runtime (swiftlang/swift#88036). Stored
    // properties are a dictionary of Task handles (Sendable); nothing needs the
    // main actor to be destroyed.
    deinit {}

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
