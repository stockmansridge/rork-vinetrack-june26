import Foundation

// MARK: - Irrigation Records (SQL 125) — shared models
//
// All RPCs return jsonb in canonical units: litres, litres/hour, m², mm,
// whole minutes. Display conversion happens in the views via RegionFormatter.
// Dates arrive as "yyyy-MM-dd" strings and are kept as strings in the DTOs.

nonisolated enum IrrigationCalculationMethod: String, CaseIterable, Codable, Sendable, Identifiable {
    case configuredFlow = "configured_flow"
    case sessionFlow    = "session_flow"
    case totalVolume    = "total_volume"
    case meterReadings  = "meter_readings"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .configuredFlow: return "Configured Flow"
        case .sessionFlow:    return "Session Flow"
        case .totalVolume:    return "Total Volume"
        case .meterReadings:  return "Meter Readings"
        }
    }
}

nonisolated struct IrrigationSystem: Identifiable, Decodable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let waterSource: String?
    let controllerProvider: String?
    let controllerName: String?
    let isActive: Bool
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case vineyardId = "vineyard_id"
        case waterSource = "water_source"
        case controllerProvider = "controller_provider"
        case controllerName = "controller_name"
        case isActive = "is_active"
    }
}

nonisolated struct IrrigationValve: Identifiable, Decodable, Sendable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let irrigationSystemId: UUID
    let name: String
    let valveNumber: String?
    let configuredFlowLitresPerHour: Double?
    let measuredFlowLitresPerHour: Double?
    let isActive: Bool
    let notes: String?
    let systemName: String?
    let activeBlockCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, notes
        case vineyardId = "vineyard_id"
        case irrigationSystemId = "irrigation_system_id"
        case valveNumber = "valve_number"
        case configuredFlowLitresPerHour = "configured_flow_litres_per_hour"
        case measuredFlowLitresPerHour = "measured_flow_litres_per_hour"
        case isActive = "is_active"
        case systemName = "system_name"
        case activeBlockCount = "active_block_count"
    }
}

nonisolated struct IrrigationValveBlock: Identifiable, Decodable, Sendable, Hashable {
    let id: UUID
    let valveId: UUID
    let blockId: UUID
    let allocationMethod: String
    let allocationPercentage: Double?
    let servicedAreaM2: Double?
    let servicedVineCount: Int?
    let servicedEmitterCount: Int?
    let blockName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case valveId = "valve_id"
        case blockId = "block_id"
        case allocationMethod = "allocation_method"
        case allocationPercentage = "allocation_percentage"
        case servicedAreaM2 = "serviced_area_m2"
        case servicedVineCount = "serviced_vine_count"
        case servicedEmitterCount = "serviced_emitter_count"
        case blockName = "block_name"
    }
}

// MARK: - Row-based allocation (SQL 126)

/// One selectable vineyard row (from `list_irrigation_available_rows`).
/// Rows come from the block's configured row records (`paddocks.rows`) — the
/// server never invents generic 1…N rows.
nonisolated struct IrrigationAvailableRow: Decodable, Sendable, Identifiable, Hashable {
    let rowId: UUID
    let blockId: UUID
    let blockName: String
    let rowNumber: Int
    let rowLabel: String?
    let vineCount: Int?
    let emitterCount: Int?
    let rowLengthMetres: Double?
    let connectedValveIds: [UUID]?
    let connectedValveNames: [String]?

    var id: UUID { rowId }

    enum CodingKeys: String, CodingKey {
        case rowId = "row_id"
        case blockId = "block_id"
        case blockName = "block_name"
        case rowNumber = "row_number"
        case rowLabel = "row_label"
        case vineCount = "vine_count"
        case emitterCount = "emitter_count"
        case rowLengthMetres = "row_length_metres"
        case connectedValveIds = "connected_valve_ids"
        case connectedValveNames = "connected_valve_names"
    }

    var displayLabel: String { rowLabel ?? "Row \(rowNumber)" }
}

/// One saved valve→row link (from `list_irrigation_valve_rows`).
nonisolated struct IrrigationValveRowLink: Decodable, Sendable, Identifiable, Hashable {
    let id: UUID
    let valveId: UUID
    let blockId: UUID
    let rowId: UUID?
    let rowNumber: Int
    let rowLabel: String?
    let vineCount: Int?
    let emitterCount: Int?
    let rowLengthMetres: Double?
    let weightingBasis: String?
    let rowWeight: Double?
    let blockName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case valveId = "valve_id"
        case blockId = "block_id"
        case rowId = "row_id"
        case rowNumber = "row_number"
        case rowLabel = "row_label"
        case vineCount = "vine_count"
        case emitterCount = "emitter_count"
        case rowLengthMetres = "row_length_metres"
        case weightingBasis = "weighting_basis"
        case rowWeight = "row_weight"
        case blockName = "block_name"
    }
}

/// Result of `set_irrigation_valve_rows` — the BACKEND percentages are the
/// authoritative values shown after saving.
nonisolated struct IrrigationValveRowsResult: Decodable, Sendable {
    let weightingBasis: String?
    let blocks: [IrrigationValveBlock]
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case weightingBasis = "weighting_basis"
        case blocks, warnings
    }
}

/// Mirror of the SQL `_irrigation_rows_weighting` core (sql/126) for
/// PROVISIONAL previews only — the server result is always authoritative.
nonisolated enum IrrigationRowWeighting {
    enum Basis: String, Sendable {
        case emitterCount = "emitter_count"
        case vineCount = "vine_count"
        case rowLength = "row_length"
        case equalRows = "equal_rows"

        var label: String {
            switch self {
            case .emitterCount: return "Emitter count"
            case .vineCount: return "Vine count"
            case .rowLength: return "Row length"
            case .equalRows: return "Equal rows (estimate)"
            }
        }
    }

    struct BlockShare: Sendable, Identifiable {
        let blockId: UUID
        let blockName: String
        let rowCount: Int
        let weight: Double
        let percentage: Double
        var id: UUID { blockId }
    }

    static func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    /// Compresses ONLY genuinely contiguous runs for display:
    /// [1, 2, 5, 8] → "1–2, 5, 8" (never "1–8"). Duplicates are ignored.
    static func rangeSummary(_ rowNumbers: [Int]) -> String {
        let sorted = Array(Set(rowNumbers)).sorted()
        guard let first = sorted.first else { return "" }
        var parts: [String] = []
        var start = first
        var prev = first
        for n in sorted.dropFirst() {
            if n == prev + 1 { prev = n; continue }
            parts.append(start == prev ? "\(start)" : "\(start)–\(prev)")
            start = n
            prev = n
        }
        parts.append(start == prev ? "\(start)" : "\(start)–\(prev)")
        return parts.joined(separator: ", ")
    }

    /// Resolves ONE common basis for the whole selection (never mixes units):
    /// emitters → vines → row length → equal rows.
    static func basis(for rows: [IrrigationAvailableRow]) -> Basis {
        guard !rows.isEmpty else { return .equalRows }
        if rows.allSatisfy({ ($0.emitterCount ?? 0) > 0 }) { return .emitterCount }
        if rows.allSatisfy({ ($0.vineCount ?? 0) > 0 }) { return .vineCount }
        if rows.allSatisfy({ ($0.rowLengthMetres ?? 0) > 0 }) { return .rowLength }
        return .equalRows
    }

    /// Same maths and rounding as SQL: blocks ordered by block id text, 4 dp
    /// percentages, and the LAST block absorbs the remainder → exactly 100.
    static func allocate(rows: [IrrigationAvailableRow]) -> (basis: Basis, blocks: [BlockShare]) {
        guard !rows.isEmpty else { return (.equalRows, []) }
        let resolved = basis(for: rows)

        func weight(_ row: IrrigationAvailableRow) -> Double {
            switch resolved {
            case .emitterCount: return Double(row.emitterCount ?? 0)
            case .vineCount: return Double(row.vineCount ?? 0)
            case .rowLength: return row.rowLengthMetres ?? 0
            case .equalRows: return 1
            }
        }

        let total = rows.reduce(0.0) { $0 + weight($1) }
        guard total > 0 else { return (resolved, []) }

        var grouped: [UUID: (name: String, count: Int, weight: Double)] = [:]
        for row in rows {
            var entry = grouped[row.blockId] ?? (row.blockName, 0, 0)
            entry.count += 1
            entry.weight += weight(row)
            entry.name = row.blockName
            grouped[row.blockId] = entry
        }

        let ordered = grouped.sorted { $0.key.uuidString.lowercased() < $1.key.uuidString.lowercased() }
        var shares: [BlockShare] = []
        var pctSum = 0.0
        for (index, element) in ordered.enumerated() {
            let pct: Double
            if index < ordered.count - 1 {
                pct = round4(element.value.weight / total * 100)
                pctSum += pct
            } else {
                pct = round4(100 - pctSum)
            }
            shares.append(BlockShare(blockId: element.key, blockName: element.value.name,
                                     rowCount: element.value.count, weight: element.value.weight,
                                     percentage: pct))
        }
        return (resolved, shares)
    }
}

// MARK: - Setup status (wizard)

nonisolated struct IrrigationSetupStatus: Decodable, Sendable {
    struct Season: Decodable, Sendable {
        let configured: Bool
        let seasonStartMonth: Int
        let seasonStartDay: Int
        let currentVintageYear: Int

        enum CodingKeys: String, CodingKey {
            case configured
            case seasonStartMonth = "season_start_month"
            case seasonStartDay = "season_start_day"
            case currentVintageYear = "current_vintage_year"
        }
    }

    struct Required: Decodable, Sendable {
        let activeBlockCount: Int
        let blocksOk: Bool
        let activeSystemCount: Int
        let systemsOk: Bool
        let activeValveCount: Int
        let valvesOk: Bool
        let fullyAllocatedValveCount: Int
        let allocationsOk: Bool
        let valvesWithConfiguredFlow: Int

        enum CodingKeys: String, CodingKey {
            case activeBlockCount = "active_block_count"
            case blocksOk = "blocks_ok"
            case activeSystemCount = "active_system_count"
            case systemsOk = "systems_ok"
            case activeValveCount = "active_valve_count"
            case valvesOk = "valves_ok"
            case fullyAllocatedValveCount = "fully_allocated_valve_count"
            case allocationsOk = "allocations_ok"
            case valvesWithConfiguredFlow = "valves_with_configured_flow"
        }
    }

    struct Recommended: Decodable, Sendable {
        let totalActiveBlocks: Int
        let blocksWithArea: Int
        let blocksWithVineCount: Int
        let blocksWithVineSpacing: Int
        let blocksWithDripperOutput: Int
        let blocksWithDripperSpacing: Int
        let blocksWithEfficiency: Int

        enum CodingKeys: String, CodingKey {
            case totalActiveBlocks = "total_active_blocks"
            case blocksWithArea = "blocks_with_area"
            case blocksWithVineCount = "blocks_with_vine_count"
            case blocksWithVineSpacing = "blocks_with_vine_spacing"
            case blocksWithDripperOutput = "blocks_with_dripper_output"
            case blocksWithDripperSpacing = "blocks_with_dripper_spacing"
            case blocksWithEfficiency = "blocks_with_efficiency"
        }
    }

    struct ValveStatus: Decodable, Sendable, Identifiable {
        let valveId: UUID
        let valveName: String
        let blockCount: Int
        let allocationTotal: Double
        let allocationOk: Bool
        let hasConfiguredFlow: Bool
        let usesRows: Bool?
        let rowCount: Int?

        var id: UUID { valveId }

        enum CodingKeys: String, CodingKey {
            case valveId = "valve_id"
            case valveName = "valve_name"
            case blockCount = "block_count"
            case allocationTotal = "allocation_total"
            case allocationOk = "allocation_ok"
            case hasConfiguredFlow = "has_configured_flow"
            case usesRows = "uses_rows"
            case rowCount = "row_count"
        }

        /// "Rows · 20 rows · 1 block", "Manual % · 1 block" or "Not configured".
        var configurationSummary: String {
            guard blockCount > 0 else { return "Not configured" }
            var parts: [String] = [(usesRows ?? false) ? "Rows" : "Manual %"]
            if usesRows ?? false {
                let rows = rowCount ?? 0
                parts.append("\(rows) row\(rows == 1 ? "" : "s")")
            }
            parts.append("\(blockCount) block\(blockCount == 1 ? "" : "s")")
            if allocationOk {
                parts.append("100%")
            } else {
                parts.append(String(format: "%.1f%%", allocationTotal))
            }
            return parts.joined(separator: " · ")
        }
    }

    let season: Season
    let required: Required
    let recommended: Recommended
    let valves: [ValveStatus]
    let isOperational: Bool

    enum CodingKeys: String, CodingKey {
        case season, required, recommended, valves
        case isOperational = "is_operational"
    }
}

// MARK: - Validation / preview

/// One resolved valve→block allocation (input shape of `_irrigation_allocate`).
nonisolated struct IrrigationAllocationConfig: Decodable, Sendable, Identifiable, Hashable {
    let blockId: String
    let blockName: String?
    let varietyName: String?
    let allocationPercentage: Double?
    let servicedAreaM2: Double?
    let servicedVineCount: Int?
    let servicedEmitterCount: Int?
    let efficiencyPercent: Double?

    var id: String { blockId }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id"
        case blockName = "block_name"
        case varietyName = "variety_name"
        case allocationPercentage = "allocation_percentage"
        case servicedAreaM2 = "serviced_area_m2"
        case servicedVineCount = "serviced_vine_count"
        case servicedEmitterCount = "serviced_emitter_count"
        case efficiencyPercent = "efficiency_percent"
    }
}

nonisolated struct IrrigationValveValidation: Decodable, Sendable {
    let valveId: UUID
    let valveName: String
    let canRecord: Bool
    let hasConfiguredFlow: Bool
    let configuredFlowLitresPerHour: Double?
    let requiresVolumeEntry: Bool
    let allocations: [IrrigationAllocationConfig]
    let allocationTotal: Double
    let issues: [String]

    enum CodingKeys: String, CodingKey {
        case valveId = "valve_id"
        case valveName = "valve_name"
        case canRecord = "can_record"
        case hasConfiguredFlow = "has_configured_flow"
        case configuredFlowLitresPerHour = "configured_flow_litres_per_hour"
        case requiresVolumeEntry = "requires_volume_entry"
        case allocations
        case allocationTotal = "allocation_total"
        case issues
    }
}

/// One computed block result (output shape of `_irrigation_allocate`).
nonisolated struct IrrigationBlockResult: Decodable, Sendable, Identifiable, Hashable {
    let blockId: String
    let blockName: String?
    let varietyName: String?
    let allocationPercentage: Double
    let allocatedVolumeLitres: Double
    let effectiveVolumeLitres: Double?
    let servicedAreaM2: Double?
    let servicedVineCount: Int?
    let waterLitresPerVine: Double?
    let waterLitresPerHectare: Double?
    let irrigationDepthMm: Double?

    var id: String { blockId }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id"
        case blockName = "block_name"
        case varietyName = "variety_name"
        case allocationPercentage = "allocation_percentage"
        case allocatedVolumeLitres = "allocated_volume_litres"
        case effectiveVolumeLitres = "effective_volume_litres"
        case servicedAreaM2 = "serviced_area_m2"
        case servicedVineCount = "serviced_vine_count"
        case waterLitresPerVine = "water_litres_per_vine"
        case waterLitresPerHectare = "water_litres_per_hectare"
        case irrigationDepthMm = "irrigation_depth_mm"
    }
}

nonisolated struct IrrigationPreview: Decodable, Sendable {
    let totalVolumeLitres: Double
    let effectiveVolumeLitres: Double?
    let irrigationEfficiencyPercent: Double?
    let blocks: [IrrigationBlockResult]
    let warnings: [String]
    let valveName: String?
    let irrigationSystemName: String?
    let flowLitresPerHourUsed: Double?
    let vintageYear: Int?

    enum CodingKeys: String, CodingKey {
        case blocks, warnings
        case totalVolumeLitres = "total_volume_litres"
        case effectiveVolumeLitres = "effective_volume_litres"
        case irrigationEfficiencyPercent = "irrigation_efficiency_percent"
        case valveName = "valve_name"
        case irrigationSystemName = "irrigation_system_name"
        case flowLitresPerHourUsed = "flow_litres_per_hour_used"
        case vintageYear = "vintage_year"
    }
}

// MARK: - Sessions

nonisolated struct IrrigationSessionBlock: Decodable, Sendable, Identifiable, Hashable {
    let id: UUID
    let blockId: UUID
    let blockName: String?
    let varietyName: String?
    let allocationPercentage: Double
    let allocatedVolumeLitres: Double
    let effectiveVolumeLitres: Double?
    let servicedAreaM2: Double?
    let servicedVineCount: Int?
    let waterLitresPerVine: Double?
    let waterLitresPerHectare: Double?
    let irrigationDepthMm: Double?

    enum CodingKeys: String, CodingKey {
        case id
        case blockId = "block_id"
        case blockName = "block_name"
        case varietyName = "variety_name"
        case allocationPercentage = "allocation_percentage"
        case allocatedVolumeLitres = "allocated_volume_litres"
        case effectiveVolumeLitres = "effective_volume_litres"
        case servicedAreaM2 = "serviced_area_m2"
        case servicedVineCount = "serviced_vine_count"
        case waterLitresPerVine = "water_litres_per_vine"
        case waterLitresPerHectare = "water_litres_per_hectare"
        case irrigationDepthMm = "irrigation_depth_mm"
    }
}

nonisolated struct IrrigationSession: Decodable, Sendable, Identifiable, Hashable {
    let id: UUID
    let vineyardId: UUID
    let irrigationSystemId: UUID
    let valveId: UUID
    let sessionDate: String
    let vintageYear: Int
    let durationMinutes: Int
    let calculationMethod: String
    let flowLitresPerHour: Double?
    let meterStartLitres: Double?
    let meterFinishLitres: Double?
    let totalVolumeLitres: Double
    let effectiveVolumeLitres: Double?
    let status: String
    let sourceType: String
    let notes: String?
    let systemName: String?
    let valveName: String?
    let blocks: [IrrigationSessionBlock]
    let duplicate: Bool?
    let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case id, status, notes, blocks, duplicate, warnings
        case vineyardId = "vineyard_id"
        case irrigationSystemId = "irrigation_system_id"
        case valveId = "valve_id"
        case sessionDate = "session_date"
        case vintageYear = "vintage_year"
        case durationMinutes = "duration_minutes"
        case calculationMethod = "calculation_method"
        case flowLitresPerHour = "flow_litres_per_hour"
        case meterStartLitres = "meter_start_litres"
        case meterFinishLitres = "meter_finish_litres"
        case totalVolumeLitres = "total_volume_litres"
        case effectiveVolumeLitres = "effective_volume_litres"
        case sourceType = "source_type"
        case systemName = "system_name"
        case valveName = "valve_name"
    }

    var blockNames: String {
        blocks.compactMap { $0.blockName }.joined(separator: ", ")
    }
}

nonisolated struct IrrigationSessionList: Decodable, Sendable {
    let sessions: [IrrigationSession]
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case sessions
        case totalCount = "total_count"
    }
}

// MARK: - Report summaries

nonisolated struct IrrigationVintageSummary: Decodable, Sendable {
    let vintageYear: Int
    let totalVolumeLitres: Double
    let effectiveVolumeLitres: Double?
    let totalRuntimeMinutes: Int
    let sessionCount: Int
    let averageSessionMinutes: Double?
    let monthVolumeLitres: Double
    let monthSessionCount: Int
    let monthRuntimeMinutes: Int
    let waterLitresPerVine: Double?
    let irrigationDepthMm: Double?

    enum CodingKeys: String, CodingKey {
        case vintageYear = "vintage_year"
        case totalVolumeLitres = "total_volume_litres"
        case effectiveVolumeLitres = "effective_volume_litres"
        case totalRuntimeMinutes = "total_runtime_minutes"
        case sessionCount = "session_count"
        case averageSessionMinutes = "average_session_minutes"
        case monthVolumeLitres = "month_volume_litres"
        case monthSessionCount = "month_session_count"
        case monthRuntimeMinutes = "month_runtime_minutes"
        case waterLitresPerVine = "water_litres_per_vine"
        case irrigationDepthMm = "irrigation_depth_mm"
    }
}

nonisolated struct IrrigationValveSummaryRow: Decodable, Sendable, Identifiable {
    let valveId: UUID
    let valveName: String
    let systemName: String?
    let totalVolumeLitres: Double
    let totalRuntimeMinutes: Int
    let sessionCount: Int
    let lastIrrigationDate: String?

    var id: UUID { valveId }

    enum CodingKeys: String, CodingKey {
        case valveId = "valve_id"
        case valveName = "valve_name"
        case systemName = "system_name"
        case totalVolumeLitres = "total_volume_litres"
        case totalRuntimeMinutes = "total_runtime_minutes"
        case sessionCount = "session_count"
        case lastIrrigationDate = "last_irrigation_date"
    }
}

nonisolated struct IrrigationBlockSummaryRow: Decodable, Sendable, Identifiable {
    let blockId: UUID
    let blockName: String?
    let totalVolumeLitres: Double
    let effectiveVolumeLitres: Double?
    let sessionCount: Int
    let lastIrrigationDate: String?
    let waterLitresPerVine: Double?
    let waterLitresPerHectare: Double?
    let irrigationDepthMm: Double?

    var id: UUID { blockId }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id"
        case blockName = "block_name"
        case totalVolumeLitres = "total_volume_litres"
        case effectiveVolumeLitres = "effective_volume_litres"
        case sessionCount = "session_count"
        case lastIrrigationDate = "last_irrigation_date"
        case waterLitresPerVine = "water_litres_per_vine"
        case waterLitresPerHectare = "water_litres_per_hectare"
        case irrigationDepthMm = "irrigation_depth_mm"
    }
}

nonisolated struct IrrigationVarietySummaryRow: Decodable, Sendable, Identifiable {
    let varietyName: String
    let totalVolumeLitres: Double
    let totalServicedAreaM2: Double?
    let totalServicedVines: Int?
    let averageWaterLitresPerHectare: Double?
    let averageWaterLitresPerVine: Double?
    let irrigationDepthMm: Double?

    var id: String { varietyName }

    enum CodingKeys: String, CodingKey {
        case varietyName = "variety_name"
        case totalVolumeLitres = "total_volume_litres"
        case totalServicedAreaM2 = "total_serviced_area_m2"
        case totalServicedVines = "total_serviced_vines"
        case averageWaterLitresPerHectare = "average_water_litres_per_hectare"
        case averageWaterLitresPerVine = "average_water_litres_per_vine"
        case irrigationDepthMm = "irrigation_depth_mm"
    }
}

nonisolated struct IrrigationDailySummaryRow: Decodable, Sendable, Identifiable {
    let date: String
    let totalVolumeLitres: Double
    let runtimeMinutes: Int
    let sessionCount: Int

    var id: String { date }

    enum CodingKeys: String, CodingKey {
        case date
        case totalVolumeLitres = "total_volume_litres"
        case runtimeMinutes = "runtime_minutes"
        case sessionCount = "session_count"
    }
}

nonisolated struct IrrigationMonthlySummaryRow: Decodable, Sendable, Identifiable {
    let month: String
    let totalVolumeLitres: Double
    let runtimeMinutes: Int
    let sessionCount: Int
    let irrigationDepthMm: Double?

    var id: String { month }

    enum CodingKeys: String, CodingKey {
        case month
        case totalVolumeLitres = "total_volume_litres"
        case runtimeMinutes = "runtime_minutes"
        case sessionCount = "session_count"
        case irrigationDepthMm = "irrigation_depth_mm"
    }
}

// MARK: - Offline pending session

/// A manual session recorded while offline, queued for idempotent replay.
/// The UUID is generated on-device BEFORE submission so a retry can never
/// create a duplicate record (`record_irrigation_session` is idempotent on id).
nonisolated struct IrrigationPendingSession: Codable, Sendable, Identifiable {
    let id: UUID
    let vineyardId: UUID
    let irrigationSystemId: UUID
    let valveId: UUID
    let valveName: String
    let sessionDate: String
    let durationMinutes: Int
    let calculationMethod: String
    let flowLitresPerHour: Double?
    let meterStartLitres: Double?
    let meterFinishLitres: Double?
    let totalVolumeLitres: Double?
    let startedAt: Date?
    let finishedAt: Date?
    let notes: String?
    let localTotalVolumeLitres: Double?
    let createdAt: Date
}

// MARK: - Local calculator (offline preview parity)

/// Byte-for-byte mirror of the authoritative SQL calculation core
/// (`irrigation_total_volume` + `_irrigation_allocate` in sql/125).
/// Used ONLY for offline previews and the pending-sync display — the server
/// always recomputes and its values replace local ones after sync.
nonisolated enum IrrigationLocalCalculator {
    enum CalcError: LocalizedError {
        case invalidDuration
        case invalidFlow
        case invalidMeter
        case invalidVolume

        var errorDescription: String? {
            switch self {
            case .invalidDuration: return "Duration must be a positive whole number of minutes."
            case .invalidFlow: return "Flow rate must be greater than zero."
            case .invalidMeter: return "The finishing meter reading must be greater than the starting reading."
            case .invalidVolume: return "Total volume must be greater than zero."
            }
        }
    }

    struct BlockResult: Sendable {
        let blockId: String
        let blockName: String
        let allocationPercentage: Double
        let allocatedVolumeLitres: Double
        let effectiveVolumeLitres: Double?
        let waterLitresPerVine: Double?
        let waterLitresPerHectare: Double?
        let irrigationDepthMm: Double?
    }

    struct Result: Sendable {
        let totalVolumeLitres: Double
        let effectiveVolumeLitres: Double?
        let blocks: [BlockResult]
        let warnings: [String]
    }

    static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    static func totalVolume(
        method: IrrigationCalculationMethod,
        flowLitresPerHour: Double?,
        durationMinutes: Int,
        meterStartLitres: Double?,
        meterFinishLitres: Double?,
        totalVolumeLitres: Double?
    ) throws -> Double {
        guard durationMinutes > 0 else { throw CalcError.invalidDuration }
        switch method {
        case .configuredFlow, .sessionFlow:
            guard let flow = flowLitresPerHour, flow > 0 else { throw CalcError.invalidFlow }
            return round3(flow * Double(durationMinutes) / 60.0)
        case .meterReadings:
            guard let start = meterStartLitres, let finish = meterFinishLitres,
                  finish - start > 0 else { throw CalcError.invalidMeter }
            return round3(finish - start)
        case .totalVolume:
            guard let total = totalVolumeLitres, total > 0 else { throw CalcError.invalidVolume }
            return round3(total)
        }
    }

    static func allocate(totalVolumeLitres: Double, allocations: [IrrigationAllocationConfig]) -> Result {
        var blocks: [BlockResult] = []
        var warnings: [String] = []
        var effectiveSum = 0.0
        var allHaveEfficiency = true

        for alloc in allocations {
            let pct = alloc.allocationPercentage ?? 0
            let name = alloc.blockName ?? "Block"
            let allocated = round3(totalVolumeLitres * pct / 100.0)

            var effective: Double?
            if let eff = alloc.efficiencyPercent, eff > 0 {
                effective = round3(allocated * eff / 100.0)
                effectiveSum += effective ?? 0
            } else {
                allHaveEfficiency = false
                warnings.append("Effective water could not be calculated because \(name) does not have an irrigation efficiency.")
            }

            var perVine: Double?
            if let vines = alloc.servicedVineCount, vines > 0 {
                perVine = round3(allocated / Double(vines))
            } else {
                warnings.append("Water per vine could not be calculated because \(name) does not have a serviced vine count.")
            }

            var perHa: Double?
            var depth: Double?
            if let area = alloc.servicedAreaM2, area > 0 {
                perHa = round2(allocated / (area / 10000.0))
                depth = round3(allocated / area)
            } else {
                warnings.append("Water per hectare and irrigation depth could not be calculated because \(name) does not have a serviced area.")
            }

            blocks.append(BlockResult(
                blockId: alloc.blockId,
                blockName: name,
                allocationPercentage: pct,
                allocatedVolumeLitres: allocated,
                effectiveVolumeLitres: effective,
                waterLitresPerVine: perVine,
                waterLitresPerHectare: perHa,
                irrigationDepthMm: depth
            ))
        }

        return Result(
            totalVolumeLitres: round3(totalVolumeLitres),
            effectiveVolumeLitres: allHaveEfficiency ? round3(effectiveSum) : nil,
            blocks: blocks,
            warnings: warnings
        )
    }

    // MARK: Display conversion constants (mirrors RegionFormatter)

    static let usGallonsPerLitre = 0.264172052
    static let imperialGallonsPerLitre = 0.219969157
    static let acresPerHectare = 2.471053814672
    static let millimetresPerInch = 25.4

    /// Litres per hectare → gallons per acre (US or imperial gallons).
    static func litresPerHectareToGallonsPerAcre(_ litresPerHectare: Double, usGallon: Bool) -> Double {
        let gallonsPerLitre = usGallon ? usGallonsPerLitre : imperialGallonsPerLitre
        return litresPerHectare * gallonsPerLitre / acresPerHectare
    }

    static func millimetresToInches(_ mm: Double) -> Double { mm / millimetresPerInch }
}
