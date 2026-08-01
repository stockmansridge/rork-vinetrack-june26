import Foundation

/// Who the restricted-vineyard screen is talking to. Derived only from the
/// server access matrix — never from local role guesses.
nonisolated enum RestrictedVineyardAudience: String, Sendable, Equatable {
    /// The matrix hasn't confirmed a denial yet — show a neutral checking
    /// state and NEVER an upgrade/purchase action.
    case unresolved
    /// Owner of this vineyard who can act on its billing.
    case billingOwner
    /// Owner-role member whose billing is controlled by another Owner.
    case coOwner
    /// Manager / Supervisor / Operator — access is provided by the Owner.
    case teamMember
}

/// Role-aware copy + allowed actions for the restricted-vineyard screen
/// (Phase 2F.2). Pure and platform-agnostic: the Android screen
/// (`RestrictedVineyardMessaging.kt`) and the portal use the same wording so
/// all three platforms explain the same thing.
nonisolated struct RestrictedVineyardMessage: Equatable, Sendable {

    /// sql/157 reason code: the vineyard's Owner is entitled, but only for
    /// their own account (Solo / legacy / user-scoped grant / assigned licence).
    static let soloFundingReasonCode = "owner_plan_not_vineyard_funding"

    let audience: RestrictedVineyardAudience
    let title: String
    let body: String
    /// Solo → Team upgrade action. Only ever true for `billingOwner` on a
    /// server-confirmed `owner_plan_not_vineyard_funding` denial.
    let showsUpgradeToTeam: Bool
    /// Generic "Review billing" action for other confirmed denials.
    let showsReviewBilling: Bool
    let footnote: String?

    /// True when the screen offers any billing/purchase entry point.
    var offersBillingAction: Bool { showsUpgradeToTeam || showsReviewBilling }

    static let upgradeActionTitle: String = "Upgrade to Team"
    static let reviewBillingActionTitle: String = "Review billing"

    /// Build the message for the selected vineyard.
    ///
    /// - Parameters:
    ///   - vineyardName: display name of the restricted vineyard.
    ///   - entry: the vineyard's row from `get_my_vineyard_access_matrix()`.
    ///   - isMatrixResolved: whether a live server matrix has been loaded.
    ///     While false, the upgrade/billing state is never shown.
    static func make(
        vineyardName: String,
        entry: VineyardAccessEntry?,
        isMatrixResolved: Bool
    ) -> RestrictedVineyardMessage {
        // Never speculate: without a loaded matrix (or with a still-accessible
        // vineyard) the denial is not server-confirmed.
        guard isMatrixResolved, let entry, !entry.hasVineyardAccess else {
            return RestrictedVineyardMessage(
                audience: .unresolved,
                title: "Checking your VineTrack access…",
                body: "We're confirming this vineyard's access with the server. This only takes a moment.",
                showsUpgradeToTeam: false,
                showsReviewBilling: false,
                footnote: nil
            )
        }

        let role = (entry.membershipRole ?? "").lowercased()
        let isOwnerRole = role == "owner"
        // sql/158 `is_billing_authority`. A pre-158 backend omits it, so an
        // Owner keeps the previous behaviour rather than losing the action.
        let hasBillingAuthority = isOwnerRole
            && (entry.isBillingAuthority ?? entry.canManageBilling ?? true)
        let isSoloFunding = (entry.vineyardAccessReason ?? "") == soloFundingReasonCode

        let audience: RestrictedVineyardAudience = isOwnerRole
            ? (hasBillingAuthority ? .billingOwner : .coOwner)
            : .teamMember

        if isSoloFunding {
            switch audience {
            case .billingOwner:
                return RestrictedVineyardMessage(
                    audience: .billingOwner,
                    title: "\(vineyardName) needs a Team plan",
                    body: "Your current VineTrack plan covers your own account only, so it doesn't fund access for the people working in \(vineyardName). Upgrade to a Team plan to restore access for every active member of this vineyard. Your other vineyards are unaffected.",
                    showsUpgradeToTeam: true,
                    showsReviewBilling: false,
                    footnote: "Team and Enterprise plans cover all active members of a vineyard."
                )
            case .coOwner:
                return RestrictedVineyardMessage(
                    audience: .coOwner,
                    title: "\(vineyardName) needs a Team plan",
                    body: "Billing for \(vineyardName) is managed by another Owner, and their current plan covers their own account only. Ask the Owner who manages this vineyard's billing to upgrade it to a Team plan. You can keep working in your other vineyards, and any pending invitations remain available.",
                    showsUpgradeToTeam: false,
                    showsReviewBilling: false,
                    footnote: nil
                )
            case .teamMember, .unresolved:
                return RestrictedVineyardMessage(
                    audience: .teamMember,
                    title: "\(vineyardName) needs a Team plan",
                    body: "Access for this vineyard is managed by its Vineyard Owner, and their current plan covers their own account only. Ask the Vineyard Owner to upgrade \(vineyardName) to a Team plan. You can keep working in your other vineyards, and any pending invitations remain available.",
                    showsUpgradeToTeam: false,
                    showsReviewBilling: false,
                    footnote: nil
                )
            }
        }

        switch audience {
        case .billingOwner:
            return RestrictedVineyardMessage(
                audience: .billingOwner,
                title: "Access to \(vineyardName) has expired",
                body: "This vineyard no longer has an active subscription, trial, or grant. Review billing to restore access for you and your team. Your other vineyards are unaffected.",
                showsUpgradeToTeam: false,
                showsReviewBilling: true,
                footnote: nil
            )
        case .coOwner:
            return RestrictedVineyardMessage(
                audience: .coOwner,
                title: "Access to \(vineyardName) has expired",
                body: "Billing for \(vineyardName) is managed by another Owner. Ask them to renew this vineyard's plan. You can keep working in your other vineyards, and any pending invitations remain available.",
                showsUpgradeToTeam: false,
                showsReviewBilling: false,
                footnote: nil
            )
        case .teamMember, .unresolved:
            return RestrictedVineyardMessage(
                audience: .teamMember,
                title: "Access to \(vineyardName) has expired",
                body: "Access for this vineyard is managed by its Vineyard Owner. You can keep working in your other vineyards, and any pending invitations remain available.",
                showsUpgradeToTeam: false,
                showsReviewBilling: false,
                footnote: nil
            )
        }
    }
}
