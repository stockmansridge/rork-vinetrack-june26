import SwiftUI

/// Pre-finalisation review of planned vs covered paths. The operator can
/// tick off any rows the app missed (e.g. a short final row that didn't
/// register) before the trip is saved. Manual completions and skips are
/// recorded as audit events on the tracking service.
struct EndTripReviewSheet: View {
    let trip: Trip
    @Environment(MigratedDataStore.self) private var store
    @Environment(TripTrackingService.self) private var tracking
    @Environment(\.dismiss) private var dismiss

    @State private var manualCompletes: Set<Double> = []
    @State private var manualSkips: Set<Double> = []
    /// Optional free-text completion notes typed by the operator.
    /// Persisted onto the trip and synced as `trips.completion_notes`.
    @State private var completionNotes: String = ""
    /// Optional engine-hour meter reading at trip end. Free text so it can be
    /// left blank; parsed to `Double` on finish. Persists as
    /// `trips.end_engine_hours` for fuel allocation (Phase 3).
    @State private var endEngineHoursText: String = ""
    @FocusState private var notesFocused: Bool

    // Collapsible sections (secondary detail). Row completion stays
    // expanded by default — it's the main purpose of this sheet.
    @State private var pinsExpanded: Bool = false
    @State private var seedingExpanded: Bool = false

    private struct DisplayRow: Identifiable {
        let id: Int
        let result: RowCompletionResult
        let manuallyTicked: Bool
        var path: Double { result.path }
        var status: RowCompletionStatus {
            manuallyTicked ? .complete : result.status
        }
    }

    private var liveTrip: Trip { tracking.activeTrip ?? trip }

    private var rows: [DisplayRow] {
        let live = liveTrip
        // Promote the live current row to .partial so the sheet still hints
        // at it; the rest of the derivation comes straight from the shared
        // deriver so this view shows exactly what the report will show.
        let currentPath: Double? = live.rowSequence.indices.contains(live.sequenceIndex)
            ? live.rowSequence[live.sequenceIndex]
            : nil
        let derived = RowCompletionDeriver.results(for: live)
        return derived.enumerated().map { idx, r in
            var result = r
            if result.status == .notComplete,
               let cp = currentPath,
               abs(cp - r.path) < 0.01 {
                result = RowCompletionResult(path: r.path, status: .partial, source: .auto)
            }
            let ticked = manualCompletes.contains(r.path)
            return DisplayRow(id: idx, result: result, manuallyTicked: ticked)
        }
    }

    private var completedCount: Int { rows.filter { $0.status == .complete }.count }
    private var partialCount: Int { rows.filter { $0.status == .partial }.count }
    private var missedCount: Int { rows.filter { $0.status == .notComplete }.count }

    private var tripPins: [VinePin] {
        let ids = Set(liveTrip.pinIds)
        return store.pins.filter { ids.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                summarySection

                if missedCount > 0 {
                    Section {
                        Button {
                            let live = liveTrip
                            let completed = Set(live.completedPaths)
                            let skipped = Set(live.skippedPaths)
                            for r in rows where r.status == .notComplete {
                                if !completed.contains(r.path) && !skipped.contains(r.path) {
                                    manualCompletes.insert(r.path)
                                }
                            }
                        } label: {
                            Label("Tick all \(missedCount) missed rows as complete", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                    } footer: {
                        Text("Use this if GPS missed rows you actually drove.")
                    }
                }

                if rows.isEmpty {
                    Section {
                        Text("No planned rows on this trip.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Row completion") {
                        ForEach(rows) { row in
                            rowItem(row)
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Completion notes")
                            .font(.subheadline.weight(.semibold))
                        TextField(
                            "e.g. Finished block but last row was wet.",
                            text: $completionNotes,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.sentences)
                        .autocorrectionDisabled(false)
                        .focused($notesFocused)
                    }
                    .padding(.vertical, 2)
                } footer: {
                    Text("Optional notes for this completed job. These will appear in reports.")
                }

                if liveTrip.tractorId != nil {
                    engineHoursSection
                    fuelEstimateSection
                }

                if !tripPins.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $pinsExpanded) {
                            ForEach(tripPins) { pin in
                                pinRow(pin)
                            }
                        } label: {
                            Label("Pins recorded (\(tripPins.count))", systemImage: "mappin.and.ellipse")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }

                if liveTrip.tripFunction == TripFunction.seeding.rawValue,
                   let seeding = liveTrip.seedingDetails {
                    Section {
                        DisclosureGroup(isExpanded: $seedingExpanded) {
                            seedingSummary(seeding)
                        } label: {
                            Label("Seeding details", systemImage: "leaf")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
            }
            .navigationTitle("Review & Finish Trip")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Final completion pass: credits the current/last
                // locked row if it was clearly driven but never
                // produced a normal row-end transition (typical for
                // first row started mid-way and last row with no
                // following row to trigger advance).
                tracking.finalizePendingRowsForReview()
                // Pre-fill any existing notes (e.g. when reopening the
                // sheet after dismissing without finishing).
                if completionNotes.isEmpty,
                   let existing = tracking.activeTrip?.completionNotes,
                   !existing.isEmpty {
                    completionNotes = existing
                }
                if endEngineHoursText.isEmpty,
                   let existing = tracking.activeTrip?.endEngineHours {
                    endEngineHoursText = Self.engineHoursFormatter.string(from: NSNumber(value: existing)) ?? ""
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish Trip") {
                        applyAndFinish()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Engine hours

    static let engineHoursFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        return f
    }()

    private var parsedEndEngineHours: Double? {
        let trimmed = endEngineHoursText.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed), value >= 0 else { return nil }
        return value
    }

    private var endBelowStartWarning: Bool {
        guard let start = liveTrip.startEngineHours, let end = parsedEndEngineHours else { return false }
        return end < start
    }

    @ViewBuilder
    private var engineHoursSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let start = liveTrip.startEngineHours {
                    HStack {
                        Text("Start engine hours")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Self.engineHoursFormatter.string(from: NSNumber(value: start)) ?? "\(start)") hrs")
                            .font(.subheadline.weight(.medium))
                    }
                }
                HStack {
                    Text("End engine hours")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    TextField("hrs", text: $endEngineHoursText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 100)
                }
                if endBelowStartWarning {
                    Label("End reading is lower than the start reading. Fuel will fall back to trip duration.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Engine hours")
        } footer: {
            Text("Optional. If higher than the start reading, fuel use is calculated from the engine-hour difference. Otherwise trip duration is used.")
        }
    }

    // MARK: - Fuel estimate (display-only)

    /// Live trip with the operator's just-entered end engine-hour reading
    /// applied, so the estimate previews the same value that will be saved
    /// on finish. Never persisted from here — display only.
    private var fuelEstimateTrip: Trip {
        var t = liveTrip
        t.endEngineHours = parsedEndEngineHours
        return t
    }

    private var fuelTractor: Tractor? {
        guard let tid = liveTrip.tractorId else { return nil }
        return store.tractors.first { $0.id == tid }
    }

    /// Vineyard machine linked to this trip (preferred fuel source). Resolves
    /// from `machineId` first, then the legacy tractor link.
    private var fuelMachine: VineyardMachine? {
        if let mid = liveTrip.machineId,
           let m = store.vineyardMachines.first(where: { $0.id == mid }) {
            return m
        }
        if let tid = liveTrip.tractorId {
            return store.vineyardMachines.first { $0.legacyTractorId == tid && $0.vineyardId == liveTrip.vineyardId }
        }
        return nil
    }

    /// Fuel-only breakdown reused from the shared `TripCostService` so the
    /// preview matches the trip detail / report figures exactly.
    private var fuelBreakdown: TripCostService.FuelBreakdown {
        TripCostService.estimate(
            trip: fuelEstimateTrip,
            operatorCategory: nil,
            machine: fuelMachine,
            tractor: fuelTractor,
            fuelPurchases: store.fuelPurchases.filter { $0.vineyardId == liveTrip.vineyardId },
            sprayRecord: nil
        ).fuel
    }

    @ViewBuilder
    private var fuelEstimateSection: some View {
        let f = fuelBreakdown
        let rateMissing = (f.fuelUsageLPerHour ?? 0) <= 0
        Section {
            VStack(alignment: .leading, spacing: 8) {
                if let name = f.machineName {
                    fuelRow("Machine", value: name)
                }
                fuelRow("Fuel basis", value: f.basis.label)
                if let delta = f.engineHourDelta {
                    fuelRow("Engine hour delta", value: "\(Self.engineHoursFormatter.string(from: NSNumber(value: delta)) ?? "\(delta)") hrs")
                }
                if let rate = f.fuelUsageLPerHour, rate > 0 {
                    fuelRow("Fuel rate", value: String(format: "%.1f L/hr", rate))
                }
                if !rateMissing, f.litres > 0 {
                    fuelRow("Estimated litres", value: String(format: "%.1f L", f.litres))
                }
                if !rateMissing, f.litres > 0 {
                    if let perL = f.costPerLitre {
                        fuelRow("Estimated fuel cost", value: formatCurrency(f.litres * perL), emphasised: true)
                    } else {
                        fuelRow("Estimated fuel cost", value: "Unavailable", muted: true)
                    }
                }

                if rateMissing {
                    fuelWarning("Fuel rate missing — set the tractor's fuel usage (L/hr) in Equipment to estimate litres.")
                }
                if endBelowStartWarning {
                    fuelWarning("End engine hours are lower than the start reading — falling back to trip duration.")
                }
                if !rateMissing, f.litres > 0, f.costPerLitre == nil {
                    fuelWarning("No fuel cost per litre available — add a fuel purchase in Equipment to estimate cost.")
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Fuel estimate")
        } footer: {
            Text("Estimate only — not stored on the trip.")
        }
    }

    private func fuelRow(_ label: String, value: String, emphasised: Bool = false, muted: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(emphasised ? .semibold : .medium))
                .foregroundStyle(muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }

    private func fuelWarning(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
    }

    private func formatCurrency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    // MARK: - Trip Summary

    @ViewBuilder
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text(liveTrip.displayFunctionLabel)
                    .font(.title3.weight(.semibold))

                if !liveTrip.paddockName.isEmpty {
                    Label(liveTrip.paddockName, systemImage: "square.grid.2x2")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Time / distance row
                HStack(spacing: 0) {
                    summaryStat(value: formattedDuration(liveTrip.activeDuration), label: "Duration")
                    Divider().frame(height: 36)
                    summaryStat(value: formattedDistance(liveTrip.totalDistance), label: "Distance")
                    Divider().frame(height: 36)
                    summaryStat(value: "\(liveTrip.pinIds.count)", label: "Pins")
                }

                // Row counts
                HStack(spacing: 0) {
                    summaryStat(value: "\(completedCount)", label: "Complete", tint: .green)
                    Divider().frame(height: 36)
                    summaryStat(value: "\(partialCount)", label: "Partial", tint: .orange)
                    Divider().frame(height: 36)
                    summaryStat(value: "\(missedCount)", label: "Missed", tint: missedCount > 0 ? .red : .secondary)
                    Divider().frame(height: 36)
                    summaryStat(value: "\(rows.count)", label: "Planned")
                }
            }
            .padding(.vertical, 4)
        } footer: {
            Text("Review the rows below and tick any GPS missed before finalising.")
        }
    }

    private func summaryStat(value: String, label: String, tint: Color = .primary) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        let s = total % 60
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private func formattedDistance(_ metres: Double) -> String {
        if metres >= 1000 {
            return String(format: "%.2f km", metres / 1000)
        }
        return String(format: "%.0f m", metres)
    }

    // MARK: - Row item

    @ViewBuilder
    private func rowItem(_ row: DisplayRow) -> some View {
        let isManualCompleted = row.manuallyTicked
        let live = liveTrip
        let alreadyCompleted = live.completedPaths.contains(where: { abs($0 - row.path) < 0.01 })
        let alreadySkipped = live.skippedPaths.contains(where: { abs($0 - row.path) < 0.01 })
        let displayStatus = row.status

        HStack(spacing: 12) {
            Image(systemName: displayStatus.iconName)
                .font(.title2)
                .foregroundStyle(tint(for: displayStatus))
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text("Path \(row.result.formattedPath)")
                    .font(.headline)
                Text(detailLabel(for: row, manuallyCompleted: isManualCompleted))
                    .font(.caption)
                    .foregroundStyle(displayStatus == .notComplete && !isManualCompleted ? .red : .secondary)
                    .fontWeight(displayStatus == .notComplete && !isManualCompleted ? .semibold : .regular)
            }

            Spacer()

            if !alreadyCompleted && !alreadySkipped {
                Toggle("", isOn: Binding(
                    get: { manualCompletes.contains(row.path) },
                    set: { newValue in
                        if newValue {
                            manualCompletes.insert(row.path)
                        } else {
                            manualCompletes.remove(row.path)
                        }
                    }
                ))
                .labelsHidden()
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(
            displayStatus == .notComplete && !isManualCompleted
                ? Color.red.opacity(0.06)
                : Color(.secondarySystemGroupedBackground)
        )
    }

    private func tint(for status: RowCompletionStatus) -> Color {
        switch status {
        case .complete: return .green
        case .partial: return .orange
        case .notComplete: return .red
        }
    }

    private func detailLabel(for row: DisplayRow, manuallyCompleted: Bool) -> String {
        if manuallyCompleted { return "Will be ticked Complete — End review" }
        switch row.status {
        case .complete:
            if let source = row.result.source { return "Complete — \(source.label)" }
            return "Complete"
        case .partial:
            return "Partial — Auto"
        case .notComplete:
            return "Not complete — not detected by GPS"
        }
    }

    // MARK: - Pins / Seeding (collapsible)

    @ViewBuilder
    private func pinRow(_ pin: VinePin) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.buttonName.isEmpty ? pin.mode.rawValue : pin.buttonName)
                    .font(.subheadline)
                if let row = pin.pinRowNumber {
                    Text("On Row \(row)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let row = pin.rowNumber {
                    Text("Row \(row)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func seedingSummary(_ seeding: SeedingDetails) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let depth = seeding.sowingDepthCm {
                Text(String(format: "Sowing depth: %.1f cm", depth))
                    .font(.subheadline)
            }
            if let lines = seeding.mixLines, !lines.isEmpty {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if let name = line.name, !name.isEmpty {
                        Text("• \(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func applyAndFinish() {
        // Persist any manual ticks AND the optional completion notes
        // onto the live trip in a single update so the saved record
        // (and the synced row) reflects everything in one shot.
        let trimmedNotes = completionNotes
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if var live = tracking.activeTrip {
            var changed = false
            if !manualCompletes.isEmpty {
                for path in manualCompletes {
                    if !live.completedPaths.contains(path) && !live.skippedPaths.contains(path) {
                        live.completedPaths.append(path)
                        changed = true
                    }
                }
            }
            if (live.completionNotes ?? "") != trimmedNotes {
                live.completionNotes = trimmedNotes.isEmpty ? nil : trimmedNotes
                changed = true
            }
            // Phase 3 fuel allocation: optional end engine-hour reading.
            if live.endEngineHours != parsedEndEngineHours {
                live.endEngineHours = parsedEndEngineHours
                changed = true
            }
            if changed {
                store.updateTrip(live)
            }
            if !manualCompletes.isEmpty {
                let summary = manualCompletes
                    .sorted()
                    .map { String(format: "%g", $0) }
                    .joined(separator: ",")
                tracking.recordManualCorrection("end_review_completed: [\(summary)]")
            }
        }
        tracking.recordManualCorrection("end_review_finalised")
        tracking.endTrip()
        dismiss()
    }
}
