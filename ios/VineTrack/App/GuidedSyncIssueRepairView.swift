import SwiftUI
import UIKit
import Supabase

/// Operator-led, per-record review. This UI never writes raw queue metadata,
/// invents data, changes a completed Trip or suppresses a reported failure.
/// All mutations are delegated to existing, authenticated, receipt-gated paths.
nonisolated struct GuidedSyncRepairIssue: Identifiable, Hashable, Sendable {
    nonisolated enum Kind: String, Sendable, Hashable {
        case tripUpload, tripDeletion, tankActual, sprayRecord, trackedSprayCompletion, initialMixDraft, protectedQueue, other
    }
    let id: String
    let recordId: UUID
    let relatedTripId: UUID?
    let kind: Kind
    let title: String
    let detail: String
    let verifiedCurrentScope: Bool
    let originalActualAvailable: Bool
}

nonisolated enum GuidedSyncRecordState: String, Sendable {
    case notChecked, active, ended, deleted, notVisible, standalone
}

/// Server identification of a historical queue ID is never evidence that its
/// original upload was accepted or that an old account's bytes may be erased.
nonisolated enum GuidedLegacyServerScope: String, Sendable {
    case unattributed, selectedNotDeleted, selectedDeleted

    static func classify(queuedID: UUID, selectedVineyard: UUID,
                         serverID: UUID?, serverVineyard: UUID?,
                         deletedAt: Date?) -> Self {
        guard serverID == queuedID, serverVineyard == selectedVineyard else {
            return .unattributed
        }
        return deletedAt == nil ? .selectedNotDeleted : .selectedDeleted
    }
}

nonisolated enum GuidedSyncCorrection: String, Identifiable, CaseIterable, Sendable {
    case recoverRecordedTank, manualVerifiedTank, amendActualUse, correctPendingActualUse, verifyCompleted, verifyCancellation, reviewLegacyDeleted, retryExisting, privateReview
    var id: Self { self }
    var label: String {
        switch self {
        case .recoverRecordedTank: "Recover tank start from confirmed Actual Use"
        case .manualVerifiedTank: "Enter verified original tank start"
        case .amendActualUse: "Amend verified server Actual Use"
        case .correctPendingActualUse: "Correct pending original Actual Use"
        case .verifyCompleted: "Verify original Trip completion"
        case .verifyCancellation: "Verify original deletion"
        case .reviewLegacyDeleted: "Reconcile deleted Trip and linked records"
        case .retryExisting: "Retry existing operations for this vineyard"
        case .privateReview: "Copy issue for owner review"
        }
    }
    var explanation: String {
        switch self {
        case .recoverRecordedTank:
            "Uses only the original confirmed tank ID, number and timestamp. Chemical amounts, paths and unknown end times are not changed. A successful local repair is NOT a server sync acknowledgement."
        case .manualVerifiedTank:
            "Select the retained original tank ID, enter the genuinely verified start time and record where that evidence came from. Never invent an ID or alter confirmed chemical amounts."
        case .amendActualUse:
            "Correct recorded water or chemical quantities through the existing audited backend RPC. A confirmed original server Actual and tank-session receipt are mandatory."
        case .correctPendingActualUse:
            "For an Actual Use that has never reached the server: archive the original operator confirmation locally, correct water or chemical amounts while preserving every original ID and tank session, then upload through the normal dependency-ordered sync."
        case .verifyCompleted:
            "Reads back the exact original ended Trip and checks its linked evidence before acknowledging the existing upload."
        case .verifyCancellation:
            "Only replays an already-recorded, original-account cancellation journal and independently verifies its server tombstone. Does not delete a different Trip."
        case .reviewLegacyDeleted:
            "The original server Trip is already deleted. After you confirm Applied or Not applied and supply an evidence note, the backend archives original compliance evidence, soft-deletes its remaining linked rows, and issues an exact cancellation receipt before any local queue is retired. It never restores the deleted Trip."
        case .retryExisting:
            "Runs the existing sync for this vineyard. Other eligible records in the same vineyard can also be retried. Original IDs and pending evidence are retained until the server accepts them."
        case .privateReview:
            "Copies a scoped issue summary to share privately. It does not discard, complete, fabricate or change any record."
        }
    }
}

/// Pure action-admission policy: server state and original scope must be known
/// before the UI can offer a write. Actual handlers reverify scope/server state.
nonisolated enum GuidedSyncCorrectionPolicy {
    static func available(for issue: GuidedSyncRepairIssue, server: GuidedSyncRecordState,
                          actualAccepted: Bool = false,
                          actualPending: Bool = false) -> [GuidedSyncCorrection] {
        guard issue.verifiedCurrentScope else {
            return issue.kind == .protectedQueue && server == .deleted
                ? [.reviewLegacyDeleted, .privateReview] : [.privateReview]
        }
        switch server {
        case .notChecked, .notVisible:
            return [.privateReview]
        case .deleted:
            return issue.kind == .tripDeletion
                ? [.verifyCancellation, .reviewLegacyDeleted, .privateReview]
                : (issue.kind == .tripUpload
                    ? [.reviewLegacyDeleted, .privateReview] : [.privateReview])
        case .active, .ended, .standalone:
            switch issue.kind {
            case .tripDeletion:
                // The operator already created an original deletion intent.
                // The handler requires its exact owner/vineyard journal before
                // replaying; it never creates a new cancellation.
                return server == .active ? [.verifyCancellation, .privateReview] : [.privateReview]
            case .tripUpload:
                var choices: [GuidedSyncCorrection] = []
                if server == .active && issue.originalActualAvailable {
                    choices.append(.recoverRecordedTank)
                    choices.append(.manualVerifiedTank)
                }
                if server == .ended { choices.append(.verifyCompleted) }
                choices.append(.retryExisting)
                choices.append(.privateReview)
                return choices
            case .tankActual:
                if actualAccepted { return [.amendActualUse, .retryExisting, .privateReview] }
                if actualPending { return [.correctPendingActualUse, .retryExisting, .privateReview] }
                return [.retryExisting, .privateReview]
            case .sprayRecord, .trackedSprayCompletion, .initialMixDraft:
                return [.retryExisting, .privateReview]
            case .protectedQueue:
                return [.privateReview]
            case .other:
                return [.retryExisting, .privateReview]
            }
        }
    }
}

/// A successful tombstone read offers a meaningful action by default; a
/// supported explicitly selected action is never overridden.
nonisolated enum GuidedSyncRepairSuggestion {
    static func choose(available: [GuidedSyncCorrection],
                       server: GuidedSyncRecordState,
                       current: GuidedSyncCorrection) -> GuidedSyncCorrection {
        if current != .privateReview && available.contains(current) { return current }
        if server == .deleted && available.contains(.reviewLegacyDeleted) {
            return .reviewLegacyDeleted
        }
        return available.first(where: { $0 != .privateReview }) ?? .privateReview
    }
}

nonisolated enum GuidedSyncIssueOrder {
    static func priority(_ kind: GuidedSyncRepairIssue.Kind) -> Int {
        switch kind {
        case .tripUpload: return 0
        case .tankActual: return 1
        case .sprayRecord: return 2
        case .trackedSprayCompletion: return 3
        case .tripDeletion: return 4
        case .initialMixDraft: return 5
        case .protectedQueue: return 9
        default: return 7
        }
    }
}

@MainActor
struct GuidedSyncIssueRepairView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripSyncService.self) private var tripSync
    @Environment(SprayRecordSyncService.self) private var spraySync
    @Environment(SyncStatusCenter.self) private var syncStatus

    @State private var items: [GuidedSyncRepairIssue] = []
    @State private var legacyServerScope: [UUID: GuidedLegacyServerScope] = [:]
    @State private var isCheckingLegacyScope = false
    @State private var legacyScopeReadFailed = false

    private var contextKey: String {
        (auth.userId?.uuidString ?? "none") + "|" + (store.selectedVineyardId?.uuidString ?? "none")
    }
    private var busy: Bool { syncStatus.isSyncing || tripSync.isSyncing || spraySync.isSyncing }

    var body: some View {
        Form {
            Section {
                Text("Choose one record, check its server state, then select a correction. The app checks the original evidence again before making any change.")
                    .font(.subheadline)
                Text("Queue entries and failures overlap; they are not separate totals. Historical or other-vineyard work is protected until its original ownership is established.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The list stays still during background sync. Use Refresh to check updated results.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isCheckingLegacyScope {
                    Label("Checking old Trip IDs in this vineyard's server records…",
                          systemImage: "arrow.clockwise")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !legacyServerScope.isEmpty {
                    Text("\(legacyServerScope.count) old Trip ID(s) matched this vineyard. No old upload or cancellation was acknowledged.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if legacyScopeReadFailed {
                    Text("Server scope could not be checked; original IDs remain protected. Refresh when connected.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Guided sync issue repair")
            }

            Section {
                Button {
                    Task { await refreshAndClassify() }
                } label: {
                    Label("Refresh issues and check server scope", systemImage: "arrow.clockwise")
                }
                .disabled(busy || !auth.isSignedIn || isCheckingLegacyScope)

                if busy {
                    Label("Sync is running. Repair actions are disabled until it finishes.", systemImage: "hourglass")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    Text("No individual issues were found in the currently loaded scope. This does not certify that the global legacy queue is empty.")
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    NavigationLink {
                        GuidedSyncIssueDetailView(issue: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 7) {
                                Image(systemName: item.kind == .protectedQueue ? "lock.shield" : "exclamationmark.circle")
                                    .foregroundStyle(item.verifiedCurrentScope ? Color.orange : Color.secondary)
                                Text(item.title).font(.headline)
                            }
                            if let tripId = item.relatedTripId,
                               let trip = store.trips.first(where: {
                                   $0.id == tripId && $0.vineyardId == store.selectedVineyardId
                               }) {
                                Text(trip.tripTitle ?? trip.tripFunction ?? "Trip")
                                    .font(.subheadline.weight(.medium))
                                Text(trip.startTime.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(item.recordId.uuidString.lowercased())
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                    .disabled(busy)
                }
            } header: {
                Text("Individual records (\(items.count))")
            } footer: {
                Text("A protected original cannot be modified by selecting the current vineyard. Do not uninstall the app or clear local data.")
            }
        }
        .navigationTitle("Review Sync Issues")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: contextKey) {
            legacyServerScope = [:]
            legacyScopeReadFailed = false
            await refreshAndClassify()
        }
        // Keep a stable issue-list snapshot while background sync retries.
        // The former status observer rebuilt all historical entries on each
        // sync transition, freezing scrolling during repeated server errors.
        // The explicit Refresh button performs the next read-only inspection.
    }

    /// Single authenticated, vineyard-filtered READ; foreign or missing server
    /// rows never become eligible uploads, cancellations or queue ACKs.
    private func refreshAndClassify() async {
        reload()
        guard !isCheckingLegacyScope, !busy, auth.isSignedIn,
              let owner = auth.userId, owner == store.currentUserIdProvider?(),
              SupabaseClientProvider.shared.client.auth.currentUser?.id == owner,
              let vineyard = store.selectedVineyardId else { return }
        let ids = tripSync.guidedQueueItems(vineyardId: vineyard)
            .filter { !$0.belongsToCurrentVineyard }.map(\.id)
        if ids.isEmpty {
            legacyServerScope = [:]
            legacyScopeReadFailed = false
            reload()
            return
        }
        isCheckingLegacyScope = true
        defer { isCheckingLegacyScope = false }
        let originalContext = contextKey
        struct ScopedTripRow: Decodable, Sendable {
            let id: UUID
            let vineyard_id: UUID
            let deleted_at: Date?
        }
        do {
            let rows: [ScopedTripRow] = try await SupabaseClientProvider.shared.client
                .from("trips")
                .select("id,vineyard_id,deleted_at")
                .eq("vineyard_id", value: vineyard.uuidString.lowercased())
                .in("id", values: ids.map { $0.uuidString.lowercased() })
                .execute().value
            guard !Task.isCancelled, originalContext == contextKey,
                  store.currentUserIdProvider?() == owner,
                  SupabaseClientProvider.shared.client.auth.currentUser?.id == owner else { return }
            let requested = Set(ids)
            legacyServerScope = Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard requested.contains(row.id) else { return nil }
                let result = GuidedLegacyServerScope.classify(
                    queuedID: row.id, selectedVineyard: vineyard,
                    serverID: row.id, serverVineyard: row.vineyard_id,
                    deletedAt: row.deleted_at)
                return result == .unattributed ? nil : (row.id, result)
            })
            legacyScopeReadFailed = false
        } catch {
            guard originalContext == contextKey else { return }
            legacyServerScope = [:]
            legacyScopeReadFailed = true
        }
        reload()
    }

    private func reload() {
        guard !busy else { return }
        guard auth.isSignedIn, auth.userId == store.currentUserIdProvider?(),
              let vineyard = store.selectedVineyardId else {
            items = []
            return
        }
        var list: [GuidedSyncRepairIssue] = []
        let actualStore = SprayTankActualStore.shared
        let pendingActuals = actualStore.records.filter {
            $0.vineyardId == vineyard && actualStore.pendingIds.contains($0.id)
        }
        let issueCenter = SyncIssueCenter.shared.issues

        let tripEntries = tripSync.guidedQueueItems(vineyardId: vineyard)
        let queuedTripIds = Set(tripEntries.filter { $0.belongsToCurrentVineyard }.map(\.id))
        for entry in tripEntries {
            let deletion = entry.pendingDeletion
            let kind: GuidedSyncRepairIssue.Kind = !entry.belongsToCurrentVineyard
                ? .protectedQueue : (deletion ? .tripDeletion : .tripUpload)
            let recordedActual = pendingActuals.contains { $0.tripId == entry.id }
            let explanation: String
            if !entry.belongsToCurrentVineyard {
                if legacyServerScope[entry.id] == .selectedDeleted {
                    explanation = "The authenticated server confirms this original Trip is soft-deleted in the selected vineyard. Review the archived original Spray/Actual evidence and obtain an exact cancellation receipt. No automatic cleanup."
                } else if legacyServerScope[entry.id] == .selectedNotDeleted {
                    explanation = "This ID exists in the selected vineyard, but the original device snapshot and operation receipt are unverified. Do not re-upload or clear."
                } else {
                    explanation = "Original queue scope remains unverified or belongs elsewhere. No automatic upload, retry or cleanup."
                }
            } else if deletion {
                explanation = "Deletion/cancellation needs independent server acknowledgement. This Trip must not be resurrected."
            } else {
                explanation = issueCenter[entry.id]?.friendlyMessage
                    ?? (entry.failed ? "Original Trip upload needs attention." : "Trip upload or finalisation is still queued.")
            }
            list.append(GuidedSyncRepairIssue(
                id: "trip:" + entry.id.uuidString,
                recordId: entry.id,
                relatedTripId: entry.belongsToCurrentVineyard ? entry.id : nil,
                kind: kind,
                title: kind == .protectedQueue
                    ? (legacyServerScope[entry.id] == .selectedDeleted
                        ? "Deleted original Trip — review" : "Protected original Trip")
                    : (deletion ? "Trip deletion" : "Trip upload / completion"),
                detail: explanation,
                verifiedCurrentScope: entry.belongsToCurrentVineyard,
                originalActualAvailable: recordedActual && entry.originalTripPresent))
        }

        // Include already accepted Actual Use linked to a failed Trip, as
        // well as records flagged by their own correction/receipt diagnostics.
        // A blank water volume can mean "not recorded", so it is offered for
        // review, not automatically called invalid.
        let actualsToReview = actualStore.records.filter {
            $0.vineyardId == vineyard &&
                (actualStore.pendingIds.contains($0.id) ||
                 queuedTripIds.contains($0.tripId) ||
                 actualStore.dependencyHolds[$0.id] != nil ||
                 issueCenter[$0.id] != nil)
        }
        for actual in actualsToReview {
            let parent = store.trips.contains { $0.id == actual.tripId && $0.vineyardId == vineyard }
            list.append(GuidedSyncRepairIssue(
                id: "actual:" + actual.id.uuidString,
                recordId: actual.id,
                relatedTripId: actual.tripId,
                kind: .tankActual,
                title: "Tank Actual Use — tank \(actual.tankNumber)",
                detail: actualStore.dependencyHolds[actual.id]
                    ?? issueCenter[actual.id]?.friendlyMessage
                    ?? (actualStore.pendingIds.contains(actual.id)
                        ? "Original Actual Use is pending its exact tank-session/server receipt."
                        : "Recorded Actual Use is available for evidence review or an audited amendment."),
                verifiedCurrentScope: parent,
                originalActualAvailable: true))
        }

        for spray in store.sprayRecords where spray.vineyardId == vineyard &&
            (spraySync.isPendingUpsert(spray.id) || spraySync.isPendingDelete(spray.id)) {
            let parentId = spray.canonicalTripId
            list.append(GuidedSyncRepairIssue(
                id: "spray:" + spray.id.uuidString, recordId: spray.id,
                relatedTripId: parentId,
                kind: .sprayRecord, title: "Spray Record",
                detail: issueCenter[spray.id]?.friendlyMessage
                    ?? "Original Spray Record upload/deletion is still awaiting a verified receipt.",
                verifiedCurrentScope: true, originalActualAvailable: false))
        }

        // The original first-tank handoff is an independent, durable record
        // and cannot be inferred from a planned spray. Surface it explicitly.
        for draft in actualStore.initialMixDrafts where
            draft.ownerId == auth.userId && draft.vineyardId == vineyard {
            let parent = store.trips.contains {
                $0.id == draft.tripId && $0.vineyardId == vineyard
            }
            list.append(GuidedSyncRepairIssue(
                id: "initialMix:" + draft.tripId.uuidString,
                recordId: draft.sprayRecordId,
                relatedTripId: draft.tripId,
                kind: .initialMixDraft, title: "Retained first tank confirmation",
                detail: "Original operator-entered tank contents are retained. Verify the real Trip tank session and confirmed Actual Use before clearing the handoff.",
                verifiedCurrentScope: parent, originalActualAvailable: false))
        }

        // Trip End and linked Spray End use a separate immutable receipt path.
        // A generic Spray Record "synced" badge cannot prove this completed.
        if let intents = try? TrackedSprayCompletionSync.shared.intents() {
            for intent in intents where intent.ownerId == auth.userId &&
                intent.vineyardId == vineyard {
                let parent = store.trips.contains {
                    $0.id == intent.tripId && $0.vineyardId == vineyard
                }
                list.append(GuidedSyncRepairIssue(
                    id: "sprayCompletion:" + intent.tripId.uuidString,
                    recordId: intent.sprayRecordId,
                    relatedTripId: intent.tripId,
                    kind: .trackedSprayCompletion,
                    title: "Linked Spray completion",
                    detail: "The original Trip End must be independently verified before its linked Spray completion can be acknowledged.",
                    verifiedCurrentScope: parent, originalActualAvailable: false))
            }
        }

        let already = Set(list.map(\.recordId))
        let visible = Set(store.trips.filter { $0.vineyardId == vineyard }.map(\.id))
            .union(store.sprayRecords.filter { $0.vineyardId == vineyard }.map(\.id))
            .union(actualStore.records.filter { $0.vineyardId == vineyard }.map(\.id))
        for issue in issueCenter.values where issue.vineyardId == vineyard &&
            !already.contains(issue.id) {
            list.append(GuidedSyncRepairIssue(
                id: "issue:" + issue.id.uuidString,
                recordId: issue.id, relatedTripId: nil,
                kind: .other, title: issue.entity,
                detail: issue.friendlyMessage,
                verifiedCurrentScope: visible.contains(issue.id), originalActualAvailable: false))
        }
        items = list.sorted {
            let first = GuidedSyncIssueOrder.priority($0.kind)
            let second = GuidedSyncIssueOrder.priority($1.kind)
            return first == second ? $0.id < $1.id : first < second
        }
    }
}

@MainActor
private struct GuidedSyncIssueDetailView: View {
    let issue: GuidedSyncRepairIssue

    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var access
    @Environment(TripSyncService.self) private var tripSync
    @Environment(SprayRecordSyncService.self) private var spraySync
    @Environment(SyncStatusCenter.self) private var syncStatus

    @State private var originatingContext: String?
    @State private var server: GuidedSyncRecordState = .notChecked
    @State private var serverExplanation = "Not checked"
    @State private var selected: GuidedSyncCorrection = .privateReview
    @State private var actualAccepted = false
    @State private var isWorking = false
    @State private var confirming = false
    @State private var outcome: String?
    @State private var independentReceipt: GuidedSyncRepairVerification.Result?
    @State private var auditHistory: [GuidedRepairAuditLedger.Entry] = []
    @State private var activeAuditOperation: UUID?
    @State private var awaitingFullSync = false
    @State private var syncWasObserved = false

    @State private var waterText = ""
    @State private var chemicalTexts: [UUID: String] = [:]
    @State private var evidenceNote = ""
    @State private var manualTime = Date()
    @State private var selectedOriginalSession: UUID?
    @State private var legacyApplicationChoice = "unselected"
    private var legacyApplied: Bool { legacyApplicationChoice == "applied" }
    @State private var legacyDeletionConfirmed = false
    @State private var recordedActualsNotAppliedConfirmed = false

    private var contextKey: String {
        (auth.userId?.uuidString ?? "none") + "|" + (store.selectedVineyardId?.uuidString ?? "none")
    }
    private var originalActual: SprayTankActual? {
        SprayTankActualStore.shared.records.first { $0.id == issue.recordId }
    }
    private var originalTrip: Trip? {
        let tripId = issue.relatedTripId ?? (
            [.protectedQueue, .tripDeletion, .tripUpload].contains(issue.kind)
                ? issue.recordId : nil)
        guard let tripId else { return nil }
        return store.trips.first { $0.id == tripId && $0.vineyardId == store.selectedVineyardId }
    }
    private var missingOriginalSessions: [SprayTankActual] {
        guard let trip = originalTrip, issue.kind == .tripUpload else { return [] }
        let recorded = TankDependencyVerification.ids(trip.tankSessions)
        return SprayTankActualStore.shared.records.filter {
            $0.tripId == trip.id && $0.vineyardId == trip.vineyardId &&
            !recorded.contains(TankDependencyVerification.normalized($0.tankSessionId)) &&
            UUID(uuidString: $0.tankSessionId) != nil
        }.sorted { $0.tankNumber < $1.tankNumber }
    }
    private var eligible: Bool {
        guard originatingContext == contextKey,
              (issue.verifiedCurrentScope ||
               (issue.kind == .protectedQueue && selected == .reviewLegacyDeleted &&
                server == .deleted)),
              !isWorking, !syncStatus.isSyncing,
              !tripSync.isSyncing, !spraySync.isSyncing,
              !TripActivityCancellationService.shared.isWorking,
              auth.isSignedIn, auth.userId == store.currentUserIdProvider?(),
              store.selectedVineyardId != nil else { return false }
        switch access.currentRole {
        case .owner, .manager: return true
        default: return false
        }
    }
    private var options: [GuidedSyncCorrection] {
        GuidedSyncCorrectionPolicy.available(
            for: issue, server: server, actualAccepted: actualAccepted,
            actualPending: SprayTankActualStore.shared.pendingIds.contains(issue.recordId))
    }
    private var reasonRequired: Bool {
        selected == .manualVerifiedTank || selected == .amendActualUse ||
            selected == .correctPendingActualUse || selected == .reviewLegacyDeleted
    }
    private var canVerifyProtectedCancellation: Bool {
        guard issue.kind == .protectedQueue, originatingContext == contextKey,
              let owner = auth.userId, let vineyard = store.selectedVineyardId else { return false }
        return auditHistory.contains { entry in
            entry.account == owner && entry.vineyard == vineyard &&
            entry.record == issue.recordId &&
            entry.stages.contains(where: { $0.code == "SERVER_CANCEL_RECEIPT_AND_ARCHIVE_VERIFIED" }) &&
            GuidedLegacyDeletedTripRepair.archiveConfirmed(
                operationId: entry.id, tripId: issue.recordId,
                vineyard: vineyard, owner: owner)
        }
    }

    var body: some View {
        Form {
            Section("1. Original record and issue") {
                LabeledContent("Record", value: issue.title)
                Text(issue.recordId.uuidString.lowercased()).font(.footnote.monospaced())
                if let trip = issue.relatedTripId {
                    LabeledContent("Original Trip", value: trip.uuidString.lowercased())
                        .font(.caption2.monospaced())
                }
                Text(issue.detail).font(.subheadline)
                if let trip = originalTrip {
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        Label("Open original Trip", systemImage: "arrow.up.right.square")
                    }
                    Text("Open the exact locally saved Trip to inspect tank sessions and Sync status. No queue entry is cleared by opening it.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if issue.relatedTripId != nil || issue.kind == .protectedQueue {
                    Label("This Trip is not present in the selected vineyard's local history. No substitute Trip will be created from its ID.",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.orange)
                }
                if !issue.verifiedCurrentScope {
                    Label("Original ownership is not established. No mutation is permitted.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let trip = originalTrip {
                    LabeledContent("Saved Trip", value: trip.endTime == nil ? "Not ended locally" : "Ended locally")
                    LabeledContent("Recorded tanks", value: String(trip.tankSessions.count))
                    LabeledContent("Pending Actual Use", value: String(SprayTankActualStore.shared.pendingCount(tripId: trip.id)))
                }
            }
            Section("2. Check original evidence (read-only)") {
                Button {
                    Task { await inspect() }
                } label: {
                    HStack {
                        Label("Inspect exact server record", systemImage: "checkmark.shield")
                        if isWorking { Spacer(); ProgressView() }
                    }
                }
                .disabled(isWorking || !auth.isSignedIn)
                LabeledContent("Server state", value: serverExplanation)
                if server == .deleted,
                   [.tankActual, .sprayRecord, .trackedSprayCompletion, .initialMixDraft].contains(issue.kind),
                   let parentId = issue.relatedTripId {
                    NavigationLink {
                        GuidedSyncIssueDetailView(issue: GuidedSyncRepairIssue(
                            id: "deletedParent:" + parentId.uuidString,
                            recordId: parentId, relatedTripId: nil,
                            kind: .protectedQueue, title: "Original deleted parent Trip",
                            detail: "Reconcile the server-deleted original Trip and its linked Spray, Actual Use and End intents with explicit operator attestation and a compliance archive.",
                            verifiedCurrentScope: false,
                            originalActualAvailable: false))
                    } label: {
                        Label("Review and reconcile deleted parent Trip",
                              systemImage: "arrow.turn.up.left")
                    }
                    Text("Ordinary child uploads cannot finish against a deleted Trip. Resolve its original cancellation before retrying this record.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if issue.kind == .tankActual, let actual = originalActual {
                    LabeledContent("Original tank", value: String(actual.tankNumber))
                    LabeledContent("Water recorded", value: actual.waterVolumeL.map { String($0) + " L" } ?? "Not recorded")
                    LabeledContent("Server actual receipt", value: actualAccepted ? "Verified" : "Not verified")
                }
                if !missingOriginalSessions.isEmpty {
                    ForEach(missingOriginalSessions) { actual in
                        Text("Missing recorded tank ID: \(actual.tankSessionId.lowercased())")
                            .font(.caption.monospaced()).foregroundStyle(.orange)
                    }
                }
                Text("A missing server row, deleted Trip or ambiguous original identity cannot be treated as a successful upload.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("3. Select a supported correction") {
                Picker("Correction", selection: $selected) {
                    ForEach(options) { action in
                        Text(action.label).tag(action)
                    }
                }
                .pickerStyle(.menu)
                Text(selected.explanation).font(.footnote).foregroundStyle(.secondary)

                if selected == .manualVerifiedTank {
                    if missingOriginalSessions.isEmpty {
                        Text("No missing original tank ID is available for a verified manual correction.")
                            .font(.footnote).foregroundStyle(.orange)
                    } else {
                        Picker("Original tank session", selection: $selectedOriginalSession) {
                            Text("Select the original ID").tag(UUID?.none)
                            ForEach(missingOriginalSessions) { actual in
                                if let id = UUID(uuidString: actual.tankSessionId) {
                                    Text("Tank \(actual.tankNumber) • \(String(id.uuidString.prefix(8)))")
                                        .tag(Optional(id))
                                }
                            }
                        }
                        DatePicker("Verified tank-start time", selection: $manualTime,
                                   displayedComponents: [.date, .hourAndMinute])
                        Text("Use a time confirmed from an actual log or operator record. The original tank ID is retained; no row, GPS or chemical amount is inferred.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if (selected == .amendActualUse || selected == .correctPendingActualUse),
                   let actual = originalActual {
                    LabeledContent("Recorded Actual Use ID", value: actual.id.uuidString.lowercased())
                        .font(.caption.monospaced())
                    TextField("Actual tank water (litres), blank = not recorded", text: $waterText)
                        .keyboardType(.decimalPad)
                    ForEach(actual.chemicals) { chemical in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(chemical.name).font(.subheadline.weight(.medium))
                            HStack {
                                TextField("Actual amount", text: Binding(
                                    get: { chemicalTexts[chemical.id] ?? "" },
                                    set: { chemicalTexts[chemical.id] = $0 }
                                ))
                                .keyboardType(.decimalPad)
                                Text(chemical.unit.rawValue).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Each amount is the actual amount used in the labelled unit, never the planned calculation. An explicit zero is valid. Saving produces server amendments with the same original Actual Use ID.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if selected == .reviewLegacyDeleted {
                    Picker("Was the spray actually applied?", selection: $legacyApplicationChoice) {
                        Text("Select").tag("unselected")
                        Text("Not applied").tag("not_applied")
                        Text("Applied").tag("applied")
                    }
                    .pickerStyle(.segmented)
                    Toggle("I confirm this original Trip was deliberately deleted", isOn: $legacyDeletionConfirmed)
                    if legacyApplicationChoice == "not_applied" {
                        Toggle("Recorded tank contents were NOT sprayed or applied", isOn: $recordedActualsNotAppliedConfirmed)
                        Text("Only confirm this when the original tank mix was recorded but genuinely never applied. All original quantities stay in the compliance archive.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("The original Trip will remain deleted. Its linked Spray, Actual Use and cost records will be retained in the compliance archive before their live rows are retired. Choose Applied if any physical spray occurred.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if reasonRequired {
                    TextField("Explain the original evidence and why this correction is needed",
                              text: $evidenceNote, axis: .vertical)
                        .lineLimit(2...5)
                    Text("Required: 12–500 characters. This is retained with the correction audit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("4. Apply, sync and verify") {
                Button(selected == .privateReview
                    ? "Copy private issue report" : "Apply selected correction") {
                    if selected == .privateReview { copyReview() }
                    else { confirming = true }
                }
                .disabled(selected != .privateReview &&
                    (!eligible || server == .notChecked ||
                     (selected == .reviewLegacyDeleted &&
                       (!legacyDeletionConfirmed || legacyApplicationChoice == "unselected"))))
                if awaitingFullSync {
                    Label(syncStatus.isSyncing
                        ? "Full dependency-chain sync is running"
                        : "Full sync requested; original receipts are pending",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                Button {
                    Task { await verify() }
                } label: {
                    Label("Verify all linked server receipts", systemImage: "checkmark.shield")
                }
                .disabled(isWorking ||
                    !(issue.verifiedCurrentScope || canVerifyProtectedCancellation) ||
                    syncStatus.isSyncing)
                if let outcome {
                    Text(outcome).font(.subheadline)
                }
                if let receipt = independentReceipt {
                    Label(receipt.verified ? "Verified on server" : "Still requires correction",
                          systemImage: receipt.verified ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(receipt.verified ? Color.green : Color.orange)
                    Text(receipt.explanation).font(.subheadline)
                    ForEach(receipt.evidence, id: \.self) { reason in
                        Text(reason).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text("A correction or retry is not success. Only independently read server receipts and durable queue acknowledgements permit a Verified result.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !auditHistory.isEmpty {
                Section("Repair history (this account and vineyard)") {
                    ForEach(auditHistory) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.correction).font(.footnote.weight(.semibold))
                            Text(entry.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                            ForEach(entry.stages, id: \.date) { stage in
                                HStack {
                                    Text(stage.code).font(.caption.monospaced())
                                    Spacer()
                                    Text(stage.date, style: .time).font(.caption2)
                                }
                                Text(stage.explanation).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Correct Sync Issue")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: issue.id + contextKey) {
            if originatingContext == nil { originatingContext = contextKey }
            server = .notChecked
            actualAccepted = false
            independentReceipt = nil
            confirming = false
            awaitingFullSync = false
            activeAuditOperation = nil
            auditHistory = []
            guard originatingContext == contextKey else {
                outcome = "Account or vineyard changed. Return to the issue list for a fresh scoped review."
                return
            }
            initialiseInputs()
            refreshHistory()
            restoreUnresolvedInputs()
            if issue.verifiedCurrentScope || issue.kind == .protectedQueue ||
               issue.relatedTripId != nil { await inspect() }
        }
        .onChange(of: server) { _, state in
            if activeAuditOperation == nil {
                selected = GuidedSyncRepairSuggestion.choose(
                    available: options, server: state, current: selected)
            }
        }
        .onChange(of: syncStatus.isSyncing) { _, now in
            if awaitingFullSync && now { syncWasObserved = true }
            if awaitingFullSync && !now && syncWasObserved {
                awaitingFullSync = false
                syncWasObserved = false
                Task { await verify() }
            }
        }
        .confirmationDialog("Apply correction to original saved record?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Apply selected correction") { Task { await apply() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selected.explanation + " Original IDs and other pending records must be preserved until server acknowledgement.")
        }
    }

    private func initialiseInputs() {
        if let actual = originalActual {
            waterText = actual.waterVolumeL.map { String($0) } ?? ""
            chemicalTexts = Dictionary(
                actual.chemicals.map { ($0.id, String($0.unit.fromBase($0.actualAmountBase))) },
                uniquingKeysWith: { first, _ in first })
        }
        if let original = missingOriginalSessions.first {
            selectedOriginalSession = UUID(uuidString: original.tankSessionId)
            manualTime = original.confirmedAt
        }
    }

    private func restoreUnresolvedInputs() {
        guard let entry = auditHistory.first(where: {
            !$0.stages.contains(where: { $0.code == "VERIFIED" })
        }) else { return }
        guard let input = entry.reviewInput,
              let correction = GuidedSyncCorrection(rawValue: entry.correction) else {
            activeAuditOperation = entry.id
            outcome = GuidedRepairAuditLedger.LegacyInputsUnavailable().localizedDescription
            return
        }
        selected = correction
        activeAuditOperation = entry.id
        evidenceNote = input.reason
        if let value = input.water { waterText = value }
        if let value = input.chemicals { chemicalTexts = value }
        if let value = input.tankTime { manualTime = value }
        if let value = input.sessionId { selectedOriginalSession = value }
        if let value = input.applied {
            legacyApplicationChoice = value ? "applied" : "not_applied"
        }
        if let value = input.recordedNotApplied { recordedActualsNotAppliedConfirmed = value }
        outcome = "Resumed the original unresolved correction inputs. Its operation ID is retained; inspect again before retrying."
    }

    private var hasFrozenAcceptedAmendment: Bool {
        guard let operation = activeAuditOperation,
              let saved = try? GuidedActualUseCorrection.savedAmendment(operation, persistence: .shared),
              saved.owner == auth.userId, saved.vineyard == store.selectedVineyardId,
              saved.original.id == issue.recordId else { return false }
        return true
    }

    private func refreshHistory() {
        guard let owner = auth.userId, let vineyard = store.selectedVineyardId else {
            auditHistory = []; return
        }
        auditHistory = (try? GuidedRepairAuditLedger.shared.history(
            account: owner, vineyard: vineyard, record: issue.recordId)) ?? []
    }

    private func inspect() async {
        guard originatingContext == contextKey, !isWorking && auth.isSignedIn,
              let owner = auth.userId, owner == store.currentUserIdProvider?(),
              let vineyard = store.selectedVineyardId else { return }
        isWorking = true
        defer { isWorking = false }
        independentReceipt = nil
        actualAccepted = false
        do {
            // For protected IDs the exact query can classify a tombstone but
            // never establishes ownership or authorises mutation by itself.
            if issue.kind == .other && issue.verifiedCurrentScope {
                server = .standalone
                serverExplanation = "Current vineyard issue; original server receipt needs entity-specific validation"
                return
            }
            if issue.kind == .sprayRecord && issue.relatedTripId == nil {
                let row = try await SprayCompletionRepository().fetchRecord(id: issue.recordId)
                guard !Task.isCancelled, originatingContext == contextKey,
                      auth.userId == owner, store.currentUserIdProvider?() == owner,
                      store.selectedVineyardId == vineyard,
                      row.vineyardId == vineyard, row.id == issue.recordId else {
                    server = .notVisible
                    serverExplanation = "Original Spray identity was not verified"
                    return
                }
                server = row.deletedAt == nil ? .standalone : .deleted
                serverExplanation = row.deletedAt == nil
                    ? "Original Spray Record exists on the server"
                    : "Spray Record is deleted"
                return
            }
            let tripId = issue.relatedTripId ?? (
                issue.kind == .protectedQueue ? issue.recordId : nil)
            guard let tripId else {
                server = .notVisible
                serverExplanation = "The original Trip scope cannot be proven"
                return
            }
            let row = try await SupabaseTripSyncRepository()
                .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard)
            guard !Task.isCancelled, originatingContext == contextKey,
                  store.selectedVineyardId == vineyard,
                  auth.userId == owner, store.currentUserIdProvider?() == owner else {
                server = .notChecked
                serverExplanation = "Account/vineyard changed; inspection discarded"
                return
            }
            guard let row else {
                server = .notVisible
                serverExplanation = "No original row visible in the authenticated vineyard-scoped read"
                return
            }
            if row.deletedAt != nil {
                server = .deleted
                serverExplanation = "Original Trip is soft-deleted on the server"
            } else if row.endTime != nil && row.isActive == false {
                server = .ended
                serverExplanation = "Original Trip is ended on the server"
            } else {
                server = .active
                serverExplanation = "Original Trip exists and has not been fully ended on the server"
            }
            if issue.kind == .tankActual, let actual = originalActual,
               !SprayTankActualStore.shared.pendingIds.contains(actual.id),
               row.deletedAt == nil {
                if let verified = try await SprayTankActualStore.shared.actualReader(actual),
                   GuidedRepairFieldValidation.immutableIdentityMatches(actual, verified),
                   (TankDependencyVerification.actualMatches(local: actual, server: verified) || hasFrozenAcceptedAmendment),
                   TankDependencyVerification.ids(row.tankSessions ?? []).contains(
                      TankDependencyVerification.normalized(actual.tankSessionId)) {
                    guard !Task.isCancelled, originatingContext == contextKey,
                          auth.userId == owner, store.currentUserIdProvider?() == owner,
                          store.selectedVineyardId == vineyard else { return }
                    actualAccepted = true
                }
            }
            if issue.kind == .protectedQueue {
                serverExplanation += ". Original queue scope is still unverified; no queue mutation allowed."
            }
        } catch {
            server = .notChecked
            serverExplanation = "Server inspection failed; correction disabled"
            outcome = "The exact original server state was not established. No record was changed."
        }
    }

    private func requestFullSync(auditId: UUID, owner: UUID, vineyard: UUID) {
        guard !Task.isCancelled, originatingContext == contextKey,
              auth.userId == owner, store.currentUserIdProvider?() == owner,
              store.selectedVineyardId == vineyard else { return }
        awaitingFullSync = true
        syncWasObserved = false
        try? GuidedRepairAuditLedger.shared.stage(
            id: auditId, account: owner, vineyard: vineyard,
            code: "FULL_SYNC_REQUESTED",
            explanation: "Original Trip → Spray → Actual Use → original finalisation → linked Spray completion requested.")
        syncStatus.requestManualSync()
        outcome = "Full ordered sync requested. The repair will remain open until exact server receipts are verified."
    }

    private func apply() async {
        guard eligible, options.contains(selected), selected != .privateReview,
              let vineyard = store.selectedVineyardId,
              let owner = auth.userId, owner == store.currentUserIdProvider?() else { return }
        isWorking = true
        defer { isWorking = false; refreshHistory() }
        independentReceipt = nil
        outcome = nil
        let chosen = selected
        if reasonRequired && GuidedRepairFieldValidation.note(evidenceNote) == nil {
            outcome = "Enter a genuine evidence source/reason (12–500 characters). Nothing was changed."
            return
        }
        // A stable input fingerprint allows a failed/lost correction response
        // to replay the original UUID rather than creating a competing amendment.
        let actualEdit = chosen == .amendActualUse || chosen == .correctPendingActualUse
        // Reject incomplete fields before freezing an unresolved operation.
        // Otherwise a typo could permanently lock out the corrected input.
        do {
            if actualEdit {
                guard let actual = originalActual, actual.vineyardId == vineyard else {
                    outcome = "Original Actual Use is unavailable in this vineyard."; return
                }
                let reviewed = try GuidedActualUseCorrection.reviewedChemicals(
                    original: actual.chemicals, amounts: chemicalTexts)
                let blankWater = waterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let water = GuidedRepairFieldValidation.nonnegativeNumber(waterText)
                guard blankWater || water != nil else {
                    outcome = "Enter valid non-negative water, or leave blank for Not recorded."; return
                }
                guard water != actual.waterVolumeL || reviewed != actual.chemicals ||
                      (chosen == .amendActualUse && hasFrozenAcceptedAmendment) else {
                    outcome = "The quantities are unchanged. No new correction was started."; return
                }
            }
            if chosen == .manualVerifiedTank {
                guard let trip = originalTrip, let session = selectedOriginalSession,
                      let actual = missingOriginalSessions.first(where: { UUID(uuidString: $0.tankSessionId) == session }),
                      let end = trip.endTime else {
                    outcome = "Select a retained original tank session on the locally ended Trip first."; return
                }
                if let error = GuidedRepairFieldValidation.manualTankTime(manualTime,
                    tripStart: trip.startTime, tripEnd: end, originalConfirmedAt: actual.confirmedAt,
                    reason: evidenceNote) { outcome = error; return }
            }
            if chosen == .reviewLegacyDeleted &&
                (!legacyDeletionConfirmed || legacyApplicationChoice == "unselected") {
                outcome = "Select Applied or Not applied and confirm the original deletion first. Nothing was changed."
                return
            }
        } catch { outcome = error.localizedDescription; return }
        let input = GuidedRepairReviewInput(
            reason: reasonRequired ? evidenceNote : "Verified original queue review",
            water: actualEdit ? waterText : nil,
            chemicals: actualEdit ? chemicalTexts : nil,
            tankTime: chosen == .manualVerifiedTank ? manualTime : nil,
            sessionId: chosen == .manualVerifiedTank ? selectedOriginalSession : nil,
            applied: chosen == .reviewLegacyDeleted ? legacyApplied : nil,
            recordedNotApplied: chosen == .reviewLegacyDeleted ? recordedActualsNotAppliedConfirmed : nil)
        let hash: String
        do { hash = try input.fingerprint(issueId: issue.id, correction: chosen.rawValue) }
        catch { outcome = "Correction inputs could not be frozen. No write was attempted."; return }
        let operation: UUID
        do {
            var preferredOriginalCancellationID: UUID?
            if chosen == .reviewLegacyDeleted,
               let original = try TripCancellationIntentStore.shared.find(
                   tripId: issue.recordId.uuidString.lowercased()), original.isOpen {
                guard original.ownerId == owner.uuidString.lowercased(),
                      original.vineyardId == vineyard.uuidString.lowercased(),
                      original.classification == (legacyApplied ? "applied" : "not_applied"),
                      let recordedID = UUID(uuidString: original.operationId) else {
                    outcome = "A retained original cancellation requires its exact account, classification and operation ID. No new operation was generated."
                    return
                }
                preferredOriginalCancellationID = recordedID
            }
            operation = try GuidedRepairAuditLedger.shared.begin(
                account: owner, vineyard: vineyard, record: issue.recordId,
                correction: chosen.rawValue, inputHash: hash,
                reason: reasonRequired ? evidenceNote : "Verified original queue review",
                preferredOperationId: preferredOriginalCancellationID, reviewInput: input)
            activeAuditOperation = operation
        } catch {
            outcome = "No write or retry was attempted: \(error.localizedDescription)"
            return
        }
        func stage(_ code: String, _ explanation: String) {
            try? GuidedRepairAuditLedger.shared.stage(
                id: operation, account: owner, vineyard: vineyard,
                code: code, explanation: explanation)
        }
        do {
            switch chosen {
            case .recoverRecordedTank:
                guard server == .active, let id = issue.relatedTripId else { return }
                outcome = try await tripSync.guidedRestoreConfirmedTankStart(
                    tripId: id, vineyardId: vineyard)
                stage("LOCAL_EVIDENCE_SAVED", "Original confirmed tank ID/time restored; dependent server receipts still pending.")
                requestFullSync(auditId: operation, owner: owner, vineyard: vineyard)
            case .manualVerifiedTank:
                guard server == .active, let id = issue.relatedTripId,
                      let session = selectedOriginalSession else {
                    outcome = "Select the retained original tank session first."; return
                }
                let manual = TripSyncService.GuidedTankStartOverride(
                    sessionId: session, startAt: manualTime, evidenceNote: evidenceNote)
                outcome = try await tripSync.guidedRestoreConfirmedTankStart(
                    tripId: id, vineyardId: vineyard, manual: manual)
                stage("OPERATOR_TANK_TIME_SAVED",
                      "Owner-reviewed original session and entered time saved with provenance; original quantities unchanged.")
                requestFullSync(auditId: operation, owner: owner, vineyard: vineyard)
            case .correctPendingActualUse:
                guard issue.kind == .tankActual,
                      SprayTankActualStore.shared.pendingIds.contains(issue.recordId),
                      server == .active || server == .ended else {
                    outcome = "Only the original, pending and independently unaccepted Actual Use can be corrected locally."
                    return
                }
                let corrected = try await GuidedActualUseCorrection.correctPendingOriginal(
                    actualId: issue.recordId, owner: owner, vineyard: vineyard,
                    reason: evidenceNote, waterText: waterText,
                    chemicalDisplayAmounts: chemicalTexts, operationId: operation,
                    store: store)
                stage("ORIGINAL_PENDING_ACTUAL_ARCHIVED_AND_CORRECTED",
                    "Original confirmed quantities were durably archived; corrected water and chemicals remain queued under original Actual ID \(corrected.id.uuidString.lowercased()).")
                outcome = "Original pending Actual Use was corrected and retained under its exact ID. Independent server acceptance is still required."
                requestFullSync(auditId: operation, owner: owner, vineyard: vineyard)
            case .amendActualUse:
                guard actualAccepted, issue.kind == .tankActual else {
                    outcome = "The server has not independently accepted this original Actual Use. Restore/sync its original dependency first."
                    return
                }
                let corrected = try await GuidedActualUseCorrection.amend(
                    actualId: issue.recordId, owner: owner, vineyard: vineyard,
                    reason: evidenceNote, waterText: waterText,
                    chemicalDisplayAmounts: chemicalTexts, operationId: operation, store: store)
                stage("SERVER_AMENDMENT_VERIFIED",
                    "Original Actual Use \(corrected.id.uuidString.lowercased()) returned identical amounts and authoritative amendment receipt.")
                outcome = "Actual Use correction saved with its original ID and verified on the server. Linked Trip/Spray still need closure verification."
                requestFullSync(auditId: operation, owner: owner, vineyard: vineyard)
            case .verifyCompleted:
                guard server == .ended, let id = issue.relatedTripId else { return }
                let accepted = await tripSync.reconcileServerEndedTrip(id)
                stage(accepted ? "TRIP_RECEIPT_ACCEPTED" : "TRIP_RECEIPT_HELD",
                      accepted ? "Original Trip readback accepted by existing sync service."
                               : "Original Trip or dependents remain unverified; no queue was cleared by repair UI.")
                requestFullSync(auditId: operation, owner: owner, vineyard: vineyard)
            case .verifyCancellation:
                guard (server == .deleted || server == .active),
                      let id = issue.relatedTripId else { return }
                let originalJournal = try store.tripDeletionJournal.load().intents[id]
                let originalIntent = try TripCancellationIntentStore.shared.find(
                    tripId: id.uuidString.lowercased())
                guard (originalJournal?.scope?.account == owner &&
                       originalJournal?.scope?.vineyard == vineyard) ||
                      (originalIntent?.ownerId == owner.uuidString.lowercased() &&
                       originalIntent?.vineyardId == vineyard.uuidString.lowercased()) else {
                    outcome = "No original account-scoped cancellation intent. Deletion is protected pending operator review."
                    stage("CANCELLATION_SCOPE_HELD", "Original cancellation journal absent or scope mismatched.")
                    return
                }
                // Original replay logic verifies the receipt/tombstone and
                // cleans only entries explicitly included in that receipt.
                requestFullSync(auditId: operation, owner: owner, vineyard: vineyard)
            case .reviewLegacyDeleted:
                guard server == .deleted, legacyDeletionConfirmed,
                      [.protectedQueue, .tripDeletion, .tripUpload].contains(issue.kind) else {
                    outcome = "Confirm the deliberate deletion and its original server tombstone first."
                    return
                }
                let accepted = try await GuidedLegacyDeletedTripRepair.reconcile(
                    tripId: issue.relatedTripId ?? issue.recordId,
                    vineyard: vineyard, owner: owner, applied: legacyApplied,
                    reason: evidenceNote, operationId: operation,
                    confirmedRecordedActualsNotApplied: recordedActualsNotAppliedConfirmed,
                    store: store, tripSync: tripSync, spraySync: spraySync)
                stage("REVIEWED_LEGACY_CANCELLATION_COMPLETE",
                      "Original server tombstone, compliance archive and linked cancellation receipts verified.")
                outcome = accepted
                await verifyAfterCorrection(owner: owner, vineyard: vineyard)
            case .retryExisting:
                guard server != .notChecked && server != .notVisible && server != .deleted else {
                    outcome = "The original server state has not been verified as writable."; return
                }
                requestFullSync(auditId: operation, owner: owner, vineyard: vineyard)
            case .privateReview:
                copyReview()
            }
        } catch {
            stage("HELD", "Correction refused or failed: \(error.localizedDescription)")
            outcome = "Original record remains protected: \(error.localizedDescription)"
        }
        if !awaitingFullSync {
            server = .notChecked
            serverExplanation = "Inspect the original record again to verify its state"
        }
    }

    private func verifyAfterCorrection(owner: UUID, vineyard: UUID) async {
        let result = await GuidedSyncRepairVerification.inspect(
            issue: issue, vineyard: vineyard, owner: owner,
            store: store, tripSync: tripSync, spraySync: spraySync)
        guard originatingContext == contextKey, auth.userId == owner,
              store.currentUserIdProvider?() == owner, store.selectedVineyardId == vineyard else { return }
        independentReceipt = result
        if let operation = activeAuditOperation {
            try? GuidedRepairAuditLedger.shared.stage(
                id: operation, account: owner, vineyard: vineyard,
                code: result.verified ? "VERIFIED" : "RETAINS_ISSUE_" + result.code,
                explanation: result.explanation)
        }
    }

    private func verify() async {
        guard originatingContext == contextKey, !isWorking, !syncStatus.isSyncing,
              let owner = auth.userId, owner == store.currentUserIdProvider?(),
              let vineyard = store.selectedVineyardId else { return }
        isWorking = true
        defer { isWorking = false; refreshHistory() }
        let result = await GuidedSyncRepairVerification.inspect(
            issue: issue, vineyard: vineyard, owner: owner,
            store: store, tripSync: tripSync, spraySync: spraySync)
        guard !Task.isCancelled, originatingContext == contextKey,
              auth.userId == owner, store.currentUserIdProvider?() == owner,
              store.selectedVineyardId == vineyard else { return }
        independentReceipt = result
        outcome = result.explanation
        if let id = activeAuditOperation {
            try? GuidedRepairAuditLedger.shared.stage(
                id: id, account: owner, vineyard: vineyard,
                code: result.verified ? "VERIFIED" : "RETAINS_ISSUE_" + result.code,
                explanation: result.explanation)
        }
        // Verify does not mutate queues or create any new operation receipts.
        resetInspectionAfterVerification()
    }

    private func resetInspectionAfterVerification() {
        // A new read on request is available above. Avoid calling inspect()
        // recursively while the verifier still holds its working state.
        actualAccepted = false
        server = .notChecked
        serverExplanation = "Run Inspect to review the latest server state"
    }

    private func copyReview() {
        var lines = [
            "VineTrack guided sync issue review",
            "Record: " + issue.recordId.uuidString.lowercased(),
            "Kind: " + issue.kind.rawValue,
            "Current-scope-evidence: " + String(issue.verifiedCurrentScope),
            "Server-state: " + server.rawValue,
            "Reason: " + issue.detail,
            "No queue mutation, receipt acknowledgement, deletion, or new data generated by review."
        ]
        if let receipt = independentReceipt {
            lines.append("Independent receipt: " + receipt.code)
            lines.append(contentsOf: receipt.evidence)
        }
        UIPasteboard.general.string = lines.joined(separator: "\n")
        outcome = "Scoped issue summary copied. The original record was not changed."
    }
}
