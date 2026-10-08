import SwiftUI

struct FertigationSessionEditView: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(NewBackendAuthService.self) private var auth
    @Environment(SystemAdminService.self) private var admin
    let session: IrrigationSession
    let application: FertigationDomain.Application?
    var onSaved: () -> Void = {}
    @State private var draft: FertigationSessionDraft
    @State private var steps: [FertigationDomain.ProgramStep] = []
    @State private var owner: UUID?
    @State private var message: String?
    @State private var isSaving: Bool = false
    @State private var pending: FertigationLinkedOutbox.Entry?
    private let repository = SupabaseIrrigationRepository.shared
    init(session: IrrigationSession, application: FertigationDomain.Application?, onSaved: @escaping () -> Void = {}) {
        self.session = session; self.application = application; self.onSaved = onSaved
        _draft = State(initialValue: FertigationSessionDraft(application: application))
    }
    private var canWrite: Bool {
        session.deletedAt == nil && owner != nil && owner == auth.userId && FertigationSessionDraft.canAttach(vineyardId: session.vineyardId, selectedVineyardId: store.selectedVineyardId, status: session.status, isSystemAdmin: admin.isSystemAdmin) && (application == nil || application?.isEditable == true)
    }
    private var totals: FertigationDomain.Totals { .init(allocations: session.blocks.map { .init(areaM2: $0.servicedAreaM2, vines: $0.servicedVineCount.map(Double.init)) }) }
    var body: some View {
        Form {
            if canWrite {
                Section("Program Step") {
                    Text(draft.step?.name ?? "Select a Program Step")
                    ForEach(steps) { step in
                        Button(step.name ?? "Program Step") {
                            do { try draft.select(step, totals: totals) } catch { message = error.localizedDescription }
                        }.disabled(pending != nil || isSaving)
                    }
                    Text("Existing frozen product fields are retained. Selecting another step changes its provenance on the server.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Actual used") {
                    ForEach(Array(draft.products.enumerated()), id: \.offset) { index, product in
                        Text(FertigationDomain.string(product, "product_name") ?? "Product")
                        Text("Planned: \(FertigationHistory.quantity(product, key: "planned_quantity"))").font(.caption)
                        TextField("Actual used (\(FertigationDomain.string(product, "quantity_unit") ?? "saved unit"))", text: $draft.actuals[index]).keyboardType(.decimalPad)
                            .disabled(pending != nil || isSaving)
                    }
                    TextField("Fertigation notes", text: $draft.notes, axis: .vertical).disabled(pending != nil || isSaving)
                }
                if let pending {
                    Section {
                        Text(pending.message)
                        Button("Retry Fertigation only") { Task { await retry(pending) } }.disabled(isSaving)
                    }
                } else {
                    Button(isSaving ? "Saving…" : "Save Fertigation") { Task { await save() } }.disabled(draft.step?.id == nil || isSaving)
                }
            } else if let application, admin.isSystemAdmin {
                Section("Fertigation") { FertigationApplicationView(application: application, formatter: store.settings.regionFormatter) }
            }
            if let message { Text(message).font(.footnote) }
        }
        .navigationTitle(application == nil ? "Add Fertigation" : "View / Edit Fertigation")
        .task(id: auth.userId) {
            if owner == nil { owner = auth.userId }
            guard canWrite, let owner else { return }
            pending = try? repository.fertigationOutbox.entries().first { $0.ownerId == owner && $0.irrigation.id == session.id && $0.phase != .acknowledged }
            do { steps = try await SupabaseFertigationRepository().programSteps(vineyardId: session.vineyardId) }
            catch { message = "Program Steps unavailable. Existing frozen quantities can still be saved for retry." }
        }
    }
    private func save() async {
        guard canWrite, let owner else { return }
        isSaving = true; defer { isSaving = false }
        do {
            let entry = try draft.entry(session: session, ownerId: owner)
            try repository.fertigationOutbox.enqueueExisting(entry)
            pending = entry
            try await repository.flushFertigation(vineyardId: session.vineyardId)
            await finish()
        } catch { message = "Fertigation could not be saved. Check access and retry; irrigation has not been changed." }
    }
    private func retry(_ entry: FertigationLinkedOutbox.Entry) async {
        guard canWrite else { return }
        isSaving = true; defer { isSaving = false }
        do { try repository.fertigationOutbox.retry(id: entry.id); try await repository.flushFertigation(vineyardId: session.vineyardId); await finish() }
        catch { message = "Fertigation is retained on this device. Retry when connected." }
    }
    private func finish() async {
        let pendingId = pending?.id ?? draft.id
        let entry = try? repository.fertigationOutbox.entries().first { $0.id == pendingId }
        message = entry?.message
        pending = entry?.phase == .acknowledged ? nil : entry
        onSaved()
    }
}
