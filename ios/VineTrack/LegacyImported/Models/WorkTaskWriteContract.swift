import Foundation

/// Scalar header values preserve omission versus deliberate null in conditional writes.
nonisolated enum WorkTaskWriteValue: Codable, Equatable {
    case null, string(String), integer(Int64), number(Double), boolean(Bool)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .boolean(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else { self = .string(try c.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        }
    }
    var filter: String? {
        switch self {
        case .null: nil
        case .string(let v): v
        case .integer(let v): String(v)
        case .number(let v): String(v)
        case .boolean(let v): v ? "true" : "false"
        }
    }
}

/// Persisted before network initiation; never consumed by legacy replay queues.
nonisolated struct WorkTaskWriteIntent: Codable {
    let taskID: UUID
    let vineyardID: UUID
    let authorID: UUID
    let baselineJSON: String?
    let payload: [String: WorkTaskWriteValue]
    var acknowledged: Bool = false
    var persistenceKey: String { "work-task-write-\(authorID)-\(vineyardID)-\(taskID)" }
}

/// Verified Portal contract at 2bed6ee35f44be381c5b5ae87dbae4c9c5065046.
nonisolated enum WorkTaskWriteContract {
    static func businessDate(_ date: Date, zone: TimeZone) -> String {
        let f = DateFormatter(); f.calendar = WorkTaskCompletion.calendar(zone)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func instant(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    static func schedule(basis: String, stage: Int?, date: Date, zone: TimeZone, existingDate: WorkTaskWriteValue?) throws -> [String: WorkTaskWriteValue] {
        guard basis == "date" || basis == "el_stage" else { throw WorkTaskPlanningWriteError.refresh }
        if basis == "el_stage" {
            guard let stage, WorkTaskPlanning.supportedStages.contains(stage) else { throw WorkTaskPlanningWriteError.refresh }
            var p: [String: WorkTaskWriteValue] = ["schedule_basis": .string(basis), "target_el_stage": .integer(Int64(stage)), "start_date": .null]
            if let existingDate { p["date"] = existingDate }
            return p
        }
        let day = WorkTaskWriteValue.string(businessDate(date, zone: zone))
        return ["schedule_basis": .string("date"), "target_el_stage": .null, "start_date": day, "date": day]
    }
    static func completion(action: String, task: WorkTask, selected: Date?, zone: TimeZone, now: Date, author: UUID) throws -> [String: WorkTaskWriteValue] {
        guard action == "complete" ? !task.isFinalized : task.isFinalized else { throw WorkTaskPlanningWriteError.conflict }
        if action == "reopen" {
            return ["is_finalized": .boolean(false), "end_date": .null, "finalized_at": .null, "finalized_by": .null, "completed_by": .null, "completed_at": .null]
        }
        guard ["complete", "completion_date"].contains(action), let selected,
              WorkTaskCompletion.isValid(selected, task: task, timeZone: zone, now: now) else { throw WorkTaskPlanningWriteError.refresh }
        var p: [String: WorkTaskWriteValue] = ["is_finalized": .boolean(true), "end_date": .string(businessDate(selected, zone: zone))]
        if action == "complete" {
            p["finalized_at"] = .string(instant(now)); p["completed_at"] = .string(instant(now))
            p["finalized_by"] = .string(author.uuidString); p["completed_by"] = .string(author.uuidString)
        }
        return p
    }
    static func planning(draft: WorkTaskPlanningDraft, id: UUID, zone: TimeZone, now: Date, paddockID: UUID?, paddockName: String, area: Double) throws -> WorkTaskWriteIntent {
        guard draft.isValid, !draft.taskType.trimmingCharacters(in: .whitespaces).isEmpty else { throw WorkTaskPlanningWriteError.refresh }
        let baseline = try draft.baselineJSON.map { try JSONDecoder().decode([String: WorkTaskWriteValue].self, from: Data($0.utf8)) }
        guard draft.taskID == nil || baseline != nil else { throw WorkTaskPlanningWriteError.refresh }
        var p: [String: WorkTaskWriteValue] = ["task_type": .string(draft.taskType), "notes": .string(draft.notes),
            "duration_hours": .number(Double(draft.durationText.replacingOccurrences(of: ",", with: ".")) ?? 0),
            "paddock_id": paddockID.map { .string($0.uuidString) } ?? .null, "paddock_name": .string(paddockName),
            "client_updated_at": .string(instant(now)), "updated_by": .string(draft.authorID.uuidString)]
        if baseline != nil, area > 0, !equivalent(baseline?["paddock_name"], p["paddock_name"], key: "paddock_name") { p["area_ha"] = .number(area) }
        let changedAssignment = baseline == nil || !equivalent(baseline?["assigned_to"], draft.assignedTo.map { .string($0.uuidString) } ?? .null, key: "assigned_to") || !equivalent(baseline?["assigned_external_resource_id"], draft.externalID.map { .string($0.uuidString) } ?? .null, key: "assigned_external_resource_id")
        if changedAssignment {
            p["assigned_to"] = draft.assignedTo.map { .string($0.uuidString) } ?? .null
            p["assigned_external_resource_id"] = draft.externalID.map { .string($0.uuidString) } ?? .null
        }
        let day = WorkTaskWriteValue.string(businessDate(draft.date, zone: zone))
        let scheduleChanged = baseline == nil || baseline?["schedule_basis"] != .string(draft.scheduleBasis) ||
            (draft.scheduleBasis == "el_stage" ? baseline?["target_el_stage"] != draft.targetStage.map { .integer(Int64($0)) } : !equivalent(baseline?["start_date"] == .null ? baseline?["date"] : baseline?["start_date"], day, key: "date"))
        if scheduleChanged { p.merge(try schedule(basis: draft.scheduleBasis, stage: draft.targetStage, date: draft.date, zone: zone, existingDate: baseline?["date"])) { _, v in v } }
        if let baseline {
            guard case .integer(let version) = baseline["sync_version"], version > 0, version < Int64.max else { throw WorkTaskPlanningWriteError.refresh }
            p["sync_version"] = .integer(version + 1)
        } else {
            p["id"] = .string(id.uuidString); p["vineyard_id"] = .string(draft.vineyardID.uuidString)
            p["sync_version"] = .integer(1); p["created_by"] = .string(draft.authorID.uuidString)
            p["is_finalized"] = .boolean(false); p["is_archived"] = .boolean(false); p["end_date"] = .null
            p["description"] = .string(""); p["deleted_at"] = .null; p["area_ha"] = .number(area)
        }
        return WorkTaskWriteIntent(taskID: id, vineyardID: draft.vineyardID, authorID: draft.authorID, baselineJSON: draft.baselineJSON, payload: p)
    }

    static func equivalent(_ a: WorkTaskWriteValue?, _ b: WorkTaskWriteValue?, key: String) -> Bool {
        guard let a, let b else { return false }
        if a == b { return true }
        if case .number(let x) = a, case .integer(let y) = b { return x == Double(y) }
        if case .integer(let x) = a, case .number(let y) = b { return Double(x) == y }
        if case .string(let x) = a, case .string(let y) = b {
            if ["date", "start_date", "end_date"].contains(key), x.count == 10 || y.count == 10 { return x.prefix(10) == y.prefix(10) }
            if key.hasSuffix("_at") || ["date", "start_date", "end_date"].contains(key) {
                let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let dx = f.date(from: x); let dy = f.date(from: y)
                f.formatOptions = [.withInternetDateTime]
                return (dx ?? f.date(from: x)).map { $0 == (dy ?? f.date(from: y)) } ?? false
            }
            if key == "id" || key.hasSuffix("_id") || ["assigned_to", "completed_by", "finalized_by", "updated_by", "created_by"].contains(key) {
                return UUID(uuidString: x).map { $0 == UUID(uuidString: y) } ?? false
            }
        }
        return false
    }
    static func predicates(baseline: [String: WorkTaskWriteValue], observedKeys: [String]) throws -> [(String, String?)] {
        guard observedKeys.allSatisfy({ baseline[$0] != nil }),
              case .integer(let version) = baseline["sync_version"], version > 0, version < Int64.max,
              baseline["deleted_at"] == .null else { throw WorkTaskPlanningWriteError.refresh }
        return observedKeys.map { ($0, baseline[$0]?.filter) }
    }

    static func verify(baseline: [String: WorkTaskWriteValue]?, payload: [String: WorkTaskWriteValue], row: [String: WorkTaskWriteValue], observedKeys: [String]) throws {
        for (key, value) in payload {
            guard equivalent(value, row[key], key: key) else { throw WorkTaskPlanningWriteError.conflict }
        }
        if let baseline {
            for key in observedKeys where payload[key] == nil && key != "updated_at" && !(key == "vintage_year" && payload["date"] != nil && !equivalent(payload["date"], baseline["date"], key: "date")) {
                guard equivalent(baseline[key], row[key], key: key) else { throw WorkTaskPlanningWriteError.conflict }
            }
        }
        guard case .integer = row["vintage_year"] else { throw WorkTaskPlanningWriteError.conflict }
    }
}
