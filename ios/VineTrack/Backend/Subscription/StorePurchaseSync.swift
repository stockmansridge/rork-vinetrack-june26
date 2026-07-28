import Foundation

/// Pure, testable plan for the bounded post-purchase synchronisation
/// (Phase 2B §13). After a successful purchase or Restore Purchases the user
/// already has access through the RevenueCat fallback; VineTrack then polls
/// `get_my_vinetrack_access()` on a short bounded schedule until Supabase
/// reflects the verified store purchase (webhook propagation), and stops —
/// it never blocks entry into the app and never polls indefinitely.
nonisolated struct StorePurchaseSyncPlan: Sendable {

    /// Poll schedule in seconds: immediate → 2s → 5s → 10s.
    static let delays: [TimeInterval] = [0, 2, 5, 10]

    enum Verdict: Equatable, Sendable {
        /// Supabase now reflects the verified purchase — stop polling.
        case synced
        /// Keep waiting for the webhook; poll again after the next delay.
        case retry
        /// RevenueCat itself no longer grants — there is nothing to wait for.
        case stopNoEntitlement
        /// Schedule exhausted; RevenueCat fallback keeps the user unlocked and
        /// the next regular refresh (foreground/launch) retries naturally.
        case timedOut
    }

    /// Decide what to do after one poll attempt.
    /// - Parameters:
    ///   - attempt: zero-based index into `delays` for the poll just made.
    ///   - serverGranted: Supabase resolver returned has_access = true.
    ///   - revenueCatEntitled: RevenueCat still reports `pro` active.
    static func verdict(afterAttempt attempt: Int, serverGranted: Bool, revenueCatEntitled: Bool) -> Verdict {
        if serverGranted { return .synced }
        if !revenueCatEntitled { return .stopNoEntitlement }
        return attempt >= delays.count - 1 ? .timedOut : .retry
    }
}
