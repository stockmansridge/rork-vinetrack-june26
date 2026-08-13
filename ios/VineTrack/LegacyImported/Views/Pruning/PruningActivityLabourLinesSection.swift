import SwiftUI

/// THE labour surface of a Pruning Activity (sql/190) — the iOS twin of the
/// Kotlin `PruningActivityLabourLinesSection`.
///
/// Labour is **PRUNING-OWNED**: these lines belong to the activity, not to the
/// linked Work Task, and they are counted ONCE no matter how many blocks the
/// activity covers. A linked Work Task never gets a copy — it reads through to
/// the same rows — so the Pruning report and the Work Task report show the same
/// number from the same record.
///
/// What is rendered depends on where the activity's labour actually comes from,
/// resolved by `PruningActivityLabourCosting.resolve`:
///
/// * `pieceRate` — a linked piece-rate job. Its snapshot IS the cost; hours here
///   are operational history and never move the money.
/// * `pruningLabourLines` — the activity's own lines. Fully editable.
/// * `workTaskLines` — labour recorded on the linked task before SQL 190. Shown
///   read-through, clearly attributed, never duplicated locally.
/// * `activityHours` — a legacy single-crew record. Shown exactly as recorded,
///   with an explicit opt-in conversion. Never silently rewritten.
struct PruningActivityLabourLinesSection: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    let activityId: UUID
    let vineyardId: UUID
    /// Date a new line defaults to — the activity's own date.
    let defaultWorkDate: Date
    /// The linked Work Task, when this device has it cached.
    let linkedTask: WorkTask?
    /// Legacy `pruning_activities.worker_or_crew` — free text, never split.
    let legacyWorker: String
    let legacyHours: Double?
    let legacyRate: Double?
    /// false renders read-only (no add, rows not tappable).
    let canEdit: Bool
    /// Non-nil lets the ONE labour sheet also choose Hourly or Piece Rate for
    /// the linked task, so pricing is never a second, separate surface.
    let costingContext: WorkTaskCostingContext?

    @State private var showAddLine: Bool = false
    @State private var editingLine: PruningActivityLabourLine?
    @State private var showConvertPrompt: Bool = false

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    /// The activity's OWN labour lines, in stable display order.
    private var lines: [PruningActivityLabourLine] {
        store.labourLines(forPruningActivity: activityId)
    }

    /// The LINKED task's labour lines — read only, and only ever a fallback.
    private var taskLines: [WorkTaskLabourLine] {
        guard let linkedTask else { return [] }
        return WorkTaskLabourCosting.lines(store.workTaskLabourLines, for: linkedTask.id)
    }

    private var resolved: PruningActivityLabourCosting.Resolved {
        PruningActivityLabourCosting.resolve(
            task: linkedTask,
            activityLines: lines,
            taskLines: taskLines,
            legacyHours: legacyHours,
            legacyRate: legacyRate,
            includeCost: canViewFinancials
        )
    }

    private var totals: PruningActivityLabourCosting.LabourTotals {
        PruningActivityLabourCosting.totals(lines)
    }

    var body: some View {
        Group {
            switch resolved.source {
            case .pieceRate:
                pieceRateSummary
            case .workTaskLines:
                workTaskFallbackRow
            case .activityHours:
                legacyRow
            case .pruningLabourLines, .none:
                EmptyView()
            }

            if lines.isEmpty {
                if resolved.source == .pruningLabourLines || resolved.source == .none {
                    Text(emptyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(lines) { line in
                    if canEdit {
                        Button { editingLine = line } label: { labourLineRow(line) }
                            .buttonStyle(.plain)
                    } else {
                        labourLineRow(line)
                    }
                }
                totalsRow
            }

            if canEdit {
                Button {
                    showAddLine = true
                } label: {
                    Label(addButtonTitle, systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                // Converting a legacy record is an explicit USER action. It is
                // offered, never performed automatically, because `worker_or_crew`
                // is free text ("Dave + 2 casuals") that cannot be honestly split
                // into a worker type and a crew size.
                if resolved.source == .activityHours, lines.isEmpty, legacyHours != nil {
                    Button {
                        showConvertPrompt = true
                    } label: {
                        Label("Convert to labour lines", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddLine) {
            AddEditPruningActivityLabourLineView(
                activityId: activityId,
                vineyardId: vineyardId,
                defaultWorkDate: defaultWorkDate,
                nextLineIndex: lines.count,
                costingContext: costingContext
            )
        }
        .sheet(item: $editingLine) { line in
            AddEditPruningActivityLabourLineView(
                activityId: line.pruningActivityId,
                vineyardId: line.vineyardId,
                existingLine: line,
                defaultWorkDate: line.workDate,
                nextLineIndex: line.lineIndex,
                costingContext: costingContext
            )
        }
        .alert("Convert to labour lines?", isPresented: $showConvertPrompt) {
            Button("Convert") { convertLegacy() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(convertMessage)
        }
    }

    // MARK: Empty + titles

    private var emptyMessage: String {
        canEdit
            ? "No labour lines yet. Add labour type, people and hours per person — one line per crew or rate."
            : "No labour recorded on this activity."
    }

    private var addButtonTitle: String {
        lines.isEmpty ? "Add labour" : "Add labour line"
    }

    private var convertMessage: String {
        let crew = legacyWorker.trimmingCharacters(in: .whitespacesAndNewlines)
        let hours = legacyHours.map { Self.hours($0) } ?? "the recorded hours"
        return "\(crew.isEmpty ? "The original crew record" : "\"\(crew)\"") becomes one labour line of \(hours). The original record is kept exactly as it is — nothing is overwritten — and you can then split it into separate lines per worker type."
    }

    private func convertLegacy() {
        guard let line = PruningActivityLabourCosting.legacyConversionLine(
            activityId: activityId,
            vineyardId: vineyardId,
            workDate: defaultWorkDate,
            workerOrCrew: legacyWorker,
            legacyHours: legacyHours,
            legacyRate: legacyRate
        ) else { return }
        store.addPruningActivityLabourLine(line)
    }

    // MARK: Rows

    @ViewBuilder
    private func labourLineRow(_ line: PruningActivityLabourLine) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(labourTypeName(line))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                Text(fmt.formatDate(line.workDate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Label(
                    "\(line.workerCount) × \(Self.decimal(line.hoursPerWorker)) h each",
                    systemImage: "person.2"
                )
                Text("\(Self.hours(PruningActivityLabourCosting.personHours(line))) person-hours")
                if canViewFinancials {
                    if let rate = line.hourlyRate {
                        Text("\(fmt.formatCurrency(rate))/h")
                        Text(
                            PruningActivityLabourCosting.lineCost(line)
                                .map { fmt.formatCurrency($0) } ?? "Not specified"
                        )
                        .fontWeight(.medium)
                    } else {
                        // An unrated line is real work, not a $0.00 cost. Its
                        // hours count; its money is simply unknown.
                        Text("No rate — hours only")
                    }
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var totalsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(totals.lineCount) labour line\(totals.lineCount == 1 ? "" : "s") · \(totals.workers) people")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(Self.hours(totals.personHours)) total labour hours")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let unrated = unratedNote {
                    Text(unrated)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            // On a piece-rate job the money belongs to the agreement above, so
            // the hourly total is deliberately not shown next to it.
            if canViewFinancials, resolved.source != .pieceRate {
                Text(totals.cost.map { fmt.formatCurrency($0) } ?? "Not specified")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
        }
        .padding(.vertical, 2)
    }

    /// Explains why hours and money can disagree: hours count every line, cost
    /// counts only the rated ones.
    private var unratedNote: String? {
        let unrated = lines.filter { !$0.isRated }.count
        guard unrated > 0 else { return nil }
        if unrated == lines.count {
            return "No rates entered — hours are recorded, cost is not specified."
        }
        return "\(unrated) line\(unrated == 1 ? "" : "s") without a rate: counted in hours, not in cost."
    }

    // MARK: Alternative sources

    /// THE piece-rate cost of this job, shown in place of an hourly total so the
    /// two are never presented as if they add up.
    @ViewBuilder
    private var pieceRateSummary: some View {
        if let linkedTask {
            let piece = PieceRateCosting.resolve(task: linkedTask, labourLines: taskLines)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Piece rate", systemImage: "scissors")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(VineyardTheme.leafGreen)
                    Spacer()
                    if canViewFinancials {
                        Text(piece.cost.map { fmt.formatCurrency($0) } ?? "Not specified")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(VineyardTheme.leafGreen)
                    }
                }
                if canViewFinancials, let vines = piece.vineCount, let rate = piece.ratePerVine {
                    Text("\(PieceRateCosting.vineCountLabel(vines)) vines × \(PieceRateCosting.rateLabel(rate)) per vine")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("This job is paid per vine. Hours below are recorded for productivity — they never change what it costs.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    /// Labour recorded on the linked Work Task before this activity owned any.
    /// Displayed READ-THROUGH — the rows live in one place and are never copied
    /// here, so the two modules cannot report the same money twice.
    @ViewBuilder
    private var workTaskFallbackRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("On the linked Work Task", systemImage: "link")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if canViewFinancials {
                    Text(resolved.cost.map { fmt.formatCurrency($0) } ?? "Not specified")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            Text("\(Self.hours(resolved.hours ?? 0)) person-hours across \(taskLines.count) line\(taskLines.count == 1 ? "" : "s"), recorded on the Work Task. Adding labour here makes this activity the record instead.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// A pre-SQL-190 single-crew record, shown EXACTLY as recorded. Never
    /// rewritten, never back-filled.
    @ViewBuilder
    private var legacyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Original crew record", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                if canViewFinancials {
                    Text(resolved.cost.map { fmt.formatCurrency($0) } ?? "Not specified")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
            }
            Text(legacySummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var legacySummary: String {
        var parts: [String] = []
        let crew = legacyWorker.trimmingCharacters(in: .whitespacesAndNewlines)
        if !crew.isEmpty { parts.append(crew) }
        if let legacyHours { parts.append(Self.hours(legacyHours)) }
        if canViewFinancials, let legacyRate { parts.append("\(fmt.formatCurrency(legacyRate))/h") }
        let head = parts.isEmpty ? "Recorded before labour lines existed." : parts.joined(separator: " · ")
        return head + " — kept exactly as recorded."
    }

    // MARK: Helpers

    private func labourTypeName(_ line: PruningActivityLabourLine) -> String {
        if let id = line.operatorCategoryId,
           let category = store.operatorCategories.first(where: { $0.id == id }) {
            return category.name
        }
        let trimmed = line.workerType.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Labour" : trimmed
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func hours(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + " h"
    }
}
