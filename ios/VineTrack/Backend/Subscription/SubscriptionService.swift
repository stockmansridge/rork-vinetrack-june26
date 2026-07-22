import Foundation
import Observation
import RevenueCat

/// RevenueCat subscription service.
///
/// V1 product configuration (managed in RevenueCat dashboard + App Store Connect):
///   - Entitlement: `pro` (a.k.a. "Vineyard Tracker Pro")
///   - Default offering exposes the legacy products only:
///       • $9.99 / month with 3-month introductory free trial
///       • $99   / year  with 3-month introductory free trial
///
/// Product IDs / package IDs / offering ID live in the RevenueCat dashboard;
/// the SDK fetches them at runtime so we don't hard-code them in the app.
///
/// IMPORTANT: do NOT add the Basic ($5/$30) products to the default offering.
@Observable
@MainActor
final class SubscriptionService {

    /// RevenueCat entitlement identifier for full app access.
    static let entitlementIdentifier = "pro"

    /// Number of days a previously-verified subscriber may keep working
    /// offline before we require a fresh online verification.
    static let offlineGraceDays = 30

    enum Status: Equatable {
        case unknown
        case loading
        case subscribed
        case notSubscribed
        case failure(String)
    }

    /// High-level access state used by the Subscription settings screen and
    /// the in-app grace banner. Derived from the live/cached subscription,
    /// the initial free-access window, and the persisted offline grace.
    enum AccessState: Equatable {
        /// Live or cached RevenueCat entitlement is active.
        case subscribed
        /// Inside the initial 3-month free-access window.
        case freeAccess
        /// Offline and currently being allowed in via the grace window.
        case offlineGrace
        /// A prior verification exists but the grace window has lapsed — a
        /// fresh online check is required.
        case needsVerification
        /// No successful verification has ever been recorded on this device.
        case notVerified
    }

    var status: Status = .unknown
    var customerInfo: CustomerInfo?
    var currentOffering: Offering?
    var isPurchasing: Bool = false
    var isRestoring: Bool = false
    var lastError: String?
    var userCreatedAt: Date?

    /// Last successful *online* verification, persisted locally to drive the
    /// offline grace window. Loaded on `login`.
    private(set) var lastVerification: EntitlementVerificationSnapshot?

    private var currentUserId: UUID?
    private var didConfigure: Bool = false
    private var customerInfoStreamTask: Task<Void, Never>?

    var isSubscribed: Bool {
        guard let info = customerInfo else { return false }
        return info.entitlements[Self.entitlementIdentifier]?.isActive == true
    }

    var isInInitialFreeAccessPeriod: Bool {
        guard let userCreatedAt else { return false }
        let calendar = Calendar(identifier: .gregorian)
        guard let freeAccessEndsAt = calendar.date(byAdding: .month, value: 3, to: userCreatedAt) else { return false }
        return Date() < freeAccessEndsAt
    }

    var freeAccessEndsAt: Date? {
        guard let userCreatedAt else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(byAdding: .month, value: 3, to: userCreatedAt)
    }

    var hasAccess: Bool {
        if isSubscribed { return true }
        if isInInitialFreeAccessPeriod { return true }
        // Offline safety net: a previously-verified subscriber keeps access
        // for the grace window when the device can't reach RevenueCat/Supabase.
        if isOffline && isWithinOfflineGracePeriod { return true }
        return false
    }

    // MARK: - Offline grace window

    /// True when the device currently has no network path.
    var isOffline: Bool { !NetworkMonitor.shared.isOnline }

    /// When the last successful online verification completed (any result).
    var lastVerifiedEntitlementAt: Date? { lastVerification?.lastVerifiedAt }

    /// Anchor for the grace window: only a verification that *granted* access
    /// extends offline access. A verified "not subscribed" result does not.
    var offlineGraceAnchorDate: Date? {
        guard let snapshot = lastVerification, snapshot.wasEntitled else { return nil }
        return snapshot.lastVerifiedAt
    }

    var offlineGraceEndsAt: Date? {
        guard let anchor = offlineGraceAnchorDate else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(byAdding: .day, value: Self.offlineGraceDays, to: anchor)
    }

    var isWithinOfflineGracePeriod: Bool {
        guard let end = offlineGraceEndsAt else { return false }
        return Date() < end
    }

    /// Remaining grace, or nil when no anchor exists / already expired.
    var offlineGraceRemaining: TimeInterval? {
        guard let end = offlineGraceEndsAt else { return nil }
        let remaining = end.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    /// Offline and we cannot confirm access locally. The caller should show a
    /// "connect to verify" message rather than the paywall — purchases can't
    /// complete offline anyway, and a "not subscribed" verdict reached while
    /// offline can't be trusted for a real subscriber.
    var shouldShowOfflineAccessNotice: Bool {
        guard isOffline else { return false }
        return !hasAccess
    }

    /// Coarse access state for display. Order matters: an active subscription
    /// always wins, then the free window, then the offline grace.
    var accessState: AccessState {
        if isSubscribed { return .subscribed }
        if isInInitialFreeAccessPeriod { return .freeAccess }
        if isOffline && isWithinOfflineGracePeriod { return .offlineGrace }
        if offlineGraceAnchorDate != nil { return .needsVerification }
        return .notVerified
    }

    /// True only when the offline grace window is the sole reason the user
    /// currently has access — i.e. offline, not subscribed (even via cache),
    /// and outside the initial free window. Drives the in-app grace banner.
    var isRelyingOnOfflineGrace: Bool {
        guard isOffline else { return false }
        if isSubscribed { return false }
        if isInInitialFreeAccessPeriod { return false }
        return isWithinOfflineGracePeriod
    }

    /// Whole days remaining in the offline grace window (rounded up), or nil
    /// when no grace anchor applies / it has already expired.
    var offlineGraceRemainingDays: Int? {
        guard let remaining = offlineGraceRemaining else { return nil }
        return max(1, Int(ceil(remaining / 86_400)))
    }

    /// True when the last successful online verification is missing or older
    /// than a day, so a manual "Refresh access" is worthwhile.
    var isVerificationStale: Bool {
        guard let last = lastVerifiedEntitlementAt else { return true }
        return Date().timeIntervalSince(last) > 86_400
    }

    var hasResolvedStatus: Bool {
        switch status {
        case .subscribed, .notSubscribed, .failure: return true
        case .unknown, .loading: return false
        }
    }

    // MARK: - Configuration

    func configureIfNeeded() {
        guard !didConfigure else { return }
        let key = AppConfig.revenueCatIOSAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            #if DEBUG
            print("[Subscription] RevenueCat API key missing — skipping configure().")
            #endif
            status = .failure("Subscription service is not configured.")
            return
        }
        Purchases.logLevel = .warn
        Purchases.configure(withAPIKey: key)
        didConfigure = true
        startCustomerInfoStream()
    }

    private func startCustomerInfoStream() {
        customerInfoStreamTask?.cancel()
        customerInfoStreamTask = Task { [weak self] in
            for await info in Purchases.shared.customerInfoStream {
                await MainActor.run {
                    guard let self else { return }
                    self.applyCustomerInfo(info)
                }
            }
        }
    }

    /// Identify RevenueCat with the Supabase auth user UUID.
    func login(userId: UUID, userCreatedAt: Date?) async {
        self.userCreatedAt = userCreatedAt
        self.currentUserId = userId
        lastVerification = EntitlementVerificationStore.shared.load(for: userId)
        configureIfNeeded()
        guard didConfigure else { return }
        do {
            let result = try await Purchases.shared.logIn(userId.uuidString)
            applyCustomerInfo(result.customerInfo)
            await refreshOfferings()
        } catch {
            lastError = error.localizedDescription
            status = .failure(error.localizedDescription)
        }
    }

    /// Reset RevenueCat identity on sign out.
    func logout() async {
        userCreatedAt = nil
        currentUserId = nil
        guard didConfigure else { return }
        do {
            let info = try await Purchases.shared.logOut()
            applyCustomerInfo(info)
        } catch {
            // Logging out of an anonymous user throws; ignore.
            customerInfo = nil
            status = .notSubscribed
        }
        currentOffering = nil
    }

    // MARK: - Refresh

    func refreshCustomerInfo() async {
        configureIfNeeded()
        guard didConfigure else { return }
        status = .loading
        do {
            let info = try await Purchases.shared.customerInfo()
            applyCustomerInfo(info)
        } catch {
            lastError = error.localizedDescription
            status = .failure(error.localizedDescription)
        }
    }

    func refreshOfferings() async {
        configureIfNeeded()
        guard didConfigure else { return }
        do {
            let offerings = try await Purchases.shared.offerings()
            currentOffering = offerings.current
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Purchase / Restore

    @discardableResult
    func purchase(package: Package) async -> Bool {
        configureIfNeeded()
        guard didConfigure else { return false }
        isPurchasing = true
        lastError = nil
        defer { isPurchasing = false }
        do {
            let result = try await Purchases.shared.purchase(package: package)
            applyCustomerInfo(result.customerInfo)
            return result.customerInfo.entitlements[Self.entitlementIdentifier]?.isActive == true
        } catch {
            if (error as? ErrorCode) == .purchaseCancelledError {
                return false
            }
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func restorePurchases() async -> Bool {
        configureIfNeeded()
        guard didConfigure else { return false }
        isRestoring = true
        lastError = nil
        defer { isRestoring = false }
        do {
            let info = try await Purchases.shared.restorePurchases()
            applyCustomerInfo(info)
            return info.entitlements[Self.entitlementIdentifier]?.isActive == true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    private func applyCustomerInfo(_ info: CustomerInfo) {
        customerInfo = info
        let active = info.entitlements[Self.entitlementIdentifier]?.isActive == true
        status = active ? .subscribed : .notSubscribed
        recordVerificationIfOnline(entitled: active, productStatus: productStatusString(info))
    }

    /// Persist a verification result, but only when the device is online — a
    /// result derived from RevenueCat's offline cache must not extend the
    /// grace window. Anonymous (signed-out) results are ignored.
    private func recordVerificationIfOnline(entitled: Bool, productStatus: String?) {
        guard NetworkMonitor.shared.isOnline, let userId = currentUserId else { return }
        lastVerification = EntitlementVerificationStore.shared.recordVerification(
            userId: userId.uuidString,
            entitled: entitled,
            productStatus: productStatus
        )
    }

    /// Short, non-sensitive description of the active entitlement.
    private func productStatusString(_ info: CustomerInfo) -> String? {
        guard let entitlement = info.entitlements[Self.entitlementIdentifier],
              entitlement.isActive else { return nil }
        if entitlement.periodType == .trial { return "trial:\(entitlement.productIdentifier)" }
        return entitlement.willRenew
            ? "active:\(entitlement.productIdentifier)"
            : "expiring:\(entitlement.productIdentifier)"
    }
}
