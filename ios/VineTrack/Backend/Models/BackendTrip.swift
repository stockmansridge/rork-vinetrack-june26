import Foundation

nonisolated struct BackendTrip: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID

    let paddockId: UUID?
    let paddockIds: [UUID]?
    let paddockName: String?

    let trackingPattern: String?
    let startTime: Date?
    let endTime: Date?
    let isActive: Bool?
    let isPaused: Bool?

    let totalDistance: Double?
    let currentPathDistance: Double?
    let currentRowNumber: Double?
    let nextRowNumber: Double?
    let sequenceIndex: Int?
    let rowSequence: [Double]?

    let pathPoints: [CoordinatePoint]?
    let completedPaths: [Double]?
    let skippedPaths: [Double]?
    let pinIds: [UUID]?
    let tankSessions: [TankSession]?
    let activeTankNumber: Int?
    let totalTanks: Int?
    let pauseTimestamps: [Date]?
    let resumeTimestamps: [Date]?
    let isFillingTank: Bool?
    let fillingTankNumber: Int?

    let personName: String?
    /// Preferred link to the vineyard machine used for this trip (see
    /// sql/098_trips_machine_id.sql). tractorId is the legacy fallback.
    let machineId: UUID?
    let tractorId: UUID?
    let operatorUserId: UUID?
    let operatorCategoryId: UUID?
    /// Optional engine-hour meter readings (see sql/093_trips_engine_hours.sql).
    let startEngineHours: Double?
    let endEngineHours: Double?
    let tripFunction: String?
    let tripTitle: String?
    let seedingDetails: SeedingDetails?
    /// Optional audit trail of manual Live-Trip corrections. Each entry is
    /// `"<ISO8601 timestamp> <note>"` (see sql/039_trips_manual_correction_events.sql).
    let manualCorrectionEvents: [String]?
    /// Optional free-text notes captured at trip completion (End Trip
    /// Review). See `sql/040_trips_completion_notes.sql`.
    let completionNotes: String?
    /// Optional grouping link to the parent Work Task (see
    /// sql/102_trips_work_task_link.sql). NULL = ungrouped standalone trip.
    let workTaskId: UUID?

    let createdBy: UUID?
    let updatedBy: UUID?
    let createdAt: Date?
    let updatedAt: Date?
    let deletedAt: Date?
    let clientUpdatedAt: Date?
    let syncVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case paddockIds = "paddock_ids"
        case paddockName = "paddock_name"
        case trackingPattern = "tracking_pattern"
        case startTime = "start_time"
        case endTime = "end_time"
        case isActive = "is_active"
        case isPaused = "is_paused"
        case totalDistance = "total_distance"
        case currentPathDistance = "current_path_distance"
        case currentRowNumber = "current_row_number"
        case nextRowNumber = "next_row_number"
        case sequenceIndex = "sequence_index"
        case rowSequence = "row_sequence"
        case pathPoints = "path_points"
        case completedPaths = "completed_paths"
        case skippedPaths = "skipped_paths"
        case pinIds = "pin_ids"
        case tankSessions = "tank_sessions"
        case activeTankNumber = "active_tank_number"
        case totalTanks = "total_tanks"
        case pauseTimestamps = "pause_timestamps"
        case resumeTimestamps = "resume_timestamps"
        case isFillingTank = "is_filling_tank"
        case fillingTankNumber = "filling_tank_number"
        case personName = "person_name"
        case machineId = "machine_id"
        case tractorId = "tractor_id"
        case operatorUserId = "operator_user_id"
        case operatorCategoryId = "worker_type_id"
        case startEngineHours = "start_engine_hours"
        case endEngineHours = "end_engine_hours"
        case tripFunction = "trip_function"
        case tripTitle = "trip_title"
        case seedingDetails = "seeding_details"
        case manualCorrectionEvents = "manual_correction_events"
        case completionNotes = "completion_notes"
        case workTaskId = "work_task_id"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case clientUpdatedAt = "client_updated_at"
        case syncVersion = "sync_version"
    }
}

/// Encodable payload used when upserting a trip from the client. Server-managed
/// fields (created_at, updated_at, deleted_at, sync_version, updated_by) are omitted.
nonisolated struct BackendTripUpsert: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let paddockId: UUID?
    let paddockIds: [UUID]
    let paddockName: String
    let trackingPattern: String?
    let startTime: Date
    let endTime: Date?
    let isActive: Bool
    let isPaused: Bool
    let totalDistance: Double
    let currentPathDistance: Double
    let currentRowNumber: Double
    let nextRowNumber: Double
    let sequenceIndex: Int
    let rowSequence: [Double]
    let pathPoints: [CoordinatePoint]
    let completedPaths: [Double]
    let skippedPaths: [Double]
    let pinIds: [UUID]
    let tankSessions: [TankSession]
    let activeTankNumber: Int?
    let totalTanks: Int
    let pauseTimestamps: [Date]
    let resumeTimestamps: [Date]
    let isFillingTank: Bool
    let fillingTankNumber: Int?
    let personName: String
    /// Preferred link to the vineyard machine used for this trip.
    let machineId: UUID?
    let tractorId: UUID?
    let operatorUserId: UUID?
    let operatorCategoryId: UUID?
    /// Optional engine-hour meter readings. Encoded only when non-nil so older
    /// clients re-upserting a trip do not clobber existing server values.
    let startEngineHours: Double?
    let endEngineHours: Double?
    let tripFunction: String?
    let tripTitle: String?
    /// Optional structured seeding payload. Encoded only when non-nil so older
    /// clients re-upserting a trip do not clobber existing `seeding_details` on
    /// the server. PostgREST upsert only updates columns present in the JSON
    /// payload, so omitting this key preserves the stored value.
    let seedingDetails: SeedingDetails?
    /// Optional audit trail of manual Live-Trip corrections. Encoded only when
    /// non-nil so older clients re-upserting a trip do not clobber existing
    /// values on the server.
    let manualCorrectionEvents: [String]?
    /// Optional free-text notes captured at trip completion (End Trip
    /// Review). Encoded only when non-nil so older clients don't clobber
    /// existing server values.
    let completionNotes: String?
    /// Optional grouping link to the parent Work Task. Encoded only when
    /// non-nil (synthesized Codable omits nil optionals), so a client that
    /// has no link does NOT overwrite an existing server work_task_id back to
    /// null on re-upsert. See sql/102_trips_work_task_link.sql.
    let workTaskId: UUID?
    let createdBy: UUID?
    let clientUpdatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case vineyardId = "vineyard_id"
        case paddockId = "paddock_id"
        case paddockIds = "paddock_ids"
        case paddockName = "paddock_name"
        case trackingPattern = "tracking_pattern"
        case startTime = "start_time"
        case endTime = "end_time"
        case isActive = "is_active"
        case isPaused = "is_paused"
        case totalDistance = "total_distance"
        case currentPathDistance = "current_path_distance"
        case currentRowNumber = "current_row_number"
        case nextRowNumber = "next_row_number"
        case sequenceIndex = "sequence_index"
        case rowSequence = "row_sequence"
        case pathPoints = "path_points"
        case completedPaths = "completed_paths"
        case skippedPaths = "skipped_paths"
        case pinIds = "pin_ids"
        case tankSessions = "tank_sessions"
        case activeTankNumber = "active_tank_number"
        case totalTanks = "total_tanks"
        case pauseTimestamps = "pause_timestamps"
        case resumeTimestamps = "resume_timestamps"
        case isFillingTank = "is_filling_tank"
        case fillingTankNumber = "filling_tank_number"
        case personName = "person_name"
        case machineId = "machine_id"
        case tractorId = "tractor_id"
        case operatorUserId = "operator_user_id"
        case operatorCategoryId = "worker_type_id"
        case startEngineHours = "start_engine_hours"
        case endEngineHours = "end_engine_hours"
        case tripFunction = "trip_function"
        case tripTitle = "trip_title"
        case seedingDetails = "seeding_details"
        case manualCorrectionEvents = "manual_correction_events"
        case completionNotes = "completion_notes"
        case workTaskId = "work_task_id"
        case createdBy = "created_by"
        case clientUpdatedAt = "client_updated_at"
    }
}

extension BackendTrip {
    /// Map a local Trip into an upsert payload.
    static func upsert(from trip: Trip, createdBy: UUID?, clientUpdatedAt: Date) -> BackendTripUpsert {
        // Ensure scalar paddock_id is populated for single-paddock trips so that
        // portal/admin queries that filter on paddock_id can find them. Multi-paddock
        // trips intentionally leave the scalar nil and rely on paddock_ids JSONB.
        let resolvedPaddockId: UUID? = {
            if let pid = trip.paddockId { return pid }
            if trip.paddockIds.count == 1 { return trip.paddockIds.first }
            return nil
        }()
        return BackendTripUpsert(
            id: trip.id,
            vineyardId: trip.vineyardId,
            paddockId: resolvedPaddockId,
            paddockIds: trip.paddockIds,
            paddockName: trip.paddockName,
            trackingPattern: trip.trackingPattern.rawValue,
            startTime: trip.startTime,
            endTime: trip.endTime,
            isActive: trip.isActive,
            isPaused: trip.isPaused,
            totalDistance: trip.totalDistance,
            currentPathDistance: trip.currentPathDistance,
            currentRowNumber: trip.currentRowNumber,
            nextRowNumber: trip.nextRowNumber,
            sequenceIndex: trip.sequenceIndex,
            rowSequence: trip.rowSequence,
            pathPoints: trip.pathPoints,
            completedPaths: trip.completedPaths,
            skippedPaths: trip.skippedPaths,
            pinIds: trip.pinIds,
            tankSessions: trip.tankSessions,
            activeTankNumber: trip.activeTankNumber,
            totalTanks: trip.totalTanks,
            pauseTimestamps: trip.pauseTimestamps,
            resumeTimestamps: trip.resumeTimestamps,
            isFillingTank: trip.isFillingTank,
            fillingTankNumber: trip.fillingTankNumber,
            personName: trip.personName,
            machineId: trip.machineId,
            tractorId: trip.tractorId,
            operatorUserId: trip.operatorUserId,
            operatorCategoryId: trip.operatorCategoryId,
            startEngineHours: trip.startEngineHours,
            endEngineHours: trip.endEngineHours,
            tripFunction: trip.tripFunction,
            tripTitle: trip.tripTitle,
            seedingDetails: trip.seedingDetails,
            manualCorrectionEvents: trip.manualCorrectionEvents.isEmpty ? nil : trip.manualCorrectionEvents,
            completionNotes: trip.completionNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
                ? nil
                : trip.completionNotes,
            workTaskId: trip.workTaskId,
            createdBy: createdBy,
            clientUpdatedAt: clientUpdatedAt
        )
    }

    /// Map a remote BackendTrip into a local Trip.
    func toTrip() -> Trip {
        Trip(
            id: id,
            vineyardId: vineyardId,
            paddockId: paddockId,
            paddockName: paddockName ?? "",
            paddockIds: paddockIds ?? (paddockId.map { [$0] } ?? []),
            startTime: startTime ?? Date(),
            endTime: endTime,
            currentRowNumber: currentRowNumber ?? 0.5,
            nextRowNumber: nextRowNumber ?? 1.5,
            pathPoints: pathPoints ?? [],
            isActive: isActive ?? false,
            trackingPattern: trackingPattern.flatMap { TrackingPattern(rawValue: $0) } ?? .sequential,
            rowSequence: rowSequence ?? [],
            sequenceIndex: sequenceIndex ?? 0,
            personName: personName ?? "",
            totalDistance: totalDistance ?? 0,
            pinIds: pinIds ?? [],
            completedPaths: completedPaths ?? [],
            skippedPaths: skippedPaths ?? [],
            currentPathDistance: currentPathDistance ?? 0,
            tankSessions: tankSessions ?? [],
            activeTankNumber: activeTankNumber,
            totalTanks: totalTanks ?? 0,
            pauseTimestamps: pauseTimestamps ?? [],
            resumeTimestamps: resumeTimestamps ?? [],
            isPaused: isPaused ?? false,
            isFillingTank: isFillingTank ?? false,
            fillingTankNumber: fillingTankNumber,
            tripFunction: tripFunction,
            tripTitle: tripTitle,
            machineId: machineId,
            tractorId: tractorId,
            operatorUserId: operatorUserId,
            operatorCategoryId: operatorCategoryId,
            startEngineHours: startEngineHours,
            endEngineHours: endEngineHours,
            seedingDetails: seedingDetails,
            manualCorrectionEvents: manualCorrectionEvents ?? [],
            completionNotes: completionNotes,
            workTaskId: workTaskId
        )
    }
}
