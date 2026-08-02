//
//  SyncStatusCenter.swift
//  VineTrack
//
//  Lightweight, app-wide aggregator of sync + network status. It does NOT
//  perform any syncing itself — the main shell (`NewMainTabView`) owns the
//  full sweep and pushes aggregate results here so a single glanceable
//  indicator (`GlobalSyncStatusBar`) and the Sync settings header can read
//  one source of truth.
//
//  Design notes:
//    * `displayState(isOnline:)` derives the coarse status the UI shows. The
//      caller passes `NetworkMonitor.isOnline` so views observing both the
//      monitor and this center re-render correctly.
//    * Manual sync is request-only: UI calls `requestManualSync()` which bumps
//      `manualSyncToken`; the main shell observes that token and runs a sweep.
//      This avoids storing closures that capture ephemeral SwiftUI views.
//

import Foundation
import Observation

@Observable
@MainActor
final class SyncStatusCenter {

    /// Coarse status surfaced to the user.
    enum DisplayState: Equatable {
        /// No network path — records are saved locally and queued.
        case offline
        /// A full sweep is in flight.
        case syncing
        /// Online, but the last sweep reported an error. Will retry.
        case error
        /// Online and idle, with `count` items still queued to upload.
        case pending(Int)
        /// Online and everything is uploaded.
        case synced
    }

    private(set) var isSyncing: Bool = false
    private(set) var pendingUpserts: Int = 0
    private(set) var pendingDeletes: Int = 0
    /// Count of individual records whose last upload attempt failed and are
    /// queued to retry. Aggregated across every per-record sync service so the
    /// UI can say "3 records need retry" without flagging healthy records.
    private(set) var failedUpserts: Int = 0
    /// Count of individual records whose last delete attempt failed.
    private(set) var failedDeletes: Int = 0
    /// When the last full sweep completed (success or failure).
    ///
    /// IMPORTANT: this is now only set when the sweep was genuinely COMPLETE —
    /// download finished *and* every eligible upload was processed. A pull-only
    /// success no longer refreshes it (regression: the screen advertised a fresh
    /// "Last full sync" while 22 uploads were still stuck).
    private(set) var lastFullSyncAt: Date?
    /// When the last sweep completed with no errors.
    private(set) var lastSuccessfulSyncAt: Date?
    /// When the download half last completed without error.
    private(set) var lastPullAt: Date?
    /// When the upload half last drained without leaving anything queued.
    private(set) var lastUploadAt: Date?
    /// When a sweep was last attempted, regardless of outcome.
    private(set) var lastAttemptAt: Date?
    /// When a sweep last reported an error.
    private(set) var lastFailureAt: Date?
    /// Human-readable summary of the last sync error, if any.
    private(set) var lastError: String?

    /// Bumped every time the UI requests a manual sync. The main shell
    /// observes this to trigger a full sweep.
    private(set) var manualSyncToken: Int = 0

    var pendingTotal: Int { pendingUpserts + pendingDeletes }
    var failedTotal: Int { failedUpserts + failedDeletes }

    /// Operator-facing summary of how many specific records are waiting to
    /// retry, or `nil` when nothing has failed. Never exposes raw server
    /// errors — just counts.
    var retrySummary: String? {
        guard failedTotal > 0 else { return nil }
        if failedUpserts > 0 && failedDeletes > 0 {
            return "\(failedUpserts) upload\(failedUpserts == 1 ? "" : "s") and \(failedDeletes) delete\(failedDeletes == 1 ? "" : "s") need retry"
        }
        if failedDeletes > 0 {
            return failedDeletes == 1
                ? "1 delete failed, will retry"
                : "\(failedDeletes) deletes need retry"
        }
        if failedUpserts == 1 {
            return "1 upload failed, will retry"
        }
        return "\(failedUpserts) records need retry"
    }

    /// Request a manual full sync from anywhere in the UI.
    func requestManualSync() {
        manualSyncToken &+= 1
    }

    /// Mark the start of a full sweep.
    func syncDidStart() {
        isSyncing = true
        lastAttemptAt = Date()
    }

    /// True when uploads are still outstanding after the last online attempt.
    var hasIncompleteUploads: Bool { pendingTotal > 0 }

    /// Banner shown when a sweep finished but records are still queued —
    /// "Sync incomplete — 22 items still waiting".
    var incompleteSummary: String? {
        guard pendingTotal > 0 else { return nil }
        return "Sync incomplete — \(pendingTotal) item\(pendingTotal == 1 ? "" : "s") still waiting"
    }

    /// Refresh the queued-item counts without touching sync timestamps. Used
    /// while offline so the indicator still reflects the local backlog.
    func refreshPending(upserts: Int, deletes: Int, failedUpserts: Int = 0, failedDeletes: Int = 0) {
        pendingUpserts = upserts
        pendingDeletes = deletes
        self.failedUpserts = failedUpserts
        self.failedDeletes = failedDeletes
    }

    /// Record the outcome of a completed full sweep.
    ///
    /// `pullSucceeded` reports the download half only. "Last full sync" is a
    /// two-way claim, so it advances only when the pull succeeded, nothing
    /// errored, and the upload queue actually drained.
    func syncDidFinish(
        upserts: Int,
        deletes: Int,
        failedUpserts: Int = 0,
        failedDeletes: Int = 0,
        pullSucceeded: Bool = true,
        error: String?
    ) {
        isSyncing = false
        pendingUpserts = upserts
        pendingDeletes = deletes
        self.failedUpserts = failedUpserts
        self.failedDeletes = failedDeletes
        let now = Date()
        let uploadsDrained = (upserts + deletes) == 0

        if pullSucceeded { lastPullAt = now }
        if uploadsDrained && error == nil { lastUploadAt = now }
        if pullSucceeded && uploadsDrained && error == nil {
            lastFullSyncAt = now
            lastSuccessfulSyncAt = now
        }
        if error != nil { lastFailureAt = now }
        lastError = error
    }

    /// Derive the coarse status the UI displays. Offline takes priority over a
    /// stale error so a user with no signal sees "Saving locally", not "error".
    func displayState(isOnline: Bool) -> DisplayState {
        if isSyncing { return .syncing }
        if !isOnline { return .offline }
        if pendingTotal > 0 { return .pending(pendingTotal) }
        if lastError != nil { return .error }
        return .synced
    }

    /// Short label for the status indicator.
    func label(isOnline: Bool) -> String {
        switch displayState(isOnline: isOnline) {
        case .offline: return "Offline · Saving locally"
        case .syncing: return "Online · Syncing"
        case .error: return "Sync error · Will retry"
        case .pending(let count):
            return "Online · \(count) item\(count == 1 ? "" : "s") waiting to sync"
        case .synced: return "Online · Synced"
        }
    }
}
