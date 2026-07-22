import Foundation
import SwiftUI

/// Central constants and tracking helpers for the VineTrack Web Portal
/// awareness prompt. Used by `VineTrackPortalPromptSheet` and the
/// trigger sites (first vineyard creation, first team invite, setup
/// completion) to present a one-time education prompt to managers and
/// supervisors.
enum VineTrackPortal {
    /// Canonical web portal URL. Centralised so it can be updated in one
    /// place later without touching every call site.
    static let urlString: String = "https://portal.vinetrack.com.au"

    static var url: URL? { URL(string: urlString) }

    static let displayHost: String = "portal.vinetrack.com.au"
}

/// Where the portal-awareness prompt was triggered from. The raw value is
/// used as a `UserDefaults` suffix so each trigger can be tracked
/// independently — we never show the same trigger twice.
enum PortalPromptTrigger: String, Sendable, Identifiable {
    case firstVineyard
    case firstInvite
    case setupComplete

    var id: String { rawValue }

    var storageKey: String {
        "vt_portal_prompt_seen_\(rawValue)"
    }
}

extension Notification.Name {
    /// Fired by any view that wants the global portal-awareness prompt to
    /// appear. `userInfo` carries the `PortalPromptTrigger.rawValue` under
    /// `"trigger"`. The listener in `NewMainTabView` decides whether to
    /// show based on role and previous interaction tracking.
    static let vineTrackPortalPromptRequest = Notification.Name("VineTrackPortalPromptRequest")
}

/// Lightweight UserDefaults-backed tracker. Marking a trigger as seen
/// (either via dismiss or open) prevents it from re-triggering, so the
/// prompt only ever appears once per milestone.
enum PortalPromptTracker {
    static func hasSeen(_ trigger: PortalPromptTrigger) -> Bool {
        UserDefaults.standard.bool(forKey: trigger.storageKey)
    }

    static func markSeen(_ trigger: PortalPromptTrigger) {
        UserDefaults.standard.set(true, forKey: trigger.storageKey)
    }

    /// Posts a request to show the portal prompt for the given trigger.
    /// Safe to call from any view — the listener will silently ignore if
    /// the trigger has already been seen, or the user's role shouldn't
    /// see the prompt.
    static func requestIfUnseen(_ trigger: PortalPromptTrigger) {
        guard !hasSeen(trigger) else { return }
        NotificationCenter.default.post(
            name: .vineTrackPortalPromptRequest,
            object: nil,
            userInfo: ["trigger": trigger.rawValue]
        )
    }
}
