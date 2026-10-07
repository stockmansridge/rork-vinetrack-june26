import Foundation
import Supabase

/// Canonical SQL 266 RPC boundary. No Fertigation table access or spray execution.
@MainActor
final class SupabaseFertigationRepository {
    typealias Object = FertigationDomain.Object
    private let adminCheck: () async throws -> Bool
    private let transport: (String, Object) async throws -> Data

    init(provider: SupabaseClientProvider = .shared) {
        let admins = SupabaseSystemAdminRepository()
        adminCheck = { try await admins.isSystemAdmin() }
        transport = { name, params in
            guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
            return try await provider.client.rpc(name, params: params).execute().data
        }
    }

    /// Injection isolates request-gating assertions from production accounts.
    init(adminCheck: @escaping () async throws -> Bool, transport: @escaping (String, Object) async throws -> Data) {
        self.adminCheck = adminCheck
        self.transport = transport
    }

    private func call<T: Decodable>(_ name: String, _ params: Object, as: T.Type) async throws -> T {
        guard try await adminCheck() else { throw FertigationDomain.Failure.systemAdminRequired }
        return try JSONDecoder().decode(T.self, from: await transport(name, params))
    }

    func capabilities(vineyardId: UUID) async throws -> Object {
        try await call("get_fertigation_capabilities", ["p_vineyard_id": .string(vineyardId.uuidString)], as: Object.self)
    }

    func programSteps(vineyardId: UUID) async throws -> [FertigationDomain.ProgramStep] {
        let steps = try await call("list_fertigation_program_steps", ["p_vineyard_id": .string(vineyardId.uuidString)], as: [FertigationDomain.ProgramStep].self)
        return steps.filter { $0.isSelectable(vineyardId: vineyardId, isSystemAdmin: true) }
    }

    func sessionApplication(vineyardId: UUID, sessionId: UUID) async throws -> FertigationDomain.Application? {
        try await call("get_irrigation_session_fertigation", [
            "p_vineyard_id": .string(vineyardId.uuidString),
            "p_irrigation_session_id": .string(sessionId.uuidString)
        ], as: FertigationDomain.Application?.self)
    }

    func applications(vineyardId: UUID, vintageYear: Int? = nil, programStepId: UUID? = nil, includeReversed: Bool = false) async throws -> [FertigationDomain.Application] {
        try await call("list_fertigation_applications", [
            "p_vineyard_id": .string(vineyardId.uuidString),
            "p_vintage_year": vintageYear.map { .number(Double($0)) } ?? .null,
            "p_program_step_id": programStepId.map { .string($0.uuidString) } ?? .null,
            "p_include_reversed": .bool(includeReversed)
        ], as: [FertigationDomain.Application].self)
    }

    func upsert(id: UUID, vineyardId: UUID, sessionId: UUID, stepId: UUID, frozenName: String?, growthStageCode: String?, notes: String?, products: [Object]) async throws -> FertigationDomain.Application {
        try await call("upsert_fertigation_application", [
            "p_id": .string(id.uuidString),
            "p_vineyard_id": .string(vineyardId.uuidString),
            "p_irrigation_session_id": .string(sessionId.uuidString),
            "p_program_step_id": .string(stepId.uuidString),
            "p_program_step_name": frozenName.map { .string($0) } ?? .null,
            "p_growth_stage_code": growthStageCode.map { .string($0) } ?? .null,
            "p_notes": notes.map { .string($0) } ?? .null,
            "p_products": .array(products.map { .object($0) })
        ], as: FertigationDomain.Application.self)
    }

    func reverse(id: UUID, reason: String?) async throws -> FertigationDomain.Application {
        try await call("reverse_fertigation_application", [
            "p_id": .string(id.uuidString), "p_reason": reason.map { .string($0) } ?? .null
        ], as: FertigationDomain.Application.self)
    }
}
