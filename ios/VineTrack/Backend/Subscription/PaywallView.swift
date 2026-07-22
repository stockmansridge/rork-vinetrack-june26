import SwiftUI
import RevenueCat

struct SubscriptionPaywallView: View {
    @Environment(SubscriptionService.self) private var subscription
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(\.dismiss) private var dismiss

    let allowDismiss: Bool

    init(allowDismiss: Bool = false) {
        self.allowDismiss = allowDismiss
    }

    var body: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            if let offering = subscription.currentOffering {
                paywallContent(offering)
            } else {
                fallbackView
            }
        }
        .task {
            await subscription.refreshOfferings()
        }
        .toolbar {
            if !allowDismiss {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out") {
                        Task {
                            await subscription.logout()
                            await auth.signOut()
                        }
                    }
                    .tint(.red)
                }
            }
        }
    }

    private func paywallContent(_ offering: Offering) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                VStack(spacing: 12) {
                    ForEach(offering.availablePackages, id: \.identifier) { package in
                        packageButton(package)
                    }
                }
                .padding(16)
                .background(VineyardTheme.cardBackground, in: .rect(cornerRadius: 22))
                .overlay {
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(VineyardTheme.cardBorder, lineWidth: 0.5)
                }

                VStack(spacing: 10) {
                    Button {
                        Task {
                            _ = await subscription.restorePurchases()
                        }
                    } label: {
                        HStack {
                            Label("Restore Purchases", systemImage: "arrow.clockwise")
                            if subscription.isRestoring { ProgressView() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(subscription.isRestoring)

                    Text("Your Apple ID confirms the trial and billing date before you subscribe. Cancel at least 24 hours before the trial ends to avoid renewal.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let error = subscription.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }
            .padding(20)
            .padding(.top, 12)
        }
    }

    private var header: some View {
        VStack(spacing: 14) {
            Image("vinetrack_logo")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 86, height: 86)
                .clipShape(.rect(cornerRadius: 20))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)

            VStack(spacing: 8) {
                Text("Start with 3 months free")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(red: 0.10, green: 0.30, blue: 0.16))
                Text("No charge today. Billing starts only after your free trial unless you cancel.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func packageButton(_ package: Package) -> some View {
        Button {
            Task {
                let unlocked = await subscription.purchase(package: package)
                if unlocked && allowDismiss {
                    dismiss()
                }
            }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(planTitle(for: package))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("3 months free, then \(renewalText(for: package))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Text(package.storeProduct.localizedTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right.circle.fill")
                    .font(.title2)
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(VineyardTheme.leafGreen.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(subscription.isPurchasing)
    }

    private func planTitle(for package: Package) -> String {
        let identifier = package.identifier.lowercased()
        let title = package.storeProduct.localizedTitle.lowercased()
        if identifier.contains("year") || identifier.contains("annual") || title.contains("year") || title.contains("annual") {
            return "Annual plan"
        }
        if identifier.contains("month") || title.contains("month") {
            return "Monthly plan"
        }
        return package.storeProduct.localizedTitle
    }

    private func renewalText(for package: Package) -> String {
        let identifier = package.identifier.lowercased()
        let title = package.storeProduct.localizedTitle.lowercased()
        if identifier.contains("year") || identifier.contains("annual") || title.contains("year") || title.contains("annual") {
            return "\(package.storeProduct.localizedPriceString)/year"
        }
        if identifier.contains("month") || title.contains("month") {
            return "\(package.storeProduct.localizedPriceString)/month"
        }
        return package.storeProduct.localizedPriceString
    }

    private var fallbackView: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Loading subscription options…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let error = subscription.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Button("Retry") {
                Task { await subscription.refreshOfferings() }
            }
            .buttonStyle(.borderedProminent)

            Button("Restore Purchases") {
                Task { await subscription.restorePurchases() }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
