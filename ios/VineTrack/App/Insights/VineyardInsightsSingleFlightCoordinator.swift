import Foundation

/// Serializes full Insights sync passes independently for each vineyard.
@MainActor
final class VineyardInsightsSingleFlightCoordinator {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    private struct State {
        var isRunning = false
        var needsAnotherPass = false
    }

    private var states: [UUID: State] = [:]
    private var generation = 0

    var hasRunningPass: Bool { states.values.contains { $0.isRunning } }

    func request(vineyardID: UUID, shouldContinue: () -> Bool = { !Task.isCancelled }, runPass: @escaping () async -> Void) async {
        guard !Task.isCancelled else { return }
        let requestGeneration = generation
        if states[vineyardID]?.isRunning == true {
            states[vineyardID]?.needsAnotherPass = true
            return
        }
        states[vineyardID] = State(isRunning: true, needsAnotherPass: false)
        defer {
            if requestGeneration == generation { states[vineyardID] = nil }
        }

        repeat {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            states[vineyardID]?.needsAnotherPass = false
            await runPass()
        } while requestGeneration == generation && !Task.isCancelled && shouldContinue()
            && states[vineyardID]?.needsAnotherPass == true
    }

    func invalidateAll() {
        generation += 1
        states.removeAll()
    }
}
