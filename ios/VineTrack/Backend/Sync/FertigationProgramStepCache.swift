import Foundation

/// Last canonical list, never a locally authored template or permission to write.
@MainActor
final class FertigationProgramStepCache {
    nonisolated struct Snapshot: Codable, Sendable {
        let ownerId: UUID
        let vineyardId: UUID
        let fetchedAt: Date
        let steps: [FertigationDomain.ProgramStep]
    }
    struct Result {
        let steps: [FertigationDomain.ProgramStep]
        let isCached: Bool
        let fetchedAt: Date
    }
    private let directory: URL
    init(directory: URL = URL.applicationSupportDirectory.appending(path: "vinetrack-fertigation-program-steps")) {
        self.directory = directory
    }
    private func file(ownerId: UUID, vineyardId: UUID) -> URL {
        directory.appending(path: "\(ownerId.uuidString)-\(vineyardId.uuidString).json")
    }
    private func adminFile(_ ownerId: UUID) -> URL { directory.appending(path: "admin-\(ownerId.uuidString).json") }
    private func write<T: Encodable>(_ value: T, to file: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }
    private func cached(ownerId: UUID, vineyardId: UUID) throws -> Result? {
        let file = file(ownerId: ownerId, vineyardId: vineyardId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: file))
        guard snapshot.ownerId == ownerId, snapshot.vineyardId == vineyardId,
              snapshot.steps.allSatisfy({ $0.isSelectable(vineyardId: vineyardId, isSystemAdmin: true) }) else {
            throw FertigationDomain.Failure.invalidStep
        }
        return Result(steps: snapshot.steps, isCached: true, fetchedAt: snapshot.fetchedAt)
    }
    /// Uses the existing System Admin authority. A failed check can reuse only this account's
    /// previously confirmed status; an affirmative denial disables fallback across vineyards.
    func load(ownerId: UUID, vineyardId: UUID,
              adminCheck: () async throws -> Bool,
              isCurrentAccount: () -> Bool = { true },
              fetch: () async throws -> [FertigationDomain.ProgramStep]) async throws -> Result? {
        guard isCurrentAccount() else { throw CancellationError() }
        let admin: Bool
        do { admin = try await adminCheck() }
        catch {
            if error is CancellationError { throw error }
            guard isCurrentAccount() else { throw CancellationError() }
            guard let data = try? Data(contentsOf: adminFile(ownerId)),
                  (try? JSONDecoder().decode(Bool.self, from: data)) == true else { return nil }
            return try cached(ownerId: ownerId, vineyardId: vineyardId)
        }
        guard isCurrentAccount() else { throw CancellationError() }
        try write(admin, to: adminFile(ownerId))
        guard admin else { throw FertigationDomain.Failure.systemAdminRequired }
        let steps: [FertigationDomain.ProgramStep]
        do {
            steps = try await fetch()
            guard isCurrentAccount() else { throw CancellationError() }
            guard steps.allSatisfy({ $0.isSelectable(vineyardId: vineyardId, isSystemAdmin: true) }) else {
                throw FertigationDomain.Failure.invalidStep
            }
        } catch {
            if error is CancellationError { throw error }
            guard isCurrentAccount() else { throw CancellationError() }
            if case FertigationDomain.Failure.systemAdminRequired = error {
                try write(false, to: adminFile(ownerId))
                throw error
            }
            return try cached(ownerId: ownerId, vineyardId: vineyardId)
        }
        let snapshot = Snapshot(ownerId: ownerId, vineyardId: vineyardId, fetchedAt: Date(), steps: steps)
        try write(snapshot, to: file(ownerId: ownerId, vineyardId: vineyardId))
        return Result(steps: steps, isCached: false, fetchedAt: snapshot.fetchedAt)
    }
}
