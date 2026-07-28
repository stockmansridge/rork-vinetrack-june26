import SwiftUI
import RevenueCat

struct SubscriptionSettingsView: View {
    @Environment(SubscriptionService.self) private var subscription
    @Environment(EntitlementGate.self) private var entitlementGate
    @Environment(NewBackendAuthService.self) private var auth
    @State private var showPaywall: Bool = false
    @State private var statusMessage: String?
    @State private var isRefreshingAccess: Bool = false

    private var entitlement: EntitlementInfo? {
        subscription.customerInfo?.entitlements[SubscriptionService.entitlementIdentifier]
    }

    var body: some View {
        Form {
            statusSection
            accessStatusSection
            actionsSection
            if let entitlement {
                detailsSection(entitlement)
            }
            entitlementDiagnosticsSection
            helpSection
        }
        .navigationTitle("Subscription")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await subscription.refreshCustomerInfo()
            await subscription.refreshOfferings()
            await entitlementGate.refresh()
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                SubscriptionPaywallView(allowDismiss: true)
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: subscription.hasAccess ? "checkmark.seal.fill" : "lock.fill")
                    .font(.title2)
                    .foregroundStyle(subscription.hasAccess ? Color.green : Color.orange)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } header: {
            Text("Status")
        }
    }

    private var statusTitle: String {
        if entitlementGate.outcome == .grantedBySupabase {
            if entitlementGate.lastServerAccess?.reasonCode == "internal_unlimited" {
                return "Internal Unlimited access"
            }
            return entitlementGate.lastServerAccess?.planName ?? "VineTrack access active"
        }
        if subscription.isSubscribed { return "Vineyard Tracker Pro" }
        if subscription.isInInitialFreeAccessPeriod { return "Free access active" }
        return "No active subscription"
    }

    private var statusSubtitle: String {
        if subscription.isSubscribed {
            if let expiry = entitlement?.expirationDate {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                let prefix = entitlement?.willRenew == true ? "Renews" : "Expires"
                return "\(prefix) \(formatter.string(from: expiry))"
            }
            return "Active"
        }
        if subscription.isInInitialFreeAccessPeriod {
            if let freeAccessEndsAt = subscription.freeAccessEndsAt {
                return "Paywall hidden until \(freeAccessEndsAt.formatted(date: .abbreviated, time: .omitted))"
            }
            return "Paywall hidden during your first 3 months"
        }
        switch subscription.status {
        case .loading: return "Checking subscription…"
        case .failure(let m): return m
        default: return "Subscribe to unlock all vineyard features"
        }
    }

    // MARK: - Access status

    private var accessStatusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: accessStateIcon)
                    .font(.title3)
                    .foregroundStyle(accessStateColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessStateTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(accessStateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            LabeledContent("Last verified", value: lastVerifiedText)
            LabeledContent("Offline grace remaining", value: graceRemainingText)
            if let account = accountIdentifier {
                LabeledContent("Account", value: account)
            }
            if showRefreshAccessButton {
                Button {
                    Task { await refreshAccess() }
                } label: {
                    HStack {
                        Label("Refresh access", systemImage: "arrow.clockwise.circle")
                        Spacer()
                        if isRefreshingAccess { ProgressView() }
                    }
                }
                .disabled(isRefreshingAccess || subscription.isOffline)
            }
        } header: {
            Text("Access")
        } footer: {
            Text(accessStateFooter)
        }
    }

    private var accessStateTitle: String {
        switch subscription.accessState {
        case .subscribed: return "Subscription active"
        case .freeAccess: return "Free access period"
        case .offlineGrace: return "Offline grace active"
        case .needsVerification: return "Needs online verification"
        case .notVerified: return "Not verified"
        }
    }

    private var accessStateDetail: String {
        switch subscription.accessState {
        case .subscribed:
            return "Verified with the App Store."
        case .freeAccess:
            if let endsAt = subscription.freeAccessEndsAt {
                return "Free until \(endsAt.formatted(date: .abbreviated, time: .omitted))."
            }
            return "Inside your first 3 months."
        case .offlineGrace:
            if let days = subscription.offlineGraceRemainingDays {
                return "Working offline — \(days) day\(days == 1 ? "" : "s") of grace remaining."
            }
            return "Working offline on cached access."
        case .needsVerification:
            return "Connect to the internet to refresh your subscription."
        case .notVerified:
            return "Subscribe to unlock all vineyard features."
        }
    }

    private var accessStateFooter: String {
        "Your last successful subscription check is stored on this device. If you go offline, a verified subscriber keeps full access for \(SubscriptionService.offlineGraceDays) days before a fresh check is needed."
    }

    private var accessStateIcon: String {
        switch subscription.accessState {
        case .subscribed: return "checkmark.seal.fill"
        case .freeAccess: return "gift.fill"
        case .offlineGrace: return "wifi.slash"
        case .needsVerification: return "exclamationmark.arrow.triangle.2.circlepath"
        case .notVerified: return "lock.fill"
        }
    }

    private var accessStateColor: Color {
        switch subscription.accessState {
        case .subscribed, .freeAccess: return .green
        case .offlineGrace, .needsVerification: return .orange
        case .notVerified: return .red
        }
    }

    private var lastVerifiedText: String {
        guard let date = subscription.lastVerifiedEntitlementAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var graceRemainingText: String {
        guard let days = subscription.offlineGraceRemainingDays else {
            return subscription.offlineGraceAnchorDate == nil ? "—" : "Expired"
        }
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private var accountIdentifier: String? {
        if let email = auth.userEmail, !email.isEmpty { return email }
        return nil
    }

    /// Offer a manual refresh when online and either stale or not currently
    /// fully verified. Hidden when there's nothing useful a refresh would do.
    private var showRefreshAccessButton: Bool {
        if subscription.isOffline { return false }
        if subscription.accessState == .subscribed && !subscription.isVerificationStale { return false }
        return true
    }

    private func refreshAccess() async {
        guard !isRefreshingAccess else { return }
        isRefreshingAccess = true
        defer { isRefreshingAccess = false }
        await subscription.refreshCustomerInfo()
        await entitlementGate.refresh(force: true)
        statusMessage = entitlementGate.hasAccess
            ? "Access refreshed."
            : (subscription.lastError ?? "No valid entitlement found.")
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if !subscription.hasAccess {
                Button {
                    showPaywall = true
                } label: {
                    Label("View Plans", systemImage: "creditcard.fill")
                }
            }
            Button {
                Task {
                    let restored = await subscription.restorePurchases()
                    // Restore refreshes RevenueCat CustomerInfo, then the
                    // combined access state; the bounded post-purchase sync
                    // waits for the server webhook without blocking access.
                    await entitlementGate.syncAfterStorePurchase()
                    statusMessage = restored
                        ? "Purchases restored."
                        : (subscription.lastError ?? "No active purchases found.")
                }
            } label: {
                HStack {
                    Label("Restore Purchases", systemImage: "arrow.clockwise")
                    Spacer()
                    if subscription.isRestoring { ProgressView() }
                }
            }
            .disabled(subscription.isRestoring)

            Button {
                Task { await subscription.refreshCustomerInfo() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.triangle.2.circlepath")
            }

            if subscription.isSubscribed,
               let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                Link(destination: url) {
                    Label("Manage Subscription", systemImage: "arrow.up.right.square")
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func detailsSection(_ entitlement: EntitlementInfo) -> some View {
        Section("Details") {
            LabeledContent("Plan", value: entitlement.productIdentifier)
            if let purchaseDate = entitlement.latestPurchaseDate {
                LabeledContent("Purchased", value: purchaseDate.formatted(date: .abbreviated, time: .omitted))
            }
            if let expiry = entitlement.expirationDate {
                LabeledContent(entitlement.willRenew ? "Renews" : "Expires",
                               value: expiry.formatted(date: .abbreviated, time: .omitted))
            }
            if entitlement.periodType == .trial {
                LabeledContent("Trial", value: "Active")
            }
        }
    }

    // MARK: - Entitlement diagnostics (Phase 2A)

    private var entitlementDiagnosticsSection: some View {
        Section {
            LabeledContent("Effective access", value: entitlementGate.hasAccess ? "Granted" : "Denied")
            LabeledContent("Access state", value: entitlementGate.stateLabel)
            if let source = diagnosticAccessSource {
                LabeledContent("Access source", value: source)
            }
            if let plan = entitlementGate.lastServerAccess?.planCode {
                LabeledContent("Plan", value: plan)
            }
            if let reason = entitlementGate.lastServerAccess?.reasonCode {
                LabeledContent("Server reason", value: reason)
            }
            LabeledContent("Server check", value: serverCheckText)
            LabeledContent("Result", value: entitlementGate.isUsingCachedResult ? "Cached (offline)" : "Live")
            if let expiry = entitlementGate.lastServerAccess?.knownExpiresAt(now: Date()) {
                LabeledContent("Known expiry", value: expiry.formatted(date: .abbreviated, time: .shortened))
            }
            LabeledContent("RevenueCat \"pro\"", value: subscription.isSubscribed ? "Active" : "Inactive")
            if let rcUserId = subscription.customerInfo?.originalAppUserId {
                LabeledContent("RevenueCat user", value: truncatedId(rcUserId))
            }
            LabeledContent("Shared entitlement", value: entitlementGate.enforcementEnabled ? "Enforced" : "Legacy gate")
            if let mismatch = mismatchText {
                Label(mismatch, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let userId = auth.userId?.uuidString {
                LabeledContent("Supabase user", value: truncatedId(userId))
            }
        } header: {
            Text("Access diagnostics")
        } footer: {
            Text("VineTrack checks your account's shared entitlement first (portal subscriptions and internal grants), then the App Store subscription. No purchase details are shown here.")
        }
    }

    private var diagnosticAccessSource: String? {
        switch entitlementGate.outcome {
        case .grantedBySupabase:
            return "Supabase (\(entitlementGate.lastServerAccess?.accessSourceLabel ?? "granted"))"
        case .grantedByRevenueCat:
            return "RevenueCat (App Store)"
        case .grantedByLegacyTrial:
            return "Initial free period"
        case .offlineCachedAccess:
            return "Offline cache"
        default:
            return nil
        }
    }

    private var serverCheckText: String {
        guard let date = entitlementGate.lastRefreshedAt else { return "Never" }
        let when = date.formatted(date: .abbreviated, time: .shortened)
        switch entitlementGate.lastServerResult {
        case .granted: return "\(when) · granted"
        case .denied: return "\(when) · denied"
        case .unreachable: return "\(when) · unreachable"
        case nil: return when
        }
    }

    private var mismatchText: String? {
        if entitlementGate.hasServerMismatch {
            return "RevenueCat grants access; Supabase does not. Reported for review — your access is unaffected."
        }
        if entitlementGate.outcome == .grantedBySupabase && !subscription.isSubscribed {
            return "Supabase grants access; RevenueCat does not. This is expected for portal subscriptions and internal grants."
        }
        return nil
    }

    private func truncatedId(_ id: String) -> String {
        guard id.count > 12 else { return id }
        return "\(id.prefix(8))…"
    }

    @Environment(\.openURL) private var openURL

    private var helpSection: some View {
        Section {
            Button {
                if let url = URL(string: "https://vinetrack.com.au/privacy") { openURL(url) }
            } label: {
                HStack {
                    Text("Privacy Policy")
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                if let url = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") { openURL(url) }
            } label: {
                HStack {
                    Text("Terms of Use (EULA)")
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } footer: {
            Text("Subscriptions are billed through your Apple ID. A 3-month free trial applies to new subscribers.")
        }
    }
}
