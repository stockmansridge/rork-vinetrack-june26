import SwiftUI

/// THE standard Work Task labour-line list + totals + add/edit surface. One
/// implementation, rendered by the Work Task editor AND the Pruning Activity
/// editor — the iOS twin of the Kotlin `WorkTaskLabourLinesSection`.
///
/// Labour belongs to the PARENT Work Task: labour type, hourly rate, number of
/// people, hours per person, person-hours and cost. A pruning allocation never
/// carries any of it, and this view never touches one.
///
/// Every figure comes from `WorkTaskLabourCosting`, which is mirrored 1:1 in
/// Kotlin, so the two platforms cannot disagree.
struct WorkTaskLabourLinesSection: View {
    @Environment(MigratedDataStore.self) private var store
    @Environment(\.accessControl) private var accessControl

    let workTaskId: UUID
    let vineyardId: UUID
    /// Date a new line defaults to — normally the task's own date.
    let defaultWorkDate: Date
    /// false renders read-only (no add, rows not tappable).
    let canEdit: Bool

    @State private var showAddLine: Bool = false
    @State private var editingLine: WorkTaskLabourLine?

    init(
        workTaskId: UUID,
        vineyardId: UUID,
        defaultWorkDate: Date = Date(),
        canEdit: Bool = true
    ) {
        self.workTaskId = workTaskId
        self.vineyardId = vineyardId
        self.defaultWorkDate = defaultWorkDate
        self.canEdit = canEdit
    }

    private var fmt: RegionFormatter { store.settings.regionFormatter }
    private var canViewFinancials: Bool { accessControl?.canViewFinancials ?? false }

    /// Live labour lines of THIS task, oldest first.
    var lines: [WorkTaskLabourLine] {
        WorkTaskLabourCosting.lines(store.workTaskLabourLines, for: workTaskId)
    }

    private var totals: WorkTaskLabourCosting.LabourTotals {
        WorkTaskLabourCosting.totals(lines)
    }

    var body: some View {
        Group {
            if lines.isEmpty {
                Text(canEdit
                     ? "No labour lines yet. Add labour type, people and hours per person to record the cost."
                     : "No labour lines recorded on this task.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(lines) { line in
                    if canEdit {
                        Button {
                            editingLine = line
                        } label: {
                            labourLineRow(line)
                        }
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
                    Label("Add labour line", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .sheet(isPresented: $showAddLine) {
            AddEditWorkTaskLabourLineView(
                workTaskId: workTaskId,
                vineyardId: vineyardId,
                defaultWorkDate: defaultWorkDate
            )
        }
        .sheet(item: $editingLine) { line in
            AddEditWorkTaskLabourLineView(
                workTaskId: line.workTaskId,
                vineyardId: line.vineyardId,
                existingLine: line,
                defaultWorkDate: line.workDate
            )
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func labourLineRow(_ line: WorkTaskLabourLine) -> some View {
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
                Text("\(Self.hours(WorkTaskLabourCosting.personHours(line))) person-hours")
                if canViewFinancials {
                    if let rate = line.hourlyRate {
                        Text("\(fmt.formatCurrency(rate))/h")
                        Text(WorkTaskLabourCosting.lineCost(line).map { fmt.formatCurrency($0) } ?? "Not specified")
                            .fontWeight(.medium)
                    } else {
                        Text("Rate: Not specified")
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
                Text("\(Self.hours(totals.personHours)) total person-hours")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Spacer()
            if canViewFinancials {
                Text(totals.cost.map { fmt.formatCurrency($0) } ?? "Not specified")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(VineyardTheme.leafGreen)
            }
        }
        .padding(.vertical, 2)
    }

    /// Display name: the linked labour type, then the stored snapshot, then a
    /// neutral fallback.
    private func labourTypeName(_ line: WorkTaskLabourLine) -> String {
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
