import Foundation
import Testing
@testable import VineTrack

@MainActor
struct SprayProgramStepCreationTests {
    @Test func canonicalEditorHasCreateAndEditModes() {
        let vineyard = UUID()
        let creator = SprayProgramStepEditView(vineyardId: vineyard) { _ in }
        #expect(creator.isCreating && creator.step.isPortalManaged)
        #expect(creator.creationVineyardId == vineyard)
        let editor = SprayProgramStepEditView(step: creator.step) { _ in }
        #expect(!editor.isCreating)
    }

    @Test func blankDraftHasNoOperationalEvidenceAndStableIdentity() {
        var draft = SprayProgramStepDraft()
        let id = draft.stepId
        #expect(draft.source == .portal && draft.name.isEmpty && draft.products.isEmpty)
        #expect(draft.targets.isEmpty && draft.growthStageCode == nil && draft.equipmentId == nil && draft.tractorId == nil)
        #expect(draft.planningIntent == nil && draft.operationType == .foliarSpray)
        draft.name = "Reusable step"; draft.notes = "Unsaved"
        #expect(draft.stepId == id)
    }

    @Test(arguments: [false, true])
    func createMethodOptionsAndOperationalExclusion(admin: Bool) {
        let options = OperationType.programMethods(isSystemAdmin: admin, isPortalTemplate: true)
        #expect(options == [.foliarSpray, .bandedSpray, .spreader] + (admin ? [.fertigation] : []))
        #expect(!OperationType.allCases.contains(.fertigation))
        #expect(!OperationType.programMethods(isSystemAdmin: admin, isPortalTemplate: false).contains(.fertigation))
    }

    @Test(arguments: [false, true])
    func systemAdminNeverOverridesVineyardRole(admin: Bool) {
        #expect(!SprayProgramStepPermissions.canCreate(canManageSprayProgram: false, method: .fertigation, isSystemAdmin: admin))
        #expect(SprayProgramStepPermissions.canCreate(canManageSprayProgram: true, method: .fertigation, isSystemAdmin: admin) == admin)
        #expect(SprayProgramStepPermissions.canCreate(canManageSprayProgram: true, method: .foliarSpray, isSystemAdmin: admin))
    }

    @Test(arguments: [OperationType.foliarSpray, .bandedSpray, .spreader, .fertigation])
    func canonicalInsertAndReadBack(method: OperationType) async throws {
        var draft = SprayProgramStepDraft()
        let chemicalId = UUID(), vineyard = UUID(), owner = UUID()
        draft.name = "Synthetic new step"; draft.growthStageCode = "EL12"; draft.notes = "Draft notes"
        draft.operationType = method
        var product = SprayProgramProductDraft(savedChemicalId: chemicalId, name: "Saved nutrient", rate: 10, unit: .kilograms)
        product.fertigationRateBasis = "per_hectare"; product.fertigationRateUnit = "kg/ha"
        draft.products = [product]
        let payload = BackendSprayJobTemplateCreate(id: draft.stepId, vineyardId: vineyard, createdBy: owner, configuration: draft.portalPayload(updatedBy: owner))
        let saved = try await SupabaseSprayJobTemplateRepository.insertConfirmed(payload: payload) { sent in
            let data = try JSONEncoder().encode(sent)
            let object = try JSONDecoder().decode(FertigationDomain.Object.self, from: data)
            #expect(object["id"] == .string(draft.stepId.uuidString))
            #expect(object["is_template"] == .bool(true) && object["status"] == .string("draft"))
            #expect(object["vineyard_id"] == .string(vineyard.uuidString))
            #expect(object["trip_id"] == nil && object["tanks"] == nil && object["planned_date"] == nil)
            if method == .fertigation {
                for key in BackendSprayJobTemplateCreate.sprayOnlyKeys { #expect(object[key] == nil) }
                if case .array(let lines) = object["chemical_lines"], case .object(let line) = lines[0] {
                    #expect(line["unit"] == nil && line["water_rate"] == nil && line["rate_basis"] == nil)
                } else { Issue.record("Chemical lines missing") }
            }
            return [try JSONDecoder().decode(BackendSprayJobTemplate.self, from: data)]
        }
        #expect(saved.id == draft.stepId && saved.isTemplate && saved.vineyardId == vineyard)
        #expect(saved.chemicalLines[0].chemicalId == chemicalId)
        #expect(saved.growthStageCode == "EL12" && saved.notes == "Draft notes")
        let step = SprayProgramStep(record: saved.toSprayRecord(), source: .portal, growthStageCode: saved.growthStageCode, portalChemicalLines: saved.chemicalLines)
        let reopened = SprayProgramStepDraft(step: step)
        #expect(reopened.products[0].savedChemicalId == chemicalId && reopened.products[0].rate == 10)
        if method == .fertigation {
            #expect(reopened.products[0].fertigationRateBasis == "per_hectare" && reopened.products[0].fertigationRateUnit == "kg/ha")
            #expect(step.operationType == .fertigation && step.isPortalManaged && step.record.isTemplate)
            #expect(!step.operationType.canPlanSpray)
        }
        let list = SprayJobTemplateService.insertingConfirmed([], row: saved)
        #expect(SprayJobTemplateService.insertingConfirmed(list, row: saved).count == 1)
    }

    @Test func overlappingRefreshCannotEraseAcknowledgedCreation() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "program-create-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let persistence = PersistenceStore(directory: directory)
        let service = SprayJobTemplateService(persistence: persistence)
        let vineyard = UUID()
        let beforeInsert = service.mutationRevision
        let row = BackendSprayJobTemplate(id: UUID(), vineyardId: vineyard, name: "Acknowledged", operationType: "Fertigation")
        service.applyConfirmedCreation(row, vineyardId: vineyard)
        #expect(!service.applyFetchedSnapshot([], vineyardId: vineyard, startedAtRevision: beforeInsert))
        #expect(service.templates.count == 1 && service.templates[0].id == row.id)
        let cached: [BackendSprayJobTemplate]? = persistence.load(key: "vinetrack_spray_job_templates_\(vineyard.uuidString)")
        #expect(cached?.first?.id == row.id)
        #expect(service.applyFetchedSnapshot([row], vineyardId: vineyard, startedAtRevision: service.mutationRevision))
        #expect(service.templates.count == 1)
    }

    @Test func addChemicalPreservesEntireUnsavedCreateDraft() {
        var draft = SprayProgramStepDraft()
        draft.name = "Unsaved name"; draft.notes = "Unsaved notes"; draft.growthStageCode = "EL12"; draft.operationType = .fertigation
        draft.products = [SprayProgramProductDraft(name: "Pending choice")]
        let original = draft
        let lineId = draft.products[0].id
        let created = SavedChemical(name: "New Saved Chemical", unit: .litres, activeIngredient: "N")
        draft.products[0].replaceFertigationProduct(with: created)
        #expect(draft.stepId == original.stepId && draft.source == original.source)
        #expect(draft.name == original.name && draft.notes == original.notes && draft.growthStageCode == original.growthStageCode)
        #expect(draft.operationType == original.operationType && draft.products[0].id == lineId)
        #expect(draft.products[0].savedChemicalId == created.id)
        #expect(draft.products[0].rate == 0 && draft.products[0].fertigationRateBasis == nil && draft.products[0].fertigationRateUnit == nil)
    }

    @Test(arguments: ["failure", "empty", "wrongId", "notTemplate"])
    func failedInsertKeepsDraftWithoutPublishing(scenario: String) async throws {
        var draft = SprayProgramStepDraft(); draft.name = "Keep me"; draft.notes = "Original notes"
        let before = draft, vineyard = UUID(), owner = UUID()
        let payload = BackendSprayJobTemplateCreate(id: draft.stepId, vineyardId: vineyard, createdBy: owner, configuration: draft.portalPayload(updatedBy: owner))
        var rows: [BackendSprayJobTemplate] = []
        do {
            let saved = try await SupabaseSprayJobTemplateRepository.insertConfirmed(payload: payload) { _ in
                if scenario == "failure" { throw URLError(.notConnectedToInternet) }
                if scenario == "empty" { return [] }
                return [.init(id: scenario == "wrongId" ? UUID() : draft.stepId, vineyardId: vineyard, name: draft.name, isTemplate: scenario != "notTemplate", operationType: draft.operationType.rawValue)]
            }
            rows = SprayJobTemplateService.insertingConfirmed(rows, row: saved)
            Issue.record("Unconfirmed insert must fail")
        } catch {
            #expect(rows.isEmpty && draft == before)
            #expect(payload.id == before.stepId)
        }
    }
}
