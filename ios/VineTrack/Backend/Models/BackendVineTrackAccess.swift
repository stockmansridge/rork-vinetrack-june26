import Foundation

/// Decoded response from the draft Supabase RPC `get_my_vinetrack_access()`.
///
/// ⚠️ DRAFT / ADDITIVE ONLY. This model prepares the app for the July 2026
/// VineTrack pricing model (Solo / Team / Enterprise). It is NOT yet wired into
/// the global access gate — the existing RevenueCat entitlement check in
/// `SubscriptionService` keeps deciding app access until the new system is
/// adopted.
///
/// The billing schema is still a draft and the RPC shape may evolve, so EVERY
/// field is optional and the decoder is deliberately tolerant: it accepts
/// several alternate key spellings (e.g. `has_access` or `has_supabase_access`,
/// `plan_code` or `plan_key`) and never fails on missing/null fields. Unknown
/// keys are ignored.
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
    }
}
