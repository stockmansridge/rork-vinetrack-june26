import Foundation

/// Decoded response from the Supabase RPC `get_my_vinetrack_access()`
/// (hardened in sql/132 — Phase 2A shared entitlement resolver).
///
/// This is the shared access source enforced by `EntitlementGate` when the
/// `use_shared_supabase_entitlement` rollout flag covers the caller
/// (`enforcement_enabled`). Every field is optional and the decoder is
/// deliberately tolerant: it accepts several alternate key spellings
/// (e.g. `has_access` or `has_supabase_access`) and never fails on
/// missing/null fields. Unknown keys are ignored, so future additive
/// columns can never break released builds.
nonisolated struct BackendVineTrackAccess: Decodable, Sendable, Hashable {
    /// Whether Supabase grants the caller direct (Team/Enterprise/legacy) access.
    let hasAccess: Bool?
    /// True when Supabase found no backend entitlement and the client should
    /// fall back to verifying RevenueCat Solo access.
    let soloCheckRequired: Bool?
    /// Human/diagnostic reason or access source, e.g. "team" | "enterprise" |
    /// "legacy" | "none".
    let reason: String?

    let planCode: String?
    let planName: String?
    let planTier: String?

    /// Generic provider / billing provider, e.g. "apple" | "stripe" | "manual".
    let provider: String?
    let billingProvider: String?

    /// Subscription status, e.g. "trialing" | "active" | "past_due" | ...
    let subscriptionStatus: String?

    let portalAccess: Bool?
    let portalAccessLevel: String?

    let role: String?
    let isOwner: Bool?

    let trialEnd: Date?
    let currentPeriodEnd: Date?

    let includedLicences: Int?
    let activeLicences: Int?
    let additionalLicences: Int?

    // Capability flags. Optional — when absent the resolver derives sensible
    // defaults from `hasAccess` / `portalAccess`.
    let canUseIOSApp: Bool?
    let canUsePortal: Bool?
    let canInviteTeam: Bool?
    let canUseLiveDashboard: Bool?
    let canExport: Bool?

    let vineyardId: UUID?
    let subscriptionId: UUID?
    let licenceId: UUID?

    // SQL 132 additive fields.
    /// Stable machine-readable reason, e.g. "internal_unlimited",
    /// "portal_subscription", "expired", "no_entitlement".
    let reasonCode: String?
    /// True for Internal Unlimited manual grants.
    let isUnlimited: Bool?
    /// Platform mirror of `can_use_ios_app`.
    let canUseAndroidApp: Bool?
    /// Server timestamp of this verification (database `now()`).
    let lastVerifiedAt: Date?
    /// Whether the shared-entitlement rollout flag covers this caller.
    let enforcementEnabled: Bool?
    /// Expiry of a manual (Internal Unlimited) grant, when set.
    let manualGrantExpiresAt: Date?

    // SQL 135 additive fields (Phase 2B — verified store subscriptions).
    /// Where the purchase happened ('ios' | 'android' | 'web'), NOT where
    /// VineTrack may be used — access is cross-platform.
    let purchasePlatform: String?
    /// Auto-renew has been turned off; access continues until period end.
    let cancelAtPeriodEnd: Bool?
    /// Provider-supplied billing-issue grace end — access holds until then.
    let gracePeriodEnd: Date?

    // MARK: - Derived convenience

    /// Effective "Supabase grants access" flag, tolerant of either key.
    var grantsSupabaseAccess: Bool { hasAccess ?? false }

    /// Whether the iOS app should be unlocked via the backend. Defaults to the
    /// general access flag when the explicit capability is not present.
    var grantsIOSAppAccess: Bool { canUseIOSApp ?? grantsSupabaseAccess }

    /// Whether the client should still verify RevenueCat Solo. Defaults to true
    /// (safe fallback) when neither access nor the flag is present.
    var requiresSoloCheck: Bool {
        if let soloCheckRequired { return soloCheckRequired }
        return !grantsSupabaseAccess
    }

    /// Short label for debug/diagnostics, e.g. "team", "enterprise", "legacy".
    var accessSourceLabel: String {
        if let planTier, !planTier.isEmpty { return planTier }
        if let reason, !reason.isEmpty { return reason }
        return "none"
    }

    /// Earliest KNOWN future expiry of the granted entitlement, used to cap
    /// the offline cache so cached access never outlives a known expiry.
    /// Returns nil when no future-dated expiry applies (e.g. an Internal
    /// Unlimited grant with no expiry).
    func knownExpiresAt(now: Date) -> Date? {
        // A billing-issue grace end EXTENDS an elapsed period, so when a grace
        // window is active the later of (period end, grace end) is the real cap.
        var candidates: [Date] = [manualGrantExpiresAt, trialEnd].compactMap { $0 }
        switch (currentPeriodEnd, gracePeriodEnd) {
        case let (period?, grace?):
            candidates.append(max(period, grace))
        case let (period?, nil):
            candidates.append(period)
        case let (nil, grace?):
            candidates.append(grace)
        case (nil, nil):
            break
        }
        return candidates.filter { $0 > now }.min()
    }

    // MARK: - Tolerant decoding

    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)

        func bool(_ keys: String...) -> Bool? {
            for key in keys {
                if let value = try? c.decodeIfPresent(Bool.self, forKey: AnyKey(key)) {
                    return value
                }
            }
            return nil
        }
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = try? c.decodeIfPresent(String.self, forKey: AnyKey(key)),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        func int(_ keys: String...) -> Int? {
            for key in keys {
                if let value = try? c.decodeIfPresent(Int.self, forKey: AnyKey(key)) {
                    return value
                }
            }
            return nil
        }
        func date(_ keys: String...) -> Date? {
            for key in keys {
                if let value = try? c.decodeIfPresent(Date.self, forKey: AnyKey(key)) {
                    return value
                }
            }
            return nil
        }
        func uuid(_ keys: String...) -> UUID? {
            for key in keys {
                if let value = try? c.decodeIfPresent(UUID.self, forKey: AnyKey(key)) {
                    return value
                }
                if let raw = try? c.decodeIfPresent(String.self, forKey: AnyKey(key)),
                   let parsed = UUID(uuidString: raw) {
                    return parsed
                }
            }
            return nil
        }

        hasAccess          = bool("has_access", "has_supabase_access")
        soloCheckRequired  = bool("solo_check_required")
        reason             = string("reason", "access_source")

        planCode           = string("plan_code", "plan_key")
        planName           = string("plan_name")
        planTier           = string("plan_tier", "tier")

        provider           = string("provider")
        billingProvider    = string("billing_provider", "provider")

        subscriptionStatus = string("subscription_status", "status")

        portalAccess       = bool("portal_access")
        portalAccessLevel  = string("portal_access_level")

        role               = string("role")
        isOwner            = bool("is_owner")

        trialEnd           = date("trial_end")
        currentPeriodEnd   = date("current_period_end")

        includedLicences   = int("included_licences", "seats_included")
        activeLicences     = int("active_licences", "active_licenses", "active_seats", "seats_used")
        additionalLicences = int("additional_licences", "additional_licenses", "seats_purchased")

        canUseIOSApp        = bool("can_use_ios_app", "ios_access", "app_access")
        canUsePortal        = bool("can_use_portal", "portal_access")
        canInviteTeam       = bool("can_invite_team")
        canUseLiveDashboard = bool("can_use_live_dashboard")
        canExport           = bool("can_export")

        vineyardId         = uuid("vineyard_id", "primary_vineyard_id")
        subscriptionId     = uuid("subscription_id")
        licenceId          = uuid("licence_id", "license_id", "user_licence_id", "user_license_id")

        reasonCode          = string("reason_code")
        isUnlimited         = bool("is_unlimited", "unlimited_licences")
        canUseAndroidApp    = bool("can_use_android_app")
        lastVerifiedAt      = date("last_verified_at")
        enforcementEnabled  = bool("enforcement_enabled")
        manualGrantExpiresAt = date("manual_grant_expires_at")

        purchasePlatform   = string("purchase_platform")
        cancelAtPeriodEnd  = bool("cancel_at_period_end")
        gracePeriodEnd     = date("grace_period_end")
    }
}
