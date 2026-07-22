import Foundation
import os

/// Lightweight, privacy-safe diagnostics for the app launch / auth-restoration
/// routing path. These logs let us see *which* state drove the screen choice on
/// cold launch (loading → login → no-vineyards → dashboard) without ever
/// recording tokens, emails, or other sensitive auth data.
///
/// Use `StartupDiagnostics.log(...)` for free-form milestones and
/// `StartupDiagnostics.route(...)` when the root view settles on a screen.
enum StartupDiagnostics {
    private static let logger = Logger(subsystem: "com.vinetrack.app", category: "startup")

    /// The screen the root view decided to present after evaluating auth,
    /// onboarding, vineyard membership and subscription gates.
    enum Route: String {
        case sessionRestoring = "session-restoring"
        case biometricLock = "biometric-lock"
        case login = "login"
        case onboarding = "onboarding"
        case vineyardLoading = "vineyard-loading"
        case vineyardLoadFailed = "vineyard-load-failed"
        case noVineyards = "no-vineyards"
        case disclaimer = "disclaimer"
        case subscriptionLoading = "subscription-loading"
        case offlineAccessNotice = "offline-access-notice"
        case paywall = "paywall"
        case dashboard = "dashboard"
    }

    static func log(_ message: String) {
        logger.log("[startup] \(message, privacy: .public)")
    }

    static func route(_ route: Route) {
        logger.log("[startup] route selected: \(route.rawValue, privacy: .public)")
    }
}
