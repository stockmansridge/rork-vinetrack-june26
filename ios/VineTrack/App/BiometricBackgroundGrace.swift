import Foundation

/// A process-local, monotonic background grace period; cold restores are gated separately.
nonisolated enum BiometricBackgroundGrace {
    static func shouldLock(elapsed: Duration, isEnabled: Bool) -> Bool {
        isEnabled && elapsed >= .seconds(3_600)
    }
}
