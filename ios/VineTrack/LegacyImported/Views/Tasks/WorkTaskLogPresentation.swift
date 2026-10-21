import Foundation

/// Temporary display values for one Task Log evaluation. No result survives a
/// subsequent view update, and these values never participate in a save or sync.
@MainActor
struct WorkTaskLogPresentation {
    nonisolated struct DisplayValues: Equatable, Sendable {
        let hours: Double
        let people: Int
        let blockLabel: String
        let costPerPerson: Double
    }

    nonisolated struct Row: Identifiable, Sendable {
        let task: WorkTask
        let display: DisplayValues
        let rollup: WorkTaskCostRollup.Result?

        // Keep the existing ForEach identity and multiplicity. In particular,
        // do not collapse legacy duplicate task IDs into a dictionary.
        var id: UUID { task.id }
    }

    nonisolated struct CostSummary: Equatable, Sendable {
        let total: Decimal
        let hasIncompleteCost: Bool
    }

    let rows: [Row]
    let totalHours: Double
    let totalPeople: Int
    let costs: CostSummary?

    static func make(
        store: MigratedDataStore,
        searchText: String,
        taskFilter: String,
        blockFilter: String,
        minimumStage: Int?,
        maximumStage: Int?,
        sort: WorkTaskLogView.SortOption,
        now: Date,
        timeZone: TimeZone,
        canViewFinancials: Bool,
        includeMaterials: Bool
    ) -> WorkTaskLogPresentation {
        make(
            tasks: store.workTasks,
            searchText: searchText,
            taskFilter: taskFilter,
            blockFilter: blockFilter,
            minimumStage: minimumStage,
            maximumStage: maximumStage,
            sort: sort,
            now: now,
            timeZone: timeZone,
            canViewFinancials: canViewFinancials,
            includeMaterials: includeMaterials,
            displayValues: { task, showFinancials in
                let people = task.displayPeople(in: store)
                return DisplayValues(
                    hours: task.displayHours(in: store),
                    people: people,
                    blockLabel: task.blockDisplay(in: store),
                    costPerPerson: showFinancials && people > 0
                        ? task.displayLabourCost(in: store) / Double(people) : 0
                )
            },
            costRollup: { task, includeMaterials in
                task.costRollup(in: store, includeMaterials: includeMaterials)
            }
        )
    }

    static func make(
        tasks: [WorkTask],
        searchText: String,
        taskFilter: String,
        blockFilter: String,
        minimumStage: Int?,
        maximumStage: Int?,
        sort: WorkTaskLogView.SortOption,
        now: Date,
        timeZone: TimeZone,
        canViewFinancials: Bool,
        includeMaterials: Bool,
        displayValues: (WorkTask, Bool) -> DisplayValues,
        costRollup: (WorkTask, Bool) -> WorkTaskCostRollup.Result
    ) -> WorkTaskLogPresentation {
        var items = tasks.filter { !$0.isArchived }
        if !taskFilter.isEmpty {
            items = items.filter { $0.taskType == taskFilter }
        }
        if !blockFilter.isEmpty {
            items = items.filter { $0.paddockName == blockFilter }
        }
        if !searchText.isEmpty {
            items = items.filter {
                $0.taskType.localizedStandardContains(searchText) ||
                $0.paddockName.localizedStandardContains(searchText) ||
                $0.notes.localizedStandardContains(searchText) ||
                ($0.stageLabel?.localizedStandardContains(searchText) ?? false)
            }
        }
        items = items.filter { $0.matchesStageRange(minimum: minimumStage, maximum: maximumStage) }

        // Keep each existing comparator and its original input order. The cost
        // comparator below uses prepared values; it never reruns the calculator.
        switch sort {
        case .portal:
            items = WorkTaskPlanning.ordered(items, now: now, timeZone: timeZone)
        case .dateDesc:
            items.sort { $0.date > $1.date }
        case .dateAsc:
            items.sort { $0.date < $1.date }
        case .task:
            items.sort { $0.taskType.localizedStandardCompare($1.taskType) == .orderedAscending }
        case .block:
            items.sort { $0.paddockName.localizedStandardCompare($1.paddockName) == .orderedAscending }
        case .costDesc:
            break
        }

        // Cost sorting remains available under the same permissions as before;
        // a hidden financial display alone does not remove that sort's inputs.
        let needsRollup = canViewFinancials || sort == .costDesc
        var rows = items.map { task in
            Row(
                task: task,
                display: displayValues(task, canViewFinancials),
                rollup: needsRollup ? costRollup(task, includeMaterials) : nil
            )
        }
        if sort == .costDesc {
            // Every row has a rollup in this branch, including incomplete costs.
            rows.sort { $0.rollup!.totalCost > $1.rollup!.totalCost }
        }

        // Sum in the final display order, matching the original computed totals
        // and preserving floating-point/Decimal accumulation order.
        let totalHours = rows.reduce(0.0) { $0 + $1.display.hours }
        let totalPeople = rows.reduce(0) { $0 + $1.display.people }
        let costs: CostSummary?
        if canViewFinancials {
            costs = CostSummary(
                total: rows.reduce(Decimal.zero) { $0 + $1.rollup!.totalCost },
                hasIncompleteCost: rows.contains { !$0.rollup!.isComplete }
            )
        } else {
            costs = nil
        }
        return WorkTaskLogPresentation(rows: rows, totalHours: totalHours, totalPeople: totalPeople, costs: costs)
    }
}
