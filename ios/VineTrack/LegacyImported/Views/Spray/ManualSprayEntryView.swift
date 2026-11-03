import SwiftUI
import Supabase
import Auth

struct ManualSprayEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private let submissionGuard = ManualSpraySubmissionGuard()

    private var verifiedOwnerId: UUID? {
        SupabaseClientProvider.shared.client.auth.currentUser?.id
    }

    /// This is the original local mutation outbox, not a new queue or retry.
    /// Any unverified save in this vineyard blocks re-entry from the single
    /// vineyard-scoped draft, even when its UI @State was discarded.
    private var retainedSaveForVineyard: PendingManualSprayOperation? {
        coordinator.operations.first {
            $0.kind == .save && $0.payload.vineyardId == vineyardId &&
                $0.payload.manualEntryId == draft.manualEntryId
        }
    }

    private var hasSubmissionMarker: Bool {
        guard let ownerId = verifiedOwnerId else { return false }
        return submissionGuard.submittedId(ownerId: ownerId, vineyardId: vineyardId,
                                           manualEntryId: draft.manualEntryId) != nil
    }
    private let vineyardId: UUID
    private let timeZone: TimeZone
    private let teamRepository: any TeamRepositoryProtocol
    private let existingRecord: SprayRecord?
    private let existingTrip: Trip?
    @State private var coordinator: ManualSprayEntryCoordinator
    @State private var draft: ManualSprayPayload
    @State private var expectedVersion: Int?
    @State private var isLoadingExisting: Bool
    @State private var savedResponse: ManualSpraySaveResponse?
    @State private var members: [BackendVineyardMember] = []
    @State private var isReviewing: Bool = false
    @State private var isSaving: Bool = false
    @State private var awaitingServerConfirmation: Bool = false
    @State private var isVerifyingReadback: Bool = false
    @State private var confirmedByReadback: Bool = false
    @State private var message: String?
    @State private var loadError: String?

    init(vineyardId: UUID, timeZone: TimeZone, existingRecord: SprayRecord? = nil, existingTrip: Trip? = nil, teamRepository: any TeamRepositoryProtocol = SupabaseTeamRepository()) {
        self.vineyardId = vineyardId
        self.timeZone = timeZone
        self.existingRecord = existingRecord
        self.existingTrip = existingTrip
        self.teamRepository = teamRepository
        _draft = State(initialValue: existingRecord == nil ? (ManualSprayDraftStore.shared.load(vineyardId: vineyardId) ?? ManualSprayPayload.empty(vineyardId: vineyardId, timeZone: timeZone)) : ManualSprayPayload.empty(vineyardId: vineyardId, timeZone: timeZone))
        _coordinator = State(initialValue: ManualSprayEntryCoordinator.shared)
        _expectedVersion = State(initialValue: existingRecord?.syncVersion ?? 0)
        _isLoadingExisting = State(initialValue: existingRecord != nil)
        _savedResponse = State(initialValue: nil)
    }

    private var reviewStatus: ManualSprayReviewStatus {
        ManualSprayReviewStatus.resolve(
            serverConfirmed: savedResponse != nil || confirmedByReadback,
            hasRetainedSave: retainedSaveForVineyard != nil,
            hasSubmissionMarker: hasSubmissionMarker || awaitingServerConfirmation,
            isSaving: isSaving
        )
    }

    var body: some View {
        Group {
            if accessControl.loadedVineyardId == vineyardId && accessControl.canManageManualSprays {
                Form {
                    if isLoadingExisting {
                        Section { ProgressView("Reloading saved actual quantities…") }
                    } else if let loadError {
                        Section("Edit unavailable") {
                            Text(loadError)
                            Button("Retry") { Task { await loadExisting() } }
                        }
                    } else if reviewStatus != .reviewOnly && savedResponse == nil {
                        protectedSubmissionSections
                    } else if isReviewing { reviewSections } else { entrySections }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            } else {
                ContentUnavailableView("Manual spray entry unavailable", systemImage: "lock.fill", description: Text("Only Owners, Managers and Supervisors can add completed manual sprays."))
            }
        }
        .navigationTitle(reviewStatus != .reviewOnly || isReviewing ? "Manual spray status" : (existingRecord == nil ? "Add manual spray" : "Edit manual spray"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { if !isSaving && !isVerifyingReadback { dismiss() } }
                    .disabled(isSaving || isVerifyingReadback)
            }
            ToolbarItem(placement: .confirmationAction) {
                if reviewStatus != .reviewOnly {
                    Button(savedResponse != nil ? "Done" : "Close") {
                        if !isSaving && !isVerifyingReadback { dismiss() }
                    }.disabled(isSaving || isVerifyingReadback)
                } else {
                    Button(isReviewing ? "Save manual spray" : "Review") {
                        if isReviewing { Task { await save() } } else { validateForReview() }
                    }
                    .disabled(isSaving || isLoadingExisting || loadError != nil ||
                              reviewStatus != .reviewOnly ||
                              accessControl.loadedVineyardId != vineyardId || !accessControl.canManageManualSprays)
                }
            }
        }
        .interactiveDismissDisabled(isSaving || isVerifyingReadback)
        .onChange(of: draft) { _, updated in
            // Once the original operation has been submitted, never replace
            // its saved form snapshot while the server state is unresolved.
            if existingRecord == nil && !isSaving && reviewStatus == .reviewOnly {
                ManualSprayDraftStore.shared.save(updated)
            }
        }
        .task {
            members = (try? await teamRepository.listMembers(vineyardId: vineyardId)) ?? []
            await loadExisting()
        }
    }

    @ViewBuilder private var entrySections: some View {
        Section("Application") {
            TextField("Name or reference", text: $draft.reference)
            DatePicker("Start", selection: $draft.startUtc).environment(\.timeZone, timeZone)
            DatePicker("End", selection: $draft.endUtc).environment(\.timeZone, timeZone)
            Text("Times use \(timeZone.identifier)").font(.caption).foregroundStyle(.secondary)
            TextField("Notes", text: Binding(get: { draft.notes ?? "" }, set: { draft.notes = $0 }), axis: .vertical)
        }
        Section("Operator and equipment") {
            Picker("Tractor", selection: $draft.tractorId) {
                Text("Select tractor").tag(UUID?.none)
                ForEach(store.currentTractors) { tractor in Text(tractor.displayName).tag(Optional(tractor.id)) }
            }
            Picker("Operator", selection: $draft.operatorUserId) {
                Text("Select operator").tag(UUID?.none)
                ForEach(members, id: \.userId) { member in
                    Text(member.fullName ?? member.displayName ?? member.email ?? "VineTrack user").tag(Optional(member.userId))
                }
            }
            Picker("Spray unit", selection: $draft.sprayEquipmentId) {
                Text("Select spray unit").tag(UUID?.none)
                ForEach(store.sprayEquipment.filter { $0.vineyardId == vineyardId }) { unit in Text(unit.name).tag(Optional(unit.id)) }
            }
            TextField("Start engine hours (optional)", value: $draft.startEngineHours, format: .number).keyboardType(.decimalPad)
            TextField("End engine hours (optional)", value: $draft.endEngineHours, format: .number).keyboardType(.decimalPad)
        }
        Section("Blocks") {
            ForEach(store.paddocks.filter { $0.vineyardId == vineyardId }) { block in
                Button {
                    if let index = draft.blocks.firstIndex(where: { $0.blockId == block.id }) { draft.blocks.remove(at: index) }
                    else { draft.blocks.append(ManualSprayBlock(blockId: block.id, blockName: block.name)) }
                } label: {
                    HStack { Text(block.name); Spacer(); if draft.blocks.contains(where: { $0.blockId == block.id }) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.purple) } }
                }.foregroundStyle(.primary)
            }
        }
        ForEach($draft.tanks) { $tank in
            Section("Tank \(tank.tankNumber)") {
                TextField("Actual water (\(fmt.volumeUnitAbbreviation))", value: Binding(get: { fmt.volumeValue(litres: tank.waterVolumeLitres) }, set: { tank.waterVolumeLitres = fmt.volumeToCanonical($0) }), format: .number).keyboardType(.decimalPad)
                ForEach($tank.chemicals) { $chemical in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chemical.name).font(.headline)
                        HStack {
                            TextField("Actual amount", value: Binding(get: { chemical.unit.fromBase(chemical.actualAmountBase) }, set: { chemical.actualAmountBase = chemical.unit.toBase($0) }), format: .number).keyboardType(.decimalPad)
                            Picker("Unit", selection: $chemical.unit) {
                                ForEach(ChemicalUnit.allCases, id: \.self) { unit in
                                    if unit.dimension == chemical.unit.dimension { Text(unit.rawValue).tag(unit) }
                                }
                            }.labelsHidden()
                        }
                        Text("\(chemical.productCategory) · \(chemical.physicalForm.rawValue)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Menu("Add chemical from store", systemImage: "plus") {
                    ForEach(store.savedChemicals.filter { $0.vineyardId == vineyardId && $0.isActive }) { product in
                        Button(product.name) { addChemical(product, to: tank.id) }
                    }
                }
                if tank.tankNumber > 1 { Button("Remove tank", role: .destructive) { removeTank(tank.id) } }
            }
        }
        Section {
            Button("Add tank", systemImage: "plus") { addTank(copyPrevious: false) }
            Button("Copy previous tank", systemImage: "doc.on.doc") { addTank(copyPrevious: true) }
        }
        Section("Weather") {
            Text("Station weather can be retrieved after saving. Manual values remain authoritative and are never overwritten by a late station result.").font(.caption).foregroundStyle(.secondary)
            Toggle("Enter weather manually", isOn: Binding(get: { draft.manualWeather != nil }, set: { enabled in draft.manualWeather = enabled ? ManualSprayWeather(observedAt: draft.startUtc, source: "Operator observation", temperatureC: nil, humidityPct: nil, windSpeedKmh: nil, windGustKmh: nil, windDirectionDeg: nil, rainMm: nil) : nil }))
            if draft.manualWeather != nil {
                TextField("Temperature \(fmt.temperatureUnitAbbreviation)", value: weatherBinding(\.temperatureC, display: fmt.temperatureValue(celsius:), canonical: fmt.celsius(fromDisplay:)), format: .number).keyboardType(.decimalPad)
                TextField("Humidity %", value: weatherBinding(\.humidityPct), format: .number).keyboardType(.decimalPad)
                TextField("Wind \(fmt.speedUnitAbbreviation)", value: weatherBinding(\.windSpeedKmh, display: fmt.speedValue(kmh:), canonical: fmt.speedKmh(fromDisplay:)), format: .number).keyboardType(.decimalPad)
                TextField("Gust \(fmt.speedUnitAbbreviation)", value: weatherBinding(\.windGustKmh, display: fmt.speedValue(kmh:), canonical: fmt.speedKmh(fromDisplay:)), format: .number).keyboardType(.decimalPad)
                TextField("Direction °", value: weatherBinding(\.windDirectionDeg), format: .number).keyboardType(.decimalPad)
                TextField("Rain \(fmt.rainfallUnitAbbreviation)", value: weatherBinding(\.rainMm, display: fmt.rainfallValue(mm:), canonical: fmt.rainfallMm(fromDisplay:)), format: .number).keyboardType(.decimalPad)
            }
        }
    }

    @ViewBuilder private var protectedSubmissionSections: some View {
        Section("Manual spray submission") {
            LabeledContent("Status", value: reviewStatus.label)
            Text(reviewStatus == .submitting
                ? "VineTrack is submitting this manual spray. Do not close or edit until the result is known."
                : (reviewStatus == .locallySavedAwaitingServer
                    ? "An original manual spray submission is retained on this device. It must be reconciled through its existing operation ID; do not create another spray."
                    : "This device previously submitted a manual spray, but the original operation is no longer available for confirmation here. Check the saved Spray Record and Portal before making another entry."))
                .foregroundStyle(.orange)
            Text("The exact application record, quantities and completion time have not been re-confirmed on this screen. Closing does not delete or retry the original operation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if reviewStatus != .submitting {
                Button(isVerifyingReadback ? "Checking original spray…" : "Verify original spray on server") {
                    Task { await verifyOriginalReadback() }
                }
                .disabled(isSaving || isVerifyingReadback ||
                          accessControl.loadedVineyardId != vineyardId)
                Text("Verification only reads the existing server report. It will never retry, replace, or delete retained work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var reviewSections: some View {
        Section { Label("Manual entry", systemImage: "pencil").foregroundStyle(.purple); LabeledContent("Status", value: reviewStatus.label) }
        Section("Application") { LabeledContent("Reference", value: draft.reference); LabeledContent("Start", value: fmt.formatDateTime(draft.startUtc)); LabeledContent("End", value: fmt.formatDateTime(draft.endUtc)); LabeledContent("Timezone", value: draft.vineyardTimeZone) }
        Section("Summary") { LabeledContent("Blocks", value: "\(draft.blocks.count)"); LabeledContent("Tanks", value: "\(draft.tanks.count)"); LabeledContent("Actual water", value: fmt.formatVolume(litres: draft.tanks.reduce(0) { $0 + $1.waterVolumeLitres })) }
        if confirmedByReadback && savedResponse == nil {
            Section {
                Text("The original application, actual quantities and times were verified against the server report.")
                Button("Done") { dismiss() }
            }
        } else if let savedResponse {
            Section("Weather station") {
                Button("Retrieve historical station weather", systemImage: "cloud.sun") { Task { await recoverWeather(savedResponse) } }
                Text("This lookup is optional. An unavailable station never changes the saved application or replaces manual observations.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
        } else if awaitingServerConfirmation {
            Section {
                Text("This application has been retained on this device but is not yet server-confirmed. Do not create a second application; check Sync status.")
                    .foregroundStyle(.orange)
                Button("Close — awaiting sync") { dismiss() }
            }
        } else {
            Button("Back to edit") {
                if !isSaving && reviewStatus == .reviewOnly { isReviewing = false }
            }.disabled(isSaving || reviewStatus != .reviewOnly)
        }
    }

    private func addChemical(_ product: SavedChemical, to tankId: UUID) {
        guard let index = draft.tanks.firstIndex(where: { $0.id == tankId }) else { return }
        let form: ManualSprayPhysicalForm = product.productForm.lowercased() == "solid" || product.unit.dimension == .mass ? .solid : .liquid
        draft.tanks[index].chemicals.append(ManualSprayChemical(id: UUID(), savedChemicalId: product.id, name: product.name, actualAmountBase: 0, unit: product.unit, productCategory: product.productCategory.isEmpty ? product.use : product.productCategory, physicalForm: form, snapshotAt: Date()))
    }

    private func addTank(copyPrevious: Bool) {
        let number = draft.tanks.count + 1
        if copyPrevious, let previous = draft.tanks.last { draft.tanks.append(previous.copied(number: number)) }
        else { draft.tanks.append(ManualSprayTank(id: UUID(), actualId: UUID(), tankNumber: number, waterVolumeLitres: 0, chemicals: [])) }
    }

    private func removeTank(_ id: UUID) {
        draft.tanks.removeAll { $0.id == id }
        for index in draft.tanks.indices { draft.tanks[index].tankNumber = index + 1 }
    }

    private func weatherBinding(_ keyPath: WritableKeyPath<ManualSprayWeather, Double?>, display: @escaping (Double) -> Double = { $0 }, canonical: @escaping (Double) -> Double = { $0 }) -> Binding<Double?> {
        Binding(get: { draft.manualWeather?[keyPath: keyPath].map(display) }, set: { draft.manualWeather?[keyPath: keyPath] = $0.map(canonical) })
    }

    @MainActor
    private func loadExisting() async {
        guard let existingRecord, let existingTrip else { return }
        isLoadingExisting = true
        loadError = nil
        await SprayTankActualStore.shared.pull(vineyardId: vineyardId)
        do {
            let report = try await SprayReportRepository.shared.fetch(tripId: existingTrip.id)
            let actuals = SprayTankActualStore.shared.records.filter { $0.vineyardId == vineyardId && $0.tripId == existingTrip.id && $0.sprayRecordId == existingRecord.id }
            draft = try ManualSprayPayload.existing(record: existingRecord, trip: existingTrip, report: report, actuals: actuals, timeZone: timeZone)
            expectedVersion = existingRecord.syncVersion
        } catch {
            loadError = "The exact saved trip, tank, actual quantities, timezone, or weather could not be loaded. Sync and retry; no replacement draft will be created."
        }
        isLoadingExisting = false
    }

    private func validateForReview() {
        do { _ = try draft.validated(); message = nil; isReviewing = true }
        catch { message = error.localizedDescription }
    }

    private func save() async {
        guard !isSaving, isReviewing, reviewStatus == .reviewOnly,
              loadError == nil, accessControl.loadedVineyardId == vineyardId,
              accessControl.canManageManualSprays,
              let ownerId = verifiedOwnerId else { return }
        // Mark the original submission BEFORE the coordinator can reach the
        // server. The outbox itself, retries and ACK policy remain unchanged.
        let validated: ManualSprayPayload
        do { validated = try draft.validated() }
        catch { message = error.localizedDescription; return }
        if existingRecord == nil { ManualSprayDraftStore.shared.save(validated) }
        guard submissionGuard.mark(ownerId: ownerId, vineyardId: vineyardId,
                                   manualEntryId: validated.manualEntryId) else {
            message = "An earlier spray submission could not be safely reconciled. Check Sync status before saving again."
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let response = try await coordinator.save(payload: validated, expectedVersion: expectedVersion)
            if let response, response.serverConfirmed {
                expectedVersion = response.syncVersion
                savedResponse = response
                submissionGuard.clearIfMatching(ownerId: ownerId, vineyardId: vineyardId,
                                                manualEntryId: validated.manualEntryId)
                ManualSprayDraftStore.shared.clear(vineyardId: vineyardId)
                message = "Manual spray confirmed by the server. Historical station weather is optional."
            } else {
                awaitingServerConfirmation = true
                message = "The submission is retained or requires verification. Do not enter this application a second time; check Sync status."
            }
        } catch {
            if error is ManualSprayMutationError,
               !coordinator.operations.contains(where: {
                    $0.kind == .save && $0.payload.vineyardId == vineyardId &&
                    $0.payload.manualEntryId == validated.manualEntryId
               }) {
                submissionGuard.clearIfMatching(ownerId: ownerId, vineyardId: vineyardId,
                                                manualEntryId: validated.manualEntryId)
                awaitingServerConfirmation = false
                message = "The server definitively rejected this application. Review the original record before resubmitting corrected details."
                return
            }
            // A local outbox-persistence failure happens before any server
            // request. Only in that specific case may we safely clear intent.
            if let persistenceError = error as? ManualSprayPersistenceError,
               case .couldNotPersist = persistenceError,
               !coordinator.operations.contains(where: {
                   $0.kind == .save && $0.payload.vineyardId == vineyardId &&
                   $0.payload.manualEntryId == validated.manualEntryId
               }) {
                submissionGuard.clearIfMatching(ownerId: ownerId, vineyardId: vineyardId,
                                                manualEntryId: validated.manualEntryId)
            }
            message = error.localizedDescription
        }
    }

    /// Explicit read-only recovery for a background ACK. The original manual
    /// entry ID, Trip, spray record, tanks and quantities must all match.
    /// No retry, ACK promotion, queue mutation or new operation occurs here.
    private func verifyOriginalReadback() async {
        guard !isSaving, !isVerifyingReadback,
              let ownerId = verifiedOwnerId,
              submissionGuard.submittedId(ownerId: ownerId, vineyardId: vineyardId,
                                          manualEntryId: draft.manualEntryId) == draft.manualEntryId,
              accessControl.loadedVineyardId == vineyardId,
              accessControl.canManageManualSprays else {
            message = "No verified submission identity is available for this account and vineyard."
            return
        }
        let original = draft
        isVerifyingReadback = true
        defer { isVerifyingReadback = false }
        do {
            let report = try await SprayReportRepository.shared.fetch(tripId: original.tripId)
            guard verifiedOwnerId == ownerId,
                  accessControl.loadedVineyardId == vineyardId,
                  ManualSprayReviewStatus.reportMatchesOriginal(report, payload: original) else {
                message = "The server report is missing or differs from the original submission. Do not resubmit this spray. Its evidence is retained."
                return
            }
            guard !coordinator.operations.contains(where: {
                $0.kind == .save && $0.payload.vineyardId == vineyardId &&
                $0.payload.manualEntryId == original.manualEntryId
            }) else {
                message = "The server report matches, but this device still retains the original operation. Check Sync status; the queue was not changed."
                return
            }
            submissionGuard.clearIfMatching(ownerId: ownerId, vineyardId: vineyardId,
                                            manualEntryId: original.manualEntryId)
            ManualSprayDraftStore.shared.clear(vineyardId: vineyardId)
            confirmedByReadback = true
            awaitingServerConfirmation = false
            isReviewing = true
            message = "Original manual spray verified from the server. You can safely start a separate new application."
        } catch {
            message = "The original spray could not be independently verified. Keep this application; no new submission was made."
        }
    }

    private func recoverWeather(_ response: ManualSpraySaveResponse) async {
        do {
            let result = try await SprayReportRepository.shared.recoverWeather(tripId: response.tripId, through: draft.endUtc)
            _ = try? await SprayReportRepository.shared.fetch(tripId: response.tripId)
            if result.captured > 0 { message = "Captured \(result.captured) historical station observation\(result.captured == 1 ? "" : "s")." }
            else if result.pending > 0 { message = "Station weather is pending or not configured. The manual spray remains saved." }
            else { message = "Historical station weather was unavailable. The manual spray remains saved." }
        } catch { message = "Station weather could not be retrieved. The manual spray remains saved." }
    }
}
