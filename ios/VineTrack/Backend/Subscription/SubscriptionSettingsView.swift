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

    private var accessPresentation: EntitlementAccessPresentation {
        EntitlementAccessPresentation(
            outcome: entitlementGate.outcome,
            serverAccess: entitlementGate.lastServerAccess,
            verification: EntitlementVerificationStore.shared.load(for: auth.userId),
            isOffline: subscription.isOffline,
            legacyTrialEndsAt: subscription.freeAccessEndsAt,
            storeExpiresAt: entitlement?.expirationDate,
            storeWillRenew: entitlement?.willRenew == true,
            offlineGraceDays: SubscriptionService.offlineGraceDays
        )
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
                Image(systemName: accessPresentation.icon)
                    .font(.title2)
                    .foregroundStyle(accessStateColor)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessPresentation.statusTitle)
                        .font(.headline)
                    Text(accessPresentation.statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: - Access status

    private var accessStatusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: accessPresentation.icon)
                    .font(.title3)
                    .foregroundStyle(accessStateColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accessPresentation.accessTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(accessPresentation.accessDetail)
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
            if accessPresentation.shouldOfferRefresh {
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

    private var accessStateFooter: String {
        "Your last verified access is stored on this device for offline use for up to \(SubscriptionService.offlineGraceDays) days, capped by any known access expiry. VineTrack refreshes access when you reconnect."
    }

    private var accessStateColor: Color {
        switch accessPresentation.tone {
        case .positive: return .green
        case .warning: return .orange
        case .negative: return .red
        case .neutral: return .secondary
        }
    }

    private var lastVerifiedText: String {
        guard let date = accessPresentation.lastVerifiedAt else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var graceRemainingText: String {
        guard let end = accessPresentation.offlineGraceEndsAt else { return "—" }
        let remaining = end.timeIntervalSinceNow
        guard remaining > 0 else { return "Expired" }
        let days = Int(ceil(remaining / 86_400))
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    private var accountIdentifier: String? {
        if let email = auth.userEmail, !email.isEmpty { return email }
        return nil
    }

    private func refreshAccess() async {
        guard !isRefreshingAccess else { return }
        isRefreshingAccess = true
        defer { isRefreshingAccess = false }
        await subscription.refreshCustomerInfo()
        await entitlementGate.refresh(force: true)
        if entitlementGate.hasAccess {
            statusMessage = "Access refreshed."
        } else if entitlementGate.outcome == .denied {
            statusMessage = "No active access was found for this account."
        } else {
            statusMessage = "Access has not been verified yet. Connect to the internet and try again."
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            if accessPresentation.shouldOfferPlans {
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
                Task { await refreshAccess() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isRefreshingAccess || subscription.isOffline)

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
        Section("App Store Details") {
            LabeledContent("Plan", value: entitlement.productIdentifier)
            LabeledContent("Status", value: entitlement.isActive ? "Active" : "Inactive")
            if let purchaseDate = entitlement.latestPurchaseDate {
                LabeledContent("Purchased", value: purchaseDate.formatted(date: .abbreviated, time: .omitted))
            }
            if let expiry = entitlement.expirationDate {
                LabeledContent(entitlement.willRenew ? "Renews" : "Expires",
                               value: expiry.formatted(date: .abbreviated, time: .omitted))
            }
            if entitlement.periodType == .trial {
                LabeledContent("Trial", value: entitlement.isActive ? "Active" : "Ended")
            }
        }
    }

    // MARK: - Entitlement diagnostics (Phase 2A)

    private var entitlementDiagnosticsSection: some View {
        Section {
            LabeledContent("Effective access", value: entitlementGate.hasAccess ? "Granted" : (entitlementGate.outcome == .denied ? "Denied" : "Unverified"))
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
            Text("App Store purchases are billed through your Apple ID. Access may also be provided by your vineyard.")
        }
    }
}
