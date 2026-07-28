import Foundation
import Observation

// MARK: - Pure decision core

/// How the combined VineTrack access decision resolved.
nonisolated enum EntitlementOutcome: Equatable, Sendable {
    /// The shared Supabase resolver granted access (portal subscription,
    /// Internal Unlimited grant, enterprise, assigned licence, server trial,
    /// or an app-store purchase recorded in Supabase).
    case grantedBySupabase
    /// RevenueCat `pro` granted access. `mismatchWithServer` is true when the
    /// server explicitly denied — recorded as a diagnostic, never blocking.
    case grantedByRevenueCat(mismatchWithServer: Bool)
    /// Inside the legacy client-side 3-month free window (temporary fallback).
    case grantedByLegacyTrial
    /// Supabase was unreachable and an eligible offline cache granted access.
    case offlineCachedAccess
    /// Nothing could be verified (typically offline with no eligible cache) —
    /// show the "connect to verify" notice, never the paywall.
    case unverified
    /// Every source confirmed no access — show the paywall.
    case denied
}

/// Result of the `get_my_vinetrack_access()` call for one refresh.
nonisolated enum EntitlementServerResult: Equatable, Sendable {
    /// Server row grants app access.
    case granted
    /// Server explicitly returned no access (a CONFIRMED denial).
    case denied
    /// Transport/auth/config failure — NOT a denial.
    case unreachable
}

/// Pure, testable decision core for the Phase 2A access gate.
///
/// Rules (in the agreed order):
///   Supabase grants → access, RevenueCat paywall suppressed.
///   Supabase denies → evaluate RevenueCat `pro` (mismatch diagnostic),
///                     then the temporary legacy 3-month window.
///   Supabase unreachable → eligible offline cache, then RevenueCat's own
///                     cached entitlement, then the legacy window; a network
///                     failure is never treated as a confirmed denial.
///   Nothing grants  → denied (paywall) when verifiable, otherwise unverified.
nonisolated struct EntitlementDecision {

    struct CacheInfo: Equatable, Sendable {
        var belongsToCurrentUser: Bool
        var wasEntitled: Bool
        var verifiedAt: Date
        /// Earliest known entitlement expiry captured at verification time.
        var knownExpiresAt: Date?
    }

    struct Input: Sendable {
        /// Whether the shared-entitlement rollout flag covers this user.
        var enforcementEnabled: Bool
        var server: EntitlementServerResult
        var revenueCatEntitled: Bool
        /// RevenueCat produced a definitive status (subscribed / not / failure).
        var revenueCatResolved: Bool
        var inLegacyFreeWindow: Bool
        var isOffline: Bool
        var cache: CacheInfo?
        var now: Date
        var offlineGraceDays: Int = 30
    }

    /// A cached positive verification is usable only when it belongs to the
    /// current user, granted access, is inside the offline grace window, and
    /// has not passed a KNOWN entitlement expiry.
    static func isCacheEligible(_ cache: CacheInfo?, now: Date, graceDays: Int) -> Bool {
        guard let cache, cache.belongsToCurrentUser, cache.wasEntitled else { return false }
        if let expiry = cache.knownExpiresAt, now >= expiry { return false }
        let graceEnds = cache.verifiedAt.addingTimeInterval(TimeInterval(graceDays) * 86_400)
        return now < graceEnds
    }

    static func resolve(_ input: Input) -> EntitlementOutcome {
        let cacheEligible = isCacheEligible(input.cache, now: input.now, graceDays: input.offlineGraceDays)

        guard input.enforcementEnabled else {
            // Legacy path — mirrors the pre-Phase-2A RevenueCat-only gate so
            // disabling the feature flag restores today's behaviour exactly.
            if input.revenueCatEntitled { return .grantedByRevenueCat(mismatchWithServer: false) }
            if input.inLegacyFreeWindow { return .grantedByLegacyTrial }
            if input.isOffline { return cacheEligible ? .offlineCachedAccess : .unverified }
            return input.revenueCatResolved ? .denied : .unverified
        }

        switch input.server {
        case .granted:
            return .grantedBySupabase

        case .denied:
            // A CONFIRMED server denial: the offline cache must not rescue
            // access, but the temporary migration fallbacks still apply so no
            // existing App Store customer is locked out.
            if input.revenueCatEntitled { return .grantedByRevenueCat(mismatchWithServer: true) }
            if input.inLegacyFreeWindow { return .grantedByLegacyTrial }
            return .denied

        case .unreachable:
            // Network failure ≠ denial. Prefer the last verified server-backed
            // cache, then RevenueCat's own (SDK-cached) entitlement.
            if cacheEligible { return .offlineCachedAccess }
            if input.revenueCatEntitled { return .grantedByRevenueCat(mismatchWithServer: false) }
            if input.inLegacyFreeWindow { return .grantedByLegacyTrial }
            if input.isOffline { return .unverified }
            return input.revenueCatResolved ? .denied : .unverified
        }
    }
}

// MARK: - Observable gate service

/// Central Phase 2A access gate. ONE service owns the server refresh, the
/// RevenueCat fallback, the offline cache, paywall state, and diagnostics —
/// `NewBackendRootView` routes exclusively on this (replacing the previous
/// RevenueCat-only `SubscriptionService.hasAccess` decision).
///
/// The paywall is presented ONLY for the final `.denied` state:
///   Supabase grants → no paywall. Supabase denies → RevenueCat evaluated.
///   RevenueCat grants → no paywall. Neither grants → paywall.
@Observable
@MainActor
final class EntitlementGate {

    /// Coalesces bursty SwiftUI-driven refreshes (foreground + task modifiers).
    static let minimumRefreshInterval: TimeInterval = 15

    enum Phase: Equatable {
        case idle
        case checking
        case resolved(EntitlementOutcome)
    }

    private(set) var phase: Phase = .idle
    /// Whether the shared-entitlement rollout flag covers this user (server
    /// value; cold-starts from the last persisted snapshot).
    private(set) var enforcementEnabled: Bool = false
    /// Last decoded resolver row (diagnostics only).
    private(set) var lastServerAccess: BackendVineTrackAccess?
    private(set) var lastServerResult: EntitlementServerResult?
    private(set) var lastRefreshedAt: Date?
    /// True when the current grant came from the offline cache, not a live check.
    private(set) var isUsingCachedResult: Bool = false
    /// True when the last resolution happened while offline.
    private(set) var resolvedWhileOffline: Bool = false
    private(set) var lastErrorDescription: String?
    /// Set when RevenueCat granted access that Supabase explicitly denied.
    private(set) var hasServerMismatch: Bool = false

    private let subscription: SubscriptionService
    private let repository: VineTrackAccessRepository
    private var currentUserId: UUID?
    private var isRefreshing: Bool = false

    private static let mismatchReportKey = "vinetrack.entitlementMismatch.lastReportedAt"

    init(
        subscription: SubscriptionService,
        repository: VineTrackAccessRepository = VineTrackAccessRepository()
    ) {
        self.subscription = subscription
        self.repository = repository
    }

    // MARK: Derived state

    var outcome: EntitlementOutcome? {
        if case .resolved(let outcome) = phase { return outcome }
        return nil
    }

    var hasAccess: Bool {
        switch outcome {
        case .grantedBySupabase, .grantedByRevenueCat, .grantedByLegacyTrial, .offlineCachedAccess:
            return true
        default:
            return false
        }
    }

    /// True until the first resolution completes (drives the loading route).
    var isChecking: Bool {
        switch phase {
        case .idle, .checking: return true
        case .resolved(let outcome):
            // Online but nothing definitive yet (RevenueCat still resolving)
            // keeps the loading view, matching the legacy gate's behaviour.
            return outcome == .unverified && !resolvedWhileOffline
        }
    }

    /// Offline with no verifiable access — show the "connect to verify"
    /// notice instead of a paywall that cannot transact offline.
    var shouldShowOfflineNotice: Bool {
        outcome == .unverified && resolvedWhileOffline
    }

    /// Stable label for diagnostics screens.
    var stateLabel: String {
        switch phase {
        case .idle, .checking: return "checking"
        case .resolved(let outcome):
            switch outcome {
            case .grantedBySupabase: return "granted_by_supabase"
            case .grantedByRevenueCat: return "granted_by_revenuecat"
            case .grantedByLegacyTrial: return "granted_by_legacy_trial"
            case .offlineCachedAccess: return "offline_cached_access"
            case .unverified: return "unverified"
            case .denied: return "denied"
            }
        }
    }

    // MARK: Session lifecycle

    /// Bind the gate to the signed-in Supabase user. Loads the persisted
    /// snapshot so the enforcement flag and cached access survive cold starts.
    func login(userId: UUID) {
        guard currentUserId != userId else { return }
        currentUserId = userId
        let snapshot = EntitlementVerificationStore.shared.load(for: userId)
        enforcementEnabled = snapshot?.supabaseEnforced ?? false
        phase = .idle
        hasServerMismatch = false
        lastServerAccess = nil
        lastServerResult = nil
        isUsingCachedResult = false
    }

    /// Clear all entitlement state on sign-out. The persisted snapshot is
    /// removed so no cached access can leak to another account.
    func logout() {
        currentUserId = nil
        phase = .idle
        enforcementEnabled = false
        lastServerAccess = nil
        lastServerResult = nil
        lastRefreshedAt = nil
        isUsingCachedResult = false
        resolvedWhileOffline = false
        lastErrorDescription = nil
        hasServerMismatch = false
        EntitlementVerificationStore.shared.clear()
    }

    // MARK: Refresh

    /// Re-resolve the combined access state. Throttled unless `force` so
    /// SwiftUI recomposition can never cause repeated RPC calls.
    func refresh(force: Bool = false) async {
        guard let userId = currentUserId, !isRefreshing else { return }
        if !force,
           let last = lastRefreshedAt,
           Date().timeIntervalSince(last) < Self.minimumRefreshInterval,
           case .resolved = phase {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        if case .resolved = phase {
            // Keep showing the previous resolution during background refreshes.
        } else {
            phase = .checking
        }
        await performRefresh(userId: userId)
    }

    private func performRefresh(userId: UUID) async {
        let snapshot = EntitlementVerificationStore.shared.load(for: userId)
        var serverResult: EntitlementServerResult
        var serverRow: BackendVineTrackAccess?

        do {
            let row = try await repository.fetchMyAccess()
            serverRow = row
            if let row {
                enforcementEnabled = row.enforcementEnabled ?? false
                serverResult = (row.grantsSupabaseAccess && row.grantsIOSAppAccess) ? .granted : .denied
            } else {
                // The resolver always returns one row; treat an empty response
                // as a confirmed "no backend entitlement" (defer to RevenueCat).
                serverResult = .denied
            }
            lastErrorDescription = nil
        } catch {
            serverResult = .unreachable
            lastErrorDescription = error.localizedDescription
            // Keep the cached enforcement flag — a transient network failure
            // must not flip the user between gate architectures.
        }

        if serverRow != nil { lastServerAccess = serverRow }
        lastServerResult = serverResult

        let now = Date()
        let cacheInfo: EntitlementDecision.CacheInfo? = snapshot.map {
            EntitlementDecision.CacheInfo(
                belongsToCurrentUser: $0.userId == nil || $0.userId == userId.uuidString,
                wasEntitled: $0.wasEntitled,
                verifiedAt: $0.lastVerifiedAt,
                knownExpiresAt: $0.knownExpiresAt
            )
        }

        let outcome = EntitlementDecision.resolve(EntitlementDecision.Input(
            enforcementEnabled: enforcementEnabled,
            server: serverResult,
            revenueCatEntitled: subscription.isSubscribed,
            revenueCatResolved: subscription.hasResolvedStatus,
            inLegacyFreeWindow: subscription.isInInitialFreeAccessPeriod,
            isOffline: subscription.isOffline,
            cache: cacheInfo,
            now: now,
            offlineGraceDays: SubscriptionService.offlineGraceDays
        ))

        resolvedWhileOffline = subscription.isOffline
        isUsingCachedResult = (outcome == .offlineCachedAccess)
        hasServerMismatch = (outcome == .grantedByRevenueCat(mismatchWithServer: true))
        phase = .resolved(outcome)
        lastRefreshedAt = now

        persistVerification(outcome: outcome, serverResult: serverResult, serverRow: serverRow, userId: userId, now: now)

        if hasServerMismatch {
            await reportMismatchIfNeeded()
        }
    }

    // MARK: Cache persistence

    /// Persist the verification snapshot — ONLY after an online, definitive
    /// server response. A transient failure never overwrites a valid cache;
    /// a confirmed denial replaces a previous positive cache.
    private func persistVerification(
        outcome: EntitlementOutcome,
        serverResult: EntitlementServerResult,
        serverRow: BackendVineTrackAccess?,
        userId: UUID,
        now: Date
    ) {
        guard !subscription.isOffline else { return }
        switch serverResult {
        case .granted:
            EntitlementVerificationStore.shared.recordVerification(
                userId: userId.uuidString,
                entitled: true,
                productStatus: "supabase:\(serverRow?.accessSourceLabel ?? "granted")",
                accessSource: "supabase",
                planCode: serverRow?.planCode,
                reasonCode: serverRow?.reasonCode,
                knownExpiresAt: serverRow?.knownExpiresAt(now: now),
                supabaseEnforced: enforcementEnabled
            )
        case .denied:
            let fallbackGranted: (entitled: Bool, source: String?)
            switch outcome {
            case .grantedByRevenueCat: fallbackGranted = (true, "revenuecat")
            case .grantedByLegacyTrial: fallbackGranted = (true, "legacy_trial")
            default: fallbackGranted = (false, nil)
            }
            EntitlementVerificationStore.shared.recordVerification(
                userId: userId.uuidString,
                entitled: fallbackGranted.entitled,
                productStatus: fallbackGranted.entitled ? nil : "supabase:denied",
                accessSource: fallbackGranted.source,
                planCode: nil,
                reasonCode: serverRow?.reasonCode,
                knownExpiresAt: nil,
                supabaseEnforced: enforcementEnabled
            )
        case .unreachable:
            break
        }
    }

    // MARK: Mismatch diagnostics

    /// Fire-and-forget mismatch report ("RevenueCat grants; Supabase does
    /// not"), throttled locally to once per 24 h (the server throttles too).
    private func reportMismatchIfNeeded() async {
        if let last = UserDefaults.standard.object(forKey: Self.mismatchReportKey) as? Date,
           Date().timeIntervalSince(last) < 86_400 {
            return
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        do {
            try await repository.reportMismatch(platform: "ios", appVersion: version)
            UserDefaults.standard.set(Date(), forKey: Self.mismatchReportKey)
        } catch {
            // Diagnostics only — never affects access.
        }
    }
}
