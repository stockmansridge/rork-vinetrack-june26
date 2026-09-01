import Foundation
import os

/// Coordinates automatic recovery of the local block (paddock) cache.
///
/// Two situations flow through here:
///   1. The persisted `vinetrack_paddocks` JSON exists but fails to decode
///      (one corrupt record poisons the whole shared array). The failure is
///      logged with the persistence key and underlying error, the corrupt
///      payload is quarantined by the caller, and a full server re-pull is
///      flagged for the next block sync.
///   2. `PaddockSyncService` consumes the flag at the start of a sync and
///      drops every `lastSync` watermark, so the next pull per vineyard is a
///      full fetch instead of an incremental one that would return nothing.
@MainActor
enum PaddockCacheRecovery {
    /// UserDefaults flag set on decode failure and consumed by the next sync.
    /// Internal (not private) so tests can reset it deterministically.
    static let pendingDefaultsKey = "vinetrack_paddock_cache_decode_recovery_pending"

    private static let logger = Logger(subsystem: "com.rork.vinetrack", category: "PaddockCacheRecovery")

    /// Record that the local paddock cache could not be decoded. Logs the
    /// persistence key + underlying error and flags a full server recovery.
    static func noteDecodeFailure(key: String, error: Error, defaults: UserDefaults = .standard) {
        logger.error("Block cache decode FAILED for persistence key '\(key, privacy: .public)': \(String(describing: error), privacy: .public). Automatic server recovery will be attempted on the next block sync.")
        #if DEBUG
        print("[PaddockCacheRecovery] decode failure for '\(key)': \(error) — automatic server recovery will be attempted on the next block sync")
        #endif
        defaults.set(true, forKey: pendingDefaultsKey)
    }

    /// True when a decode failure is awaiting server recovery.
    static func isRecoveryPending(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: pendingDefaultsKey)
    }

    /// Consume the pending-recovery flag. Returns true exactly once per
    /// flagged failure; the caller must then reset the sync watermarks.
    static func consumePendingRecovery(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: pendingDefaultsKey) else { return false }
        defaults.removeObject(forKey: pendingDefaultsKey)
        return true
    }
}
