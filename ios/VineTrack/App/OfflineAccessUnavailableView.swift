import SwiftUI

/// Shown when the device is offline, the user is not within the initial free
/// period, and the persisted offline grace window has expired (or no prior
/// verification exists). A real subscriber should never see this for long —
/// the moment connectivity returns we re-verify automatically.
struct OfflineAccessUnavailableView: View {
    @Environment(SubscriptionService.self) private var subscription
    @Environment(NetworkMonitor.self) private var network

    @State private var isRetrying: Bool = false

    var body: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)

                Text("Can't verify your subscription")
                    .font(.title3.bold())
                    .multilineTextAlignment(.center)

                Text("We couldn’t verify your subscription because this device is offline. Connect to the internet to refresh access.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                if let lastVerified = subscription.lastVerifiedEntitlementAt {
                    Text("Last verified \(lastVerified.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Button {
                    Task { await retry() }
                } label: {
                    HStack(spacing: 8) {
                        if isRetrying { ProgressView().tint(.white) }
                        Text(isRetrying ? "Checking…" : "Try Again")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.vineyardPrimary)
                .disabled(isRetrying)
                .padding(.horizontal, 40)
                .padding(.top, 8)
            }
        }
        .task {
            // Auto-recover if connectivity is already back when this appears.
            if network.isOnline { await retry() }
        }
        .onChange(of: network.isOnline) { _, online in
            if online { Task { await retry() } }
        }
    }

    private func retry() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }
        await subscription.refreshCustomerInfo()
    }
}
