#if DEBUG
import Foundation

/// Opt-in, bounded stage evidence. Fixed labels only; never logs record contents or identities.
@MainActor
final class VineyardSwitchPerformanceProbe {
    // Explicit deinit keeps this non-isolated: Swift's implicit isolated deinit aborts on iOS 18.x–26.3 (swiftlang/swift#88036).
    deinit {}
    struct Sample {
        let stage: String
        let milliseconds: Double
        let mainThread: Bool
    }
    private var previous = ProcessInfo.processInfo.systemUptime
    private var stage = "entry"
    private let receive: ((Sample) -> Void)?
    init(receive: ((Sample) -> Void)?) { self.receive = receive }
    func next(_ label: String) {
        let now = ProcessInfo.processInfo.systemUptime
        receive?(Sample(stage: stage, milliseconds: (now - previous) * 1000, mainThread: Thread.isMainThread))
        stage = label
        previous = now
    }
    func finish() { next("finished") }
}
#endif
