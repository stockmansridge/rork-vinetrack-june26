//
//  RecordSyncBadge.swift
//  VineTrack
//
//  Reusable, read-only per-record sync badge. Shows a small dot/icon plus a
//  short label where space allows. It never blocks interaction — it is purely
//  informational and sits alongside record content in lists, headers, and
//  summaries.
//

import SwiftUI

struct RecordSyncBadge: View {
    let state: RecordSyncState
    /// When false, only the coloured icon/dot is shown (for tight list rows).
    var showsLabel: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: state.symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(state.tint)
                .symbolEffect(.pulse, options: .repeating, isActive: state == .syncing)
            if showsLabel {
                Text(state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(state.tint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, showsLabel ? 8 : 6)
        .padding(.vertical, showsLabel ? 4 : 5)
        .background(state.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync status: \(state.accessibilityLabel)")
    }
}

/// Small, read-only explanatory hint for use in detail headers. Renders only
/// when the record's last push failed (`state == .error`); otherwise it draws
/// nothing. It never shows raw server errors — just a reassuring retry note.
struct RecordSyncFailureHint: View {
    let state: RecordSyncState

    var body: some View {
        if state == .error {
            Label("Last sync failed — will retry.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Last sync failed, will retry automatically")
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        RecordSyncBadge(state: .synced)
        RecordSyncBadge(state: .queued)
        RecordSyncBadge(state: .syncing)
        RecordSyncBadge(state: .error)
        HStack(spacing: 10) {
            RecordSyncBadge(state: .synced, showsLabel: false)
            RecordSyncBadge(state: .queued, showsLabel: false)
            RecordSyncBadge(state: .syncing, showsLabel: false)
            RecordSyncBadge(state: .error, showsLabel: false)
        }
    }
    .padding()
}
