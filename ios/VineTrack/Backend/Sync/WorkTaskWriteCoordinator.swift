import Foundation

/// One-shot durable online initiation. Unconfirmed intents cannot be overwritten or retried implicitly.
struct WorkTaskWriteCoordinator {
    let persistence: PersistenceStore

    func submit(_ intent: WorkTaskWriteIntent, canWrite: () -> Bool, send: (WorkTaskWriteIntent) async throws -> WorkTask) async throws -> WorkTask {
        guard canWrite() else { throw WorkTaskPlanningWriteError.conflict }
        let outcome: PersistenceStore.LoadOutcome<WorkTaskWriteIntent> = persistence.loadOutcome(key: intent.persistenceKey)
        switch outcome {
        case .decoded(let prior) where !prior.acknowledged: throw WorkTaskPlanningWriteError.conflict
        case .failed: throw WorkTaskPlanningWriteError.conflict
        default: break
        }
        try persistence.saveOrThrow(intent, key: intent.persistenceKey)
        let saved = try await send(intent)
        guard canWrite(), saved.id == intent.taskID, saved.vineyardId == intent.vineyardID else { throw WorkTaskPlanningWriteError.conflict }
        var acknowledged = intent; acknowledged.acknowledged = true
        try persistence.saveOrThrow(acknowledged, key: intent.persistenceKey)
        return saved
    }
}
