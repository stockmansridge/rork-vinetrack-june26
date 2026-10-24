import Foundation
import Supabase

/// Canonical SQL 266 RPC boundary. No Fertigation table access or spray execution.
@MainActor
final class SupabaseFertigationRepository {
    typealias Object = FertigationDomain.Object
    private let adminCheck: () async throws -> Bool
    private let transport: (String, Object) async throws -> Data
    private let authority: VineyardWriteAuthority

    init(provider: SupabaseClientProvider = .shared, expectedOwnerId: UUID? = nil) {
        authority = .shared
        let admins = SupabaseSystemAdminRepository()
        adminCheck = {
            if let expectedOwnerId, provider.client.auth.currentUser?.id != expectedOwnerId { throw CancellationError() }
            let allowed = try await admins.isSystemAdmin()
            if let expectedOwnerId, provider.client.auth.currentUser?.id != expectedOwnerId { throw CancellationError() }
            return allowed
        }
        transport = { name, params in
            guard provider.isConfigured else { throw BackendRepositoryError.missingSupabaseConfiguration }
            return try await provider.client.rpc(name, params: params).execute().data
        }
    }

    /// Injection isolates request-gating assertions from production accounts.
    init(authority: VineyardWriteAuthority = .shared, adminCheck: @escaping () async throws -> Bool, transport: @escaping (String, Object) async throws -> Data) {
        self.authority = authority
        self.adminCheck = adminCheck
        self.transport = transport
    }

    private func call<T: Decodable>(_ name: String, _ params: Object, as: T.Type, writeVineyard: UUID? = nil) async throws -> T {
        let account = authority.accountBinding
        if let writeVineyard { try authority.requireWrite(vineyardId: writeVineyard.uuidString) }
        guard try await adminCheck() else { throw FertigationDomain.Failure.systemAdminRequired }
        guard authority.accountBinding == account else { throw CancellationError() }
        // The role lookup suspends. Re-admit immediately before this independent send.
        if let writeVineyard { try authority.requireWrite(vineyardId: writeVineyard.uuidString) }
        do {
            return try JSONDecoder().decode(T.self, from: await transport(name, params))
        } catch {
            guard authority.accountBinding == account else { throw CancellationError() }
            if let writeVineyard, authority.handleServerCode((error as? PostgrestError)?.code, vineyardId: writeVineyard.uuidString) {
                throw VineyardWriteAuthority.Restricted(reason: "VT_READ_ONLY")
            }
            throw error
        }
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

    /// One list request for the loaded scope, never one request per irrigation row.
    func historyIndex(vineyardId: UUID, vintageYear: Int? = nil, isSystemAdmin: Bool) async throws -> [UUID: FertigationDomain.Application] {
        guard isSystemAdmin else { return [:] }
        return FertigationHistory.index(try await applications(vineyardId: vineyardId, vintageYear: vintageYear, includeReversed: true), isSystemAdmin: true)
    }
    func historicalSession(vineyardId: UUID, sessionId: UUID, vintageYear: Int, isSystemAdmin: Bool) async throws -> FertigationDomain.Application? {
        guard isSystemAdmin else { return nil }
        if let active = try await sessionApplication(vineyardId: vineyardId, sessionId: sessionId) { return active }
        return try await historyIndex(vineyardId: vineyardId, vintageYear: vintageYear, isSystemAdmin: true)[sessionId]
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
        ], as: FertigationDomain.Application.self, writeVineyard: vineyardId)
    }

    func reverse(id: UUID, reason: String?, vineyardId: UUID? = nil) async throws -> FertigationDomain.Application {
        // An opaque ID is not authority. Verify membership using the existing authenticated read RPC.
        guard let vineyardId else { throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED") }
        try authority.requireWrite(vineyardId: vineyardId.uuidString)
        let account = authority.accountBinding
        let rows = try await applications(vineyardId: vineyardId, includeReversed: true)
        guard authority.accountBinding == account else { throw CancellationError() }
        guard rows.contains(where: { $0.id == id && (FertigationDomain.uuid($0.raw, "vineyard_id") == nil || FertigationDomain.uuid($0.raw, "vineyard_id") == vineyardId) }) else {
            throw VineyardWriteAuthority.Restricted(reason: "WRITE_SCOPE_UNRESOLVED")
        }
        return try await call("reverse_fertigation_application", [
            "p_id": .string(id.uuidString), "p_reason": reason.map { .string($0) } ?? .null
        ], as: FertigationDomain.Application.self, writeVineyard: vineyardId)
    }
}
