import Foundation
import Observation

/// Resolves effective VineTrack access by combining the draft Supabase
/// entitlement (`get_my_vinetrack_access()`) with the existing RevenueCat
/// (Solo / legacy) check.
///
/// ⚠️ ADDITIVE / NOT YET ENFORCED. This resolver is wired up to prepare the app
/// for the July 2026 pricing model, but it does NOT replace the global access
/// gate. The existing `SubscriptionService.hasAccess` in `NewBackendRootView`
/// continues to decide app access until the new system is adopted. Calling
/// `resolve()` is side-effect free with respect to the existing gate and is
/// safe to run for diagnostics/testing.
///
/// Resolution order (matches the agreed contract):
///   A. Call Supabase `get_my_vinetrack_access()`.
///   B. If Supabase says `has_access == true` and `can_use_ios_app == true`,
///      unlock via backend access.
///   C. If Supabase says `solo_check_required == true`, fall back to the
///      existing RevenueCat access check.
///   D. If the Supabase RPC fails, fall back to the existing RevenueCat check.
///   E. If neither grants access, no access (existing paywall applies).
@Observable
@MainActor
final class VineTrackAccessResolver {

    /// How access was ultimately granted (or denied).
    enum Source: String, Sendable {
        case supabaseTeam       = "supabase_team"
        case supabaseEnterprise = "supabase_enterprise"
        case supabaseLegacy     = "supabase_legacy"
        case supabaseOther      = "supabase_other"
        case revenueCat         = "revenuecat"
        case none               = "none"
    }

    struct Outcome: Sendable {
        let hasAccess: Bool
        let source: Source
        /// The backend entitlement, when the RPC returned a row.
        let backendAccess: BackendVineTrackAccess?
        /// True when the RPC failed and we fell back to RevenueCat.
        let didFallBackOnError: Bool
    }

    private(set) var lastOutcome: Outcome?
    private(set) var isResolving: Bool = false

    private let repository: VineTrackAccessRepository
    private let subscription: SubscriptionService

    init(
        subscription: SubscriptionService,
        repository: VineTrackAccessRepository = VineTrackAccessRepository()
    ) {
        self.subscription = subscription
        self.repository = repository
    }

    /// Resolve effective access. Never throws — RPC failures fall back to
    /// RevenueCat so existing subscribers are never blocked by a backend issue.
    @discardableResult
    func resolve() async -> Outcome {
        isResolving = true
        defer { isResolving = false }

        // A. Supabase backend entitlement.
        do {
            let access = try await repository.fetchMyAccess()

            if let access {
                // B. Backend grants iOS app access directly.
                if access.grantsSupabaseAccess && access.grantsIOSAppAccess {
                    let source = source(for: access)
                    log("Supabase access active: \(access.accessSourceLabel)")
                    return finish(Outcome(
                        hasAccess: true,
                        source: source,
                        backendAccess: access,
                        didFallBackOnError: false
                    ))
                }

                // C. Backend defers to RevenueCat Solo verification.
                if access.requiresSoloCheck {
                    log("Supabase says solo check required — falling back to RevenueCat")
                    return finish(revenueCatOutcome(backendAccess: access, didFallBackOnError: false))
                }

                // Backend returned a row but neither granted access nor asked
                // for a Solo check — still verify RevenueCat before denying.
                log("Supabase returned no access — falling back to RevenueCat")
                return finish(revenueCatOutcome(backendAccess: access, didFallBackOnError: false))
            }

            // No row → treat as "verify Solo / RevenueCat".
            log("Supabase returned no row — falling back to RevenueCat")
            return finish(revenueCatOutcome(backendAccess: nil, didFallBackOnError: false))
        } catch {
            // D. RPC failed — never block existing RevenueCat users.
            log("RPC failed (\(error.localizedDescription)), falling back to RevenueCat")
            return finish(revenueCatOutcome(backendAccess: nil, didFallBackOnError: true))
        }
    }

    // MARK: - RevenueCat fallback

    private func revenueCatOutcome(
        backendAccess: BackendVineTrackAccess?,
        didFallBackOnError: Bool
    ) -> Outcome {
        if subscription.hasAccess {
            log("RevenueCat active")
            return Outcome(
                hasAccess: true,
                source: .revenueCat,
                backendAccess: backendAccess,
                didFallBackOnError: didFallBackOnError
            )
        }
        // E. Neither Supabase nor RevenueCat grants access.
        log("No active access")
        return Outcome(
            hasAccess: false,
            source: .none,
            backendAccess: backendAccess,
            didFallBackOnError: didFallBackOnError
        )
    }

    private func source(for access: BackendVineTrackAccess) -> Source {
        switch access.accessSourceLabel.lowercased() {
        case "team":       return .supabaseTeam
        case "enterprise": return .supabaseEnterprise
        case "legacy":     return .supabaseLegacy
        default:           return .supabaseOther
        }
    }

    private func finish(_ outcome: Outcome) -> Outcome {
        lastOutcome = outcome
        return outcome
    }

    /// Debug-only logging. Never logs raw billing payloads or sensitive fields.
    private func log(_ message: String) {
        #if DEBUG
        print("[VineTrackAccess] \(message)")
        #endif
    }
}
