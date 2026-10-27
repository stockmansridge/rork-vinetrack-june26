import Foundation

/// Yield only BETWEEN complete per-record applications. Persistence, conflict
/// handling and acknowledgement inside a row retain their original ordering.
@MainActor
enum ResponsiveRemoteApplication {
    static func forEach<Row>(
        _ rows: [Row], isCurrent: () -> Bool,
        apply: (Row) async throws -> Void
    ) async throws {
        for row in rows {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try await apply(row)
            await Task.yield()
        }
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }
}

extension MigratedDataStore {
    /// Account incarnation AND selection request generation, including A→B→A.
    /// Does not grant write authority or replace any service's admission checks.
    func remoteApplicationCurrentCheck() -> @MainActor () -> Bool {
        let generation = vineyardSelectionGeneration
        let selected = selectedVineyardId
        let account = currentUserIdProvider?()
        let authority = operationalWriteAuthority
        let binding = authority.accountBinding
        let incarnation = authority.accountGeneration
        return { [weak self] in
            guard let self else { return false }
            return self.vineyardSelectionGeneration == generation && self.selectedVineyardId == selected &&
                self.currentUserIdProvider?() == account && self.operationalWriteAuthority === authority &&
                authority.accountBinding == binding && authority.accountGeneration == incarnation
        }
    }
}
