import Foundation

/// Serializes full Insights sync passes independently for each vineyard.
@MainActor
final class VineyardInsightsSingleFlightCoordinator {
    private struct State {
        var isRunning = false
        var needsAnotherPass = false
    }

    private var states: [UUID: State] = [:]
    private var generation = 0

    var hasRunningPass: Bool { states.values.contains { $0.isRunning } }

    func request(vineyardID: UUID, runPass: @escaping () async -> Void) async {
        let requestGeneration = generation
        if states[vineyardID]?.isRunning == true {
            states[vineyardID]?.needsAnotherPass = true
            return
        }
        states[vineyardID] = State(isRunning: true, needsAnotherPass: false)

        repeat {
            guard requestGeneration == generation else { return }
            states[vineyardID]?.needsAnotherPass = false
            await runPass()
        } while requestGeneration == generation && states[vineyardID]?.needsAnotherPass == true

        guard requestGeneration == generation else { return }
        states[vineyardID] = nil
    }

    func invalidateAll() {
        generation += 1
        states.removeAll()
    }
}
