import Foundation

/// User-facing status for the same resolved access decision that routes the
/// app. Store purchase details stay separate so an expired App Store trial
/// cannot label an active vineyard grant as expired or offer another purchase.
nonisolated struct EntitlementAccessPresentation {
    enum Tone {
        case positive
        case warning
        case negative
        case neutral
    }

    let statusTitle: String
    let statusSubtitle: String
    let accessTitle: String
    let accessDetail: String
    let icon: String
    let tone: Tone
    let hasAccess: Bool
    let shouldOfferPlans: Bool
    let shouldOfferRefresh: Bool
    let lastVerifiedAt: Date?
    let offlineGraceEndsAt: Date?

    init(
        outcome: EntitlementOutcome?,
        serverAccess: BackendVineTrackAccess?,
        verification: EntitlementVerificationSnapshot?,
        isOffline: Bool,
        legacyTrialEndsAt: Date?,
        storeExpiresAt: Date?,
        storeWillRenew: Bool,
        now: Date = Date(),
        offlineGraceDays: Int = 30
    ) {
        lastVerifiedAt = verification?.lastVerifiedAt
        if let verification, verification.wasEntitled {
            let graceEnd = verification.lastVerifiedAt.addingTimeInterval(
                TimeInterval(offlineGraceDays) * 86_400
            )
            offlineGraceEndsAt = verification.knownExpiresAt.map { min($0, graceEnd) } ?? graceEnd
        } else {
            offlineGraceEndsAt = nil
        }

        shouldOfferPlans = outcome == .denied && !isOffline
        shouldOfferRefresh = !isOffline
            && (outcome == .offlineCachedAccess || outcome == .unverified || outcome == .denied)

        func dateText(_ date: Date) -> String {
            date.formatted(date: .abbreviated, time: .omitted)
        }

        switch outcome {
        case .grantedBySupabase:
            let isTrial = serverAccess?.reasonCode == "active_trial" || serverAccess?.planCode == "trial"
            if serverAccess?.reasonCode == "internal_unlimited" {
                statusTitle = "Internal Unlimited access"
            } else if isTrial {
                statusTitle = "Free trial active"
            } else if let planName = serverAccess?.planName {
                statusTitle = "\(planName) access active"
            } else {
                statusTitle = "VineTrack access active"
            }
            if let expiry = serverAccess?.knownExpiresAt(now: now) {
                statusSubtitle = "\(isTrial ? "Trial ends" : "Access until") \(dateText(expiry))"
            } else {
                statusSubtitle = "Your VineTrack access is active."
            }
            accessTitle = isTrial ? "Free trial active" : "Access active"
            accessDetail = "Verified with VineTrack."
            icon = isTrial ? "gift.fill" : "checkmark.seal.fill"
            tone = .positive
            hasAccess = true

        case .grantedByRevenueCat:
            statusTitle = "Vineyard Tracker Pro"
            if let expiry = storeExpiresAt {
                statusSubtitle = "\(storeWillRenew ? "Renews" : "Expires") \(dateText(expiry))"
            } else {
                statusSubtitle = "Your App Store subscription is active."
            }
            accessTitle = "Subscription active"
            accessDetail = "Verified with the App Store."
            icon = "checkmark.seal.fill"
            tone = .positive
            hasAccess = true

        case .grantedByLegacyTrial:
            statusTitle = "Free access active"
            statusSubtitle = legacyTrialEndsAt.map { "Free until \(dateText($0))" }
                ?? "Your initial free access period is active."
            accessTitle = "Free access period"
            accessDetail = "Your account is in its initial free access period."
            icon = "gift.fill"
            tone = .positive
            hasAccess = true

        case .offlineCachedAccess:
            statusTitle = "Verified access available"
            statusSubtitle = "Using your last verified access."
            accessTitle = "Offline grace active"
            if let graceEnd = offlineGraceEndsAt {
                accessDetail = "Cached access is available until \(dateText(graceEnd)). Connect to refresh."
            } else {
                accessDetail = "Connect to refresh your verified access."
            }
            icon = "wifi.slash"
            tone = .warning
            hasAccess = true

        case .unverified:
            statusTitle = isOffline ? "Needs online verification" : "Checking access…"
            statusSubtitle = isOffline
                ? "Connect to the internet to verify your access."
                : "Waiting for your account access to be verified."
            accessTitle = isOffline ? "Needs online verification" : "Checking access"
            accessDetail = statusSubtitle
            icon = isOffline ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.2.circlepath"
            tone = isOffline ? .warning : .neutral
            hasAccess = false

        case .denied:
            statusTitle = "No active access"
            statusSubtitle = "Choose a plan to continue using VineTrack."
            accessTitle = "Access inactive"
            accessDetail = "No active access was found for this account."
            icon = "lock.fill"
            tone = .negative
            hasAccess = false

        case nil:
            statusTitle = "Checking access…"
            statusSubtitle = "Verifying your VineTrack account access."
            accessTitle = "Checking access"
            accessDetail = statusSubtitle
            icon = "arrow.triangle.2.circlepath"
            tone = .neutral
            hasAccess = false
        }
    }
}
