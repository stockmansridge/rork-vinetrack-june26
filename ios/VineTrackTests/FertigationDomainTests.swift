import Foundation
import Testing
@testable import VineTrack

@MainActor
struct FertigationDomainTests {
    private let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let stepId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    @Test func deniedAdminMakesNoFertigationRequests() async throws {
        var calls: Int = 0
        let repo = SupabaseFertigationRepository(adminCheck: { false }, transport: { _, _ in
            calls += 1; return Data("{}".utf8)
        })
        do { _ = try await repo.capabilities(vineyardId: vineyardId); Issue.record("Gate accepted non-admin") }
        catch { #expect(error is FertigationDomain.Failure) }
        #expect(calls == 0)
    }

    @Test func programStepSelectionRequiresAdminTemplateVineyardAndMethod() {
        var raw: FertigationDomain.Object = ["id": .string(stepId.uuidString), "vineyard_id": .string(vineyardId.uuidString), "is_template": .bool(true), "operation_type": .string("Fertigation")]
        #expect(FertigationDomain.ProgramStep(raw: raw).isSelectable(vineyardId: vineyardId, isSystemAdmin: true))
        #expect(!FertigationDomain.ProgramStep(raw: raw).isSelectable(vineyardId: vineyardId, isSystemAdmin: false))
        #expect(!FertigationDomain.ProgramStep(raw: raw).isSelectable(vineyardId: UUID(), isSystemAdmin: true))
        raw["is_template"] = .bool(false)
        #expect(!FertigationDomain.ProgramStep(raw: raw).isSelectable(vineyardId: vineyardId, isSystemAdmin: true))
        raw["is_template"] = .bool(true); raw["operation_type"] = .string("Foliar Spray")
        #expect(!FertigationDomain.ProgramStep(raw: raw).isSelectable(vineyardId: vineyardId, isSystemAdmin: true))
        raw["operation_type"] = .string("Fertigation"); raw["deleted_at"] = .string("2026-10-07")
        #expect(!FertigationDomain.ProgramStep(raw: raw).isSelectable(vineyardId: vineyardId, isSystemAdmin: true))
    }

    @Test func canonicalRpcNamesAndExplicitNullParameters() async throws {
        var requests: [(String, FertigationDomain.Object)] = []
        let repo = SupabaseFertigationRepository(adminCheck: { true }, transport: { name, params in
            requests.append((name, params))
            return Data((name == "list_fertigation_applications" || name == "list_fertigation_program_steps" ? "[]" : name == "get_irrigation_session_fertigation" ? "null" : "{}").utf8)
        })
        _ = try await repo.capabilities(vineyardId: vineyardId)
        _ = try await repo.programSteps(vineyardId: vineyardId)
        _ = try await repo.sessionApplication(vineyardId: vineyardId, sessionId: stepId)
        _ = try await repo.applications(vineyardId: vineyardId, programStepId: stepId, includeReversed: true)
        _ = try await repo.upsert(id: stepId, vineyardId: vineyardId, sessionId: stepId, stepId: stepId, frozenName: nil, growthStageCode: nil, notes: nil, products: [])
        _ = try await repo.reverse(id: stepId, reason: nil)
        #expect(requests.map(\.0) == ["get_fertigation_capabilities", "list_fertigation_program_steps", "get_irrigation_session_fertigation", "list_fertigation_applications", "upsert_fertigation_application", "reverse_fertigation_application"])
        #expect(requests[3].1["p_program_step_id"] == .string(stepId.uuidString))
        #expect(requests[3].1["p_vintage_year"] == .null)
        #expect(requests[4].1["p_notes"] == .null)
    }

    @Test func hectaresUseOnlyAuthoritativeAllocations() {
        let totals = FertigationDomain.Totals(allocations: [.init(areaM2: 9620, vines: 4500)])
        let result = FertigationDomain.plannedQuantity(line: ["rate": .number(10), "fertigation_rate_basis": .string("per_hectare"), "fertigation_rate_unit": .string("kg/ha")], totals: totals)
        #expect(result.quantity == 9.62); #expect(result.unit == "kg")
    }

    @Test(arguments: ["g/vine", "mL/vine"])
    func vineConversion(unit: String) {
        let result = FertigationDomain.plannedQuantity(line: ["rate": .number(25), "fertigation_rate_basis": .string("per_vine"), "fertigation_rate_unit": .string(unit)], totals: .init(allocations: [.init(areaM2: 9620, vines: 4500)]))
        #expect(result.quantity == 112.5)
        #expect(result.unit == (unit == "g/vine" ? "kg" : "L"))
    }

    @Test func cycleDoesNotNeedGeometry() {
        #expect(FertigationDomain.plannedQuantity(line: ["rate": .number(50), "fertigation_rate_basis": .string("per_irrigation_cycle"), "fertigation_rate_unit": .string("kg")], totals: .init(allocations: [])).quantity == 50)
    }

    @Test func missingAllocationIsNullNotZero() {
        let totals = FertigationDomain.Totals(allocations: [.init(areaM2: 9620, vines: 4500), .init(areaM2: nil, vines: nil)])
        #expect(totals.areaHa == nil); #expect(totals.vines == nil)
        #expect(FertigationDomain.Totals(allocations: []).areaHa == nil)
        #expect(FertigationDomain.Totals(allocations: [.init(areaM2: 0, vines: 0)]).vines == nil)
    }

    @Test func sprayBasisCannotBeInferred() {
        let line: FertigationDomain.Object = ["rate": .number(10), "unit": .string("L/100 L")]
        #expect(FertigationDomain.plannedQuantity(line: line, totals: .init(allocations: [.init(areaM2: 10000, vines: 1000)])).quantity == nil)
        #expect(FertigationDomain.rateText(line: line) == "Rate not set")
    }

    @Test func savedUnitNotProductFormAndUnknownKeysRoundTrip() throws {
        let line: FertigationDomain.Object = ["chemical_id": .string(stepId.uuidString), "rate": .number(10), "fertigation_rate_basis": .string("per_hectare"), "fertigation_rate_unit": .string("kg/ha"), "product_form": .string("liquid"), "future_key": .object(["nested": .array([.null, .bool(true)])])]
        let step = FertigationDomain.ProgramStep(raw: ["chemical_lines": .array([.object(line)])])
        let decoded = try JSONDecoder().decode(FertigationDomain.ProgramStep.self, from: JSONEncoder().encode(step))
        #expect(decoded.lines[0] == line)
        #expect(FertigationDomain.rateText(line: decoded.lines[0]) == "10 kg/ha")
    }

    @Test func actualSeparateAndIdsStableAcrossPayloadRetries() throws {
        let line: FertigationDomain.Object = ["chemical_id": .string(stepId.uuidString), "name": .string("Nutrient"), "rate": .number(10), "fertigation_rate_basis": .string("per_hectare"), "fertigation_rate_unit": .string("kg/ha")]
        var draft = FertigationDomain.DraftProduct(line: line)
        let totals = FertigationDomain.Totals(allocations: [.init(areaM2: 9620, vines: 4500)])
        let step = FertigationDomain.ProgramStep(raw: ["id": .string(stepId.uuidString)])
        let first = try draft.payload(totals: totals, step: step)
        #expect(first["planned_quantity"] == .number(9.62)); #expect(first["actual_quantity"] == .null)
        draft.actual = "8.5"
        let second = try draft.payload(totals: totals, step: step)
        #expect(second["id"] == first["id"]); #expect(second["saved_chemical_id"] == .string(stepId.uuidString))
        #expect(second["planned_quantity"] == first["planned_quantity"]); #expect(second["actual_quantity"] == .number(8.5))
    }

    @Test func costUnavailableAndReversedReadOnly() {
        #expect(FertigationDomain.frozenCost(product: ["cost_per_unit": .number(0), "actual_quantity": .number(10)]) == nil)
        #expect(FertigationDomain.frozenCost(product: ["cost_per_unit": .number(2), "actual_quantity": .number(10)]) == 20)
        #expect(!FertigationDomain.Application(raw: ["status": .string("reversed")]).isEditable)
        #expect(!FertigationDomain.Application(raw: [:]).isEditable)
    }
}
