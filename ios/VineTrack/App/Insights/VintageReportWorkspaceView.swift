import SwiftUI
import UIKit

/// Preview-gated native workspace. Generation is always an explicit user action.
struct VintageReportScreen: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(BackendAccessControl.self) private var access
    @Environment(SystemAdminService.self) private var admin
    @Environment(VineyardInsightsService.self) private var insights
    @Environment(TripSyncService.self) private var trips
    @Environment(SprayRecordSyncService.self) private var sprays
    @Environment(WorkTaskSyncService.self) private var tasks
    @Environment(GrowthStageRecordSyncService.self) private var growth
    @Environment(PruningSyncService.self) private var pruning
    @Environment(FertiliserSyncService.self) private var fertiliser
    @Environment(PickingRecordSyncService.self) private var picking
    @Environment(DamageRecordSyncService.self) private var damage
    @Environment(YieldEstimationSessionSyncService.self) private var yields
    @State private var vintage: Int?
    @State private var model = VintageReportModel()
    @State private var selected: UUID?
    @State private var through: String = ""
    @State private var editing: Bool = false
    @State private var narrative: String = ""
    @State private var editingRevisionID: UUID?
    @State private var proposedAction: String?
    @State private var showGenerateConfirmation: Bool = false
    @State private var syncBusy: Bool = false
    @State private var shareURL: URL?
    @State private var showShare: Bool = false
    @State private var exportError: String?
    private var formatter: RegionFormatter {
        var settings = store.settings.regionSettings
        settings.timezone = model.cache.coverage?.timezone ?? settings.timezone
        return RegionFormatter(settings: settings)
    }
    private var resolvedVintage: Int { vintage ?? VintageResolver.vintageYear(for: Date(), seasonStartMonth: store.settings.seasonStartMonth, seasonStartDay: store.settings.seasonStartDay, calendar: store.settings.resolvedCalendar) }
    private var allowed: Bool { auth.isSignedIn && admin.isSystemAdmin && access.currentRole != nil && store.selectedVineyardId != nil }
    private var selectedRevision: VintageReportRevision? {
        if let selected { return model.cache.revisions.first { $0.id == selected } }
        return model.current
    }
    private var scope: String { "\(SupabaseClientProvider.shared.client.auth.currentUser?.id.uuidString ?? "signed-out")/\(store.selectedVineyardId?.uuidString ?? "none")/\(resolvedVintage)" }
    private var pendingEvidence: Bool {
        guard let id = store.selectedVineyardId else { return true }
        return SupabaseIrrigationRepository.shared.pendingSessions().contains { $0.vineyardId == id }
            || ((try? SupabaseIrrigationRepository.shared.fertigationOutbox.entries()) ?? []).contains { $0.irrigation.vineyardId == id && $0.phase != .acknowledged }
            || insights.hasPendingReportEvidence(vineyardID: id) || trips.pendingUpsertCount + trips.pendingDeleteCount + sprays.pendingUpsertCount + sprays.pendingDeleteCount + tasks.pendingUpsertCount + tasks.pendingDeleteCount + growth.pendingUpsertCount + growth.pendingDeleteCount + pruning.pendingUpsertCount + pruning.pendingDeleteCount + fertiliser.pendingUpsertCount + fertiliser.pendingDeleteCount + picking.pendingUpsertCount + picking.pendingDeleteCount + damage.pendingUpsertCount + damage.pendingDeleteCount + yields.pendingUpsertCount + yields.pendingDeleteCount > 0
    }
    var body: some View {
        Group {
            if allowed { workspace }
            else { ContentUnavailableView("This tool is not available.", systemImage: "lock") }
        }
        .navigationTitle("Vintage Report").navigationBarTitleDisplayMode(.inline)
        .task(id: scope) {
            selected = nil; editing = false; editingRevisionID = nil; narrative = ""; proposedAction = nil; showGenerateConfirmation = false; showShare = false
            guard allowed, let id = store.selectedVineyardId else { return }
            let capturedVintage = resolvedVintage
            await model.configure(vineyard: id, vintage: capturedVintage, isCurrentScope: { allowed && store.selectedVineyardId == id && resolvedVintage == capturedVintage })
            through = model.cache.coverage?.reportThrough ?? ""
        }
        .confirmationDialog("Generate from synced records?", isPresented: $showGenerateConfirmation, titleVisibility: .visible) {
            Button("Retry sync") { Task { await syncEvidence() } }
            Button("Generate from synced records") {
                guard let action = proposedAction, allowed else { return }
                Task { await model.submit(action: action, through: through) }
            }
            Button("Cancel", role: .cancel) { proposedAction = nil }
        } message: {
            Text(pendingEvidence ? "This device still has pending evidence, so it will NOT be included. Other devices may also have unsynced work that cannot be detected here. The previous report will stay visible." : "Only server-synced evidence will be included. Other devices' pending work cannot be detected here. A regeneration is saved for review before you confirm it as current.")
        }
        .sheet(isPresented: $showShare) { if allowed, let shareURL { VintageReportShareSheet(url: shareURL, onError: { exportError = $0 }) } }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "Please retry.") }
    }
    private var workspace: some View {
        List {
            Section { PreviewBadge(); Text(model.cache.coverage?.vineyardName ?? store.vineyards.first { $0.id == store.selectedVineyardId }?.name ?? "Vineyard").font(.headline) }
            Section("Reporting period") {
                Stepper("Vintage \(VintageYearText.format(resolvedVintage))", value: Binding(get: { resolvedVintage }, set: { vintage = $0 }), in: 1900...2200).disabled(model.isBusy || syncBusy)
                if let coverage = model.cache.coverage {
                    Text("Season \(formatter.formatDate(coverage.seasonStart)) – \(formatter.formatDate(coverage.seasonEnd))")
                    if coverage.notStarted == true { Text("Not yet covered — this vintage has not started.") }
                }
                TextField("Report through (YYYY-MM-DD)", text: $through).keyboardType(.numbersAndPunctuation)
                Button("Validate reporting date") { Task { await model.updateThrough(through) } }.disabled(model.isBusy)
            }
            Section("Report status") {
                LabeledContent("Status", value: model.cache.request?.status ?? (model.current == nil ? "Not generated" : "Saved"))
                if let current = model.current { Text("Current revision \(current.revision) • saved \(VintageReportExport.timestamp(current.createdAt, formatter: formatter))") }
                if let generated = model.history.first(where: { $0.action != "edit" }) {
                    Text("Last generated revision saved \(VintageReportExport.timestamp(generated.createdAt, formatter: formatter)) (including candidates)").font(.caption)
                }
                if model.isBusy || syncBusy { ProgressView("Working…") }
                if let message = model.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                Button("Refresh reports and coverage") { Task { await model.refresh() } }.disabled(model.isBusy)
                if model.cache.pending != nil {
                    Button("Recover same request / refresh status") { Task { await model.recover() } }.disabled(model.isBusy)
                    Button("Safely cancel unsent / queued request") { Task { await model.abandonPending() } }.disabled(model.isBusy)
                    if ["succeeded", "failed", "unchanged"].contains(model.cache.request?.status ?? "") {
                        Button("Acknowledge result") { model.acknowledgeResult() }
                        Text("A failed request with an unknown provider outcome is never automatically replayed. Starting another request can incur another charge.").font(.caption)
                    }
                }
            }
            Section("Source coverage") {
                ForEach((model.cache.coverage?.coverage ?? [:]).keys.sorted(), id: \.self) { key in LabeledContent(key.replacingOccurrences(of: "_", with: " "), value: String(model.cache.coverage?.coverage?[key] ?? 0)) }
                ForEach(model.cache.coverage?.gaps ?? [], id: \.self) { Text($0).font(.caption) }
                Text("Generation requires connectivity. Downloaded reports and exports remain readable offline.").font(.caption)
                Text("Pending local evidence is excluded; other devices' pending work is unknown.").font(.caption)
            }
            Section {
                Button(model.current == nil ? "Generate Report" : "Re-generate Report") { begin(model.current == nil ? "generate" : "regenerate") }
                Button("Add to Existing Report") { begin("append") }.disabled(model.current == nil)
                Button("Retry evidence sync") { Task { await syncEvidence() } }
            }.disabled(model.isBusy || syncBusy || model.cache.pending != nil || through.isEmpty || model.cache.coverage?.notStarted == true)
            if let revision = selectedRevision {
                Section("Revision \(revision.revision) • \(revision.action)") {
                    if revision.evidence.seasonToDate == true { Text("SEASON TO DATE").font(.caption.bold()) }
                    if editing {
                        if editingRevisionID != model.cache.currentID {
                            Text("A newer revision is current. This draft still belongs to the revision you opened; its wording has not been replaced.").font(.callout)
                        }
                        TextEditor(text: $narrative).frame(minHeight: 300)
                        Button("Save narrative as new revision") { Task { let saved = await model.submit(action: "edit", through: revision.reportThrough, narrative: narrative, editingRevisionID: editingRevisionID); if saved { editing = false; selected = model.cache.currentID } } }.disabled(model.isBusy || model.cache.pending != nil)
                        Button("Cancel editing", role: .cancel) { editing = false }
                    } else {
                        ForEach(Array(revision.content.narrative.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            Text(line).font(VintageReportExport.headings.contains(line) ? .headline : .body).textSelection(.enabled)
                        }
                        Button("Review / edit current narrative") { selected = revision.id; editingRevisionID = revision.id; narrative = revision.content.narrative; editing = true }.disabled(revision.id != model.cache.currentID || model.cache.pending != nil)
                    }
                    if revision.id != model.cache.currentID, revision.action == "regenerate" {
                        Button("Confirm this regenerated revision as current") { Task { await model.activate(revision) } }.disabled(model.isBusy)
                    }
                    Button("Export PDF") { export(revision, word: false) }
                    Button("Export Word (.docx)") { export(revision, word: true) }
                }
                Section("Key-event timeline") { ForEach(Array(revision.content.timeline.enumerated()), id: \.offset) { _, line in Text(line) } }
                Section("Sources and coverage appendix") { ForEach(Array(revision.content.appendix.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) } }
            }
            if let selected, selectedRevision == nil {
                Section { Text("Selected revision content is not downloaded."); Button("Download selected revision") { Task { await model.selectRevision(selected) } }.disabled(model.isBusy) }
            }
            Section("Revision history") {
                ForEach(model.history) { revision in
                    Button("Revision \(revision.revision) • \(revision.action) • \(revision.createdAt)\(revision.id == model.cache.currentID ? " • Current" : "")") {
                        selected = revision.id; editing = false
                        Task { await model.selectRevision(revision.id) }
                    }.disabled(model.isBusy)
                }
                if model.hasMoreHistory { Button("Load older revision metadata") { Task { await model.loadMoreHistory() } }.disabled(model.isBusy) }
            }
        }
    }
    private func begin(_ action: String) {
        proposedAction = action
        Task { let original = scope; await syncEvidence(); guard original == scope, allowed else { return }; showGenerateConfirmation = true }
    }
    private func syncEvidence() async {
        guard allowed, let id = store.selectedVineyardId, !syncBusy else { return }
        let original = scope; syncBusy = true
        defer { syncBusy = false }
        await insights.sync(vineyardID: id)
        guard original == scope, allowed else { return }
        await trips.sync(vineyardId: id); await sprays.sync(vineyardId: id); await tasks.sync(vineyardId: id)
        guard original == scope, allowed else { return }
        await growth.sync(vineyardId: id); await pruning.sync(vineyardId: id); await fertiliser.sync(vineyardId: id)
        guard original == scope, allowed else { return }
        await picking.sync(vineyardId: id); await damage.sync(vineyardId: id); await yields.sync(vineyardId: id)
        guard original == scope, allowed else { return }
        await SupabaseIrrigationRepository.shared.flushPending(vineyardId: id)
    }
    private func export(_ revision: VintageReportRevision, word: Bool) {
        guard allowed, let account = SupabaseClientProvider.shared.client.auth.currentUser?.id else { return }
        do {
            let vineyard = store.vineyards.first { $0.id == store.selectedVineyardId }
            shareURL = try VintageReportExport.export(revision, vineyard: revision.evidence.vineyardName ?? vineyard?.name ?? "Vineyard", vintage: resolvedVintage, logo: vineyard?.logoData, word: word, account: account, formatter: formatter)
            showShare = true
        } catch { exportError = "Could not create the export. Check device storage and retry." }
    }
}
private struct VintageReportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onError: @MainActor (String) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if error != nil { Task { @MainActor in onError("Could not share the report. The exported file remains saved; retry sharing.") } }
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
