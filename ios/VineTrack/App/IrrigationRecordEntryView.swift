import SwiftUI

// MARK: - Record / edit an irrigation session

struct IrrigationRecordEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MigratedDataStore.self) private var store

    /// When set, the form edits an existing session via `update_irrigation_session`.
    var editingSession: IrrigationSession?
    /// When set (duplicate flow), prefills from a previous session but records
    /// a brand-new session with a fresh UUID.
    var duplicateFrom: IrrigationSession?
    var onSaved: () -> Void = {}

    @State private var systems: [IrrigationSystem] = []
    @State private var valves: [IrrigationValve] = []
    @State private var systemId: UUID?
    @State private var valveId: UUID?
    @State private var validation: IrrigationValveValidation?
    @State private var sessionDate = Date()
    @State private var durationHours = ""
    @State private var durationMinutes = ""
    @State private var method: IrrigationCalculationMethod = .configuredFlow
    @State private var sessionFlow = ""
    @State private var meterStart = ""
    @State private var meterFinish = ""
    @State private var totalVolume = ""
    @State private var useStartTime = false
    @State private var startTime = Date()
    @State private var useEndTime = false
    @State private var finishTime = Date()
    @State private var notes = ""
    @State private var useCurrentConfiguration = false
    /// SQL 131 — the advanced measurement options are hidden while the
    /// default configured-flow workflow is available.
    @State private var showAdvancedMethods = false

    @State private var preview: IrrigationPreview?
    @State private var localPreview: IrrigationLocalCalculator.Result?
    @State private var previewError: String?
    @State private var isSaving = false
    @State private var isOfflinePreview = false
    @State private var saveMessage: String?
    @State private var errorMessage: String?

    private let repository = SupabaseIrrigationRepository.shared

    private var vineyardId: UUID? { store.selectedVineyardId }
    private var formatter: RegionFormatter { RegionFormatter(settings: store.settings.regionSettings) }
    private var isEditing: Bool { editingSession != nil }

    // MARK: Start/end time handling (SQL 130)

    private var startMinutesOfDay: Int? {
        guard useStartTime else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: startTime)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var endMinutesOfDay: Int? {
        guard useStartTime, useEndTime else { return nil }
        let c = Calendar.current.dateComponents([.hour, .minute], from: finishTime)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// Derived duration when both times are set; `nil` when times are equal
    /// (invalid) or when either time is missing. Overnight rolls to next day.
    private var derivedDurationMinutes: Int? {
        guard let start = startMinutesOfDay, let end = endMinutesOfDay else { return nil }
        return IrrigationLocalCalculator.minutesBetweenTimes(startMinutesOfDay: start, endMinutesOfDay: end)
    }

    private var isOvernight: Bool {
        guard let start = startMinutesOfDay, let end = endMinutesOfDay else { return false }
        return end < start
    }

    private var bothTimesSet: Bool { useStartTime && useEndTime }

    private var totalDurationMinutes: Int {
        if let derived = derivedDurationMinutes { return derived }
        if bothTimesSet { return 0 }  // equal start/end — invalid, blocks saving
        let hours = Int(durationHours) ?? 0
        let minutes = Int(durationMinutes) ?? 0
        return hours * 60 + minutes
    }

    /// Turning a time toggle off returns the duration to an editable field,
    /// preserving the last valid derived value.
    private var startTimeBinding: Binding<Bool> {
        Binding(get: { useStartTime }, set: { on in
            if !on {
                preserveDerivedDuration()
                useEndTime = false
            }
            useStartTime = on
        })
    }

    private var endTimeBinding: Binding<Bool> {
        Binding(get: { useEndTime }, set: { on in
            if !on { preserveDerivedDuration() }
            useEndTime = on
        })
    }

    private func preserveDerivedDuration() {
        guard let derived = derivedDurationMinutes else { return }
        durationHours = "\(derived / 60)"
        durationMinutes = "\(derived % 60)"
    }

    private func formattedTimeOfDay(_ minutesOfDay: Int) -> String {
        let cal = Calendar.current
        let base = cal.startOfDay(for: sessionDate)
        let date = cal.date(byAdding: .minute, value: minutesOfDay, to: base) ?? base
        return date.formatted(date: .omitted, time: .shortened)
    }

    /// Absolute timestamps built from the LOCAL session date + wall-clock
    /// times in the device timezone. An end earlier than (or equal to) the
    /// start ends on the following day; with start + duration the calculated
    /// end is submitted as a convenience.
    private func resolvedTimestamps() -> (start: Date?, finish: Date?) {
        guard useStartTime else { return (nil, nil) }
        let cal = Calendar.current
        let sc = cal.dateComponents([.hour, .minute], from: startTime)
        guard let start = cal.date(bySettingHour: sc.hour ?? 0, minute: sc.minute ?? 0,
                                   second: 0, of: sessionDate) else { return (nil, nil) }
        if useEndTime {
            let ec = cal.dateComponents([.hour, .minute], from: finishTime)
            guard var end = cal.date(bySettingHour: ec.hour ?? 0, minute: ec.minute ?? 0,
                                     second: 0, of: sessionDate) else { return (start, nil) }
            if end <= start {
                end = cal.date(byAdding: .day, value: 1, to: end) ?? end
            }
            return (start, end)
        }
        if totalDurationMinutes > 0 {
            return (start, cal.date(byAdding: .minute, value: totalDurationMinutes, to: start))
        }
        return (start, nil)
    }

    private var availableValves: [IrrigationValve] {
        valves.filter { $0.isActive && ($0.irrigationSystemId == systemId || systemId == nil) }
    }

    private var canPreview: Bool {
        guard valveId != nil, totalDurationMinutes > 0 else { return false }
        switch method {
        case .configuredFlow: return validation?.automaticFlowAvailable == true
        case .sessionFlow: return Double(sessionFlow.replacingOccurrences(of: ",", with: ".")) ?? 0 > 0
        case .totalVolume: return Double(totalVolume.replacingOccurrences(of: ",", with: ".")) ?? 0 > 0
        case .meterReadings:
            let start = Double(meterStart.replacingOccurrences(of: ",", with: ".")) ?? 0
            let finish = Double(meterFinish.replacingOccurrences(of: ",", with: ".")) ?? 0
            return finish > start && finish > 0
        }
    }

    var body: some View {
        Form {
            if !isEditing {
                valveSection
            } else {
                Section("Session") {
                    LabeledContent("Valve", value: editingSession?.valveName ?? "—")
                    LabeledContent("System", value: editingSession?.systemName ?? "—")
                }
            }

            dateDurationSection
            methodSection

            Section("Notes") {
                TextField("Notes (optional)", text: $notes, axis: .vertical)
            }

            if isEditing {
                Section {
                    Toggle("Apply current valve configuration", isOn: $useCurrentConfiguration)
                    Text(useCurrentConfiguration
                         ? "The record will be recalculated with today's valve and block setup instead of the configuration saved with it."
                         : "The configuration saved with this record is kept — editing values never silently applies a newer valve setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            previewSection

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(isEditing ? "Save Changes" : "Save Irrigation Record")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(!canPreview || isSaving)
            }
        }
        .navigationTitle(isEditing ? "Edit Irrigation" : "Record Irrigation")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: valveId) { _, newValue in
            preview = nil
            localPreview = nil
            Task { await loadValidation(valveId: newValue) }
        }
        .onChange(of: systemId) { _, _ in
            if let valveId, !availableValves.contains(where: { $0.id == valveId }) {
                self.valveId = availableValves.count == 1 ? availableValves.first?.id : nil
            }
        }
        .alert("Saved", isPresented: .init(get: { saveMessage != nil }, set: { if !$0 { saveMessage = nil } })) {
            Button("OK") {
                saveMessage = nil
                onSaved()
                dismiss()
            }
        } message: {
            Text(saveMessage ?? "")
        }
    }

    // MARK: Sections

    private var valveSection: some View {
        Section("Irrigation") {
            Picker("System", selection: $systemId) {
                Text("Select…").tag(UUID?.none)
                ForEach(systems.filter { $0.isActive }) { system in
                    Text(system.name).tag(UUID?.some(system.id))
                }
            }
            Picker("Valve", selection: $valveId) {
                Text("Select…").tag(UUID?.none)
                ForEach(availableValves) { valve in
                    Text(valve.name).tag(UUID?.some(valve.id))
                }
            }
            if let validation, !validation.canRecord {
                ForEach(validation.issues, id: \.self) { issue in
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var dateDurationSection: some View {
        Section("Date & duration") {
            DatePicker("Date", selection: $sessionDate, displayedComponents: .date)
            Toggle("Start time", isOn: startTimeBinding.animation())
            if useStartTime {
                DatePicker("Starts", selection: $startTime, displayedComponents: .hourAndMinute)
                Toggle("End time", isOn: endTimeBinding.animation())
                if useEndTime {
                    DatePicker("Ends", selection: $finishTime, displayedComponents: .hourAndMinute)
                }
            }
            if bothTimesSet {
                if let derived = derivedDurationMinutes {
                    LabeledContent("Duration", value: IrrigationFormat.duration(minutes: derived))
                    if isOvernight {
                        Label("Ends the following day", systemImage: "moon.stars")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Label("End time must be different from start time.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                HStack {
                    TextField("Hours", text: $durationHours)
                        .keyboardType(.numberPad)
                    Text("h")
                        .foregroundStyle(.secondary)
                    TextField("Minutes", text: $durationMinutes)
                        .keyboardType(.numberPad)
                    Text("min")
                        .foregroundStyle(.secondary)
                }
                if useStartTime, totalDurationMinutes > 0 {
                    let end = IrrigationLocalCalculator.endOfSession(
                        startMinutesOfDay: startMinutesOfDay ?? 0,
                        durationMinutes: totalDurationMinutes)
                    LabeledContent("Calculated end",
                                   value: formattedTimeOfDay(end.minutesOfDay)
                                          + (end.daysLater > 0 ? " next day" : ""))
                }
            }
        }
    }

    /// The default workflow: configured flow resolves automatically, so the
    /// method picker stays out of the way behind an "advanced" disclosure.
    private var showsDefaultFlowWorkflow: Bool {
        validation?.automaticFlowAvailable == true && method == .configuredFlow && !showAdvancedMethods
    }

    private var methodSection: some View {
        Section("Water calculation") {
            if !showsDefaultFlowWorkflow {
                Picker("Method", selection: $method) {
                    ForEach(IrrigationCalculationMethod.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.menu)
            }

            switch method {
            case .configuredFlow:
                if let validation, validation.automaticFlowAvailable,
                   let flow = validation.flowForCalculation {
                    LabeledContent("Calculated flow", value: IrrigationFormat.flow(flow, formatter: formatter))
                    if let sourceLabel = validation.resolvedFlowSourceLabel {
                        Label {
                            Text(sourceLabel + (validation.resolvedFlowIsEstimated == true ? " (estimated)" : ""))
                        } icon: {
                            Image(systemName: validation.resolvedFlowIsEstimated == true
                                  ? "function" : "checkmark.seal")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if showsDefaultFlowWorkflow {
                        Button("Change measurement method") {
                            withAnimation { showAdvancedMethods = true }
                        }
                        .font(.caption)
                    }
                } else {
                    Label(validation?.resolvedFlowWarning
                          ?? "No configured flow source exists for this valve. Enter a session flow, total volume or meter readings instead.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            case .sessionFlow:
                LabeledContent("Flow rate") {
                    TextField("L/h", text: $sessionFlow)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            case .totalVolume:
                LabeledContent("Total water") {
                    TextField("Litres", text: $totalVolume)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            case .meterReadings:
                LabeledContent("Meter start") {
                    TextField("Litres", text: $meterStart)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Meter finish") {
                    TextField("Litres", text: $meterFinish)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            Button {
                Task { await refreshPreview() }
            } label: {
                Label("Calculate Preview", systemImage: "function")
            }
            .disabled(!canPreview)

            if let previewError {
                Text(previewError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if isOfflinePreview {
                Label("Offline preview — the server will confirm the final values when the record syncs.",
                      systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let preview {
                serverPreviewRows(preview)
            } else if let localPreview {
                localPreviewRows(localPreview)
            }
        }
    }

    @ViewBuilder
    private func serverPreviewRows(_ preview: IrrigationPreview) -> some View {
        LabeledContent("Total water",
                       value: IrrigationFormat.volume(preview.totalVolumeLitres, formatter: formatter))
        if let effective = preview.effectiveVolumeLitres {
            LabeledContent("Effective water",
                           value: IrrigationFormat.volume(effective, formatter: formatter))
        }
        if let flow = preview.flowLitresPerHourUsed {
            LabeledContent("Flow used", value: IrrigationFormat.flow(flow, formatter: formatter))
        }
        if let explanation = preview.flowExplanation {
            Label {
                Text(explanation + (preview.flowIsEstimated == true ? " (estimated)" : ""))
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        ForEach(preview.blocks) { block in
            blockPreviewRow(
                name: block.blockName ?? "Block",
                percentage: block.allocationPercentage,
                allocated: block.allocatedVolumeLitres,
                perVine: block.waterLitresPerVine,
                perHa: block.waterLitresPerHectare,
                depth: block.irrigationDepthMm)
        }
        ForEach(preview.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func localPreviewRows(_ result: IrrigationLocalCalculator.Result) -> some View {
        LabeledContent("Total water",
                       value: IrrigationFormat.volume(result.totalVolumeLitres, formatter: formatter))
        if let effective = result.effectiveVolumeLitres {
            LabeledContent("Effective water",
                           value: IrrigationFormat.volume(effective, formatter: formatter))
        }
        ForEach(result.blocks, id: \.blockId) { block in
            blockPreviewRow(
                name: block.blockName,
                percentage: block.allocationPercentage,
                allocated: block.allocatedVolumeLitres,
                perVine: block.waterLitresPerVine,
                perHa: block.waterLitresPerHectare,
                depth: block.irrigationDepthMm)
        }
        ForEach(result.warnings, id: \.self) { warning in
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func blockPreviewRow(name: String, percentage: Double, allocated: Double,
                                 perVine: Double?, perHa: Double?, depth: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f%%", percentage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(IrrigationFormat.volume(allocated, formatter: formatter))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.cyan)
                if let perVine {
                    Text(IrrigationFormat.perVine(perVine, formatter: formatter))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let perHa {
                    Text(IrrigationFormat.perHectare(perHa, formatter: formatter))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let depth {
                    Text(IrrigationFormat.depth(depth, formatter: formatter))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Data

    private func load() async {
        guard let vineyardId else { return }
        if let source = editingSession ?? duplicateFrom {
            systemId = source.irrigationSystemId
            valveId = source.valveId
            method = IrrigationCalculationMethod(rawValue: source.calculationMethod) ?? .configuredFlow
            if let date = IrrigationFormat.dateFormat.date(from: source.sessionDate), editingSession != nil {
                sessionDate = date
            }
            durationHours = "\(source.durationMinutes / 60)"
            durationMinutes = "\(source.durationMinutes % 60)"
            if editingSession != nil, let startedIso = source.startedAt,
               let started = IrrigationFormat.parseTimestamp(startedIso) {
                useStartTime = true
                startTime = started
                if let finishedIso = source.finishedAt,
                   let finished = IrrigationFormat.parseTimestamp(finishedIso) {
                    useEndTime = true
                    finishTime = finished
                }
            }
            if method == .sessionFlow, let flow = source.flowLitresPerHour {
                sessionFlow = String(format: "%g", flow)
            }
            if method == .totalVolume {
                totalVolume = String(format: "%g", source.totalVolumeLitres)
            }
            if method == .meterReadings {
                if let v = source.meterStartLitres { meterStart = String(format: "%g", v) }
                if let v = source.meterFinishLitres { meterFinish = String(format: "%g", v) }
            }
            if editingSession != nil {
                notes = source.notes ?? ""
            }
        }
        do {
            async let systemsTask = repository.listSystems(vineyardId: vineyardId)
            async let valvesTask = repository.listValves(vineyardId: vineyardId)
            systems = try await systemsTask
            valves = try await valvesTask
            if systemId == nil && systems.filter({ $0.isActive }).count == 1 {
                systemId = systems.first { $0.isActive }?.id
            }
            if valveId == nil && availableValves.count == 1 {
                valveId = availableValves.first?.id
            }
            await loadValidation(valveId: valveId)
        } catch {
            errorMessage = "Setup data could not be loaded — cached configuration will be used where available."
        }
    }

    private func loadValidation(valveId: UUID?) async {
        guard let vineyardId, let valveId else {
            validation = nil
            return
        }
        do {
            validation = try await repository.validateValve(vineyardId: vineyardId, valveId: valveId)
        } catch {
            // Offline: fall back to the cached validation for this valve.
            validation = repository.cachedValidation(vineyardId: vineyardId, valveId: valveId)
        }
    }

    private func refreshPreview() async {
        guard let vineyardId, let valveId, canPreview else { return }
        previewError = nil
        isOfflinePreview = false
        let dateString = IrrigationFormat.dateFormat.string(from: sessionDate)
        do {
            preview = try await repository.preview(
                vineyardId: vineyardId, valveId: valveId, sessionDate: dateString,
                durationMinutes: totalDurationMinutes, method: method,
                flow: method == .sessionFlow ? Double(sessionFlow.replacingOccurrences(of: ",", with: ".")) : nil,
                meterStart: Double(meterStart.replacingOccurrences(of: ",", with: ".")),
                meterFinish: Double(meterFinish.replacingOccurrences(of: ",", with: ".")),
                totalVolume: Double(totalVolume.replacingOccurrences(of: ",", with: ".")))
            localPreview = nil
        } catch {
            preview = nil
            computeLocalPreview(reason: error)
        }
    }

    /// Offline fallback: mirrors the server maths using the cached validation.
    private func computeLocalPreview(reason: Error) {
        guard let validation else {
            previewError = friendlyIrrigationError(reason)
            return
        }
        do {
            let flow: Double? = switch method {
            case .configuredFlow: validation.flowForCalculation
            case .sessionFlow: Double(sessionFlow.replacingOccurrences(of: ",", with: "."))
            default: nil
            }
            let total = try IrrigationLocalCalculator.totalVolume(
                method: method, flowLitresPerHour: flow,
                durationMinutes: totalDurationMinutes,
                meterStartLitres: Double(meterStart.replacingOccurrences(of: ",", with: ".")),
                meterFinishLitres: Double(meterFinish.replacingOccurrences(of: ",", with: ".")),
                totalVolumeLitres: Double(totalVolume.replacingOccurrences(of: ",", with: ".")))
            localPreview = IrrigationLocalCalculator.allocate(
                totalVolumeLitres: total, allocations: validation.allocations)
            isOfflinePreview = true
        } catch {
            previewError = error.localizedDescription
        }
    }

    // MARK: Save

    private func save() async {
        guard let vineyardId, let valveId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let dateString = IrrigationFormat.dateFormat.string(from: sessionDate)
        let flowValue = method == .sessionFlow
            ? Double(sessionFlow.replacingOccurrences(of: ",", with: ".")) : nil
        let meterStartValue = method == .meterReadings
            ? Double(meterStart.replacingOccurrences(of: ",", with: ".")) : nil
        let meterFinishValue = method == .meterReadings
            ? Double(meterFinish.replacingOccurrences(of: ",", with: ".")) : nil
        let totalValue = method == .totalVolume
            ? Double(totalVolume.replacingOccurrences(of: ",", with: ".")) : nil

        let times = resolvedTimestamps()

        if let editing = editingSession {
            do {
                // Clearing is explicit: the session had stored times and the
                // user switched the start time off.
                let clearTimes = editing.startedAt != nil && !useStartTime
                _ = try await repository.updateSession(
                    id: editing.id, sessionDate: dateString,
                    durationMinutes: totalDurationMinutes, method: method,
                    flow: flowValue, meterStart: meterStartValue,
                    meterFinish: meterFinishValue, totalVolume: totalValue,
                    startedAt: times.start, finishedAt: times.finish,
                    clearTimes: clearTimes,
                    notes: notes.isEmpty ? nil : notes,
                    useCurrentConfiguration: useCurrentConfiguration)
                saveMessage = "The irrigation record was updated and all block allocations were recalculated."
            } catch {
                errorMessage = friendlyIrrigationError(error)
            }
            return
        }

        guard let systemIdValue = systemId ?? valves.first(where: { $0.id == valveId })?.irrigationSystemId else {
            errorMessage = "Select an irrigation system."
            return
        }

        let pending = IrrigationPendingSession(
            id: UUID(),
            vineyardId: vineyardId,
            irrigationSystemId: systemIdValue,
            valveId: valveId,
            valveName: validation?.valveName ?? "Valve",
            sessionDate: dateString,
            durationMinutes: totalDurationMinutes,
            calculationMethod: method.rawValue,
            flowLitresPerHour: flowValue,
            meterStartLitres: meterStartValue,
            meterFinishLitres: meterFinishValue,
            totalVolumeLitres: totalValue,
            startedAt: times.start,
            finishedAt: times.finish,
            notes: notes.isEmpty ? nil : notes,
            localTotalVolumeLitres: localPreview?.totalVolumeLitres ?? preview?.totalVolumeLitres,
            createdAt: Date())

        do {
            let saved = try await repository.recordSession(pending)
            if saved.duplicate == true {
                saveMessage = "This irrigation record was already saved."
            } else {
                saveMessage = "Irrigation recorded: \(IrrigationFormat.volume(saved.totalVolumeLitres, formatter: formatter)) across \(saved.blocks.count) block\(saved.blocks.count == 1 ? "" : "s")."
            }
        } catch {
            let description = error.localizedDescription.lowercased()
            let looksOffline = description.contains("offline")
                || description.contains("network")
                || description.contains("internet")
                || description.contains("timed out")
                || description.contains("could not connect")
            if looksOffline {
                repository.enqueuePending(pending)
                saveMessage = "You're offline. The irrigation record was saved on this device and will sync automatically."
            } else {
                errorMessage = friendlyIrrigationError(error)
            }
        }
    }
}
