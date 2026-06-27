import SwiftUI

/// Compact, glanceable sync/network status chip for the Home tab header.
///
/// Unlike `GlobalSyncStatusBar` (which hides itself in the "all good" state),
/// this chip is always visible so an operator can confirm at a glance whether
/// VineTrack is online, offline, syncing, synced, or saving locally. It reuses
/// the shared `SyncStatusCenter` as the single source of truth — it never runs
/// a sweep or maintains its own reachability.
///
/// Tapping the chip pushes the Sync settings/status screen via the surrounding
/// NavigationStack. It never blocks field work.
struct HomeSyncStatusChip: View {
    @Environment(SyncStatusCenter.self) private var sync
    @Environment(NetworkMonitor.self) private var network

    var body: some View {
        let state = sync.displayState(isOnline: network.isOnline)
        // Per-record failures take visual priority: surface a retry count so an
        // operator notices specific records need attention, while the normal
        // wording stays in place when nothing has failed.
        let failedTotal = sync.failedTotal
        let showFailures = failedTotal > 0
        let tint = showFailures ? Color.red : tint(for: state)
        let symbol = showFailures ? "exclamationmark.triangle.fill" : symbol(for: state)
        let label = showFailures ? "\(failedTotal) need retry" : label(for: state)
        return NavigationLink {
            SyncSettingsView()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating, isActive: state == .syncing && !showFailures)
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sync status: \(sync.label(isOnline: network.isOnline)). Tap to open Sync settings.")
    }

    /// Short, header-friendly label. The full phrasing lives in Sync settings
    /// and the global status bar.
    private func label(for state: SyncStatusCenter.DisplayState) -> String {
        switch state {
        case .offline: return "Offline"
        case .syncing: return "Syncing"
        case .error: return "Sync error"
        case .pending(let count): return "\(count) waiting"
        case .synced: return "Synced"
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
