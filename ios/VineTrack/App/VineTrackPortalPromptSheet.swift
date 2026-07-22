import SwiftUI

/// One-time "Want to manage this from a desktop?" prompt that introduces
/// users to the VineTrack Web Portal after key onboarding milestones.
///
/// Role behaviour:
/// - Owner / Manager: full prominent prompt.
/// - Supervisor: lower-key variant (smaller icon, muted styling).
/// - Operator (or unknown role): the parent shouldn't even present this
///   sheet for that role — but if it does, we still respect the user by
///   marking the trigger as seen and dismissing.
struct VineTrackPortalPromptSheet: View {
    let trigger: PortalPromptTrigger
    let role: BackendRole?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var isProminent: Bool {
        switch role {
        case .owner, .manager: true
        default: false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    bodyText
                    bulletList
                    buttons
                    footerHint
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismissAndMarkSeen() }
                        .font(.subheadline)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents(isProminent ? [.medium, .large] : [.medium])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isProminent
                                ? [VineyardTheme.leafGreen, VineyardTheme.leafGreen.opacity(0.7)]
                                : [Color.secondary.opacity(0.25), Color.secondary.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: isProminent ? 84 : 64, height: isProminent ? 84 : 64)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: isProminent ? 36 : 28, weight: .semibold))
                    .foregroundStyle(isProminent ? Color.white : Color.primary)
            }
            .padding(.top, 8)

            Text("Want to manage this from a desktop?")
                .font(isProminent ? .title2.weight(.semibold) : .title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
    }

    private var bodyText: some View {
        Text("Use the VineTrack Web Portal to set up blocks, chemicals, tasks, reports and team access.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var bulletList: some View {
        if isProminent {
            VStack(alignment: .leading, spacing: 10) {
                bullet("square.grid.2x2.fill", "Blocks, chemicals & spray planning")
                bullet("doc.text.fill", "Reports & exports for the season")
                bullet("person.2.fill", "Team access & invitations")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 14))
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(VineyardTheme.leafGreen)
                .frame(width: 22)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                openPortal()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "safari")
                    Text("Open Web Portal")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(VineyardTheme.leafGreen)

            Button("Not now") { dismissAndMarkSeen() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private var footerHint: some View {
        Text(VineTrackPortal.displayHost)
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
    }

    private func openPortal() {
        PortalPromptTracker.markSeen(trigger)
        if let url = VineTrackPortal.url {
            openURL(url)
        }
        dismiss()
    }

    private func dismissAndMarkSeen() {
        PortalPromptTracker.markSeen(trigger)
        dismiss()
    }
}
