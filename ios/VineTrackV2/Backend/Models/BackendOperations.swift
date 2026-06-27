import Foundation

// MARK: - Work Tasks

nonisolated struct BackendWorkTask: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let paddockName: String?
    let date: Date?
    let taskType: String?
    let durationHours: Double?
    let resources: [WorkTaskResource]?
    let notes: String?
    let isArchived: Bool?
    let archivedAt: Date?
    let archivedBy: String?
    let isFinalized: Bool?
    let finalizedAt: Date?
    let finalizedBy: String?
    // Phase 16 additive parent fields (sql/050).
    let startDate: Date?
    let endDate: Date?
    let areaHa: Double?
    let taskDescription: String?
    let status: String?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case date
        case taskType = "task_type"
        case durationHours = "duration_hours"
        case resources
        case notes
        case isArchived = "is_archived"
        case archivedAt = "archived_at"
        case archivedBy = "archived_by"
        case isFinalized = "is_finalized"
        case finalizedAt = "finalized_at"
        case finalizedBy = "finalized_by"
        case startDate = "start_date"
        case endDate = "end_date"
        case areaHa = "area_ha"
        case taskDescription = "description"
        case status
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendWorkTaskUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let paddockName: String
    let date: Date
    let taskType: String
    let durationHours: Double
    let resources: [WorkTaskResource]
    let notes: String
    let isArchived: Bool
    let archivedAt: Date?
    let archivedBy: String?
    let isFinalized: Bool
    let finalizedAt: Date?
    let finalizedBy: String?
    // Phase 16 additive parent fields. Encoded only when non-nil so iOS
    // writes never overwrite portal-set values with NULL.
    let startDate: Date?
    let endDate: Date?
    let areaHa: Double?
    let taskDescription: String?
    let status: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case paddockName = "paddock_name"
        case date
        case taskType = "task_type"
        case durationHours = "duration_hours"
        case resources
        case notes
        case isArchived = "is_archived"
        case archivedAt = "archived_at"
        case archivedBy = "archived_by"
        case isFinalized = "is_finalized"
        case finalizedAt = "finalized_at"
        case finalizedBy = "finalized_by"
        case startDate = "start_date"
        case endDate = "end_date"
        case areaHa = "area_ha"
        case taskDescription = "description"
        case status
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encodeIfPresent(paddockId, forKey: .paddockId)
        try c.encode(paddockName, forKey: .paddockName)
        try c.encode(date, forKey: .date)
        try c.encode(taskType, forKey: .taskType)
        try c.encode(durationHours, forKey: .durationHours)
        try c.encode(resources, forKey: .resources)
        try c.encode(notes, forKey: .notes)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(archivedBy, forKey: .archivedBy)
        try c.encode(isFinalized, forKey: .isFinalized)
        try c.encodeIfPresent(finalizedAt, forKey: .finalizedAt)
        try c.encodeIfPresent(finalizedBy, forKey: .finalizedBy)
        try c.encodeIfPresent(startDate, forKey: .startDate)
        try c.encodeIfPresent(endDate, forKey: .endDate)
        try c.encodeIfPresent(areaHa, forKey: .areaHa)
        try c.encodeIfPresent(taskDescription, forKey: .taskDescription)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendWorkTask {
    static func upsert(from t: WorkTask, createdBy: UUID?, clientUpdatedAt: Date) -> BackendWorkTaskUpsert {
        BackendWorkTaskUpsert(
            id: t.id,
            vineyardId: t.vineyardId,
            paddockId: t.paddockId,
            paddockName: t.paddockName,
            date: t.date,
            taskType: t.taskType,
            durationHours: t.durationHours,
            resources: t.resources,
            notes: t.notes,
            isArchived: t.isArchived,
            archivedAt: t.archivedAt,
            archivedBy: t.archivedBy,
            isFinalized: t.isFinalized,
            finalizedAt: t.finalizedAt,
            finalizedBy: t.finalizedBy,
            startDate: t.startDate,
            endDate: t.endDate,
            areaHa: t.areaHa,
            taskDescription: t.taskDescription,
            status: t.status,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toWorkTask() -> WorkTask {
        WorkTask(
            id: id,
            vineyardId: vineyardId,
            date: date ?? Date(),
            taskType: taskType ?? "",
            paddockId: paddockId,
            paddockName: paddockName ?? "",
            durationHours: durationHours ?? 0,
            resources: resources ?? [],
            notes: notes ?? "",
            createdBy: createdBy?.uuidString,
            isArchived: isArchived ?? false,
            archivedAt: archivedAt,
            archivedBy: archivedBy,
            isFinalized: isFinalized ?? false,
            finalizedAt: finalizedAt,
            finalizedBy: finalizedBy,
            startDate: startDate,
            endDate: endDate,
            areaHa: areaHa,
            taskDescription: taskDescription,
            status: status
        )
    }
}

// MARK: - Work Task Labour Lines (Phase 16)

nonisolated struct BackendWorkTaskLabourLine: Codable, Sendable, Identifiable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let workDate: Date?
    let operatorCategoryId: UUID?
    let workerType: String?
    let workerCount: Int?
    let hoursPerWorker: Double?
    let hourlyRate: Double?
    let totalHours: Double?
    let totalCost: Double?
    let notes: String?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case workDate = "work_date"
        case operatorCategoryId = "operator_category_id"
        case workerType = "worker_type"
        case workerCount = "worker_count"
        case hoursPerWorker = "hours_per_worker"
        case hourlyRate = "hourly_rate"
        case totalHours = "total_hours"
        case totalCost = "total_cost"
        case notes
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    // Per-row resilient decode: tolerate missing optional fields and
    // string-encoded dates from PostgREST so one malformed row does not
    // break sync for the rest of the vineyard's labour lines.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.workDate = Self.flexibleDate(c, .workDate)
        self.operatorCategoryId = try c.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        self.workerType = try c.decodeIfPresent(String.self, forKey: .workerType)
        self.workerCount = try c.decodeIfPresent(Int.self, forKey: .workerCount)
        self.hoursPerWorker = try c.decodeIfPresent(Double.self, forKey: .hoursPerWorker)
        self.hourlyRate = try c.decodeIfPresent(Double.self, forKey: .hourlyRate)
        self.totalHours = try c.decodeIfPresent(Double.self, forKey: .totalHours)
        self.totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        self.createdAt = Self.flexibleDate(c, .createdAt)
        self.updatedAt = Self.flexibleDate(c, .updatedAt)
        self.deletedAt = Self.flexibleDate(c, .deletedAt)
        self.clientUpdatedAt = Self.flexibleDate(c, .clientUpdatedAt)
    }

    private static func flexibleDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }
}

nonisolated struct BackendWorkTaskLabourLineUpsert: Encodable, Sendable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let workDate: Date
    let operatorCategoryId: UUID?
    let workerType: String
    let workerCount: Int
    let hoursPerWorker: Double
    let hourlyRate: Double?
    let notes: String
    let createdBy: UUID?
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case workDate = "work_date"
        case operatorCategoryId = "operator_category_id"
        case workerType = "worker_type"
        case workerCount = "worker_count"
        case hoursPerWorker = "hours_per_worker"
        case hourlyRate = "hourly_rate"
        case notes
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }

    // work_date is encoded as `yyyy-MM-dd` to match the SQL `date` column.
    private static let workDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workTaskId, forKey: .workTaskId)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(Self.workDateFormatter.string(from: workDate), forKey: .workDate)
        try c.encodeIfPresent(operatorCategoryId, forKey: .operatorCategoryId)
        try c.encode(workerType, forKey: .workerType)
        try c.encode(workerCount, forKey: .workerCount)
        try c.encode(hoursPerWorker, forKey: .hoursPerWorker)
        try c.encodeIfPresent(hourlyRate, forKey: .hourlyRate)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(updatedBy, forKey: .updatedBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendWorkTaskLabourLine {
    static func upsert(
        from l: WorkTaskLabourLine,
        createdBy: UUID?,
        updatedBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendWorkTaskLabourLineUpsert {
        BackendWorkTaskLabourLineUpsert(
            id: l.id,
            workTaskId: l.workTaskId,
            vineyardId: l.vineyardId,
            workDate: l.workDate,
            operatorCategoryId: l.operatorCategoryId,
            workerType: l.workerType,
            workerCount: l.workerCount,
            hoursPerWorker: l.hoursPerWorker,
            hourlyRate: l.hourlyRate,
            notes: l.notes,
            createdBy: createdBy,
            updatedBy: updatedBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toWorkTaskLabourLine() -> WorkTaskLabourLine {
        WorkTaskLabourLine(
            id: id,
            workTaskId: workTaskId,
            vineyardId: vineyardId,
            workDate: workDate ?? Date(),
            operatorCategoryId: operatorCategoryId,
            workerType: workerType ?? "",
            workerCount: workerCount ?? 1,
            hoursPerWorker: hoursPerWorker ?? 0,
            hourlyRate: hourlyRate,
            notes: notes ?? ""
        )
    }
}

// MARK: - Work Task Machine Lines (Step 1C)

nonisolated struct BackendWorkTaskMachineLine: Codable, Sendable, Identifiable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let workDate: Date?
    let equipmentSource: String?
    let equipmentRefId: UUID?
    let equipmentNameSnapshot: String?
    let operatorUserId: UUID?
    let operatorCategoryId: UUID?
    let durationHours: Double?
    let startTime: Date?
    let endTime: Date?
    let startEngineHours: Double?
    let endEngineHours: Double?
    let engineHoursUsed: Double?
    let fuelLitres: Double?
    let fuelCost: Double?
    let hourlyMachineRate: Double?
    let totalMachineCost: Double?
    let entrySource: String?
    let notes: String?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case workDate = "work_date"
        case equipmentSource = "equipment_source"
        case equipmentRefId = "equipment_ref_id"
        case equipmentNameSnapshot = "equipment_name_snapshot"
        case operatorUserId = "operator_user_id"
        case operatorCategoryId = "operator_category_id"
        case durationHours = "duration_hours"
        case startTime = "start_time"
        case endTime = "end_time"
        case startEngineHours = "start_engine_hours"
        case endEngineHours = "end_engine_hours"
        case engineHoursUsed = "engine_hours_used"
        case fuelLitres = "fuel_litres"
        case fuelCost = "fuel_cost"
        case hourlyMachineRate = "hourly_machine_rate"
        case totalMachineCost = "total_machine_cost"
        case entrySource = "entry_source"
        case notes
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    // Per-row resilient decode: tolerate missing optional fields and
    // string-encoded dates so one malformed row does not break sync for the
    // rest of the vineyard's machine lines.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.workDate = Self.flexibleDate(c, .workDate)
        self.equipmentSource = try c.decodeIfPresent(String.self, forKey: .equipmentSource)
        self.equipmentRefId = try c.decodeIfPresent(UUID.self, forKey: .equipmentRefId)
        self.equipmentNameSnapshot = try c.decodeIfPresent(String.self, forKey: .equipmentNameSnapshot)
        self.operatorUserId = try c.decodeIfPresent(UUID.self, forKey: .operatorUserId)
        self.operatorCategoryId = try c.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        self.durationHours = try c.decodeIfPresent(Double.self, forKey: .durationHours)
        self.startTime = Self.flexibleDate(c, .startTime)
        self.endTime = Self.flexibleDate(c, .endTime)
        self.startEngineHours = try c.decodeIfPresent(Double.self, forKey: .startEngineHours)
        self.endEngineHours = try c.decodeIfPresent(Double.self, forKey: .endEngineHours)
        self.engineHoursUsed = try c.decodeIfPresent(Double.self, forKey: .engineHoursUsed)
        self.fuelLitres = try c.decodeIfPresent(Double.self, forKey: .fuelLitres)
        self.fuelCost = try c.decodeIfPresent(Double.self, forKey: .fuelCost)
        self.hourlyMachineRate = try c.decodeIfPresent(Double.self, forKey: .hourlyMachineRate)
        self.totalMachineCost = try c.decodeIfPresent(Double.self, forKey: .totalMachineCost)
        self.entrySource = try c.decodeIfPresent(String.self, forKey: .entrySource)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        self.createdAt = Self.flexibleDate(c, .createdAt)
        self.updatedAt = Self.flexibleDate(c, .updatedAt)
        self.deletedAt = Self.flexibleDate(c, .deletedAt)
        self.clientUpdatedAt = Self.flexibleDate(c, .clientUpdatedAt)
    }

    private static func flexibleDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }
}

nonisolated struct BackendWorkTaskMachineLineUpsert: Encodable, Sendable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let workDate: Date
    let equipmentSource: String?
    let equipmentRefId: UUID?
    let equipmentNameSnapshot: String
    let operatorUserId: UUID?
    let operatorCategoryId: UUID?
    let durationHours: Double?
    let startTime: Date?
    let endTime: Date?
    let startEngineHours: Double?
    let endEngineHours: Double?
    let engineHoursUsed: Double?
    let fuelLitres: Double?
    let fuelCost: Double?
    let hourlyMachineRate: Double?
    let totalMachineCost: Double?
    let entrySource: String
    let notes: String
    let createdBy: UUID?
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case workDate = "work_date"
        case equipmentSource = "equipment_source"
        case equipmentRefId = "equipment_ref_id"
        case equipmentNameSnapshot = "equipment_name_snapshot"
        case operatorUserId = "operator_user_id"
        case operatorCategoryId = "operator_category_id"
        case durationHours = "duration_hours"
        case startTime = "start_time"
        case endTime = "end_time"
        case startEngineHours = "start_engine_hours"
        case endEngineHours = "end_engine_hours"
        case engineHoursUsed = "engine_hours_used"
        case fuelLitres = "fuel_litres"
        case fuelCost = "fuel_cost"
        case hourlyMachineRate = "hourly_machine_rate"
        case totalMachineCost = "total_machine_cost"
        case entrySource = "entry_source"
        case notes
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }

    // work_date is encoded as `yyyy-MM-dd` to match the SQL `date` column.
    private static let workDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workTaskId, forKey: .workTaskId)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(Self.workDateFormatter.string(from: workDate), forKey: .workDate)
        try c.encodeIfPresent(equipmentSource, forKey: .equipmentSource)
        try c.encodeIfPresent(equipmentRefId, forKey: .equipmentRefId)
        try c.encode(equipmentNameSnapshot, forKey: .equipmentNameSnapshot)
        try c.encodeIfPresent(operatorUserId, forKey: .operatorUserId)
        try c.encodeIfPresent(operatorCategoryId, forKey: .operatorCategoryId)
        try c.encodeIfPresent(durationHours, forKey: .durationHours)
        try c.encodeIfPresent(startTime, forKey: .startTime)
        try c.encodeIfPresent(endTime, forKey: .endTime)
        try c.encodeIfPresent(startEngineHours, forKey: .startEngineHours)
        try c.encodeIfPresent(endEngineHours, forKey: .endEngineHours)
        try c.encodeIfPresent(engineHoursUsed, forKey: .engineHoursUsed)
        try c.encodeIfPresent(fuelLitres, forKey: .fuelLitres)
        try c.encodeIfPresent(fuelCost, forKey: .fuelCost)
        try c.encodeIfPresent(hourlyMachineRate, forKey: .hourlyMachineRate)
        try c.encodeIfPresent(totalMachineCost, forKey: .totalMachineCost)
        try c.encode(entrySource, forKey: .entrySource)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(updatedBy, forKey: .updatedBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendWorkTaskMachineLine {
    static func upsert(
        from l: WorkTaskMachineLine,
        createdBy: UUID?,
        updatedBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendWorkTaskMachineLineUpsert {
        BackendWorkTaskMachineLineUpsert(
            id: l.id,
            workTaskId: l.workTaskId,
            vineyardId: l.vineyardId,
            workDate: l.workDate,
            equipmentSource: l.equipmentSource,
            equipmentRefId: l.equipmentRefId,
            equipmentNameSnapshot: l.equipmentNameSnapshot,
            operatorUserId: l.operatorUserId,
            operatorCategoryId: l.operatorCategoryId,
            durationHours: l.durationHours,
            startTime: l.startTime,
            endTime: l.endTime,
            startEngineHours: l.startEngineHours,
            endEngineHours: l.endEngineHours,
            engineHoursUsed: l.engineHoursUsed,
            fuelLitres: l.fuelLitres,
            fuelCost: l.fuelCost,
            hourlyMachineRate: l.hourlyMachineRate,
            totalMachineCost: l.totalMachineCost,
            entrySource: l.entrySource,
            notes: l.notes,
            createdBy: createdBy,
            updatedBy: updatedBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toWorkTaskMachineLine() -> WorkTaskMachineLine {
        WorkTaskMachineLine(
            id: id,
            workTaskId: workTaskId,
            vineyardId: vineyardId,
            workDate: workDate ?? Date(),
            equipmentSource: equipmentSource,
            equipmentRefId: equipmentRefId,
            equipmentNameSnapshot: equipmentNameSnapshot ?? "",
            operatorUserId: operatorUserId,
            operatorCategoryId: operatorCategoryId,
            durationHours: durationHours,
            startTime: startTime,
            endTime: endTime,
            startEngineHours: startEngineHours,
            endEngineHours: endEngineHours,
            engineHoursUsed: engineHoursUsed,
            fuelLitres: fuelLitres,
            fuelCost: fuelCost,
            hourlyMachineRate: hourlyMachineRate,
            totalMachineCost: totalMachineCost,
            entrySource: entrySource ?? "manual",
            notes: notes ?? ""
        )
    }
}

// MARK: - Work Task Paddocks (Phase 17)

nonisolated struct BackendWorkTaskPaddock: Codable, Sendable, Identifiable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let areaHa: Double?
    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case areaHa = "area_ha"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    // Per-row resilient decode: tolerate missing optional fields and
    // string-encoded dates from PostgREST so one malformed row does not
    // break sync for the rest of the vineyard's join rows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.workTaskId = try c.decode(UUID.self, forKey: .workTaskId)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.paddockId = try c.decode(UUID.self, forKey: .paddockId)
        self.areaHa = try c.decodeIfPresent(Double.self, forKey: .areaHa)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.updatedBy = try c.decodeIfPresent(UUID.self, forKey: .updatedBy)
        self.createdAt = Self.flexibleDate(c, .createdAt)
        self.updatedAt = Self.flexibleDate(c, .updatedAt)
        self.deletedAt = Self.flexibleDate(c, .deletedAt)
        self.clientUpdatedAt = Self.flexibleDate(c, .clientUpdatedAt)
    }

    private static func flexibleDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }
}

nonisolated struct BackendWorkTaskPaddockUpsert: Encodable, Sendable {
    let id: UUID
    let workTaskId: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let areaHa: Double?
    let createdBy: UUID?
    let updatedBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case workTaskId = "work_task_id"
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case areaHa = "area_ha"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(workTaskId, forKey: .workTaskId)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(paddockId, forKey: .paddockId)
        try c.encodeIfPresent(areaHa, forKey: .areaHa)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encodeIfPresent(updatedBy, forKey: .updatedBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendWorkTaskPaddock {
    static func upsert(
        from p: WorkTaskPaddock,
        createdBy: UUID?,
        updatedBy: UUID?,
        clientUpdatedAt: Date
    ) -> BackendWorkTaskPaddockUpsert {
        BackendWorkTaskPaddockUpsert(
            id: p.id,
            workTaskId: p.workTaskId,
            vineyardId: p.vineyardId,
            paddockId: p.paddockId,
            areaHa: p.areaHa,
            createdBy: createdBy,
            updatedBy: updatedBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toWorkTaskPaddock() -> WorkTaskPaddock {
        WorkTaskPaddock(
            id: id,
            workTaskId: workTaskId,
            vineyardId: vineyardId,
            paddockId: paddockId,
            areaHa: areaHa
        )
    }
}

// MARK: - Maintenance Logs

nonisolated struct BackendMaintenanceLog: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let itemName: String?
    let equipmentSource: String?
    let equipmentRefId: UUID?
    let hours: Double?
    let machineHours: Double?
    let workCompleted: String?
    let partsUsed: String?
    let partsCost: Double?
    let labourCost: Double?
    let date: Date?
    let photoPath: String?
    let isArchived: Bool?
    let archivedAt: Date?
    let archivedBy: String?
    let isFinalized: Bool?
    let finalizedAt: Date?
    let finalizedBy: String?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case itemName = "item_name"
        case equipmentSource = "equipment_source"
        case equipmentRefId = "equipment_ref_id"
        case hours
        case machineHours = "machine_hours"
        case workCompleted = "work_completed"
        case partsUsed = "parts_used"
        case partsCost = "parts_cost"
        case labourCost = "labour_cost"
        case date
        case photoPath = "photo_path"
        case isArchived = "is_archived"
        case archivedAt = "archived_at"
        case archivedBy = "archived_by"
        case isFinalized = "is_finalized"
        case finalizedAt = "finalized_at"
        case finalizedBy = "finalized_by"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendMaintenanceLogUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let itemName: String
    let equipmentSource: String?
    let equipmentRefId: UUID?
    let hours: Double
    let machineHours: Double?
    let workCompleted: String
    let partsUsed: String
    let partsCost: Double
    let labourCost: Double
    let date: Date
    let photoPath: String?
    let isArchived: Bool
    let archivedAt: Date?
    let archivedBy: String?
    let isFinalized: Bool
    let finalizedAt: Date?
    let finalizedBy: String?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case itemName = "item_name"
        case equipmentSource = "equipment_source"
        case equipmentRefId = "equipment_ref_id"
        case hours
        case machineHours = "machine_hours"
        case workCompleted = "work_completed"
        case partsUsed = "parts_used"
        case partsCost = "parts_cost"
        case labourCost = "labour_cost"
        case date
        case photoPath = "photo_path"
        case isArchived = "is_archived"
        case archivedAt = "archived_at"
        case archivedBy = "archived_by"
        case isFinalized = "is_finalized"
        case finalizedAt = "finalized_at"
        case finalizedBy = "finalized_by"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(itemName, forKey: .itemName)
        try c.encodeIfPresent(equipmentSource, forKey: .equipmentSource)
        try c.encodeIfPresent(equipmentRefId, forKey: .equipmentRefId)
        try c.encode(hours, forKey: .hours)
        try c.encodeIfPresent(machineHours, forKey: .machineHours)
        try c.encode(workCompleted, forKey: .workCompleted)
        try c.encode(partsUsed, forKey: .partsUsed)
        try c.encode(partsCost, forKey: .partsCost)
        try c.encode(labourCost, forKey: .labourCost)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(photoPath, forKey: .photoPath)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(archivedAt, forKey: .archivedAt)
        try c.encodeIfPresent(archivedBy, forKey: .archivedBy)
        try c.encode(isFinalized, forKey: .isFinalized)
        try c.encodeIfPresent(finalizedAt, forKey: .finalizedAt)
        try c.encodeIfPresent(finalizedBy, forKey: .finalizedBy)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendMaintenanceLog {
    static func upsert(from m: MaintenanceLog, createdBy: UUID?, clientUpdatedAt: Date) -> BackendMaintenanceLogUpsert {
        BackendMaintenanceLogUpsert(
            id: m.id,
            vineyardId: m.vineyardId,
            itemName: m.itemName,
            equipmentSource: m.equipmentSource,
            equipmentRefId: m.equipmentRefId,
            hours: m.hours,
            machineHours: m.machineHours,
            workCompleted: m.workCompleted,
            partsUsed: m.partsUsed,
            partsCost: m.partsCost,
            labourCost: m.labourCost,
            date: m.date,
            photoPath: m.photoPath,
            isArchived: m.isArchived,
            archivedAt: m.archivedAt,
            archivedBy: m.archivedBy,
            isFinalized: m.isFinalized,
            finalizedAt: m.finalizedAt,
            finalizedBy: m.finalizedBy,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toMaintenanceLog(preservingPhoto: Data? = nil) -> MaintenanceLog {
        MaintenanceLog(
            id: id,
            vineyardId: vineyardId,
            itemName: itemName ?? "",
            equipmentSource: equipmentSource,
            equipmentRefId: equipmentRefId,
            hours: hours ?? 0,
            machineHours: machineHours,
            workCompleted: workCompleted ?? "",
            partsUsed: partsUsed ?? "",
            partsCost: partsCost ?? 0,
            labourCost: labourCost ?? 0,
            date: date ?? Date(),
            invoicePhotoData: preservingPhoto,
            photoPath: photoPath,
            createdBy: createdBy?.uuidString,
            isArchived: isArchived ?? false,
            archivedAt: archivedAt,
            archivedBy: archivedBy,
            isFinalized: isFinalized ?? false,
            finalizedAt: finalizedAt,
            finalizedBy: finalizedBy
        )
    }
}

// MARK: - Yield Estimation Sessions

nonisolated struct BackendYieldEstimationSession: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let payload: YieldEstimationSession?
    let isCompleted: Bool?
    let completedAt: Date?
    let sessionCreatedAt: Date?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case payload
        case isCompleted = "is_completed"
        case completedAt = "completed_at"
        case sessionCreatedAt = "session_created_at"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendYieldEstimationSessionUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let payload: YieldEstimationSession
    let isCompleted: Bool
    let completedAt: Date?
    let sessionCreatedAt: Date
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case payload
        case isCompleted = "is_completed"
        case completedAt = "completed_at"
        case sessionCreatedAt = "session_created_at"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendYieldEstimationSession {
    static func upsert(from s: YieldEstimationSession, createdBy: UUID?, clientUpdatedAt: Date) -> BackendYieldEstimationSessionUpsert {
        BackendYieldEstimationSessionUpsert(
            id: s.id,
            vineyardId: s.vineyardId,
            payload: s,
            isCompleted: s.isCompleted,
            completedAt: s.completedAt,
            sessionCreatedAt: s.createdAt,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toYieldEstimationSession() -> YieldEstimationSession? {
        payload
    }
}

// MARK: - Damage Records

nonisolated struct BackendDamageRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let date: Date?
    let damageType: String?
    let damagePercent: Double?
    let polygonPoints: [CoordinatePoint]?
    let notes: String?
    // Portal extension (sql/048) — additive optional columns.
    let rowNumber: Int?
    let side: String?
    let severity: String?
    let status: String?
    let dateObserved: Date?
    let operatorName: String?
    let latitude: Double?
    let longitude: Double?
    let pinId: UUID?
    let tripId: UUID?
    let photoUrls: [String]?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case date
        case damageType = "damage_type"
        case damagePercent = "damage_percent"
        case polygonPoints = "polygon_points"
        case notes
        case rowNumber = "row_number"
        case side
        case severity
        case status
        case dateObserved = "date_observed"
        case operatorName = "operator_name"
        case latitude
        case longitude
        case pinId = "pin_id"
        case tripId = "trip_id"
        case photoUrls = "photo_urls"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.vineyardId = try c.decode(UUID.self, forKey: .vineyardId)
        self.paddockId = try c.decode(UUID.self, forKey: .paddockId)
        self.date = Self.flexibleDate(c, .date)
        self.damageType = try c.decodeIfPresent(String.self, forKey: .damageType)
        self.damagePercent = try c.decodeIfPresent(Double.self, forKey: .damagePercent)
        self.polygonPoints = (try? c.decodeIfPresent([CoordinatePoint].self, forKey: .polygonPoints)) ?? nil
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.rowNumber = try c.decodeIfPresent(Int.self, forKey: .rowNumber)
        self.side = try c.decodeIfPresent(String.self, forKey: .side)
        self.severity = try c.decodeIfPresent(String.self, forKey: .severity)
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
        self.dateObserved = Self.flexibleDate(c, .dateObserved)
        self.operatorName = try c.decodeIfPresent(String.self, forKey: .operatorName)
        self.latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        self.longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        self.pinId = try c.decodeIfPresent(UUID.self, forKey: .pinId)
        self.tripId = try c.decodeIfPresent(UUID.self, forKey: .tripId)
        self.photoUrls = try c.decodeIfPresent([String].self, forKey: .photoUrls)
        self.createdBy = try c.decodeIfPresent(UUID.self, forKey: .createdBy)
        self.createdAt = Self.flexibleDate(c, .createdAt)
        self.updatedAt = Self.flexibleDate(c, .updatedAt)
        self.deletedAt = Self.flexibleDate(c, .deletedAt)
        self.clientUpdatedAt = Self.flexibleDate(c, .clientUpdatedAt)
    }

    private static func flexibleDate(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
        if let d = try? c.decodeIfPresent(Date.self, forKey: key) { return d }
        guard let s = try? c.decodeIfPresent(String.self, forKey: key), !s.isEmpty else { return nil }
        return BackendDamageRecordDateParser.parse(s)
    }
}

nonisolated enum BackendDamageRecordDateParser {
    static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let dateOnly: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .iso8601); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static let timestampNoTZ: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .iso8601); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; return f
    }()

    static func parse(_ s: String) -> Date? {
        if let d = isoFractional.date(from: s) { return d }
        if let d = isoBasic.date(from: s) { return d }
        if let d = dateOnly.date(from: s) { return d }
        if let d = timestampNoTZ.date(from: s) { return d }
        return nil
    }
}

nonisolated struct BackendDamageRecordUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID
    let date: Date
    let damageType: String
    let damagePercent: Double
    let polygonPoints: [CoordinatePoint]
    let notes: String
    // Portal extension fields — encoded only when non-nil so iOS writes
    // never overwrite portal-set values with NULL.
    let rowNumber: Int?
    let side: String?
    let severity: String?
    let status: String?
    let dateObserved: Date?
    let operatorName: String?
    let latitude: Double?
    let longitude: Double?
    let pinId: UUID?
    let tripId: UUID?
    let photoUrls: [String]?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case date
        case damageType = "damage_type"
        case damagePercent = "damage_percent"
        case polygonPoints = "polygon_points"
        case notes
        case rowNumber = "row_number"
        case side
        case severity
        case status
        case dateObserved = "date_observed"
        case operatorName = "operator_name"
        case latitude
        case longitude
        case pinId = "pin_id"
        case tripId = "trip_id"
        case photoUrls = "photo_urls"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(vineyardId, forKey: .vineyardId)
        try c.encode(paddockId, forKey: .paddockId)
        try c.encode(date, forKey: .date)
        try c.encode(damageType, forKey: .damageType)
        try c.encode(damagePercent, forKey: .damagePercent)
        try c.encode(polygonPoints, forKey: .polygonPoints)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(rowNumber, forKey: .rowNumber)
        try c.encodeIfPresent(side, forKey: .side)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(dateObserved, forKey: .dateObserved)
        try c.encodeIfPresent(operatorName, forKey: .operatorName)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(pinId, forKey: .pinId)
        try c.encodeIfPresent(tripId, forKey: .tripId)
        try c.encodeIfPresent(photoUrls, forKey: .photoUrls)
        try c.encodeIfPresent(createdBy, forKey: .createdBy)
        try c.encode(clientUpdatedAt, forKey: .clientUpdatedAt)
    }
}

extension BackendDamageRecord {
    /// Map portal/iOS damage_type strings (any case, including new portal-only
    /// labels) to the closest local DamageType so a row never fails to render.
    static func normalizeDamageType(_ raw: String?) -> DamageType {
        guard let raw, !raw.isEmpty else { return .other }
        if let exact = DamageType(rawValue: raw) { return exact }
        let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "frost": return .frost
        case "hail": return .hail
        case "wind": return .wind
        case "heat", "sunburn", "heat / sunburn", "heat/sunburn": return .heat
        case "disease": return .disease
        case "pest", "animal / bird damage", "animal/bird damage", "animal damage", "bird damage": return .pest
        default: return .other
        }
    }

    static func upsert(from d: DamageRecord, createdBy: UUID?, clientUpdatedAt: Date) -> BackendDamageRecordUpsert {
        BackendDamageRecordUpsert(
            id: d.id,
            vineyardId: d.vineyardId,
            paddockId: d.paddockId,
            date: d.date,
            damageType: d.damageType.rawValue,
            damagePercent: d.damagePercent,
            polygonPoints: d.polygonPoints,
            notes: d.notes,
            rowNumber: d.rowNumber,
            side: d.side,
            severity: d.severity,
            status: d.status,
            dateObserved: d.dateObserved,
            operatorName: d.operatorName,
            latitude: d.latitude,
            longitude: d.longitude,
            pinId: d.pinId,
            tripId: d.tripId,
            photoUrls: d.photoUrls,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toDamageRecord() -> DamageRecord {
        DamageRecord(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddockId,
            polygonPoints: polygonPoints ?? [],
            date: date ?? dateObserved ?? Date(),
            damageType: BackendDamageRecord.normalizeDamageType(damageType),
            damagePercent: damagePercent ?? 0,
            notes: notes ?? "",
            rowNumber: rowNumber,
            side: side,
            severity: severity,
            status: status,
            dateObserved: dateObserved,
            operatorName: operatorName,
            latitude: latitude,
            longitude: longitude,
            pinId: pinId,
            tripId: tripId,
            photoUrls: photoUrls
        )
    }
}

// MARK: - Historical Yield Records

nonisolated struct BackendHistoricalYieldRecord: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let season: String?
    let year: Int?
    let archivedAt: Date?
    let totalYieldTonnes: Double?
    let totalAreaHectares: Double?
    let notes: String?
    let blockResults: [HistoricalBlockResult]?
    let createdBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case season
        case year
        case archivedAt = "archived_at"
        case totalYieldTonnes = "total_yield_tonnes"
        case totalAreaHectares = "total_area_hectares"
        case notes
        case blockResults = "block_results"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
    }
}

nonisolated struct BackendHistoricalYieldRecordUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let season: String
    let year: Int
    let archivedAt: Date
    let totalYieldTonnes: Double
    let totalAreaHectares: Double
    let notes: String
    let blockResults: [HistoricalBlockResult]
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case season
        case year
        case archivedAt = "archived_at"
        case totalYieldTonnes = "total_yield_tonnes"
        case totalAreaHectares = "total_area_hectares"
        case notes
        case blockResults = "block_results"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendHistoricalYieldRecord {
    static func upsert(from h: HistoricalYieldRecord, createdBy: UUID?, clientUpdatedAt: Date) -> BackendHistoricalYieldRecordUpsert {
        BackendHistoricalYieldRecordUpsert(
            id: h.id,
            vineyardId: h.vineyardId,
            season: h.season,
            year: h.year,
            archivedAt: h.archivedAt,
            totalYieldTonnes: h.totalYieldTonnes,
            totalAreaHectares: h.totalAreaHectares,
            notes: h.notes,
            blockResults: h.blockResults,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    func toHistoricalYieldRecord() -> HistoricalYieldRecord {
        HistoricalYieldRecord(
            id: id,
            vineyardId: vineyardId,
            season: season ?? "",
            year: year ?? 0,
            archivedAt: archivedAt ?? Date(),
            blockResults: blockResults ?? [],
            totalYieldTonnes: totalYieldTonnes ?? 0,
            totalAreaHectares: totalAreaHectares ?? 0,
            notes: notes ?? ""
        )
    }
}
