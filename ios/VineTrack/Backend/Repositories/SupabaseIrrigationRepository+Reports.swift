import Foundation
import Supabase

// MARK: - Phase 2B reporting RPCs (SQL 147)
//
// All authoritative calculations run in the shared backend; these methods
// only fetch and decode the enveloped raw-metric payloads.

extension SupabaseIrrigationRepository {

    private struct StandardReportParams: Encodable {
        let vineyardId: UUID
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
        var includeEstimated: Bool?
        var includeImported: Bool?
        var includeReversed: Bool?
        var includeZeroDays: Bool?
        var includeZeroWeeks: Bool?
        var groupBy: String?
        var vintageCount: Int?
        var limit: Int?
        var offset: Int?

        enum CodingKeys: String, CodingKey {
            case vineyardId = "p_vineyard_id"
            case vintageYear = "p_vintage_year"
            case dateFrom = "p_date_from"
            case dateTo = "p_date_to"
            case systemId = "p_system_id"
            case waterSource = "p_water_source"
            case valveId = "p_valve_id"
            case blockId = "p_block_id"
            case varietyId = "p_variety_id"
            case sourceType = "p_source_type"
            case sourceGroup = "p_source_group"
            case calculationMethod = "p_calculation_method"
            case measurementGroup = "p_measurement_group"
            case includeEstimated = "p_include_estimated"
            case includeImported = "p_include_imported"
            case includeReversed = "p_include_reversed"
            case includeZeroDays = "p_include_zero_days"
            case includeZeroWeeks = "p_include_zero_weeks"
            case groupBy = "p_group_by"
            case vintageCount = "p_vintage_count"
            case limit = "p_limit"
            case offset = "p_offset"
        }
    }

    private func standardParams(vineyardId: UUID,
                                filter: IrrigationReportFilter,
                                includeDates: Bool = true) -> StandardReportParams {
        StandardReportParams(
            vineyardId: vineyardId,
            vintageYear: filter.vintageYear,
            dateFrom: includeDates ? filter.dateFrom : nil,
            dateTo: includeDates ? filter.dateTo : nil,
            systemId: filter.systemId,
            waterSource: filter.waterSource,
            valveId: filter.valveId,
            blockId: filter.blockId,
            varietyId: filter.varietyId,
            sourceType: filter.sourceType,
            sourceGroup: filter.sourceGroup,
            calculationMethod: filter.calculationMethod,
            measurementGroup: filter.measurementGroup,
            includeEstimated: filter.includeEstimated,
            includeImported: filter.includeImported,
            includeReversed: filter.includeReversed)
    }

    func vintageOverview(vineyardId: UUID,
                         filter: IrrigationReportFilter) async throws -> IrrigationVintageOverview {
        try await client
            .rpc("get_irrigation_vintage_overview",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func dailyReport(vineyardId: UUID, filter: IrrigationReportFilter,
                     includeZeroDays: Bool = false)
    async throws -> IrrigationReportEnvelope<IrrigationPeriodReportRow> {
        var params = standardParams(vineyardId: vineyardId, filter: filter)
        params.includeZeroDays = includeZeroDays
        return try await client
            .rpc("get_irrigation_daily_report", params: params)
            .execute().value
    }

    func weeklyReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationPeriodReportRow> {
        try await client
            .rpc("get_irrigation_weekly_summary",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func monthlyReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationPeriodReportRow> {
        try await client
            .rpc("get_irrigation_monthly_report",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func valveReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationValveReportRow> {
        try await client
            .rpc("get_irrigation_valve_report",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func blockReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationBlockReportRow> {
        try await client
            .rpc("get_irrigation_block_report",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func varietyReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationVarietyReportRow> {
        try await client
            .rpc("get_irrigation_variety_report",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func waterSourceReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationWaterSourceReportRow> {
        try await client
            .rpc("get_irrigation_water_source_summary",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func calculationSourceReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationCalcSourceReportRow> {
        try await client
            .rpc("get_irrigation_calculation_source_summary",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func recordSourceReport(vineyardId: UUID, filter: IrrigationReportFilter)
    async throws -> IrrigationReportEnvelope<IrrigationRecordSourceReportRow> {
        try await client
            .rpc("get_irrigation_record_source_summary",
                 params: standardParams(vineyardId: vineyardId, filter: filter))
            .execute().value
    }

    func rainfallReport(vineyardId: UUID, filter: IrrigationReportFilter,
                        groupBy: String = "month")
    async throws -> IrrigationReportEnvelope<IrrigationRainfallReportRow> {
        var params = standardParams(vineyardId: vineyardId, filter: filter)
        params.groupBy = groupBy
        return try await client
            .rpc("get_irrigation_rainfall_summary", params: params)
            .execute().value
    }

    func vintageTrends(vineyardId: UUID, filter: IrrigationReportFilter,
                       vintageCount: Int = 5)
    async throws -> IrrigationReportEnvelope<IrrigationVintageTrendRow> {
        var params = standardParams(vineyardId: vineyardId, filter: filter, includeDates: false)
        params.vintageCount = vintageCount
        return try await client
            .rpc("get_irrigation_vintage_trends", params: params)
            .execute().value
    }

    /// Drill-down: sessions behind any report row (existing session model).
    func reportSessions(vineyardId: UUID, filter: IrrigationReportFilter,
                        limit: Int = 50, offset: Int = 0)
    async throws -> IrrigationSessionList {
        var params = standardParams(vineyardId: vineyardId, filter: filter)
        params.limit = limit
        params.offset = offset
        return try await client
            .rpc("list_irrigation_report_sessions", params: params)
            .execute().value
    }
}
