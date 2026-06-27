//
//  RecordSyncState.swift
//  VineTrackV2
//
//  Shared foundation for per-record sync badges. A single record (a trip, pin,
//  spray record, etc.) can be in one of four coarse states, derived from the
//  relevant sync service's per-record pending sets plus the global
//  `SyncStatusCenter`. This is read-only — badges never block opening, editing,
//  exporting, or reviewing records.
//
//  This intentionally mirrors the language used by the global sync system
//  (`SyncStatusCenter` / `GlobalSyncStatusBar`): Synced, Queued, Syncing,
//  Error / Will retry. It does NOT introduce a second sync state system; it is a
//  thin presentation layer over the existing per-service pending/error state.
//

import SwiftUI

/// Coarse, per-record sync state surfaced via `RecordSyncBadge`.
enum RecordSyncState: Equatable, Sendable {
    /// Uploaded and confirmed — no local changes pending.
    case synced
    /// Has local changes queued for upload (offline or waiting for a sweep).
    case queued
    /// Currently being pushed/pulled by an in-flight sweep.
    case syncing
    /// The last sweep failed while this record was still pending. Will retry.
    case error

    /// Short label matching the global sync vocabulary.
    var label: String {
        switch self {
        case .synced: return "Synced"
        case .queued: return "Queued"
        case .syncing: return "Syncing"
        case .error: return "Will retry"
        }
    }

    /// Slightly longer accessibility phrasing.
    var accessibilityLabel: String {
        switch self {
        case .synced: return "Synced"
        case .queued: return "Queued for upload"
        case .syncing: return "Syncing"
        case .error: return "Sync error, will retry"
        }
    }

    var symbol: String {
        switch self {
        case .synced: return "checkmark.circle.fill"
        case .queued: return "clock.arrow.circlepath"
        case .syncing: return "arrow.triangle.2.circlepath"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .synced: return .green
        case .queued: return .orange
        case .syncing: return .blue
        case .error: return .red
        }
    }
}

extension RecordSyncState {
    /// Resolve a record's sync state from generic per-record + service inputs.
    ///
    /// - Parameters:
    ///   - isPending: Whether the record has local changes queued (upsert or delete).
    ///   - serviceIsSyncing: Whether the owning sync service has a sweep in flight.
    ///   - recordHasFailure: Whether *this specific record's* last push failed
    ///     while still pending. This is per-record, not service-wide, so one
    ///     failed record never makes unrelated records look failed.
    ///
    /// Records with no pending changes are always `.synced`. A pending record is
    /// `.syncing` during an active sweep, `.error` if this record's last push
    /// failed, otherwise `.queued`.
    static func resolve(
        isPending: Bool,
        serviceIsSyncing: Bool,
        recordHasFailure: Bool
    ) -> RecordSyncState {
        guard isPending else { return .synced }
        if serviceIsSyncing { return .syncing }
        if recordHasFailure { return .error }
        return .queued
    }

    /// Convenience resolver for trips, reading the live `TripSyncService` state.
    @MainActor
    static func forTrip(_ tripId: UUID, tripSync: TripSyncService) -> RecordSyncState {
        resolve(
            isPending: tripSync.isPendingUpsert(tripId) || tripSync.isPendingDelete(tripId),
            serviceIsSyncing: tripSync.isSyncing,
            recordHasFailure: tripSync.hasFailure(tripId)
        )
    }

    /// Convenience resolver for pins, reading the live `PinSyncService` state.
    ///
    /// A pin created or edited offline (including one with a photo still
    /// waiting to upload) is tracked as a pending upsert, so it resolves to
    /// `.queued` until the sweep confirms it, `.syncing` during an active
    /// sweep, and `.error` if the last sweep failed while still pending.
    @MainActor
    static func forPin(_ pinId: UUID, pinSync: PinSyncService) -> RecordSyncState {
        resolve(
            isPending: pinSync.isPendingUpsert(pinId) || pinSync.isPendingDelete(pinId),
            serviceIsSyncing: pinSync.isSyncing,
            recordHasFailure: pinSync.hasFailure(pinId)
        )
    }

    /// Convenience resolver for spray records, reading the live
    /// `SprayRecordSyncService` state.
    ///
    /// Compliance note: a spray record resolves purely from its own pending
    /// state. It is never marked synced because a linked trip is synced — the
    /// two records track independently.
    @MainActor
    static func forSprayRecord(_ recordId: UUID, spraySync: SprayRecordSyncService) -> RecordSyncState {
        resolve(
            isPending: spraySync.isPendingUpsert(recordId) || spraySync.isPendingDelete(recordId),
            serviceIsSyncing: spraySync.isSyncing,
            recordHasFailure: spraySync.hasFailure(recordId)
        )
    }

    /// Convenience resolver for damage records, reading the live
    /// `DamageRecordSyncService` state.
    ///
    /// A damage record is treated as a single sync unit — its polygon points and
    /// geometry vertices are never badged individually. It resolves purely from
    /// its own pending state: `.queued` when created/edited offline, `.syncing`
    /// during an active sweep, `.error` if the last sweep failed while still
    /// pending, otherwise `.synced`.
    @MainActor
    static func forDamageRecord(_ recordId: UUID, damageSync: DamageRecordSyncService) -> RecordSyncState {
        resolve(
            isPending: damageSync.isPendingUpsert(recordId) || damageSync.isPendingDelete(recordId),
            serviceIsSyncing: damageSync.isSyncing,
            recordHasFailure: damageSync.hasFailure(recordId)
        )
    }

    /// Convenience resolver for yield sessions, reading the live
    /// `YieldEstimationSessionSyncService` state.
    ///
    /// A yield session is treated as a single sync unit — its embedded sample
    /// points are covered by the session badge and are never badged
    /// individually. It resolves purely from its own pending state: `.queued`
    /// when created/continued offline, `.syncing` during an active sweep,
    /// `.error` if the last sweep failed while still pending, otherwise
    /// `.synced`.
    @MainActor
    static func forYieldSession(_ sessionId: UUID, yieldSync: YieldEstimationSessionSyncService) -> RecordSyncState {
        resolve(
            isPending: yieldSync.isPendingUpsert(sessionId) || yieldSync.isPendingDelete(sessionId),
            serviceIsSyncing: yieldSync.isSyncing,
            recordHasFailure: yieldSync.hasFailure(sessionId)
        )
    }

    /// Convenience resolver for work tasks, reading the live
    /// `WorkTaskSyncService` state.
    ///
    /// Compliance note: a work task resolves purely from its own pending state.
    /// Related records (labour lines, paddock links) sync independently via
    /// their own services and never mark the task itself synced or unsynced.
    @MainActor
    static func forWorkTask(_ taskId: UUID, taskSync: WorkTaskSyncService) -> RecordSyncState {
        resolve(
            isPending: taskSync.isPendingUpsert(taskId) || taskSync.isPendingDelete(taskId),
            serviceIsSyncing: taskSync.isSyncing,
            recordHasFailure: taskSync.hasFailure(taskId)
        )
    }
}
