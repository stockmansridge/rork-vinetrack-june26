import Foundation
import Testing
@testable import VineTrack

@MainActor
struct WorkTaskLogPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_792_560_000)
    private static let utc = TimeZone(secondsFromGMT: 0)!
    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private struct Filters {
        var search = ""
        var task = ""
        var block = ""
        var minimum: Int?
        var maximum: Int?
    }

    @Test func everySortMatchesOriginalRowsAndStoreBackedDisplayValues() throws {
        try withStore { store in
            populate(store)
            for sort in WorkTaskLogView.SortOption.allCases {
                let result = make(store, sort: sort)
                assertEquivalent(result, store: store, sort: sort)
            }
        }
    }

    @Test func combinedFiltersKeepOriginalScopeAndEmptyResults() throws {
        try withStore { store in
            populate(store)
            let filters = [
                Filters(search: "pruning"),
                Filters(search: "E-L 35"),
                Filters(task: "Pruning 2", block: "Block 10", minimum: 12, maximum: 35),
                Filters(minimum: 35, maximum: 12),
                Filters(search: "not a matching task"),
                Filters(search: " ")
            ]
            for filter in filters {
                for sort in WorkTaskLogView.SortOption.allCases {
                    assertEquivalent(make(store, sort: sort, filters: filter), store: store, sort: sort, filters: filter)
                }
            }
            let empty = make(store, filters: Filters(minimum: 35, maximum: 12))
            #expect(empty.rows.isEmpty)
            #expect(empty.totalHours == 0 && empty.totalPeople == 0)
            #expect(empty.costs == WorkTaskLogPresentation.CostSummary(total: 0, hasIncompleteCost: false))
        }
    }

    @Test func equalSortKeysAndDuplicateIDsKeepEveryOriginalRow() throws {
        try withStore { store in
            let sharedID = id(1)
            store.workTasks = [
                WorkTask(id: sharedID, vineyardId: vineyard, date: Self.now, taskType: "Same", durationHours: 3, resources: [WorkTaskResource(hourlyRate: 1, count: 1)], notes: "First duplicate"),
                WorkTask(id: id(2), vineyardId: vineyard, date: Self.now, taskType: "Same", durationHours: 3, resources: [WorkTaskResource(hourlyRate: 1, count: 1)], notes: "Equal sort keys"),
                WorkTask(id: sharedID, vineyardId: vineyard, date: Self.now, taskType: "Same", durationHours: 3, resources: [WorkTaskResource(hourlyRate: 1, count: 1)], notes: "Second duplicate")
            ]
            for sort in WorkTaskLogView.SortOption.allCases {
                let result = make(store, sort: sort)
                assertEquivalent(result, store: store, sort: sort)
                #expect(result.rows.count == 3)
                #expect(result.rows.filter { $0.id == sharedID }.map { $0.task.notes } == ["First duplicate", "Second duplicate"])
            }
        }
    }

    @Test func costSortUsesOneRollupPerMatchingRowAndNeverPerComparison() {
        let tasks = (1...40).map { index in
            WorkTask(id: id(index), vineyardId: vineyard, date: Self.now, taskType: "Task", durationHours: Double(index), isArchived: index % 5 == 0)
        }
        var displayCalls: [UUID] = []
        var costCalls: [UUID] = []
        var materialFlags: [Bool] = []
        let result = WorkTaskLogPresentation.make(
            tasks: tasks, searchText: "", taskFilter: "", blockFilter: "",
            minimumStage: nil, maximumStage: nil, sort: .costDesc,
            now: Self.now, timeZone: Self.utc, canViewFinancials: true, includeMaterials: false,
            displayValues: { task, financials in
                displayCalls.append(task.id)
                #expect(financials)
                return .init(hours: task.durationHours, people: 1, blockLabel: "No block", costPerPerson: 0)
            },
            costRollup: { task, includeMaterials in
                costCalls.append(task.id)
                materialFlags.append(includeMaterials)
                return WorkTaskCostRollup.combine(
                    labourCost: Decimal(task.durationHours), manualMachineCost: 0,
                    linkedTripCost: 0, materialCost: 0, isComplete: true
                )
            }
        )
        let visible = tasks.filter { !$0.isArchived }
        #expect(displayCalls == visible.map(\.id))
        #expect(costCalls == visible.map(\.id))
        #expect(materialFlags == Array(repeating: false, count: visible.count))
        #expect(result.rows.map { $0.task.durationHours } == visible.map(\.durationHours).sorted(by: >))
        // Reading totals and rows reuses these values; it cannot call either closure.
        #expect(result.totalPeople == visible.count)
        #expect(result.costs?.total == visible.reduce(Decimal(0)) { $0 + Decimal($1.durationHours) })
        #expect(costCalls.count == visible.count)
    }

    @Test func hiddenFinancialsSkipRollupsUnlessCostOrderingNeedsThem() throws {
        try withStore { store in
            populate(store)
            for sort in WorkTaskLogView.SortOption.allCases {
                var count = 0
                let result = WorkTaskLogPresentation.make(
                    tasks: store.workTasks, searchText: "", taskFilter: "", blockFilter: "",
                    minimumStage: nil, maximumStage: nil, sort: sort,
                    now: Self.now, timeZone: Self.utc, canViewFinancials: false, includeMaterials: false,
                    displayValues: { task, financials in
                        #expect(!financials)
                        return .init(hours: task.displayHours(in: store), people: task.displayPeople(in: store), blockLabel: task.blockDisplay(in: store), costPerPerson: 0)
                    },
                    costRollup: { task, includeMaterials in
                        count += 1
                        return task.costRollup(in: store, includeMaterials: includeMaterials)
                    }
                )
                #expect(count == (sort == .costDesc ? result.rows.count : 0))
                #expect(result.costs == nil)
                #expect(result.rows.allSatisfy { $0.display.costPerPerson == 0 })
                #expect(result.rows.map(\.task) == referenceTasks(store, sort: sort, includeMaterials: false))
            }
        }
    }

    @Test func actualIncompletePieceRateMachineTripAndMaterialCostsRemainUnchanged() throws {
        try withStore { store in
            populate(store)
            let completePiece = WorkTask(id: id(20), vineyardId: vineyard, date: Self.now, taskType: "Piece complete", costingMethodRaw: "piece_rate", pieceRatePerVine: 0.125, pieceVineCount: 101)
            let incompletePiece = WorkTask(id: id(21), vineyardId: vineyard, date: Self.now, taskType: "Piece incomplete", costingMethodRaw: "piece_rate", pieceRatePerVine: nil, pieceVineCount: 101)
            let incompleteMachine = WorkTask(id: id(22), vineyardId: vineyard, date: Self.now, taskType: "Machine incomplete")
            let incompleteTrip = WorkTask(id: id(23), vineyardId: vineyard, date: Self.now, taskType: "Trip incomplete")
            store.workTasks += [completePiece, incompletePiece, incompleteMachine, incompleteTrip]
            store.workTaskMachineLines = [WorkTaskMachineLine(workTaskId: incompleteMachine.id, vineyardId: vineyard, fuelCost: nil, totalMachineCost: 35)]
            store.trips = [Trip(vineyardId: vineyard, endTime: Self.now, isActive: false, workTaskId: incompleteTrip.id)]
            let material = WorkTaskMaterial(workTaskId: completePiece.id, vineyardId: vineyard, materialName: "Wire", unit: "m", quantity: Decimal(string: "3.25")!, unitCost: Decimal(string: "1.17")!)
            store.workTaskMaterials = [material]
            for includeMaterials in [false, true] {
                let result = make(store, sort: .costDesc, includeMaterials: includeMaterials)
                assertEquivalent(result, store: store, sort: .costDesc, includeMaterials: includeMaterials)
                #expect(result.costs?.hasIncompleteCost == true)
                let row = try #require(result.rows.first { $0.id == completePiece.id })
                #expect(row.rollup?.labourCost == Decimal(string: "12.63"))
                #expect(row.rollup?.materialCost == (includeMaterials ? material.totalCost : 0))
                #expect(row.rollup?.isComplete == true)
                #expect(result.rows.first { $0.id == incompletePiece.id }?.rollup?.isComplete == false)
                #expect(result.rows.first { $0.id == incompleteMachine.id }?.rollup?.isComplete == false)
                #expect(result.rows.first { $0.id == incompleteTrip.id }?.rollup?.isComplete == false)
            }
        }
    }

    @Test func aNewEvaluationReadsChangedRecordsAndPermissionInputs() throws {
        try withStore { store in
            populate(store)
            let before = make(store)
            store.workTaskLabourLines[0].hoursPerWorker = 7
            store.workTaskLabourLines[0].hourlyRate = 39.5
            store.workTasks[0].paddockName = "Renamed block"
            let after = make(store)
            assertEquivalent(after, store: store, sort: .portal)
            #expect(after.totalHours != before.totalHours)
            #expect(after.costs != before.costs)
            #expect(before.rows.first { $0.id == store.workTasks[0].id }?.display.blockLabel != after.rows.first { $0.id == store.workTasks[0].id }?.display.blockLabel)
            let hidden = make(store, canViewFinancials: false)
            #expect(hidden.costs == nil && hidden.rows.allSatisfy { $0.rollup == nil && $0.display.costPerPerson == 0 })

            // A different current vineyard supplies a new collection, not a
            // result keyed only by a task ID from the previous evaluation.
            let otherVineyard = id(90)
            store.selectedVineyardId = otherVineyard
            store.workTasks = [WorkTask(id: id(91), vineyardId: otherVineyard, date: Self.now, durationHours: 0.5)]
            store.workTaskLabourLines = []
            let switched = make(store)
            #expect(switched.rows.map(\.id) == [id(91)])
            #expect(switched.totalHours == 0.5)
        }
    }

    @Test func defaultOrderingReevaluatesAtTheVineyardDayBoundary() throws {
        try withStore { store in
            let parse = ISO8601DateFormatter()
            let zone = try #require(TimeZone(identifier: "Australia/Sydney"))
            let before = try #require(parse.date(from: "2026-10-21T12:59:59Z"))
            let after = before.addingTimeInterval(1)
            let today = WorkTask(id: id(1), vineyardId: vineyard, date: try #require(parse.date(from: "2026-10-21T01:00:00Z")))
            let tomorrow = WorkTask(id: id(2), vineyardId: vineyard, date: try #require(parse.date(from: "2026-10-22T01:00:00Z")))
            let yesterday = WorkTask(id: id(3), vineyardId: vineyard, date: try #require(parse.date(from: "2026-10-20T01:00:00Z")))
            store.workTasks = [tomorrow, yesterday, today]
            let early = make(store, now: before, timeZone: zone)
            let late = make(store, now: after, timeZone: zone)
            #expect(early.rows.map(\.id) == [today.id, tomorrow.id, yesterday.id])
            #expect(late.rows.map(\.id) == [tomorrow.id, today.id, yesterday.id])
            #expect(make(store, now: after, timeZone: Self.utc).rows.map(\.id) == early.rows.map(\.id))
            #expect(late.rows.map(\.task) == WorkTaskPlanning.ordered(store.workTasks, now: after, timeZone: zone))
        }
    }

    // MARK: - Baseline contract and isolated fixtures

    /// Retains the original Task Log filtering/comparators as the comparison
    /// contract. Display assertions below call the unchanged production helpers.
    private func referenceTasks(_ store: MigratedDataStore, sort: WorkTaskLogView.SortOption, filters: Filters = Filters(), includeMaterials: Bool = true) -> [WorkTask] {
        var items = store.workTasks.filter { !$0.isArchived }
        if !filters.task.isEmpty { items = items.filter { $0.taskType == filters.task } }
        if !filters.block.isEmpty { items = items.filter { $0.paddockName == filters.block } }
        if !filters.search.isEmpty {
            items = items.filter {
                $0.taskType.localizedStandardContains(filters.search) || $0.paddockName.localizedStandardContains(filters.search) ||
                $0.notes.localizedStandardContains(filters.search) || ($0.stageLabel?.localizedStandardContains(filters.search) ?? false)
            }
        }
        items = items.filter { $0.matchesStageRange(minimum: filters.minimum, maximum: filters.maximum) }
        switch sort {
        case .portal: return WorkTaskPlanning.ordered(items, now: Self.now, timeZone: Self.utc)
        case .dateDesc: items.sort { $0.date > $1.date }
        case .dateAsc: items.sort { $0.date < $1.date }
        case .task: items.sort { $0.taskType.localizedStandardCompare($1.taskType) == .orderedAscending }
        case .block: items.sort { $0.paddockName.localizedStandardCompare($1.paddockName) == .orderedAscending }
        case .costDesc: items.sort { $0.costRollup(in: store, includeMaterials: includeMaterials).totalCost > $1.costRollup(in: store, includeMaterials: includeMaterials).totalCost }
        }
        return items
    }

    private func assertEquivalent(_ result: WorkTaskLogPresentation, store: MigratedDataStore, sort: WorkTaskLogView.SortOption, filters: Filters = Filters(), includeMaterials: Bool = true) {
        let tasks = referenceTasks(store, sort: sort, filters: filters, includeMaterials: includeMaterials)
        let rollups = tasks.map { $0.costRollup(in: store, includeMaterials: includeMaterials) }
        #expect(result.rows.map(\.task) == tasks)
        #expect(result.totalHours == tasks.reduce(0.0) { $0 + $1.displayHours(in: store) })
        #expect(result.totalPeople == tasks.reduce(0) { $0 + $1.displayPeople(in: store) })
        #expect(result.costs == WorkTaskLogPresentation.CostSummary(total: rollups.reduce(Decimal(0)) { $0 + $1.totalCost }, hasIncompleteCost: rollups.contains { !$0.isComplete }))
        for row in result.rows {
            let people = row.task.displayPeople(in: store)
            let perPerson = people > 0 ? row.task.displayLabourCost(in: store) / Double(people) : 0
            #expect(row.display == WorkTaskLogPresentation.DisplayValues(hours: row.task.displayHours(in: store), people: people, blockLabel: row.task.blockDisplay(in: store), costPerPerson: perPerson))
            #expect(row.rollup == row.task.costRollup(in: store, includeMaterials: includeMaterials))
        }
    }

    private func make(_ store: MigratedDataStore, sort: WorkTaskLogView.SortOption = .portal, filters: Filters = Filters(), canViewFinancials: Bool = true, includeMaterials: Bool = true, now: Date? = nil, timeZone: TimeZone? = nil) -> WorkTaskLogPresentation {
        WorkTaskLogPresentation.make(
            store: store, searchText: filters.search, taskFilter: filters.task, blockFilter: filters.block,
            minimumStage: filters.minimum, maximumStage: filters.maximum, sort: sort,
            now: now ?? Self.now, timeZone: timeZone ?? Self.utc,
            canViewFinancials: canViewFinancials, includeMaterials: includeMaterials
        )
    }

    private func populate(_ store: MigratedDataStore) {
        store.selectedVineyardId = vineyard
        store.workTasks = [
            WorkTask(id: id(4), vineyardId: vineyard, date: Self.now.addingTimeInterval(86_400), taskType: "Wire lifting", paddockId: id(80), paddockName: "Block 2", durationHours: 4, resources: [WorkTaskResource(hourlyRate: 12.345, count: 2)], notes: "Check the northern rows"),
            WorkTask(id: id(2), vineyardId: vineyard, date: Self.now, taskType: "Pruning 2", paddockName: "Block 10", durationHours: 3, scheduleBasis: "el_stage", targetELStage: 12),
            WorkTask(id: id(1), vineyardId: vineyard, date: Self.now.addingTimeInterval(-86_400), taskType: "Pruning 2", paddockName: "Block 10", durationHours: 1.25, resources: [WorkTaskResource(hourlyRate: 9.99, count: 1)], scheduleBasis: "el_stage", targetELStage: 35),
            WorkTask(id: id(3), vineyardId: vineyard, date: Self.now.addingTimeInterval(-172_800), taskType: "Past task", durationHours: 0.5),
            WorkTask(id: id(5), vineyardId: vineyard, date: Self.now, taskType: "Completed", isFinalized: true),
            WorkTask(id: id(6), vineyardId: vineyard, date: Self.now, taskType: "Archived", durationHours: 99, isArchived: true)
        ]
        store.workTaskLabourLines = [
            WorkTaskLabourLine(workTaskId: id(4), vineyardId: vineyard, workerType: "Crew", workerCount: 2, hoursPerWorker: 3, hourlyRate: 31.25),
            WorkTaskLabourLine(workTaskId: id(2), vineyardId: vineyard, workerType: "Missing price", workerCount: 1, hoursPerWorker: 2.25, hourlyRate: nil)
        ]
    }

    private func withStore(_ body: (MigratedDataStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("task-log-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MigratedDataStore(persistence: PersistenceStore(directory: directory))
        try body(store)
    }

    private func id(_ value: Int) -> UUID {
        let suffix = String(value)
        return UUID(uuidString: "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - suffix.count) + suffix)!
    }
}
