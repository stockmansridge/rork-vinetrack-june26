import SwiftUI

/// Subtle, glanceable sync/network status shown at the top of the main shell.
///
/// It stays hidden when everything is online and fully synced (the "all good"
/// state needs no attention), and appears only when there is something worth
/// telling the user: offline, syncing, queued items, or a sync error. The full
/// always-visible status (including "Online · Synced") lives in Sync settings.
///
/// Tapping the inline button requests a manual full sync via `SyncStatusCenter`.
/// It is disabled while offline or already syncing, and shows progress while a
/// sweep is running. It never blocks field work — records keep saving locally.
struct GlobalSyncStatusBar: View {
    @Environment(SyncStatusCenter.self) private var sync
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        let state = sync.displayState(isOnline: network.isOnline)
        if state != .synced {
            content(for: state)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func content(for state: SyncStatusCenter.DisplayState) -> some View {
        let tint = tint(for: state)
        HStack(spacing: 10) {
            Image(systemName: symbol(for: state))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: state == .syncing)

            Text(sync.label(isOnline: network.isOnline))
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if state == .syncing {
                ProgressView()
                    .controlSize(.mini)
            } else if network.isOnline {
                Button {
                    sync.requestManualSync()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sync now")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(tint.opacity(0.35)).frame(height: 0.5)
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
        }
    }

    private func symbol(for state: SyncStatusCenter.DisplayState) -> String {
        switch state {
        case .offline: return "wifi.slash"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        case .pending: return "clock.arrow.circlepath"
        case .synced: return "checkmark.circle.fill"
        }
    }

    private func tint(for state: SyncStatusCenter.DisplayState) -> Color {
        switch state {
        case .offline: return .secondary
        case .syncing: return .blue
        case .error: return .red
        case .pending: return .orange
        case .synced: return .green
        }
    }
}
