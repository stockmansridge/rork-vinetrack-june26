import Foundation

// MARK: - Phase 2B irrigation reporting models (SQL 147 envelope contract)
//
// Every report RPC returns a stable envelope with raw METRIC values
// (litres, mm, minutes, hectares). Conversion happens client-side only.

nonisolated struct IrrigationReportWarning: Decodable, Sendable, Identifiable, Hashable {
    let code: String
    let severity: String?
    let message: String
    let affectedCount: Int?

    var id: String { code + message }

    enum CodingKeys: String, CodingKey {
        case code, severity, message
        case affectedCount = "affected_count"
    }
}

/// Generic report envelope for row-based reports.
nonisolated struct IrrigationReportEnvelope<Row: Decodable & Sendable>: Decodable, Sendable {
    let report: String?
    let vintageYear: Int?
    let periodStart: String?
    let periodEnd: String?
    let groupBy: String?
    let totalLitres: Double?
    let rows: [Row]
    let warnings: [IrrigationReportWarning]?

    enum CodingKeys: String, CodingKey {
        case report, rows, warnings
        case vintageYear = "vintage_year"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case groupBy = "group_by"
        case totalLitres = "total_litres"
    }
}

nonisolated struct IrrigationVintageOverview: Decodable, Sendable {
    let vintageYear: Int
    let periodStart: String?
    let periodEnd: String?
    let totalIrrigationLitres: Double
    let effectiveIrrigationLitres: Double?
    let directlyReportedLitres: Double?
    let directlyMeasuredLitres: Double?
    let calculatedLitres: Double?
    let estimatedLitres: Double?
    let manualLitres: Double?
    let importedLitres: Double?
    let averageSessionLitres: Double?
    let totalRuntimeMinutes: Int
    let sessionCount: Int
    let averageSessionMinutes: Double?
    let longestSessionMinutes: Int?
    let shortestSessionMinutes: Int?
    let systemsUsed: Int?
    let waterSourcesUsed: Int?
    let valvesUsed: Int?
    let blocksIrrigated: Int?
    let varietiesIrrigated: Int?
    let servicedAreaHectares: Double?
    let servicedVines: Int?
    let litresPerHectare: Double?
    let litresPerVine: Double?
    let irrigationDepthMm: Double?
    let effectiveIrrigationDepthMm: Double?
    let firstIrrigationDate: String?
    let lastIrrigationDate: String?
    let daysSinceLastIrrigation: Int?
    let highestUseDate: String?
    let highestUseDateLitres: Double?
    let highestUseMonth: String?
    let highestUseMonthLitres: Double?
    let previousVintageYear: Int?
    let previousTotalLitres: Double?
    let volumeDifferenceLitres: Double?
    let volumeDifferencePercent: Double?
    let previousDepthMm: Double?
    let depthDifferenceMm: Double?
    let previousRuntimeMinutes: Int?
    let runtimeDifferenceMinutes: Int?
    let previousSessionCount: Int?
    let sessionCountDifference: Int?
    let rainfallMm: Double?
    let rainfallDataComplete: Bool?
    let dataQuality: String?
    let warnings: [IrrigationReportWarning]?

    enum CodingKeys: String, CodingKey {
        case vintageYear = "vintage_year"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case totalIrrigationLitres = "total_irrigation_litres"
        case effectiveIrrigationLitres = "effective_irrigation_litres"
        case directlyReportedLitres = "directly_reported_litres"
        case directlyMeasuredLitres = "directly_measured_litres"
        case calculatedLitres = "calculated_litres"
        case estimatedLitres = "estimated_litres"
        case manualLitres = "manual_litres"
        case importedLitres = "imported_litres"
        case averageSessionLitres = "average_session_litres"
        case totalRuntimeMinutes = "total_runtime_minutes"
        case sessionCount = "session_count"
        case averageSessionMinutes = "average_session_minutes"
        case longestSessionMinutes = "longest_session_minutes"
        case shortestSessionMinutes = "shortest_session_minutes"
        case systemsUsed = "systems_used"
        case waterSourcesUsed = "water_sources_used"
        case valvesUsed = "valves_used"
        case blocksIrrigated = "blocks_irrigated"
        case varietiesIrrigated = "varieties_irrigated"
        case servicedAreaHectares = "serviced_area_hectares"
        case servicedVines = "serviced_vines"
        case litresPerHectare = "litres_per_hectare"
        case litresPerVine = "litres_per_vine"
        case irrigationDepthMm = "irrigation_depth_mm"
        case effectiveIrrigationDepthMm = "effective_irrigation_depth_mm"
        case firstIrrigationDate = "first_irrigation_date"
        case lastIrrigationDate = "last_irrigation_date"
        case daysSinceLastIrrigation = "days_since_last_irrigation"
        case highestUseDate = "highest_use_date"
        case highestUseDateLitres = "highest_use_date_litres"
        case highestUseMonth = "highest_use_month"
        case highestUseMonthLitres = "highest_use_month_litres"
        case previousVintageYear = "previous_vintage_year"
        case previousTotalLitres = "previous_total_litres"
        case volumeDifferenceLitres = "volume_difference_litres"
        case volumeDifferencePercent = "volume_difference_percent"
        case previousDepthMm = "previous_depth_mm"
        case depthDifferenceMm = "depth_difference_mm"
        case previousRuntimeMinutes = "previous_runtime_minutes"
        case runtimeDifferenceMinutes = "runtime_difference_minutes"
        case previousSessionCount = "previous_session_count"
        case sessionCountDifference = "session_count_difference"
        case rainfallMm = "rainfall_mm"
        case rainfallDataComplete = "rainfall_data_complete"
        case dataQuality = "data_quality"
        case warnings
    }
}

nonisolated struct IrrigationPeriodReportRow: Decodable, Sendable, Identifiable {
    let periodKey: String
    let periodStart: String?
    let periodEnd: String?
    let weekNumber: Int?
    let monthLabel: String?
    let totalLitres: Double
    let effectiveLitres: Double?
    let runtimeMinutes: Int
    let sessionCount: Int
    let manualLitres: Double?
    let importedLitres: Double?
    let estimatedLitres: Double?
    let directlyReportedLitres: Double?
    let valvesUsed: Int?
    let blocksIrrigated: Int?
    let servicedAreaHectares: Double?
    let litresPerHectare: Double?
    let litresPerVine: Double?
    let irrigationDepthMm: Double?
    let effectiveDepthMm: Double?
    let rainfallMm: Double?
    let combinedWaterInputMm: Double?
    let rainfallDataComplete: Bool?
    let previousVintageTotalLitres: Double?
    let previousVintageDepthMm: Double?
    let differenceLitres: Double?
    let differencePercent: Double?

    var id: String { periodKey }

    enum CodingKeys: String, CodingKey {
        case periodKey = "period_key"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case weekNumber = "week_number"
        case monthLabel = "month_label"
        case totalLitres = "total_litres"
        case effectiveLitres = "effective_litres"
        case runtimeMinutes = "runtime_minutes"
        case sessionCount = "session_count"
        case manualLitres = "manual_litres"
        case importedLitres = "imported_litres"
        case estimatedLitres = "estimated_litres"
        case directlyReportedLitres = "directly_reported_litres"
        case valvesUsed = "valves_used"
        case blocksIrrigated = "blocks_irrigated"
        case servicedAreaHectares = "serviced_area_hectares"
        case litresPerHectare = "litres_per_hectare"
        case litresPerVine = "litres_per_vine"
        case irrigationDepthMm = "irrigation_depth_mm"
        case effectiveDepthMm = "effective_depth_mm"
        case rainfallMm = "rainfall_mm"
        case combinedWaterInputMm = "combined_water_input_mm"
        case rainfallDataComplete = "rainfall_data_complete"
        case previousVintageTotalLitres = "previous_vintage_total_litres"
        case previousVintageDepthMm = "previous_vintage_depth_mm"
        case differenceLitres = "difference_litres"
        case differencePercent = "difference_percent"
    }
}

nonisolated struct IrrigationValveReportRow: Decodable, Sendable, Identifiable {
    let valveId: UUID
    let valveName: String
    let valveNumber: String?
    let systemName: String?
    let waterSource: String?
    let allocationMethod: String?
    let automaticFlowSource: String?
    let sessionCount: Int
    let totalLitres: Double
    let effectiveLitres: Double?
    let runtimeMinutes: Int
    let averageSessionMinutes: Double?
    let averageFlowLitresPerHour: Double?
    let manualLitres: Double?
    let importedLitres: Double?
    let estimatedLitres: Double?
    let directlyReportedLitres: Double?
    let blocksSupplied: Int?
    let rowsSupplied: Int?
    let firstUse: String?
    let lastUse: String?
    let daysSinceLastUse: Int?
    let percentOfVineyardTotal: Double?
    let warnings: [IrrigationReportWarning]?

    var id: UUID { valveId }

    enum CodingKeys: String, CodingKey {
        case valveId = "valve_id"
        case valveName = "valve_name"
        case valveNumber = "valve_number"
        case systemName = "system_name"
        case waterSource = "water_source"
        case allocationMethod = "allocation_method"
        case automaticFlowSource = "automatic_flow_source"
        case sessionCount = "session_count"
        case totalLitres = "total_litres"
        case effectiveLitres = "effective_litres"
        case runtimeMinutes = "runtime_minutes"
        case averageSessionMinutes = "average_session_minutes"
        case averageFlowLitresPerHour = "average_flow_litres_per_hour"
        case manualLitres = "manual_litres"
        case importedLitres = "imported_litres"
        case estimatedLitres = "estimated_litres"
        case directlyReportedLitres = "directly_reported_litres"
        case blocksSupplied = "blocks_supplied"
        case rowsSupplied = "rows_supplied"
        case firstUse = "first_use"
        case lastUse = "last_use"
        case daysSinceLastUse = "days_since_last_use"
        case percentOfVineyardTotal = "percent_of_vineyard_total"
        case warnings
    }
}

nonisolated struct IrrigationBlockReportRow: Decodable, Sendable, Identifiable {
    let blockId: UUID
    let blockName: String?
    let varietyName: String?
    let sessionCount: Int
    let totalLitres: Double
    let effectiveLitres: Double?
    let runtimeMinutes: Int?
    let servicedAreaHectares: Double?
    let servicedVines: Int?
    let litresPerHectare: Double?
    let litresPerVine: Double?
    let irrigationDepthMm: Double?
    let effectiveDepthMm: Double?
    let rainfallMm: Double?
    let combinedWaterInputMm: Double?
    let manualLitres: Double?
    let importedLitres: Double?
    let estimatedLitres: Double?
    let firstIrrigationDate: String?
    let lastIrrigationDate: String?
    let daysSinceLastIrrigation: Int?
    let previousVintageLitres: Double?
    let differenceLitres: Double?
    let differencePercent: Double?
    let warnings: [IrrigationReportWarning]?

    var id: UUID { blockId }

    enum CodingKeys: String, CodingKey {
        case blockId = "block_id"
        case blockName = "block_name"
        case varietyName = "variety_name"
        case sessionCount = "session_count"
        case totalLitres = "total_litres"
        case effectiveLitres = "effective_litres"
        case runtimeMinutes = "runtime_minutes"
        case servicedAreaHectares = "serviced_area_hectares"
        case servicedVines = "serviced_vines"
        case litresPerHectare = "litres_per_hectare"
        case litresPerVine = "litres_per_vine"
        case irrigationDepthMm = "irrigation_depth_mm"
        case effectiveDepthMm = "effective_depth_mm"
        case rainfallMm = "rainfall_mm"
        case combinedWaterInputMm = "combined_water_input_mm"
        case manualLitres = "manual_litres"
        case importedLitres = "imported_litres"
        case estimatedLitres = "estimated_litres"
        case firstIrrigationDate = "first_irrigation_date"
        case lastIrrigationDate = "last_irrigation_date"
        case daysSinceLastIrrigation = "days_since_last_irrigation"
        case previousVintageLitres = "previous_vintage_litres"
        case differenceLitres = "difference_litres"
        case differencePercent = "difference_percent"
        case warnings
    }
}

nonisolated struct IrrigationVarietyReportRow: Decodable, Sendable, Identifiable {
    let varietyName: String
    let blockCount: Int?
    let sessionCount: Int
    let totalLitres: Double
    let effectiveLitres: Double?
    let servicedAreaHectares: Double?
    let servicedVines: Int?
    let litresPerHectare: Double?
    let litresPerVine: Double?
    let irrigationDepthMm: Double?
    let effectiveDepthMm: Double?
    let rainfallMm: Double?
    let combinedWaterInputMm: Double?
    let manualLitres: Double?
    let importedLitres: Double?
    let previousVintageLitres: Double?
    let differenceLitres: Double?
    let differencePercent: Double?

    var id: String { varietyName }

    enum CodingKeys: String, CodingKey {
        case varietyName = "variety_name"
        case blockCount = "block_count"
        case sessionCount = "session_count"
        case totalLitres = "total_litres"
        case effectiveLitres = "effective_litres"
        case servicedAreaHectares = "serviced_area_hectares"
        case servicedVines = "serviced_vines"
        case litresPerHectare = "litres_per_hectare"
        case litresPerVine = "litres_per_vine"
        case irrigationDepthMm = "irrigation_depth_mm"
        case effectiveDepthMm = "effective_depth_mm"
        case rainfallMm = "rainfall_mm"
        case combinedWaterInputMm = "combined_water_input_mm"
        case manualLitres = "manual_litres"
        case importedLitres = "imported_litres"
        case previousVintageLitres = "previous_vintage_litres"
        case differenceLitres = "difference_litres"
        case differencePercent = "difference_percent"
    }
}

nonisolated struct IrrigationWaterSourceReportRow: Decodable, Sendable, Identifiable {
    let waterSource: String
    let systemCount: Int?
    let valveCount: Int?
    let sessionCount: Int
    let totalLitres: Double
    let effectiveLitres: Double?
    let runtimeMinutes: Int?
    let percentOfVineyardTotal: Double?
    let manualLitres: Double?
    let importedLitres: Double?
    let estimatedLitres: Double?
    let directlyReportedLitres: Double?
    let firstUse: String?
    let lastUse: String?

    var id: String { waterSource }

    enum CodingKeys: String, CodingKey {
        case waterSource = "water_source"
        case systemCount = "system_count"
        case valveCount = "valve_count"
        case sessionCount = "session_count"
        case totalLitres = "total_litres"
        case effectiveLitres = "effective_litres"
        case runtimeMinutes = "runtime_minutes"
        case percentOfVineyardTotal = "percent_of_vineyard_total"
        case manualLitres = "manual_litres"
        case importedLitres = "imported_litres"
        case estimatedLitres = "estimated_litres"
        case directlyReportedLitres = "directly_reported_litres"
        case firstUse = "first_use"
        case lastUse = "last_use"
    }
}

nonisolated struct IrrigationCalcSourceReportRow: Decodable, Sendable, Identifiable {
    let calculationMethod: String
    let calculationLabel: String?
    let measurementGroup: String?
    let measurementLabel: String?
    let sessionCount: Int
    let totalLitres: Double
    let percentOfTotalLitres: Double?
    let runtimeMinutes: Int?

    var id: String { calculationMethod + (measurementGroup ?? "") }

    enum CodingKeys: String, CodingKey {
        case calculationMethod = "calculation_method"
        case calculationLabel = "calculation_label"
        case measurementGroup = "measurement_group"
        case measurementLabel = "measurement_label"
        case sessionCount = "session_count"
        case totalLitres = "total_litres"
        case percentOfTotalLitres = "percent_of_total_litres"
        case runtimeMinutes = "runtime_minutes"
    }
}

nonisolated struct IrrigationRecordSourceReportRow: Decodable, Sendable, Identifiable {
    let sourceType: String
    let sourceLabel: String?
    let sourceGroup: String?
    let sessionCount: Int
    let totalLitres: Double
    let percentOfTotalLitres: Double?
    let firstRecordedAt: String?
    let lastRecordedAt: String?

    var id: String { sourceType }

    enum CodingKeys: String, CodingKey {
        case sourceType = "source_type"
        case sourceLabel = "source_label"
        case sourceGroup = "source_group"
        case sessionCount = "session_count"
        case totalLitres = "total_litres"
        case percentOfTotalLitres = "percent_of_total_litres"
        case firstRecordedAt = "first_recorded_at"
        case lastRecordedAt = "last_recorded_at"
    }
}

nonisolated struct IrrigationRainfallReportRow: Decodable, Sendable, Identifiable {
    let periodKey: String
    let periodStart: String?
    let periodEnd: String?
    let rainfallMm: Double?
    let grossIrrigationDepthMm: Double?
    let effectiveIrrigationDepthMm: Double?
    let combinedWaterInputMm: Double?
    let irrigationPercentOfCombined: Double?
    let rainfallPercentOfCombined: Double?
    let rainfallDataComplete: Bool?

    var id: String { periodKey }

    enum CodingKeys: String, CodingKey {
        case periodKey = "period_key"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case rainfallMm = "rainfall_mm"
        case grossIrrigationDepthMm = "gross_irrigation_depth_mm"
        case effectiveIrrigationDepthMm = "effective_irrigation_depth_mm"
        case combinedWaterInputMm = "combined_water_input_mm"
        case irrigationPercentOfCombined = "irrigation_percent_of_combined"
        case rainfallPercentOfCombined = "rainfall_percent_of_combined"
        case rainfallDataComplete = "rainfall_data_complete"
    }
}

nonisolated struct IrrigationVintageTrendRow: Decodable, Sendable, Identifiable {
    let vintageYear: Int
    let periodStart: String?
    let periodEnd: String?
    let totalLitres: Double
    let effectiveLitres: Double?
    let manualLitres: Double?
    let importedLitres: Double?
    let estimatedLitres: Double?
    let directlyReportedLitres: Double?
    let runtimeMinutes: Int?
    let sessionCount: Int
    let servicedAreaHectares: Double?
    let litresPerHectare: Double?
    let litresPerVine: Double?
    let irrigationDepthMm: Double?
    let effectiveDepthMm: Double?
    let rainfallMm: Double?
    let combinedWaterInputMm: Double?
    let dataQuality: String?
    let warnings: [IrrigationReportWarning]?

    var id: Int { vintageYear }

    enum CodingKeys: String, CodingKey {
        case vintageYear = "vintage_year"
        case periodStart = "period_start"
        case periodEnd = "period_end"
        case totalLitres = "total_litres"
        case effectiveLitres = "effective_litres"
        case manualLitres = "manual_litres"
        case importedLitres = "imported_litres"
        case estimatedLitres = "estimated_litres"
        case directlyReportedLitres = "directly_reported_litres"
        case runtimeMinutes = "runtime_minutes"
        case sessionCount = "session_count"
        case servicedAreaHectares = "serviced_area_hectares"
        case litresPerHectare = "litres_per_hectare"
        case litresPerVine = "litres_per_vine"
        case irrigationDepthMm = "irrigation_depth_mm"
        case effectiveDepthMm = "effective_depth_mm"
        case rainfallMm = "rainfall_mm"
        case combinedWaterInputMm = "combined_water_input_mm"
        case dataQuality = "data_quality"
        case warnings
    }
}

/// Shared client-side filter for every Phase 2B report call.
nonisolated struct IrrigationReportFilter: Sendable, Equatable {
    var vintageYear: Int?
    var dateFrom: String?
    var dateTo: String?
    var systemId: UUID?
    var waterSource: String?
    var valveId: UUID?
    var blockId: UUID?
    var varietyId: UUID?
    var sourceType: String?
    var sourceGroup: String?
    var calculationMethod: String?
    var measurementGroup: String?
    var includeEstimated: Bool = true
    var includeImported: Bool = true
    var includeReversed: Bool = false
}
