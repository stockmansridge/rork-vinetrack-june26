import SwiftUI
import UIKit

/// Centralised idle-timer control so we never leave the screen pinned awake
/// after a trip ends. ActiveTripView (or any other "must stay awake" screen)
/// calls `acquire`/`release` with a stable owner key. The idle timer is only
/// disabled while at least one owner holds it AND the user preference allows.
@MainActor
final class ScreenAwakeManager {
    static let shared = ScreenAwakeManager()

    /// User preference key shared with `@AppStorage` in settings UI.
    static let preferenceKey = "keepScreenAwakeDuringTrips"

    private var owners: Set<String> = []

    private init() {}

    /// Whether the user has opted into keep-awake during active trips.
    /// Defaults to `true` because field operators typically want it on.
    var preferenceEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.preferenceKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: Self.preferenceKey)
    }

    func acquire(_ owner: String) {
        owners.insert(owner)
        applyState()
    }

    func release(_ owner: String) {
        owners.remove(owner)
        applyState()
    }

    /// Force-restore the system idle timer. Use as a safety path on app
    /// termination or when toggling the preference off mid-trip.
    func forceRestore() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Re-evaluate state when the user flips the preference toggle.
    func preferenceDidChange() {
        applyState()
    }

    private func applyState() {
        let shouldKeepAwake = preferenceEnabled && !owners.isEmpty
        UIApplication.shared.isIdleTimerDisabled = shouldKeepAwake
    }
}
