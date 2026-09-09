import SwiftUI

struct ManualSprayEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store
    @Environment(BackendAccessControl.self) private var accessControl

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
    @State private var message: String?

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

    var body: some View {
        Group {
            if accessControl.canManageManualSprays {
                Form {
                    if isLoadingExisting {
                        Section { ProgressView("Reloading saved actual quantities…") }
                    } else if isReviewing { reviewSections } else { entrySections }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            } else {
                ContentUnavailableView("Manual spray entry unavailable", systemImage: "lock.fill", description: Text("Only Owners, Managers and Supervisors can add completed manual sprays."))
            }
        }
        .navigationTitle(isReviewing ? "Review manual spray" : (existingRecord == nil ? "Add manual spray" : "Edit manual spray"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isReviewing ? "Save manual spray" : "Review") {
                    if isReviewing { Task { await save() } } else { validateForReview() }
                }
                .disabled(isSaving || isLoadingExisting || !accessControl.canManageManualSprays)
            }
        }
        .onChange(of: draft) { _, updated in
            if existingRecord == nil && savedResponse == nil { ManualSprayDraftStore.shared.save(updated) }
        }
        .task {
            members = (try? await teamRepository.listMembers(vineyardId: vineyardId)) ?? []
            guard let existingRecord, let existingTrip else { return }
            do {
                let report = try await SprayReportRepository.shared.fetch(tripId: existingTrip.id)
                let actuals = SprayTankActualStore.shared.records.filter { $0.tripId == existingTrip.id && $0.sprayRecordId == existingRecord.id }
                draft = try ManualSprayPayload.existing(record: existingRecord, trip: existingTrip, report: report, actuals: actuals, timeZone: timeZone)
                expectedVersion = existingRecord.syncVersion
            } catch { message = error.localizedDescription }
            isLoadingExisting = false
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
                TextField("Actual water (L)", value: $tank.waterVolumeLitres, format: .number).keyboardType(.decimalPad)
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
                    ForEach(store.savedChemicals.filter { $0.vineyardId == vineyardId }) { product in
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
                TextField("Temperature °C", value: weatherBinding(\.temperatureC), format: .number).keyboardType(.decimalPad)
                TextField("Humidity %", value: weatherBinding(\.humidityPct), format: .number).keyboardType(.decimalPad)
                TextField("Wind km/h", value: weatherBinding(\.windSpeedKmh), format: .number).keyboardType(.decimalPad)
                TextField("Gust km/h", value: weatherBinding(\.windGustKmh), format: .number).keyboardType(.decimalPad)
                TextField("Direction °", value: weatherBinding(\.windDirectionDeg), format: .number).keyboardType(.decimalPad)
                TextField("Rain mm", value: weatherBinding(\.rainMm), format: .number).keyboardType(.decimalPad)
            }
        }
    }

    @ViewBuilder private var reviewSections: some View {
        Section { Label("Manual entry", systemImage: "pencil").foregroundStyle(.purple); LabeledContent("Status", value: "Completed") }
        Section("Application") { LabeledContent("Reference", value: draft.reference); LabeledContent("Start", value: draft.startUtc.formatted()); LabeledContent("End", value: draft.endUtc.formatted()); LabeledContent("Timezone", value: draft.vineyardTimeZone) }
        Section("Summary") { LabeledContent("Blocks", value: "\(draft.blocks.count)"); LabeledContent("Tanks", value: "\(draft.tanks.count)"); LabeledContent("Actual water", value: "\(draft.tanks.reduce(0) { $0 + $1.waterVolumeLitres }.formatted()) L") }
        if let savedResponse {
            Section("Weather station") {
                Button("Retrieve historical station weather", systemImage: "cloud.sun") { Task { await recoverWeather(savedResponse) } }
                Text("This lookup is optional. An unavailable station never changes the saved application or replaces manual observations.").font(.caption).foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }
        } else {
            Button("Back to edit") { isReviewing = false }
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

    private func weatherBinding(_ keyPath: WritableKeyPath<ManualSprayWeather, Double?>) -> Binding<Double?> {
        Binding(get: { draft.manualWeather?[keyPath: keyPath] }, set: { draft.manualWeather?[keyPath: keyPath] = $0 })
    }

    private func validateForReview() {
        do { _ = try draft.validated(); message = nil; isReviewing = true }
        catch { message = error.localizedDescription }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        if draft.manualWeather != nil { draft.manualWeather?.observedAt = draft.startUtc }
        do {
            let response = try await coordinator.save(payload: draft, expectedVersion: expectedVersion)
            if let response, response.serverConfirmed {
                expectedVersion = response.syncVersion
                savedResponse = response
                ManualSprayDraftStore.shared.clear(vineyardId: vineyardId)
                message = "Manual spray saved. Historical station weather is optional."
            } else { message = "Saved on this device — awaiting sync" }
        } catch { message = error.localizedDescription }
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
