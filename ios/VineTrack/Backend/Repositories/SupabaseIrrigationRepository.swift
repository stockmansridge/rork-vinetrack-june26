import Foundation
import Supabase

// MARK: - RPC parameter payloads (nil keys are omitted so SQL defaults apply)

nonisolated private struct VineyardParams: Encodable, Sendable {
    let vineyardId: UUID
    var includeInactive: Bool = false
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case includeInactive = "p_include_inactive"
    }
}

nonisolated private struct SetupStatusParams: Encodable, Sendable {
    let vineyardId: UUID
    enum CodingKeys: String, CodingKey { case vineyardId = "p_vineyard_id" }
}

nonisolated private struct CreateSystemParams: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let name: String
    let waterSource: String?
    let notes: String?
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case name = "p_name"
        case waterSource = "p_water_source"
        case notes = "p_notes"
    }
}

nonisolated private struct UpdateSystemParams: Encodable, Sendable {
    let id: UUID
    let name: String?
    let waterSource: String?
    let notes: String?
    let isActive: Bool?
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case name = "p_name"
        case waterSource = "p_water_source"
        case notes = "p_notes"
        case isActive = "p_is_active"
    }
}

nonisolated private struct CreateValveParams: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let irrigationSystemId: UUID
    let name: String
    let valveNumber: String?
    let configuredFlowLitresPerHour: Double?
    let measuredFlowLitresPerHour: Double?
    let notes: String?
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case irrigationSystemId = "p_irrigation_system_id"
        case name = "p_name"
        case valveNumber = "p_valve_number"
        case configuredFlowLitresPerHour = "p_configured_flow_litres_per_hour"
        case measuredFlowLitresPerHour = "p_measured_flow_litres_per_hour"
        case notes = "p_notes"
    }
}

nonisolated private struct UpdateValveParams: Encodable, Sendable {
    let id: UUID
    let name: String?
    let valveNumber: String?
    let configuredFlowLitresPerHour: Double?
    let measuredFlowLitresPerHour: Double?
    let notes: String?
    let isActive: Bool?
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case name = "p_name"
        case valveNumber = "p_valve_number"
        case configuredFlowLitresPerHour = "p_configured_flow_litres_per_hour"
        case measuredFlowLitresPerHour = "p_measured_flow_litres_per_hour"
        case notes = "p_notes"
        case isActive = "p_is_active"
    }
}

nonisolated private struct ListValveBlocksParams: Encodable, Sendable {
    let vineyardId: UUID
    let valveId: UUID?
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case valveId = "p_valve_id"
    }
}

nonisolated struct IrrigationValveBlockInput: Encodable, Sendable {
    let blockId: UUID
    var allocationMethod: String = "manual_percentage"
    let allocationPercentage: Double?
    let servicedAreaM2: Double?
    let servicedVineCount: Int?
    let servicedEmitterCount: Int?
    enum CodingKeys: String, CodingKey {
        case blockId = "block_id"
        case allocationMethod = "allocation_method"
        case allocationPercentage = "allocation_percentage"
        case servicedAreaM2 = "serviced_area_m2"
        case servicedVineCount = "serviced_vine_count"
        case servicedEmitterCount = "serviced_emitter_count"
    }
}

nonisolated private struct SetValveBlocksParams: Encodable, Sendable {
    let vineyardId: UUID
    let valveId: UUID
    let blocks: [IrrigationValveBlockInput]
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case valveId = "p_valve_id"
        case blocks = "p_blocks"
    }
}

nonisolated private struct ListAvailableRowsParams: Encodable, Sendable {
    let vineyardId: UUID
    let blockId: UUID?
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case blockId = "p_block_id"
    }
}

nonisolated private struct ListValveRowsParams: Encodable, Sendable {
    let vineyardId: UUID
    let valveId: UUID?
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case valveId = "p_valve_id"
    }
}

nonisolated private struct SetValveRowsParams: Encodable, Sendable {
    let vineyardId: UUID
    let valveId: UUID
    let rowIds: [UUID]
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case valveId = "p_valve_id"
        case rowIds = "p_row_ids"
    }
}

nonisolated private struct ValidateParams: Encodable, Sendable {
    let vineyardId: UUID
    let valveId: UUID
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case valveId = "p_valve_id"
    }
}

nonisolated private struct PreviewParams: Encodable, Sendable {
    let vineyardId: UUID
    let valveId: UUID
    let sessionDate: String
    let durationMinutes: Int
    let calculationMethod: String
    let flowLitresPerHour: Double?
    let meterStartLitres: Double?
    let meterFinishLitres: Double?
    let totalVolumeLitres: Double?
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case valveId = "p_valve_id"
        case sessionDate = "p_session_date"
        case durationMinutes = "p_duration_minutes"
        case calculationMethod = "p_calculation_method"
        case flowLitresPerHour = "p_flow_litres_per_hour"
        case meterStartLitres = "p_meter_start_litres"
        case meterFinishLitres = "p_meter_finish_litres"
        case totalVolumeLitres = "p_total_volume_litres"
    }
}

nonisolated private struct RecordSessionParams: Encodable, Sendable {
    let id: UUID
    let vineyardId: UUID
    let irrigationSystemId: UUID
    let valveId: UUID
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
    let sourceType: String
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case vineyardId = "p_vineyard_id"
        case irrigationSystemId = "p_irrigation_system_id"
        case valveId = "p_valve_id"
        case sessionDate = "p_session_date"
        case durationMinutes = "p_duration_minutes"
        case calculationMethod = "p_calculation_method"
        case flowLitresPerHour = "p_flow_litres_per_hour"
        case meterStartLitres = "p_meter_start_litres"
        case meterFinishLitres = "p_meter_finish_litres"
        case totalVolumeLitres = "p_total_volume_litres"
        case startedAt = "p_started_at"
        case finishedAt = "p_finished_at"
        case notes = "p_notes"
        case sourceType = "p_source_type"
    }
}

nonisolated private struct UpdateSessionParams: Encodable, Sendable {
    let id: UUID
    let sessionDate: String?
    let durationMinutes: Int?
    let calculationMethod: String?
    let flowLitresPerHour: Double?
    let meterStartLitres: Double?
    let meterFinishLitres: Double?
    let totalVolumeLitres: Double?
    let startedAt: Date?
    let finishedAt: Date?
    let notes: String?
    let useCurrentConfiguration: Bool
    let clearTimes: Bool
    enum CodingKeys: String, CodingKey {
        case id = "p_id"
        case sessionDate = "p_session_date"
        case durationMinutes = "p_duration_minutes"
        case calculationMethod = "p_calculation_method"
        case flowLitresPerHour = "p_flow_litres_per_hour"
        case meterStartLitres = "p_meter_start_litres"
        case meterFinishLitres = "p_meter_finish_litres"
        case totalVolumeLitres = "p_total_volume_litres"
        case startedAt = "p_started_at"
        case finishedAt = "p_finished_at"
        case notes = "p_notes"
        case useCurrentConfiguration = "p_use_current_configuration"
        case clearTimes = "p_clear_times"
    }
}

nonisolated private struct SessionIdParams: Encodable, Sendable {
    let id: UUID
    enum CodingKeys: String, CodingKey { case id = "p_id" }
}

nonisolated private struct ListSessionsParams: Encodable, Sendable {
    let vineyardId: UUID
    let vintageYear: Int?
    let fromDate: String?
    let toDate: String?
    let irrigationSystemId: UUID?
    let valveId: UUID?
    let blockId: UUID?
    let status: String?
    /// SQL 142: exact source, or the pseudo filters 'manual' / 'imported'.
    let sourceType: String?
    let includeReversed: Bool
    let limit: Int
    let offset: Int
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case vintageYear = "p_vintage_year"
        case fromDate = "p_from_date"
        case toDate = "p_to_date"
        case irrigationSystemId = "p_irrigation_system_id"
        case valveId = "p_valve_id"
        case blockId = "p_block_id"
        case status = "p_status"
        case sourceType = "p_source_type"
        case includeReversed = "p_include_reversed"
        case limit = "p_limit"
        case offset = "p_offset"
    }
}

nonisolated private struct SummaryParams: Encodable, Sendable {
    let vineyardId: UUID
    let vintageYear: Int?
    enum CodingKeys: String, CodingKey {
        case vineyardId = "p_vineyard_id"
        case vintageYear = "p_vintage_year"
    }
}

// MARK: - Repository

/// Irrigation Records (SQL 125). All calculation authority lives server-side;
/// this repository is a thin RPC layer plus the offline pending-session queue.
final class SupabaseIrrigationRepository {
    static let shared = SupabaseIrrigationRepository()

    private let provider: SupabaseClientProvider

    init(provider: SupabaseClientProvider = .shared) {
        self.provider = provider
    }

    var client: SupabaseClient {
        get throws {
            guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
            return provider.client
        }
    }

    // MARK: Feature gate

    func hasAccess(vineyardId: UUID) async throws -> Bool {
        struct Params: Encodable { let vineyardId: UUID
            enum CodingKeys: String, CodingKey { case vineyardId = "p_vineyard_id" } }
        let result: Bool = try await client
            .rpc("has_irrigation_records_access", params: Params(vineyardId: vineyardId))
            .execute().value
        return result
    }

    /// SQL 151 — shared role-based capability set. The server is the single
    /// source of truth; the app only mirrors these flags for visibility.
    func capabilities(vineyardId: UUID) async throws -> IrrigationCapabilities {
        struct Params: Encodable { let vineyardId: UUID
            enum CodingKeys: String, CodingKey { case vineyardId = "p_vineyard_id" } }
        return try await client
            .rpc("get_irrigation_capabilities", params: Params(vineyardId: vineyardId))
            .execute().value
    }

    // MARK: Setup

    func listSystems(vineyardId: UUID, includeInactive: Bool = false) async throws -> [IrrigationSystem] {
        try await client
            .rpc("list_irrigation_systems", params: VineyardParams(vineyardId: vineyardId, includeInactive: includeInactive))
            .execute().value
    }

    @discardableResult
    func createSystem(id: UUID = UUID(), vineyardId: UUID, name: String,
                      waterSource: String?, notes: String?) async throws -> IrrigationSystem {
        try await client
            .rpc("create_irrigation_system", params: CreateSystemParams(
                id: id, vineyardId: vineyardId, name: name, waterSource: waterSource, notes: notes))
            .execute().value
    }

    @discardableResult
    func updateSystem(id: UUID, name: String? = nil, waterSource: String? = nil,
                      notes: String? = nil, isActive: Bool? = nil) async throws -> IrrigationSystem {
        try await client
            .rpc("update_irrigation_system", params: UpdateSystemParams(
                id: id, name: name, waterSource: waterSource, notes: notes, isActive: isActive))
            .execute().value
    }

    func listValves(vineyardId: UUID, includeInactive: Bool = false) async throws -> [IrrigationValve] {
        try await client
            .rpc("list_irrigation_valves", params: VineyardParams(vineyardId: vineyardId, includeInactive: includeInactive))
            .execute().value
    }

    @discardableResult
    func createValve(id: UUID = UUID(), vineyardId: UUID, systemId: UUID, name: String,
                     valveNumber: String?, configuredFlow: Double?, measuredFlow: Double?,
                     notes: String?) async throws -> IrrigationValve {
        try await client
            .rpc("create_irrigation_valve", params: CreateValveParams(
                id: id, vineyardId: vineyardId, irrigationSystemId: systemId, name: name,
                valveNumber: valveNumber, configuredFlowLitresPerHour: configuredFlow,
                measuredFlowLitresPerHour: measuredFlow, notes: notes))
            .execute().value
    }

    @discardableResult
    func updateValve(id: UUID, name: String? = nil, valveNumber: String? = nil,
                     configuredFlow: Double? = nil, measuredFlow: Double? = nil,
                     notes: String? = nil, isActive: Bool? = nil) async throws -> IrrigationValve {
        try await client
            .rpc("update_irrigation_valve", params: UpdateValveParams(
                id: id, name: name, valveNumber: valveNumber,
                configuredFlowLitresPerHour: configuredFlow,
                measuredFlowLitresPerHour: measuredFlow, notes: notes, isActive: isActive))
            .execute().value
    }

    func listValveBlocks(vineyardId: UUID, valveId: UUID? = nil) async throws -> [IrrigationValveBlock] {
        try await client
            .rpc("list_irrigation_valve_blocks", params: ListValveBlocksParams(vineyardId: vineyardId, valveId: valveId))
            .execute().value
    }

    @discardableResult
    func setValveBlocks(vineyardId: UUID, valveId: UUID,
                        blocks: [IrrigationValveBlockInput]) async throws -> [IrrigationValveBlock] {
        try await client
            .rpc("set_irrigation_valve_blocks", params: SetValveBlocksParams(
                vineyardId: vineyardId, valveId: valveId, blocks: blocks))
            .execute().value
    }

    // MARK: Row-based allocation (SQL 126)

    /// The vineyard's REAL configured rows, grouped/sortable by block.
    func listAvailableRows(vineyardId: UUID, blockId: UUID? = nil) async throws -> [IrrigationAvailableRow] {
        try await client
            .rpc("list_irrigation_available_rows", params: ListAvailableRowsParams(vineyardId: vineyardId, blockId: blockId))
            .execute().value
    }

    func listValveRows(vineyardId: UUID, valveId: UUID? = nil) async throws -> [IrrigationValveRowLink] {
        try await client
            .rpc("list_irrigation_valve_rows", params: ListValveRowsParams(vineyardId: vineyardId, valveId: valveId))
            .execute().value
    }

    /// Atomically replaces the valve's row links; the server derives the block
    /// connections and authoritative percentages (allocation_method = rows).
    @discardableResult
    func setValveRows(vineyardId: UUID, valveId: UUID, rowIds: [UUID]) async throws -> IrrigationValveRowsResult {
        try await client
            .rpc("set_irrigation_valve_rows", params: SetValveRowsParams(
                vineyardId: vineyardId, valveId: valveId, rowIds: rowIds))
            .execute().value
    }

    func setupStatus(vineyardId: UUID) async throws -> IrrigationSetupStatus {
        let status: IrrigationSetupStatus = try await client
            .rpc("get_irrigation_setup_status", params: SetupStatusParams(vineyardId: vineyardId))
            .execute().value
        return status
    }

    func validateValve(vineyardId: UUID, valveId: UUID) async throws -> IrrigationValveValidation {
        let validation: IrrigationValveValidation = try await client
            .rpc("validate_irrigation_configuration", params: ValidateParams(vineyardId: vineyardId, valveId: valveId))
            .execute().value
        cacheValidation(validation, vineyardId: vineyardId)
        return validation
    }

    // MARK: Recording

    func preview(vineyardId: UUID, valveId: UUID, sessionDate: String, durationMinutes: Int,
                 method: IrrigationCalculationMethod, flow: Double?, meterStart: Double?,
                 meterFinish: Double?, totalVolume: Double?) async throws -> IrrigationPreview {
        try await client
            .rpc("calculate_irrigation_preview", params: PreviewParams(
                vineyardId: vineyardId, valveId: valveId, sessionDate: sessionDate,
                durationMinutes: durationMinutes, calculationMethod: method.rawValue,
                flowLitresPerHour: flow, meterStartLitres: meterStart,
                meterFinishLitres: meterFinish, totalVolumeLitres: totalVolume))
            .execute().value
    }

    @discardableResult
    func recordSession(_ pending: IrrigationPendingSession) async throws -> IrrigationSession {
        try await client
            .rpc("record_irrigation_session", params: RecordSessionParams(
                id: pending.id, vineyardId: pending.vineyardId,
                irrigationSystemId: pending.irrigationSystemId, valveId: pending.valveId,
                sessionDate: pending.sessionDate, durationMinutes: pending.durationMinutes,
                calculationMethod: pending.calculationMethod,
                flowLitresPerHour: pending.flowLitresPerHour,
                meterStartLitres: pending.meterStartLitres,
                meterFinishLitres: pending.meterFinishLitres,
                totalVolumeLitres: pending.totalVolumeLitres,
                startedAt: pending.startedAt, finishedAt: pending.finishedAt,
                notes: pending.notes, sourceType: "manual_ios"))
            .execute().value
    }

    @discardableResult
    func updateSession(id: UUID, sessionDate: String?, durationMinutes: Int?,
                       method: IrrigationCalculationMethod?, flow: Double?, meterStart: Double?,
                       meterFinish: Double?, totalVolume: Double?,
                       startedAt: Date? = nil, finishedAt: Date? = nil,
                       clearTimes: Bool = false, notes: String?,
                       useCurrentConfiguration: Bool) async throws -> IrrigationSession {
        try await client
            .rpc("update_irrigation_session", params: UpdateSessionParams(
                id: id, sessionDate: sessionDate, durationMinutes: durationMinutes,
                calculationMethod: method?.rawValue, flowLitresPerHour: flow,
                meterStartLitres: meterStart, meterFinishLitres: meterFinish,
                totalVolumeLitres: totalVolume, startedAt: startedAt, finishedAt: finishedAt,
                notes: notes, useCurrentConfiguration: useCurrentConfiguration,
                clearTimes: clearTimes))
            .execute().value
    }

    @discardableResult
    func reverseSession(id: UUID) async throws -> IrrigationSession {
        try await client
            .rpc("reverse_irrigation_session", params: SessionIdParams(id: id))
            .execute().value
    }

    func getSession(id: UUID) async throws -> IrrigationSession {
        try await client
            .rpc("get_irrigation_session", params: SessionIdParams(id: id))
            .execute().value
    }

    func listSessions(vineyardId: UUID, vintageYear: Int? = nil, fromDate: String? = nil,
                      toDate: String? = nil, systemId: UUID? = nil, valveId: UUID? = nil,
                      blockId: UUID? = nil, status: String? = nil, sourceType: String? = nil,
                      includeReversed: Bool = false, limit: Int = 50, offset: Int = 0)
    async throws -> IrrigationSessionList {
        try await client
            .rpc("list_irrigation_sessions", params: ListSessionsParams(
                vineyardId: vineyardId, vintageYear: vintageYear, fromDate: fromDate,
                toDate: toDate, irrigationSystemId: systemId, valveId: valveId,
                blockId: blockId, status: status, sourceType: sourceType,
                includeReversed: includeReversed, limit: limit, offset: offset))
            .execute().value
    }

    // MARK: Reports

    func vintageSummary(vineyardId: UUID, vintageYear: Int? = nil) async throws -> IrrigationVintageSummary {
        try await client
            .rpc("get_irrigation_vintage_summary", params: SummaryParams(vineyardId: vineyardId, vintageYear: vintageYear))
            .execute().value
    }

    func valveSummary(vineyardId: UUID, vintageYear: Int? = nil) async throws -> [IrrigationValveSummaryRow] {
        try await client
            .rpc("get_irrigation_valve_summary", params: SummaryParams(vineyardId: vineyardId, vintageYear: vintageYear))
            .execute().value
    }

    func blockSummary(vineyardId: UUID, vintageYear: Int? = nil) async throws -> [IrrigationBlockSummaryRow] {
        try await client
            .rpc("get_irrigation_block_summary", params: SummaryParams(vineyardId: vineyardId, vintageYear: vintageYear))
            .execute().value
    }

    func varietySummary(vineyardId: UUID, vintageYear: Int? = nil) async throws -> [IrrigationVarietySummaryRow] {
        try await client
            .rpc("get_irrigation_variety_summary", params: SummaryParams(vineyardId: vineyardId, vintageYear: vintageYear))
            .execute().value
    }

    func dailySummary(vineyardId: UUID, vintageYear: Int? = nil) async throws -> [IrrigationDailySummaryRow] {
        try await client
            .rpc("get_irrigation_daily_summary", params: SummaryParams(vineyardId: vineyardId, vintageYear: vintageYear))
            .execute().value
    }

    func monthlySummary(vineyardId: UUID, vintageYear: Int? = nil) async throws -> [IrrigationMonthlySummaryRow] {
        try await client
            .rpc("get_irrigation_monthly_summary", params: SummaryParams(vineyardId: vineyardId, vintageYear: vintageYear))
            .execute().value
    }

    // MARK: - Offline support
    //
    // Manual entry works offline: the form calculates a local preview using
    // the cached valve validation (IrrigationLocalCalculator mirrors the SQL
    // core), queues the pending session with its pre-generated UUID, and this
    // repository replays the queue when connectivity returns. The server's
    // idempotent RPC guarantees a retry can never duplicate a record.

    private let pendingKey = "vinetrack_irrigation_pending_sessions"

    private func cacheKey(_ vineyardId: UUID) -> String {
        "vinetrack_irrigation_valve_cache_\(vineyardId.uuidString)"
    }

    func pendingSessions() -> [IrrigationPendingSession] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey) else { return [] }
        return (try? JSONDecoder().decode([IrrigationPendingSession].self, from: data)) ?? []
    }

    func enqueuePending(_ session: IrrigationPendingSession) {
        var queue = pendingSessions()
        guard !queue.contains(where: { $0.id == session.id }) else { return }
        queue.append(session)
        persistPending(queue)
    }

    func removePending(id: UUID) {
        persistPending(pendingSessions().filter { $0.id != id })
    }

    private func persistPending(_ queue: [IrrigationPendingSession]) {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: pendingKey)
        }
    }

    /// Replays every queued offline session. Idempotent server-side; a session
    /// is only removed from the queue once the server confirms it.
    @discardableResult
    func flushPending(vineyardId: UUID) async -> Int {
        var flushed = 0
        for pending in pendingSessions() where pending.vineyardId == vineyardId {
            do {
                _ = try await recordSession(pending)
                removePending(id: pending.id)
                flushed += 1
            } catch {
                print("[Irrigation] pending replay failed for \(pending.id): \(error.localizedDescription)")
            }
        }
        return flushed
    }

    // Cached valve validations so the record form works offline.

    func cacheValidation(_ validation: IrrigationValveValidation, vineyardId: UUID) {
        var cache = cachedValidations(vineyardId: vineyardId)
        cache.removeAll { $0.valveId == validation.valveId }
        cache.append(CachedValidation(from: validation))
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey(vineyardId))
        }
    }

    func cachedValidation(vineyardId: UUID, valveId: UUID) -> IrrigationValveValidation? {
        cachedValidations(vineyardId: vineyardId).first { $0.valveId == valveId }?.toValidation()
    }

    private func cachedValidations(vineyardId: UUID) -> [CachedValidation] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(vineyardId)) else { return [] }
        return (try? JSONDecoder().decode([CachedValidation].self, from: data)) ?? []
    }
}

// MARK: - Cached validation (Codable snapshot of IrrigationValveValidation)

nonisolated private struct CachedValidation: Codable, Sendable {
    struct Allocation: Codable, Sendable {
        let blockId: String
        let blockName: String?
        let varietyName: String?
        let allocationPercentage: Double?
        let servicedAreaM2: Double?
        let servicedVineCount: Int?
        let servicedEmitterCount: Int?
        let efficiencyPercent: Double?
    }

    let valveId: UUID
    let valveName: String
    let canRecord: Bool
    let hasConfiguredFlow: Bool
    let configuredFlowLitresPerHour: Double?
    let requiresVolumeEntry: Bool
    // SQL 131 resolved-flow snapshot (optional so pre-131 caches still decode).
    let configuredFlowAvailable: Bool?
    let resolvedFlowLitresPerHour: Double?
    let resolvedFlowSource: String?
    let resolvedFlowIsEstimated: Bool?
    let resolvedFlowWarning: String?
    let resolvedFlowEmitterCount: Int?
    let allocations: [Allocation]
    let allocationTotal: Double
    let issues: [String]

    init(from validation: IrrigationValveValidation) {
        valveId = validation.valveId
        valveName = validation.valveName
        canRecord = validation.canRecord
        hasConfiguredFlow = validation.hasConfiguredFlow
        configuredFlowLitresPerHour = validation.configuredFlowLitresPerHour
        requiresVolumeEntry = validation.requiresVolumeEntry
        configuredFlowAvailable = validation.configuredFlowAvailable
        resolvedFlowLitresPerHour = validation.resolvedFlowLitresPerHour
        resolvedFlowSource = validation.resolvedFlowSource
        resolvedFlowIsEstimated = validation.resolvedFlowIsEstimated
        resolvedFlowWarning = validation.resolvedFlowWarning
        resolvedFlowEmitterCount = validation.resolvedFlowEmitterCount
        allocationTotal = validation.allocationTotal
        issues = validation.issues
        allocations = validation.allocations.map {
            Allocation(blockId: $0.blockId, blockName: $0.blockName, varietyName: $0.varietyName,
                       allocationPercentage: $0.allocationPercentage, servicedAreaM2: $0.servicedAreaM2,
                       servicedVineCount: $0.servicedVineCount, servicedEmitterCount: $0.servicedEmitterCount,
                       efficiencyPercent: $0.efficiencyPercent)
        }
    }

    func toValidation() -> IrrigationValveValidation? {
        var json: [String: Any] = [
            "valve_id": valveId.uuidString,
            "valve_name": valveName,
            "can_record": canRecord,
            "has_configured_flow": hasConfiguredFlow,
            "requires_volume_entry": requiresVolumeEntry,
            "allocation_total": allocationTotal,
            "issues": issues
        ]
        if let flow = configuredFlowLitresPerHour {
            json["configured_flow_litres_per_hour"] = flow
        }
        if let v = configuredFlowAvailable { json["configured_flow_available"] = v }
        if let v = resolvedFlowLitresPerHour { json["resolved_flow_litres_per_hour"] = v }
        if let v = resolvedFlowSource { json["resolved_flow_source"] = v }
        if let v = resolvedFlowIsEstimated { json["resolved_flow_is_estimated"] = v }
        if let v = resolvedFlowWarning { json["resolved_flow_warning"] = v }
        if let v = resolvedFlowEmitterCount { json["resolved_flow_emitter_count"] = v }
        json["allocations"] = allocations.map { alloc in
            var dict: [String: Any] = ["block_id": alloc.blockId]
            if let v = alloc.blockName { dict["block_name"] = v }
            if let v = alloc.varietyName { dict["variety_name"] = v }
            if let v = alloc.allocationPercentage { dict["allocation_percentage"] = v }
            if let v = alloc.servicedAreaM2 { dict["serviced_area_m2"] = v }
            if let v = alloc.servicedVineCount { dict["serviced_vine_count"] = v }
            if let v = alloc.servicedEmitterCount { dict["serviced_emitter_count"] = v }
            if let v = alloc.efficiencyPercent { dict["efficiency_percent"] = v }
            return dict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? JSONDecoder().decode(IrrigationValveValidation.self, from: data)
    }
}
