import Foundation

/// Read-only Portal order; the compatibility date never ranks an E-L task.
nonisolated enum WorkTaskPlanning {
    static var supportedStages: [Int] {
        GrowthStage.allStages.compactMap { Int($0.code.dropFirst(2)) }.filter { (1...43).contains($0) }
    }

    static func canSaveDraft(_ draft: WorkTaskPlanningDraft, signedInUser: UUID?, selectedVineyard: UUID?, membershipRole: String?) -> Bool {
        draft.isValid && draft.authorID == signedInUser && draft.vineyardID == selectedVineyard && ["owner", "manager", "supervisor", "operator"].contains(membershipRole ?? "")
    }

    static func canSelect(_ resource: VineyardExternalResource, vineyard: UUID) -> Bool {
        resource.vineyardId == vineyard && resource.isActive && resource.deletedAt == nil
    }

    static func ordered(_ tasks: [WorkTask], now: Date, timeZone: TimeZone) -> [WorkTask] {
        let today = WorkTaskCompletion.calendar(timeZone).startOfDay(for: now)
        return tasks.sorted { lhs, rhs in
            let lc = lhs.isFinalized
            let rc = rhs.isFinalized
            if lc != rc { return !lc }
            if lhs.isStageScheduled != rhs.isStageScheduled { return lhs.isStageScheduled }
            if lhs.isStageScheduled {
                if lhs.targetELStage != rhs.targetELStage { return (lhs.targetELStage ?? 0) > (rhs.targetELStage ?? 0) }
            } else {
                let ld = lhs.plannedDate ?? .distantPast
                let rd = rhs.plannedDate ?? .distantPast
                let lu = ld >= today
                let ru = rd >= today
                if lu != ru { return lu }
                if ld != rd { return lu ? ld < rd : ld > rd }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Hub-only projection; the full Task Log retains all history.\n    static func upcoming(_ tasks: [WorkTask], now: Date, timeZone: TimeZone) -> [WorkTask] {\n        let calendar = WorkTaskCompletion.calendar(timeZone)\n        let today = calendar.startOfDay(for: now)\n        return tasks.filter { task in\n            guard !task.isArchived && !task.isFinalized else { return false }\n            if task.isStageScheduled { return true }\n            guard let date = task.plannedDate else { return false }\n            return WorkTaskCompletion.businessDay(date, timeZone: timeZone) >= today\n        }.sorted { lhs, rhs in\n            if lhs.isStageScheduled != rhs.isStageScheduled { return lhs.isStageScheduled }\n            if lhs.isStageScheduled {\n                if lhs.targetELStage != rhs.targetELStage { return (lhs.targetELStage ?? 0) > (rhs.targetELStage ?? 0) }\n            } else {\n                let left = WorkTaskCompletion.businessDay(lhs.plannedDate!, timeZone: timeZone)\n                let right = WorkTaskCompletion.businessDay(rhs.plannedDate!, timeZone: timeZone)\n                if left != right { return left < right }\n            }\n            return lhs.id.uuidString < rhs.id.uuidString\n        }\n    }\n\n    static func completingUser(_ task: WorkTask, trips: [Trip], verifiedMemberIDs: Set<UUID>) -> UUID? {
        guard task.isFinalized else { return nil }
        if let recorded = task.completedBy { return recorded }
        let linked = trips.filter { $0.vineyardId == task.vineyardId && $0.workTaskId == task.id && !$0.isActive && $0.endTime != nil }
        let operators = Set(linked.compactMap(\.operatorUserId))
        if !linked.isEmpty, linked.allSatisfy({ $0.operatorUserId != nil }), operators.count == 1 { return operators.first }
        if let raw = task.finalizedBy, let id = UUID(uuidString: raw), verifiedMemberIDs.contains(id) { return id }
        return nil
    }
}

/// Local-only editor snapshot. It is deliberately not a sync payload or a canonical task.
nonisolated struct WorkTaskPlanningDraft: Codable, Equatable {
    var taskID: UUID?
    var vineyardID: UUID
    var authorID: UUID
    var assignedTo: UUID?
    var externalID: UUID?
    var assignmentName: String
    var scheduleBasis: String
    var targetStage: Int?
    var date: Date
    var endDate: Date?
    var taskType: String
    var blockIDs: Set<UUID>
    var durationText: String
    var notes: String
    var resources: [WorkTaskResource] = []
    /// Immutable original online read; drafts without one are never automatically rebased.
    var baselineJSON: String? = nil
    var creationID: UUID? = nil

    var isValid: Bool {
        !(assignedTo != nil && externalID != nil) && (scheduleBasis == "el_stage" || endDate.map { $0 >= date } != false) &&
        (scheduleBasis == "date" || (scheduleBasis == "el_stage" && targetStage.map { WorkTaskPlanning.supportedStages.contains($0) } == true))
    }

    var persistenceKey: String {
        "work-task-planning-\(authorID.uuidString)-\(vineyardID.uuidString)-\(taskID?.uuidString ?? "new")"
    }
}
