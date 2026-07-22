import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var page: Int = 0

    private struct Page: Identifiable {
        let id = UUID()
        let icon: String
        let iconColor: Color
        let title: String
        let message: String
        var assetImage: String? = nil
        var useBrandWordmark: Bool = false
    }

    private let pages: [Page] = [
        Page(
            icon: "leaf.fill",
            iconColor: VineyardTheme.leafGreen,
            title: "Welcome to VineTrack",
            message: "Built by vignerons for vignerons — manage vineyard observations, spray records, irrigation, disease risk and team activity in one place.",
            assetImage: "vinetrack_logo",
            useBrandWordmark: true
        ),
        Page(
            icon: "mappin.and.ellipse",
            iconColor: .blue,
            title: "Track work in the vineyard",
            message: "Drop pins for repairs and observations, record trips, capture growth stages and keep your team aligned row by row."
        ),
        Page(
            icon: "cloud.sun.rain.fill",
            iconColor: .orange,
            title: "Smarter vineyard decisions",
            message: "Use weather data, irrigation recommendations and disease-risk alerts for Downy, Powdery and Botrytis to help prioritise vineyard work."
        ),
        Page(
            icon: "person.2.fill",
            iconColor: .purple,
            title: "Sync with your vineyard team",
            message: "Choose or create a vineyard, invite team members, manage roles and keep records synced securely across devices."
        )
    ]

    var body: some View {
        ZStack {
            VineyardTheme.appBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, p in
                        pageView(p).tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: 12) {
                    Button {
                        if page < pages.count - 1 {
                            withAnimation { page += 1 }
                        } else {
                            onComplete()
                        }
                    } label: {
                        Text(page < pages.count - 1 ? "Continue" : "Get Started")
                    }
                    .buttonStyle(.vineyardPrimary)

                    if page < pages.count - 1 {
                        Button("Skip") {
                            onComplete()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func pageView(_ p: Page) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                if let asset = p.assetImage {
                    Image(asset)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 140, height: 140)
                        .clipShape(.rect(cornerRadius: 30, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .strokeBorder(.white.opacity(0.6), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
                } else {
                    Circle()
                        .fill(p.iconColor.opacity(0.15))
                        .frame(width: 140, height: 140)
                    Image(systemName: p.icon)
                        .font(.system(size: 64, weight: .semibold))
                        .foregroundStyle(p.iconColor)
                }
            }
            if p.useBrandWordmark {
                HStack(spacing: 6) {
                    Text("Welcome to")
                        .foregroundStyle(.primary)
                    BrandWordmark(
                        size: 28,
                        vineColor: .primary
                    )
                }
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            } else {
                Text(p.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)
            }
            Text(p.message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}

enum OnboardingState {
    private static let key = "vinetrack_onboarding_completed_v1"

    static var isCompleted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: key)
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
