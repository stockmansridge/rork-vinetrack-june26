import Foundation
import Supabase

/// Online-only narrow PATCH of existing Work Task fields. Never queues or rebases a draft.
final class SupabaseWorkTaskPlanningRepository {
    private let provider: SupabaseClientProvider
    init(provider: SupabaseClientProvider = .shared) { self.provider = provider }

    static let observedKeys: [String] = [
        "id", "vineyard_id", "sync_version", "updated_at", "deleted_at", "is_archived",
        "assigned_to", "assigned_external_resource_id", "schedule_basis", "target_el_stage",
        "date", "start_date", "end_date", "vintage_year", "status", "is_finalized",
        "completed_by", "completed_at", "finalized_by", "finalized_at",
        "task_type", "description", "notes", "paddock_id", "paddock_name", "duration_hours"
    ]

    /// Capture only against the task originally loaded by the editor, not a new save-time read.
    func baseline(for task: WorkTask) async throws -> String {
        guard provider.isConfigured, let version = task.syncVersion, version > 0 else { throw WorkTaskPlanningWriteError.refresh }
        let data = try await provider.client.from("work_tasks").select(Self.observedKeys.joined(separator: ","))
            .eq("id", value: task.id.uuidString).eq("vineyard_id", value: task.vineyardId.uuidString)
            .eq("sync_version", value: String(version)).is("deleted_at", value: nil).execute().data
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], rows.count == 1,
              let row = rows.first, Self.observedKeys.allSatisfy({ row.keys.contains($0) }),
              uuid(row["assigned_to"]) == task.assignedTo,
              uuid(row["assigned_external_resource_id"]) == task.assignedExternalResourceId,
              row["schedule_basis"] as? String == task.scheduleBasis,
              (row["target_el_stage"] as? NSNumber)?.intValue == task.targetELStage,
              row["is_finalized"] as? Bool == task.isFinalized,
              uuid(row["completed_by"]) == task.completedBy,
              row["status"] as? String == task.status,
              row["task_type"] as? String == task.taskType, row["notes"] as? String == task.notes,
              uuid(row["paddock_id"]) == task.paddockId, row["paddock_name"] as? String == task.paddockName,
              (row["duration_hours"] as? NSNumber)?.doubleValue == task.durationHours,
              row["is_archived"] as? Bool == task.isArchived,
              instant(row["date"]) == task.date, instant(row["start_date"]) == task.startDate,
              instant(row["end_date"]) == task.endDate, instant(row["completed_at"]) == task.completedAt,
              instant(row["finalized_at"]) == task.finalizedAt, row["finalized_by"] as? String == task.finalizedBy else { throw WorkTaskPlanningWriteError.refresh }
        return String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Scope/version/all observed predicates are in the UPDATE itself, not a read-before-write check.
    func saveSelection(_ draft: WorkTaskPlanningDraft) async throws -> WorkTask {
        guard provider.isConfigured, draft.isValid, let id = draft.taskID, let raw = draft.baselineJSON,
              let data = raw.data(using: .utf8), let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.observedKeys.allSatisfy({ row.keys.contains($0) }), uuid(row["id"]) == id,
              uuid(row["vineyard_id"]) == draft.vineyardID, row["deleted_at"] is NSNull,
              let version = (row["sync_version"] as? NSNumber)?.int64Value, version > 0, version < Int64.max,
              row["schedule_basis"] as? String == draft.scheduleBasis else { throw WorkTaskPlanningWriteError.refresh }
        // This path does not change dates, vintage, lifecycle, commercial terms or child rows.
        guard provider.client.auth.currentUser?.id == draft.authorID else { throw BackendRepositoryError.missingAuthenticatedUser }
        let membershipData = try await provider.client.from("vineyard_members").select("role")
            .eq("vineyard_id", value: draft.vineyardID.uuidString).eq("user_id", value: draft.authorID.uuidString).execute().data
        guard let members = try JSONSerialization.jsonObject(with: membershipData) as? [[String: Any]], members.count == 1,
              let role = members.first?["role"] as? String, ["owner", "manager", "supervisor", "operator"].contains(role) else { throw WorkTaskPlanningWriteError.invalidResource }
        let assignmentChanged = uuid(row["assigned_to"]) != draft.assignedTo || uuid(row["assigned_external_resource_id"]) != draft.externalID
        let stageChanged = draft.scheduleBasis == "el_stage" && (row["target_el_stage"] as? NSNumber)?.intValue != draft.targetStage
        guard assignmentChanged || stageChanged else { throw WorkTaskPlanningWriteError.noChange }
        if assignmentChanged, let user = draft.assignedTo {
            let data = try await provider.client.from("vineyard_members").select("user_id")
                .eq("vineyard_id", value: draft.vineyardID.uuidString).eq("user_id", value: user.uuidString).execute().data
            guard let members = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], members.count == 1 else { throw WorkTaskPlanningWriteError.invalidResource }
        }
        if assignmentChanged, let external = draft.externalID {
            let resources = try await SupabaseExternalResourceRepository(provider: provider).list(vineyardId: draft.vineyardID)
            guard resources.contains(where: { $0.id == external && WorkTaskPlanning.canSelect($0, vineyard: draft.vineyardID) }) else { throw WorkTaskPlanningWriteError.invalidResource }
        }
        guard provider.client.auth.currentUser?.id == draft.authorID else { throw BackendRepositoryError.missingAuthenticatedUser }
        var query = try provider.client.from("work_tasks").update(WorkTaskSelectionPatch(
            assignmentChanged: assignmentChanged, assignedTo: draft.assignedTo, externalID: draft.externalID,
            stageChanged: stageChanged, stage: draft.targetStage, version: version + 1))
        for key in Self.observedKeys {
            if row[key] is NSNull { query = query.is(key, value: nil) }
            else if let value = row[key] as? String { query = query.eq(key, value: value) }
            else if let value = row[key] as? NSNumber { query = query.eq(key, value: value.stringValue) }
            else { throw WorkTaskPlanningWriteError.refresh }
        }
        let response: PostgrestResponse<[BackendWorkTask]> = try await query.select().execute()
        let rows = response.value
        guard let acknowledgements = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]],
              acknowledgements.count == 1, let acknowledgement = acknowledgements.first else { throw WorkTaskPlanningWriteError.conflict }
        let changedKeys: Set<String> = Set(["updated_at", "sync_version"])
            .union(assignmentChanged ? ["assigned_to", "assigned_external_resource_id"] : [])
            .union(stageChanged ? ["target_el_stage"] : [])
        for key in Self.observedKeys where !changedKeys.contains(key) {
            guard let expectedValue = row[key] as? NSObject, let actualValue = acknowledgement[key] as? NSObject,
                  expectedValue.isEqual(actualValue) else { throw WorkTaskPlanningWriteError.conflict }
        }
        guard provider.client.auth.currentUser?.id == draft.authorID, rows.count == 1, let saved = rows.first, saved.id == id, saved.vineyardId == draft.vineyardID,
              saved.syncVersion == version + 1, saved.assignedTo == draft.assignedTo,
              saved.assignedExternalResourceId == draft.externalID,
              !stageChanged || saved.targetELStage == draft.targetStage else { throw WorkTaskPlanningWriteError.conflict }
        return saved.toWorkTask()
    }

    private func instant(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }

    private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
}

/// Only deliberately changed selection fields are encoded; historical external links stay untouched.
nonisolated struct WorkTaskSelectionPatch: Encodable {
    let assignmentChanged: Bool
    let assignedTo: UUID?
    let externalID: UUID?
    let stageChanged: Bool
    let stage: Int?
    let version: Int64
    enum CodingKeys: String, CodingKey {
        case assignedTo = "assigned_to", externalID = "assigned_external_resource_id", stage = "target_el_stage", version = "sync_version"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if assignmentChanged { try c.encode(assignedTo, forKey: .assignedTo); try c.encode(externalID, forKey: .externalID) }
        if stageChanged { try c.encode(stage, forKey: .stage) }
        try c.encode(version, forKey: .version)
    }
}

nonisolated enum WorkTaskPlanningWriteError: LocalizedError {
    case refresh, conflict, invalidResource, noChange
    var errorDescription: String? {
        switch self {
        case .refresh: "Refresh the task before starting a new online selection edit. This draft has no matching original server baseline; it was not rebased or queued."
        case .conflict: "Task changed, permission was lost, or save was not acknowledged. Your local draft is retained. Review the server task before resolving; no automatic retry."
        case .invalidResource: "Choose a current vineyard member or active resource. Membership is checked online, but database membership enforcement remains incomplete."
        case .noChange: "No assignment or existing E-L target change to save. Other fields remain in the local draft."
        }
    }
}
