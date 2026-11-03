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
    case recoverRecordedTank, manualVerifiedTank, amendActualUse, verifyCompleted, verifyCancellation, reviewLegacyDeleted, retryExisting, privateReview
    var id: Self { self }
    var label: String {
        switch self {
        case .recoverRecordedTank: "Recover tank start from confirmed Actual Use"
        case .manualVerifiedTank: "Enter verified original tank start"
        case .amendActualUse: "Correct water and chemical Actual Use"
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
            "Correct recorded water or chemical quantities through the existing audited backend RPC. A confirmed original server Actual and tank-session receipt are mandatory; missing uploads must sync first."
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
                          actualAccepted: Bool = false) -> [GuidedSyncCorrection] {
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
    @State private var legacyApplied = false
    @State private var legacyDeletionConfirmed = false

    private var contextKey: String {
        (auth.userId?.uuidString ?? "none") + "|" + (store.selectedVineyardId?.uuidString ?? "none")
    }
    private var originalActual: SprayTankActual? {
        SprayTankActualStore.shared.records.first { $0.id == issue.recordId }
    }
    private var originalTrip: Trip? {
        guard let tripId = issue.relatedTripId else { return nil }
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
        guard (issue.verifiedCurrentScope ||
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
            for: issue, server: server, actualAccepted: actualAccepted)
    }
    private var reasonRequired: Bool {
        selected == .manualVerifiedTank || selected == .amendActualUse ||
            selected == .reviewLegacyDeleted
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

                if selected == .amendActualUse, let actual = originalActual {
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
                    Picker("Was the spray actually applied?", selection: $legacyApplied) {
                        Text("Not applied").tag(false)
                        Text("Applied").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Toggle("I confirm this original Trip was deliberately deleted", isOn: $legacyDeletionConfirmed)
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
                     (selected == .reviewLegacyDeleted && !legacyDeletionConfirmed)))
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
                .disabled(isWorking || !issue.verifiedCurrentScope || syncStatus.isSyncing)
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
            initialiseInputs()
            refreshHistory()
            if issue.verifiedCurrentScope { await inspect() }
        }
        .onChange(of: server) { _, _ in
            if !options.contains(selected) {
                selected = options.first ?? .privateReview
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

    private func refreshHistory() {
        guard let owner = auth.userId, let vineyard = store.selectedVineyardId else {
            auditHistory = []; return
        }
        auditHistory = (try? GuidedRepairAuditLedger.shared.history(
            account: owner, vineyard: vineyard, record: issue.recordId)) ?? []
    }

    private func inspect() async {
        guard !isWorking && auth.isSignedIn,
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
                guard row.vineyardId == vineyard, row.id == issue.recordId else {
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
            guard store.selectedVineyardId == vineyard,
                  auth.userId == store.currentUserIdProvider?() else {
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
                   TankDependencyVerification.actualMatches(local: actual, server: verified),
                   TankDependencyVerification.ids(row.tankSessions ?? []).contains(
                      TankDependencyVerification.normalized(actual.tankSessionId)) {
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
        let orderedAmounts = chemicalTexts.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { $0.key.uuidString + "=" + $0.value }.joined(separator: "|")
        let hash = GuidedRepairAuditLedger.fingerprint(
            "\(issue.id)|\(chosen.rawValue)|\(evidenceNote)|\(manualTime.timeIntervalSince1970)|" +
            "\(selectedOriginalSession?.uuidString ?? "")|\(waterText)|\(orderedAmounts)|reviewApplied=\(legacyApplied)")
        let operation: UUID
        do {
            operation = try GuidedRepairAuditLedger.shared.begin(
                account: owner, vineyard: vineyard, record: issue.recordId,
                correction: chosen.rawValue, inputHash: hash,
                reason: reasonRequired ? evidenceNote : "Verified original queue review")
            activeAuditOperation = operation
        } catch {
            outcome = "The durable correction audit could not be saved. No write or retry was attempted."
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
            case .amendActualUse:
                guard actualAccepted, issue.kind == .tankActual else {
                    outcome = "The server has not independently accepted this original Actual Use. Restore/sync its original dependency first."
                    return
                }
                let corrected = try await GuidedActualUseCorrection.amend(
                    actualId: issue.recordId, owner: owner, vineyard: vineyard,
                    reason: evidenceNote, waterText: waterText,
                    chemicalDisplayAmounts: chemicalTexts, operationId: operation)
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
        independentReceipt = result
        if let operation = activeAuditOperation {
            try? GuidedRepairAuditLedger.shared.stage(
                id: operation, account: owner, vineyard: vineyard,
                code: result.verified ? "VERIFIED" : "RETAINS_ISSUE_" + result.code,
                explanation: result.explanation)
        }
    }

    private func verify() async {
        guard !isWorking, !syncStatus.isSyncing,
              let owner = auth.userId, owner == store.currentUserIdProvider?(),
              let vineyard = store.selectedVineyardId else { return }
        isWorking = true
        defer { isWorking = false; refreshHistory() }
        let result = await GuidedSyncRepairVerification.inspect(
            issue: issue, vineyard: vineyard, owner: owner,
            store: store, tripSync: tripSync, spraySync: spraySync)
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
