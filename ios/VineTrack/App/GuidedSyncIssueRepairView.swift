import SwiftUI
import UIKit

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

nonisolated enum GuidedSyncCorrection: String, Identifiable, CaseIterable, Sendable {
    case recoverRecordedTank, manualVerifiedTank, amendActualUse, verifyCompleted, verifyCancellation, retryExisting, privateReview
    var id: Self { self }
    var label: String {
        switch self {
        case .recoverRecordedTank: "Recover tank start from confirmed Actual Use"
        case .manualVerifiedTank: "Enter verified original tank start"
        case .amendActualUse: "Correct water and chemical Actual Use"
        case .verifyCompleted: "Verify original Trip completion"
        case .verifyCancellation: "Verify original deletion"
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
            "Correct recorded water or chemical quantities through the existing audited backend RPC. A confirmed original server Actual and tank-session receipt are mandatory; missing uploads must sync first."
        case .verifyCompleted:
            "Reads back the exact original ended Trip and checks its linked evidence before acknowledging the existing upload."
        case .verifyCancellation:
            "Only replays an already-recorded, original-account cancellation journal and independently verifies its server tombstone. Does not delete a different Trip."
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
                          actualAccepted: Bool = false) -> [GuidedSyncCorrection] {
        guard issue.verifiedCurrentScope else { return [.privateReview] }
        switch server {
        case .notChecked, .notVisible:
            return [.privateReview]
        case .deleted:
            return issue.kind == .tripDeletion ? [.verifyCancellation, .privateReview] : [.privateReview]
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
                return actualAccepted
                    ? [.amendActualUse, .retryExisting, .privateReview]
                    : [.retryExisting, .privateReview]
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

@MainActor
struct GuidedSyncIssueRepairView: View {
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripSyncService.self) private var tripSync
    @Environment(SprayRecordSyncService.self) private var spraySync
    @Environment(SyncStatusCenter.self) private var syncStatus

    @State private var items: [GuidedSyncRepairIssue] = []

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
            } header: {
                Text("Guided sync issue repair")
            }

            Section {
                Button {
                    reload()
                } label: {
                    Label("Refresh issue list", systemImage: "arrow.clockwise")
                }
                .disabled(busy || !auth.isSignedIn)

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
            reload()
        }
        .onChange(of: syncStatus.isSyncing) { _, active in
            if !active { reload() }
        }
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
                explanation = "Unattributed original queue ID. Original account/vineyard evidence is required; no automatic cleanup."
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
                title: kind == .protectedQueue ? "Protected original Trip" :
                    (deletion ? "Trip deletion" : "Trip upload / completion"),
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
                relatedTripId: parent ? actual.tripId : nil,
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
                relatedTripId: store.trips.contains(where: { $0.id == parentId && $0.vineyardId == vineyard })
                    ? parentId : nil,
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
                relatedTripId: parent ? draft.tripId : nil,
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
                    relatedTripId: parent ? intent.tripId : nil,
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
            if $0.kind == .protectedQueue && $1.kind != .protectedQueue { return false }
            if $1.kind == .protectedQueue && $0.kind != .protectedQueue { return true }
            return $0.id < $1.id
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

    @State private var server: GuidedSyncRecordState = .notChecked
    @State private var serverExplanation = "Not checked"
    @State private var selected: GuidedSyncCorrection = .privateReview
    @State private var isWorking = false
    @State private var confirming = false
    @State private var outcome: String?

    private var eligible: Bool {
        guard issue.verifiedCurrentScope, !isWorking, !syncStatus.isSyncing,
              !tripSync.isSyncing, !spraySync.isSyncing,
              auth.isSignedIn, auth.userId == store.currentUserIdProvider?(),
              store.selectedVineyardId != nil else { return false }
        switch access.currentRole {
        case .owner, .manager: return true
        default: return false
        }
    }
    private var options: [GuidedSyncCorrection] {
        GuidedSyncCorrectionPolicy.available(for: issue, server: server)
    }

    var body: some View {
        Form {
            Section("Record") {
                LabeledContent("Type", value: issue.title)
                Text(issue.recordId.uuidString.lowercased()).font(.footnote.monospaced())
                Text(issue.detail).font(.subheadline)
                if !issue.verifiedCurrentScope {
                    Text("Ownership is not verified for the selected vineyard. This record is read-only; original account evidence must be reviewed.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            Section("1. Inspect original server record") {
                Button {
                    Task { await inspect() }
                } label: {
                    HStack {
                        Label("Check server status (read-only)", systemImage: "checkmark.shield")
                        if isWorking { Spacer(); ProgressView() }
                    }
                }
                .disabled(isWorking || !auth.isSignedIn || !issue.verifiedCurrentScope)
                LabeledContent("Server", value: serverExplanation)
                Text("A missing or inaccessible server row is not proof that it can be recreated.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("2. Select the correction") {
                Picker("Correction", selection: $selected) {
                    ForEach(options) { action in
                        Text(action.label).tag(action)
                    }
                }
                .pickerStyle(.menu)
                Text(selected.explanation)
                    .font(.footnote).foregroundStyle(.secondary)
                if selected == .recoverRecordedTank {
                    Text("The original, confirmed tank start is the only permitted source. No manual estimate or replacement chemical quantity is allowed.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section("3. Apply and verify") {
                Button(selected == .privateReview ? "Copy private review summary" : "Apply selected correction") {
                    if selected == .privateReview { copyReview() }
                    else { confirming = true }
                }
                .disabled(selected != .privateReview && (!eligible || server == .notChecked))
                if let outcome {
                    Text(outcome).font(.subheadline)
                }
                Text("An attempted retry is not success. The issue remains open until the original record and its dependents have verified server receipts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Correct Sync Issue")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: server) { _, _ in
            selected = options.first ?? .privateReview
        }
        .confirmationDialog("Apply this correction?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Apply original-evidence correction") {
                Task { await apply() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(selected.explanation)
        }
    }

    private func inspect() async {
        guard issue.verifiedCurrentScope, auth.isSignedIn,
              auth.userId == store.currentUserIdProvider?(),
              let vineyard = store.selectedVineyardId else { return }
        isWorking = true
        defer { isWorking = false }
        outcome = nil
        guard let tripId = issue.relatedTripId else {
            server = .notVisible
            serverExplanation = "No verified original Trip association; private review required"
            return
        }
        do {
            let row = try await SupabaseTripSyncRepository()
                .fetchTripForOccurrenceStart(tripId: tripId, vineyardId: vineyard)
            guard store.selectedVineyardId == vineyard,
                  auth.userId == store.currentUserIdProvider?() else {
                server = .notChecked
                serverExplanation = "Account or vineyard changed; inspection discarded"
                return
            }
            guard let row else {
                server = .notVisible
                serverExplanation = "Not visible in authenticated scoped read"
                return
            }
            if row.deletedAt != nil {
                server = .deleted
                serverExplanation = "Trip is deleted on the server. No upload/recreation allowed"
            } else if row.endTime != nil && row.isActive == false {
                server = .ended
                serverExplanation = "Original Trip is ended on the server"
            } else {
                server = .active
                serverExplanation = "Original Trip exists and has not been completed on the server"
            }
        } catch {
            server = .notChecked
            serverExplanation = "Server check failed; no correction allowed"
            outcome = "Unable to establish an authoritative server state. Original evidence remains unchanged."
        }
    }

    private func apply() async {
        guard eligible, options.contains(selected),
              let vineyard = store.selectedVineyardId,
              auth.userId == store.currentUserIdProvider?() else { return }
        isWorking = true
        defer { isWorking = false }
        outcome = nil
        do {
            switch selected {
            case .recoverRecordedTank:
                guard server == .active, let id = issue.relatedTripId else { return }
                outcome = try await tripSync.guidedRestoreConfirmedTankStart(
                    tripId: id, vineyardId: vineyard)
            case .verifyCompleted:
                guard server == .ended, let id = issue.relatedTripId else { return }
                let settled = await tripSync.reconcileServerEndedTrip(id)
                outcome = settled
                    ? "Original Trip completion acknowledged. Check linked Actual Use and Spray separately."
                    : "Original completion is not fully verified. Queue and evidence remain retained."
            case .verifyCancellation:
                guard (server == .deleted || server == .active), let id = issue.relatedTripId,
                      (try? store.tripDeletionJournal.load().intents[id])?.scope?.vineyard == vineyard,
                      (try? store.tripDeletionJournal.load().intents[id])?.scope?.account == auth.userId else {
                    outcome = "A verified original cancellation journal is required. No queue was cleared."
                    return
                }
                await tripSync.sync(vineyardId: vineyard)
                outcome = tripSync.isPendingDelete(id)
                    ? "The original cancellation is still pending verification."
                    : "Deletion queue processed. Retained originals remain archived; other issues require separate verification."
            case .retryExisting:
                guard server != .deleted && server != .notVisible && server != .notChecked else { return }
                switch issue.kind {
                case .tripUpload:
                    await tripSync.sync(vineyardId: vineyard)
                    outcome = tripSync.isPendingUpsert(issue.recordId)
                        ? "Original Trip is still pending. Review its new diagnostic code; nothing was discarded."
                        : "Trip queue changed. Verify linked Actual Use and Spray receipts before considering it fully synced."
                case .tankActual:
                    await SprayTankActualStore.shared.syncPending(
                        tripSync: tripSync, spraySync: spraySync, vineyardId: vineyard)
                    outcome = SprayTankActualStore.shared.pendingIds.contains(issue.recordId)
                        ? "Original Actual Use remains pending; its tank dependency was not acknowledged."
                        : "Actual Use queue changed. Verify the server and linked Trip completion separately."
                case .sprayRecord:
                    await spraySync.sync(vineyardId: vineyard)
                    outcome = spraySync.isPendingUpsert(issue.recordId) || spraySync.isPendingDelete(issue.recordId)
                        ? "Original Spray Record is still pending."
                        : "Spray upload queue changed. Linked Spray completion may require another verified stage."
                default:
                    outcome = "This type needs owner review; no generic retry is allowed."
                }
            case .privateReview:
                copyReview()
            }
        } catch {
            outcome = "The correction was not admitted or could not be saved. Original records remain protected. \(error.localizedDescription)"
        }
        // Mutations are not receipts. Require a fresh, explicit inspection.
        server = .notChecked
        serverExplanation = "Check server again to verify the result"
    }

    private func copyReview() {
        let summary = [
            "VineTrack guided sync issue review",
            "Record: " + issue.recordId.uuidString.lowercased(),
            "Kind: " + issue.kind.rawValue,
            "Current-scope-evidence: " + String(issue.verifiedCurrentScope),
            "Server-state: " + server.rawValue,
            "Reason: " + issue.detail,
            "No queue mutation, receipt acknowledgement, deletion, or new data generated by review."
        ].joined(separator: "\n")
        UIPasteboard.general.string = summary
        outcome = "Scoped issue summary copied. The original record was not changed."
    }
}
