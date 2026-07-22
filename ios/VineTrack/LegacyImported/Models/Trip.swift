import Foundation
import CoreLocation

nonisolated struct TankSession: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var tankNumber: Int
    var startTime: Date
    var endTime: Date?
    var pathsCovered: [Double]
    var startRow: Double?
    var endRow: Double?
    var fillStartTime: Date?
    var fillEndTime: Date?

    var fillDuration: TimeInterval? {
        guard let start = fillStartTime, let end = fillEndTime else { return nil }
        return end.timeIntervalSince(start)
    }

    init(
        id: UUID = UUID(),
        tankNumber: Int = 1,
        startTime: Date = Date(),
        endTime: Date? = nil,
        pathsCovered: [Double] = [],
        startRow: Double? = nil,
        endRow: Double? = nil,
        fillStartTime: Date? = nil,
        fillEndTime: Date? = nil
    ) {
        self.id = id
        self.tankNumber = tankNumber
        self.startTime = startTime
        self.endTime = endTime
        self.pathsCovered = pathsCovered
        self.startRow = startRow
        self.endRow = endRow
        self.fillStartTime = fillStartTime
        self.fillEndTime = fillEndTime
    }

    var rowRange: String {
        guard let start = startRow, let end = endRow else { return "" }
        if start == end { return "Row \(formatRow(start))" }
        return "Rows \(formatRow(min(start, end)))–\(formatRow(max(start, end)))"
    }

    private func formatRow(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.1f", value)
    }
}

nonisolated struct Trip: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var vineyardId: UUID
    var paddockId: UUID?
    let paddockName: String
    var paddockIds: [UUID]
    let startTime: Date
    var endTime: Date?
    var currentRowNumber: Double
    var nextRowNumber: Double
    var pathPoints: [CoordinatePoint]
    var isActive: Bool
    var trackingPattern: TrackingPattern
    var rowSequence: [Double]
    var sequenceIndex: Int
    var personName: String
    var totalDistance: Double
    var pinIds: [UUID]
    var completedPaths: [Double]
    var skippedPaths: [Double]
    var currentPathDistance: Double
    var tankSessions: [TankSession]
    var activeTankNumber: Int?
    var totalTanks: Int
    var pauseTimestamps: [Date]
    var resumeTimestamps: [Date]
    var isPaused: Bool
    var isFillingTank: Bool
    var fillingTankNumber: Int?

    /// Operator-selected operation type (e.g. "slashing", "mowing"). Stored
    /// as the raw value of `TripFunction` so the column stays stable.
    var tripFunction: String?
    /// Optional free-text title / notes (used when `tripFunction == .other`
    /// or when the operator wants to add a custom label).
    var tripTitle: String?

    /// Linked vineyard machine used for this trip (preferred). Drives fuel cost
    /// estimation via `vineyard_machines.fuel_usage_l_per_hour` when an approved
    /// (> 0) rate is set. Synced as `trips.machine_id` (see
    /// sql/098_trips_machine_id.sql). When the machine is tractor-backed,
    /// `tractorId` is also populated for backward compatibility.
    var machineId: UUID?
    /// Legacy linked tractor for this trip. Retained as the fuel-costing
    /// fallback when no machine rate is available. Drives fuel cost estimation
    /// via `tractors.fuel_usage_l_per_hour` × `activeDuration`.
    /// Synced as `trips.tractor_id` (see sql/057_trips_costing_links.sql).
    var tractorId: UUID?
    /// Linked operator (vineyard_members.user_id) when the operator is a known
    /// app user. Falls back to `personName` for free-text entry.
    /// Synced as `trips.operator_user_id` (see sql/057_trips_costing_links.sql).
    var operatorUserId: UUID?
    /// Operator category override for this trip. When nil the cost service
    /// falls back to `vineyard_members.operator_category_id` of the operator.
    /// Synced as `trips.operator_category_id` (see sql/057_trips_costing_links.sql).
    var operatorCategoryId: UUID?

    /// Optional tractor engine-hour meter reading captured at trip start.
    /// When both start/end are present and end > start, the engine-hour delta
    /// is the preferred basis for fuel allocation. Synced as
    /// `trips.start_engine_hours` (see sql/093_trips_engine_hours.sql).
    var startEngineHours: Double?
    /// Optional tractor engine-hour meter reading captured at trip end.
    /// Synced as `trips.end_engine_hours` (see sql/093_trips_engine_hours.sql).
    var endEngineHours: Double?
    /// Optional structured Seeding Details (only normally populated when
    /// `tripFunction == "seeding"`). Persisted to Supabase as JSONB at
    /// `trips.seeding_details`. Encoded with snake_case nested keys.
    var seedingDetails: SeedingDetails?

    /// Audit trail of manual corrections recorded during the trip
    /// (e.g. `manual_next_path`, `end_review_completed: [...]`,
    /// `paddocks_added: ...`). Persisted locally with the trip so the
    /// final Trip Report can include the full corrections history.
    /// Each entry is `"<ISO8601 timestamp> <note>"`.
    var manualCorrectionEvents: [String]

    /// Optional free-text notes captured at trip completion (End Trip
    /// Review). Distinct from `tripTitle` (job details entered at start)
    /// and from `manualCorrectionEvents` (audit log). Synced to
    /// Supabase as `trips.completion_notes` (see
    /// `sql/040_trips_completion_notes.sql`).
    var completionNotes: String?

    /// Optional grouping link: the Work Task this successful GPS trip belongs
    /// to. NULL = ungrouped standalone trip. One Work Task can have many trips;
    /// a trip belongs to zero or one Work Task. Synced as `trips.work_task_id`
    /// (see sql/102_trips_work_task_link.sql). No costing/reporting impact.
    var workTaskId: UUID?

    /// Convenience: returns a short label suitable for the active trip header.
    /// Prefers an explicit user-entered title, then the friendly label for the
    /// selected `tripFunction` (built-in or `custom:<slug>`), then "Trip".
    var displayFunctionLabel: String {
        if let title = tripTitle, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        if let raw = tripFunction, !raw.isEmpty {
            if let function = TripFunction(rawValue: raw) {
                return function.displayName
            }
            if raw.hasPrefix("custom:") {
                let slug = String(raw.dropFirst("custom:".count))
                if !slug.isEmpty {
                    return slug.replacingOccurrences(of: "-", with: " ").capitalized
                }
            }
        }
        return "Trip"
    }

    var activeDuration: TimeInterval {
        let end = endTime ?? Date()
        var total: TimeInterval = 0
        var lastStart = startTime
        for i in 0..<pauseTimestamps.count {
            total += pauseTimestamps[i].timeIntervalSince(lastStart)
            if i < resumeTimestamps.count {
                lastStart = resumeTimestamps[i]
            } else {
                return total
            }
        }
        total += end.timeIntervalSince(lastStart)
        return total
    }

    init(
        id: UUID = UUID(),
        vineyardId: UUID = UUID(),
        paddockId: UUID? = nil,
        paddockName: String = "",
        paddockIds: [UUID] = [],
        startTime: Date = Date(),
        endTime: Date? = nil,
        currentRowNumber: Double = 0.5,
        nextRowNumber: Double = 1.5,
        pathPoints: [CoordinatePoint] = [],
        isActive: Bool = true,
        trackingPattern: TrackingPattern = .sequential,
        rowSequence: [Double] = [],
        sequenceIndex: Int = 0,
        personName: String = "",
        totalDistance: Double = 0,
        pinIds: [UUID] = [],
        completedPaths: [Double] = [],
        skippedPaths: [Double] = [],
        currentPathDistance: Double = 0,
        tankSessions: [TankSession] = [],
        activeTankNumber: Int? = nil,
        totalTanks: Int = 0,
        pauseTimestamps: [Date] = [],
        resumeTimestamps: [Date] = [],
        isPaused: Bool = false,
        isFillingTank: Bool = false,
        fillingTankNumber: Int? = nil,
        tripFunction: String? = nil,
        tripTitle: String? = nil,
        machineId: UUID? = nil,
        tractorId: UUID? = nil,
        operatorUserId: UUID? = nil,
        operatorCategoryId: UUID? = nil,
        startEngineHours: Double? = nil,
        endEngineHours: Double? = nil,
        seedingDetails: SeedingDetails? = nil,
        manualCorrectionEvents: [String] = [],
        completionNotes: String? = nil,
        workTaskId: UUID? = nil
    ) {
        self.id = id
        self.vineyardId = vineyardId
        self.paddockId = paddockId
        self.paddockName = paddockName
        self.paddockIds = paddockIds
        self.startTime = startTime
        self.endTime = endTime
        self.currentRowNumber = currentRowNumber
        self.nextRowNumber = nextRowNumber
        self.pathPoints = pathPoints
        self.isActive = isActive
        self.trackingPattern = trackingPattern
        self.rowSequence = rowSequence
        self.sequenceIndex = sequenceIndex
        self.personName = personName
        self.totalDistance = totalDistance
        self.pinIds = pinIds
        self.completedPaths = completedPaths
        self.skippedPaths = skippedPaths
        self.currentPathDistance = currentPathDistance
        self.tankSessions = tankSessions
        self.activeTankNumber = activeTankNumber
        self.totalTanks = totalTanks
        self.pauseTimestamps = pauseTimestamps
        self.resumeTimestamps = resumeTimestamps
        self.isPaused = isPaused
        self.isFillingTank = isFillingTank
        self.fillingTankNumber = fillingTankNumber
        self.tripFunction = tripFunction
        self.tripTitle = tripTitle
        self.machineId = machineId
        self.tractorId = tractorId
        self.operatorUserId = operatorUserId
        self.operatorCategoryId = operatorCategoryId
        self.startEngineHours = startEngineHours
        self.endEngineHours = endEngineHours
        self.seedingDetails = seedingDetails
        self.manualCorrectionEvents = manualCorrectionEvents
        self.completionNotes = completionNotes
        self.workTaskId = workTaskId
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, vineyardId, paddockId, paddockName, paddockIds, startTime, endTime
        case currentRowNumber, nextRowNumber, pathPoints, isActive
        case trackingPattern, rowSequence, sequenceIndex
        case personName, totalDistance, pinIds
        case completedPaths, skippedPaths, currentPathDistance
        case tankSessions, activeTankNumber, totalTanks
        case pauseTimestamps, resumeTimestamps, isPaused
        case isFillingTank, fillingTankNumber
        case tripFunction, tripTitle
        case machineId, tractorId, operatorUserId, operatorCategoryId
        case startEngineHours, endEngineHours
        case seedingDetails
        case manualCorrectionEvents
        case completionNotes
        case workTaskId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        vineyardId = try container.decode(UUID.self, forKey: .vineyardId)
        paddockId = try container.decodeIfPresent(UUID.self, forKey: .paddockId)
        paddockName = try container.decode(String.self, forKey: .paddockName)
        paddockIds = try container.decodeIfPresent([UUID].self, forKey: .paddockIds) ?? (paddockId.map { [$0] } ?? [])
        startTime = try container.decode(Date.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Date.self, forKey: .endTime)
        pathPoints = try container.decode([CoordinatePoint].self, forKey: .pathPoints)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        trackingPattern = try container.decodeIfPresent(TrackingPattern.self, forKey: .trackingPattern) ?? .sequential
        sequenceIndex = try container.decodeIfPresent(Int.self, forKey: .sequenceIndex) ?? 0
        personName = try container.decodeIfPresent(String.self, forKey: .personName) ?? ""
        totalDistance = try container.decodeIfPresent(Double.self, forKey: .totalDistance) ?? 0
        pinIds = try container.decodeIfPresent([UUID].self, forKey: .pinIds) ?? []
        completedPaths = try container.decodeIfPresent([Double].self, forKey: .completedPaths) ?? []
        skippedPaths = try container.decodeIfPresent([Double].self, forKey: .skippedPaths) ?? []
        currentPathDistance = try container.decodeIfPresent(Double.self, forKey: .currentPathDistance) ?? 0
        tankSessions = try container.decodeIfPresent([TankSession].self, forKey: .tankSessions) ?? []
        activeTankNumber = try container.decodeIfPresent(Int.self, forKey: .activeTankNumber)
        totalTanks = try container.decodeIfPresent(Int.self, forKey: .totalTanks) ?? 0
        pauseTimestamps = try container.decodeIfPresent([Date].self, forKey: .pauseTimestamps) ?? []
        resumeTimestamps = try container.decodeIfPresent([Date].self, forKey: .resumeTimestamps) ?? []
        isPaused = try container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        isFillingTank = try container.decodeIfPresent(Bool.self, forKey: .isFillingTank) ?? false
        fillingTankNumber = try container.decodeIfPresent(Int.self, forKey: .fillingTankNumber)
        tripFunction = try container.decodeIfPresent(String.self, forKey: .tripFunction)
        tripTitle = try container.decodeIfPresent(String.self, forKey: .tripTitle)
        machineId = try container.decodeIfPresent(UUID.self, forKey: .machineId)
        tractorId = try container.decodeIfPresent(UUID.self, forKey: .tractorId)
        operatorUserId = try container.decodeIfPresent(UUID.self, forKey: .operatorUserId)
        operatorCategoryId = try container.decodeIfPresent(UUID.self, forKey: .operatorCategoryId)
        startEngineHours = try container.decodeIfPresent(Double.self, forKey: .startEngineHours)
        endEngineHours = try container.decodeIfPresent(Double.self, forKey: .endEngineHours)
        seedingDetails = try container.decodeIfPresent(SeedingDetails.self, forKey: .seedingDetails)
        manualCorrectionEvents = try container.decodeIfPresent([String].self, forKey: .manualCorrectionEvents) ?? []
        completionNotes = try container.decodeIfPresent(String.self, forKey: .completionNotes)
        workTaskId = try container.decodeIfPresent(UUID.self, forKey: .workTaskId)

        if let doubleRow = try? container.decode(Double.self, forKey: .currentRowNumber) {
            currentRowNumber = doubleRow
        } else if let intRow = try? container.decode(Int.self, forKey: .currentRowNumber) {
            currentRowNumber = Double(intRow)
        } else {
            currentRowNumber = 0.5
        }

        if let doubleRow = try? container.decode(Double.self, forKey: .nextRowNumber) {
            nextRowNumber = doubleRow
        } else if let intRow = try? container.decode(Int.self, forKey: .nextRowNumber) {
            nextRowNumber = Double(intRow)
        } else {
            nextRowNumber = 1.5
        }

        if let doubleSeq = try? container.decode([Double].self, forKey: .rowSequence) {
            rowSequence = doubleSeq
        } else if let intSeq = try? container.decode([Int].self, forKey: .rowSequence) {
            rowSequence = intSeq.map { Double($0) }
        } else {
            rowSequence = []
        }
    }
}
