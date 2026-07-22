import SwiftUI

/// Subtle, non-blocking banner shown only while the user is being allowed into
/// the app via the offline subscription grace window. It never gates any
/// action — field records keep saving locally regardless.
///
/// Visibility is driven entirely by `SubscriptionService.isRelyingOnOfflineGrace`,
/// so it stays hidden when:
///   - online and fully verified
///   - inside the initial 3-month free-access period
///   - offline but still covered by a live/cached subscription
struct OfflineGraceBanner: View {
    @Environment(SubscriptionService.self) private var subscription

    var body: some View {
        if subscription.isRelyingOnOfflineGrace {
            content
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var isExpiringSoon: Bool {
        guard let days = subscription.offlineGraceRemainingDays else { return true }
        return days < 3
    }

    private var message: String {
        if isExpiringSoon {
            return "Offline access expires soon — connect to the internet to refresh access."
        }
        let days = subscription.offlineGraceRemainingDays ?? 0
        return "Offline access active — \(days) day\(days == 1 ? "" : "s") remaining. Records will keep saving locally."
    }

    private var tint: Color { isExpiringSoon ? .red : .orange }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpiringSoon ? "exclamationmark.triangle.fill" : "wifi.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.35))
                .frame(height: 0.5)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
        }
    }
}
