import Foundation
import Testing
@testable import VineTrack

/// Editing a Program Step that is synced with the Admin Portal.
///
/// The Program is a SHARED vineyard resource. Both interfaces edit the same
/// `public.spray_jobs` row, so the three claims worth defending are:
///
///  1. an authorised user can edit a portal step, and an unauthorised one cannot;
///  2. the edit lands on the SAME row — same id, still a template, no local copy;
///  3. changing what a Program Step points at changes nothing that already
///     happened.
struct SprayProgramStepEditingTests {

    // MARK: - Fixtures

    private static let stepId = UUID(uuidString: "dddddddd-0000-0000-0000-0000000000a1")!
    private static let vineyardId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private static let equipmentId = UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000001")!
    private static let legacyChemicalId = UUID(uuidString: "cccccccc-0000-0000-0000-000000000009")!

    /// A real portal row: an unresolved legacy product ("Spray Seal") on a
    /// per-hectare rate, and a resolved one on a per-100 L rate.
    private let dormancyJSON = """
    {
      "id": "dddddddd-0000-0000-0000-0000000000a1",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Dormancy",
      "is_template": true,
      "status": "draft",
      "growth_stage_code": "EL1",
      "target": "Phomopsis · Powdery Mildew",
      "operation_type": "Foliar Spray",
      "notes": "Winter clean-up.",
      "equipment_id": "eeeeeeee-0000-0000-0000-000000000001",
      "water_volume": 1200,
      "spray_rate_per_ha": 500,
      "chemical_lines": [
        { "name": "Spray Seal", "rate": 2, "unit": "L/ha" },
        {
          "chemical_id": "cccccccc-0000-0000-0000-000000000009",
          "name": "Wettable Sulphur",
          "rate": 45,
          "unit": "mL/100L",
          "water_rate": 500,
          "chemical_snapshot": {
            "productName": "Wettable Sulphur",
            "activeIngredients": [],
            "activityGroupCodes": ["M2"],
            "verificationStatus": "verified",
            "schemaVersion": 1,
            "activityGroupTableVersion": 1
          }
        }
      ]
    }
    """

    private func portalRow() throws -> BackendSprayJobTemplate {
        try JSONDecoder().decode(BackendSprayJobTemplate.self, from: Data(dormancyJSON.utf8))
    }

    private func portalStep() throws -> SprayProgramStep {
        let row = try portalRow()
        return SprayProgramStep(
            record: row.toSprayRecord(),
            source: .portal,
            growthStageCode: row.growthStageCode,
            targetRaw: row.target
        )
    }

    private func localStep(id: UUID = UUID()) -> SprayProgramStep {
        SprayProgramStep(
            record: SprayRecord(
                id: id,
                vineyardId: Self.vineyardId,
                sprayReference: "EL12 Pre-Flowering",
                tanks: [SprayTank(chemicals: [
                    SprayChemical(
                        name: "Copper Hydroxide",
                        ratePerHa: 1_000,
                        unit: .kilograms,
                        rateBasis: .wholeBlockArea
                    )
                ])],
                notes: "Local step",
                isTemplate: true
            ),
            source: .local
        )
    }

    /// The replacement the operator explicitly picks from the Chemical Store.
    private func sprayOil() -> SavedChemical {
        SavedChemical(
            id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-00000000000b")!,
            vineyardId: Self.vineyardId,
            name: "Biosafe Spray Oil",
            unit: .litres,
            manufacturer: "Example Crop Science",
            activeIngredient: "Paraffinic oil 815 g/L"
        )
    }

    private func encoded(_ payload: BackendSprayJobTemplateUpdate) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 1/2. Permission

    /// The client rule mirrors `spray_jobs_update_managers` (sql/032) exactly.
    /// It is a mirror, not the enforcement point — Postgres still refuses.
    @Test("Owner and manager may edit a portal Program Step; supervisor and operator may not")
    func portalEditFollowsTheUpdatePolicy() throws {
        let step = try portalStep()

        for role in [BackendRole.owner, .manager] {
            #expect(role.canManageSprayProgram)
            #expect(SprayProgramStepPermissions.canEdit(
                step: step,
                canManageSprayProgram: role.canManageSprayProgram,
                canEditRecords: role.canEditRecords
            ))
        }

        for role in [BackendRole.supervisor, .operator] {
            #expect(!role.canManageSprayProgram)
            // `canEditRecords` is true for these roles. The portal branch must
            // not fall through to it — that would widen access to make a button
            // appear, and the write would then be refused by RLS anyway.
            #expect(role.canEditRecords)
            #expect(!SprayProgramStepPermissions.canEdit(
                step: step,
                canManageSprayProgram: role.canManageSprayProgram,
                canEditRecords: role.canEditRecords
            ))
        }
    }

    @Test("Local Program Steps keep the edit rule they already had")
    func localEditRuleUnchanged() {
        let step = localStep()
        for role in BackendRole.allCases {
            #expect(SprayProgramStepPermissions.canEdit(
                step: step,
                canManageSprayProgram: role.canManageSprayProgram,
                canEditRecords: role.canEditRecords
            ))
        }
    }

    /// Editing became shared. Deleting did not.
    @Test("Mobile delete of a portal Program Step stays out of scope")
    func deleteStaysRestricted() throws {
        let portal = try portalStep()
        #expect(!SprayProgramStepPermissions.canDelete(step: portal, canDeleteRecords: true))
        #expect(SprayProgramStepPermissions.canDelete(step: localStep(), canDeleteRecords: true))
        #expect(!SprayProgramStepPermissions.canDelete(step: localStep(), canDeleteRecords: false))
    }

    // MARK: - 3. Identity

    @Test("Editing preserves the Program Step id, vineyard and template flag")
    func identityPreserved() throws {
        let row = try portalRow()
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.name = "Dormancy (revised)"

        let saved = row.applying(draft.portalPayload(updatedBy: UUID()))

        #expect(saved.id == Self.stepId)
        #expect(saved.vineyardId == Self.vineyardId)
        #expect(saved.name == "Dormancy (revised)")
        // `is_template` is not in the payload at all, so it cannot be changed.
        #expect(saved.toSprayRecord().isTemplate)
        #expect(saved.toSprayRecord().id == Self.stepId)
    }

    /// A PATCH must touch only the Program Step's own configuration. Columns
    /// mobile does not model have to be absent from the payload entirely — an
    /// explicit null would overwrite the portal's value with mobile's ignorance.
    @Test("The payload writes configuration columns only, never row identity")
    func payloadScope() throws {
        let object = try encoded(SprayProgramStepDraft(step: try portalStep()).portalPayload(updatedBy: nil))

        #expect(object["name"] as? String == "Dormancy")
        #expect(object["growth_stage_code"] as? String == "EL1")
        #expect(object["operation_type"] as? String == "Foliar Spray")
        #expect(object["target"] as? String == "Phomopsis · Powdery Mildew")
        #expect(object["chemical_lines"] != nil)

        for absent in ["id", "vineyard_id", "is_template", "status", "planned_date",
                       "water_volume", "spray_rate_per_ha", "created_by", "updated_at"] {
            #expect(object[absent] == nil, "\(absent) must not be written by mobile")
        }
    }

    /// Clearing a value has to persist as SQL NULL. If the encoder omitted the
    /// key instead, "the operator removed the tractor" would save successfully
    /// and change nothing.
    @Test("Cleared optional fields encode as null, not as an absent key")
    func clearedFieldsEncodeAsNull() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.equipmentId = nil
        draft.tractorId = nil
        draft.growthStageCode = nil
        draft.targets = []

        let object = try encoded(draft.portalPayload(updatedBy: nil))
        for key in ["equipment_id", "tractor_id", "growth_stage_code", "target"] {
            #expect(object.keys.contains(key))
            #expect(object[key] is NSNull, "\(key) must clear as null")
        }
    }

    @Test("Columns the payload preserves survive an applied update")
    func untouchedColumnsSurvive() throws {
        let row = try portalRow()
        let saved = row.applying(SprayProgramStepDraft(step: try portalStep()).portalPayload(updatedBy: nil))

        #expect(saved.status == "draft")
        #expect(saved.waterVolume == 1_200)
        #expect(saved.sprayRatePerHa == 500)
    }

    // MARK: - 4. No local duplicate

    /// The defect this design exists to prevent: a portal edit that quietly
    /// forks into a second, device-owned Program Step.
    @Test("Saving a portal Program Step leaves exactly one step and no local template")
    func noLocalDuplicateIsCreated() throws {
        let row = try portalRow()
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.name = "Dormancy (revised)"
        let saved = row.applying(draft.portalPayload(updatedBy: nil))

        let cached = SprayJobTemplateService.patched([row], with: saved)
        #expect(cached.count == 1)
        #expect(cached[0].id == Self.stepId)

        // A local template list that never learned about this step at all.
        let localRecords: [SprayRecord] = [localStep().record]
        let steps = SprayProgramCatalog.steps(
            localRecords: localRecords,
            portalRecords: cached.map { $0.toSprayRecord() },
            portalRows: cached
        )

        let matching = steps.filter { $0.id == Self.stepId }
        #expect(matching.count == 1)
        #expect(matching.first?.isPortalManaged == true)
        #expect(matching.first?.name == "Dormancy (revised)")
        // The local side gained nothing.
        #expect(steps.filter { !$0.isPortalManaged }.count == 1)
        #expect(localRecords.count == 1)
    }

    // MARK: - 5/6. Chemical identity

    @Test("An explicitly selected Saved Chemical writes its actual chemical_id and name")
    func replacementWritesIdentity() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        let replacement = sprayOil()

        var line = try #require(draft.products.first)
        #expect(line.name == "Spray Seal")
        #expect(line.savedChemicalId == nil)

        line.replaceProduct(with: replacement, seedRate: nil)
        draft.products[0] = line

        let lines = draft.chemicalLines()
        #expect(lines[0].chemicalId == replacement.id)
        #expect(lines[0].name == "Biosafe Spray Oil")
        #expect(lines[0].activeIngredient == "Paraffinic oil 815 g/L")

        let object = try encoded(draft.portalPayload(updatedBy: nil))
        let encodedLines = try #require(object["chemical_lines"] as? [[String: Any]])
        #expect(encodedLines[0]["chemical_id"] as? String == replacement.id.uuidString)
        #expect(encodedLines[0]["name"] as? String == "Biosafe Spray Oil")
    }

    /// The second line is untouched, so every field it arrived with — including
    /// the portal's `water_rate` and its frozen snapshot — round-trips verbatim.
    @Test("Untouched product lines round-trip every field the contract defines")
    func untouchedLineRoundTrips() throws {
        let draft = SprayProgramStepDraft(step: try portalStep())
        let line = draft.chemicalLines()[1]

        #expect(line.chemicalId == Self.legacyChemicalId)
        #expect(line.name == "Wettable Sulphur")
        #expect(line.unit == "mL/100L")
        #expect(line.rate == 45)
        #expect(line.chemicalSnapshot?.activityGroupCodes == ["M2"])
    }

    /// A snapshot describes ONE product. Carrying it onto a different product
    /// would be a fabrication, and capturing a fresh one here would be wrong
    /// too: a Program Step reads today's Chemical Store, and freezing belongs to
    /// the job and the completed record.
    @Test("Replacing a product drops its frozen chemistry rather than reassigning it")
    func snapshotDroppedOnReplacement() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        #expect(draft.products[1].chemicalSnapshot != nil)

        draft.products[1].replaceProduct(with: sprayOil(), seedRate: nil)

        #expect(draft.products[1].chemicalSnapshot == nil)
        #expect(draft.chemicalLines()[1].chemicalSnapshot == nil)
    }

    // MARK: - 7/8. Rate basis

    @Test("A per-hectare rate survives an edit round trip")
    func perHectareRateSurvives() throws {
        let row = try portalRow()
        let draft = SprayProgramStepDraft(step: try portalStep())

        #expect(draft.products[0].rate == 2)
        #expect(draft.products[0].unit == .litres)
        #expect(draft.products[0].basis == .wholeBlockArea)

        let saved = row.applying(draft.portalPayload(updatedBy: nil))
        let reloaded = saved.toSprayRecord().tanks.flatMap(\.chemicals)[0]

        #expect(saved.chemicalLines[0].unit == "L/ha")
        #expect(reloaded.reportedRateBasis == .wholeBlockArea)
        #expect(reloaded.displayReportedRate == 2)
        #expect(reloaded.ratePer100L == 0)
    }

    /// The basis lives INSIDE the unit string; there is no separate column. A
    /// per-100 L line written back as "mL/ha" would reload as a per-hectare
    /// rate and report the step's rate as 0/ha — the P10 class of defect.
    @Test("A per-100 L rate survives with its basis intact")
    func per100LitreRateSurvives() throws {
        let row = try portalRow()
        let draft = SprayProgramStepDraft(step: try portalStep())

        #expect(draft.products[1].rate == 45)
        #expect(draft.products[1].unit == .millilitres)
        #expect(draft.products[1].basis == .per100Litres)

        let saved = row.applying(draft.portalPayload(updatedBy: nil))
        let reloaded = saved.toSprayRecord().tanks.flatMap(\.chemicals)[1]

        #expect(saved.chemicalLines[1].unit == "mL/100L")
        #expect(reloaded.reportedRateBasis == .per100Litres)
        #expect(reloaded.displayReportedRate == 45)
        #expect(reloaded.ratePerHa == 0)
    }

    @Test("Every unit and basis pair composes to a string that parses back")
    func unitStringRoundTrips() {
        for unit in ChemicalUnit.allCases {
            for basis in [SprayProductRateBasis.wholeBlockArea, .per100Litres] {
                let composed = BackendSprayJobTemplate.composeLineUnit(unit, basis: basis)
                let parsed = BackendSprayJobTemplate.parseLineUnit(composed)
                #expect(parsed.unit == unit, "\(composed) parsed as \(parsed.unit)")
                #expect(parsed.per100L == (basis == .per100Litres), "\(composed) lost its basis")
            }
        }
    }

    /// A local step can legitimately carry a basis the shared JSONB cannot
    /// express. Refusing is the honest answer; writing "/ha" over it would
    /// silently restate the rate.
    @Test("A basis the shared program can't store blocks the save instead of restating it")
    func unrepresentableBasisIsRefused() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.products[0].basis = .treatedArea

        #expect(!draft.isValid)
        #expect(draft.validationError?.contains("Spray Seal") == true)
    }

    // MARK: - 9. Unresolved legacy product

    /// The screenshot case. "Spray Seal is not in your Chemical Store" must stay
    /// true until the operator picks a product — never resolved by name.
    @Test("An unresolved legacy product stays unresolved until explicitly replaced")
    func unresolvedProductRequiresExplicitReplacement() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        let replacement = sprayOil()

        // A Chemical Store that contains a plausibly named product. Resolution
        // is identifier-only, so this must NOT quietly satisfy the line.
        let library = [
            replacement,
            SavedChemical(vineyardId: Self.vineyardId, name: "Spray Seal", unit: .litres)
        ]

        #expect(!draft.products[0].isResolved(in: library))
        #expect(draft.chemicalLines()[0].chemicalId == nil)

        draft.products[0].replaceProduct(with: replacement, seedRate: nil)

        #expect(draft.products[0].isResolved(in: library))
        #expect(draft.products[0].savedChemicalId == replacement.id)
    }

    @Test("Detaching a product clears its identity but keeps the typed name")
    func clearingProductKeepsTheName() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.products[1].clearProduct(name: "Unlisted wetting agent")

        #expect(draft.products[1].savedChemicalId == nil)
        #expect(draft.products[1].name == "Unlisted wetting agent")
        #expect(draft.products[1].chemicalSnapshot == nil)
        #expect(draft.chemicalLines()[1].chemicalId == nil)
    }

    /// Restating "2" from litres into kilograms would change what the step
    /// applies. The number is converted through base units instead.
    @Test("Replacing a product restates the rate in the new product's unit")
    func replacementConvertsTheRate() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        let solid = SavedChemical(vineyardId: Self.vineyardId, name: "Sulphur WG", unit: .grams)

        // 2 L = 2000 base units.
        #expect(draft.products[0].baseRate == 2_000)
        draft.products[0].replaceProduct(with: solid, seedRate: nil)

        #expect(draft.products[0].unit == .grams)
        #expect(draft.products[0].rate == 2_000)
        #expect(draft.products[0].baseRate == 2_000)
    }

    // MARK: - 10. Cancel

    @Test("Cancelling an edit changes nothing")
    func cancelChangesNothing() throws {
        let original = try portalStep()
        var draft = SprayProgramStepDraft(step: original)
        draft.name = "Never saved"
        draft.products.removeAll()
        draft.growthStageCode = "EL31"

        // The draft is a VALUE. Discarding it is the whole of "cancel": the
        // step, its record and the row it came from are all untouched.
        #expect(original.name == "Dormancy")
        #expect(original.products.count == 2)
        #expect(original.growthStageCode == "EL1")
        #expect(try portalRow().name == "Dormancy")
    }

    // MARK: - 11. Cache refresh

    @Test("Saving replaces the cached Program Step in place and never appends")
    func cacheIsPatchedNotAppended() throws {
        let row = try portalRow()
        let other = BackendSprayJobTemplate(
            id: UUID(),
            vineyardId: Self.vineyardId,
            name: "Flowering"
        )
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.name = "Dormancy (revised)"
        let saved = row.applying(draft.portalPayload(updatedBy: nil))

        let patched = SprayJobTemplateService.patched([row, other], with: saved)

        #expect(patched.count == 2)
        #expect(patched[0].id == Self.stepId)
        #expect(patched[0].name == "Dormancy (revised)")
        #expect(patched[1].name == "Flowering")
    }

    @Test("A row that isn't cached leaves the cache alone")
    func unknownRowDoesNotAppend() throws {
        let row = try portalRow()
        let stranger = BackendSprayJobTemplate(id: UUID(), vineyardId: Self.vineyardId, name: "Elsewhere")

        #expect(SprayJobTemplateService.patched([row], with: stranger).count == 1)
        #expect(SprayJobTemplateService.patched([row], with: stranger)[0].id == row.id)
    }

    // MARK: - 12. Plan Spray after save

    /// The operator's actual goal: fix the product, then plan a spray with it.
    @Test("Plan Spray after a save carries the newly saved configuration")
    func planSprayUsesTheSavedStep() throws {
        let row = try portalRow()
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.products[0].replaceProduct(with: sprayOil(), seedRate: nil)
        draft.growthStageCode = "EL4"
        draft.targets = [SprayTargetTag(.powderyMildew)]

        let saved = row.applying(draft.portalPayload(updatedBy: nil))
        let step = SprayProgramStep(
            record: saved.toSprayRecord(),
            source: .portal,
            growthStageCode: saved.growthStageCode,
            targetRaw: saved.target
        )

        #expect(step.id == Self.stepId)
        #expect(step.products.map(\.name).contains("Biosafe Spray Oil"))
        #expect(step.products[0].savedChemicalId == sprayOil().id)

        let prefill = step.calculatorPrefill
        #expect(prefill.growthStageCode == "EL4")
        #expect(prefill.targets == [.powderyMildew])
        #expect(prefill.equipmentId == Self.equipmentId)
    }

    /// The detail screen shows the saved configuration without a round trip
    /// through sync, so the operator does not have to leave and reopen Program.
    @Test("The projected step reflects the edit immediately")
    func projectedStepReflectsTheEdit() throws {
        let base = try portalStep()
        var draft = SprayProgramStepDraft(step: base)
        draft.name = "Dormancy (revised)"
        draft.targets = [SprayTargetTag(.botrytis)]

        let projected = draft.projectedStep(base: base)

        #expect(projected.id == base.id)
        #expect(projected.source == .portal)
        #expect(projected.name == "Dormancy (revised)")
        #expect(projected.targetDisplay == "Botrytis")
    }

    // MARK: - 13. History is untouched

    /// A Program Step is reusable configuration; a spray record is a compliance
    /// document. Re-pointing the configuration must not reach backwards.
    @Test("Editing a Program Step does not alter a completed spray record")
    func historicalRecordsAreUntouched() throws {
        let frozen = ChemicalLineSnapshot(
            savedChemicalId: Self.legacyChemicalId.uuidString,
            productName: "Spray Seal",
            activityGroupCodes: ["M1"],
            verificationStatus: .verified,
            legacyChemicalGroup: "M1"
        )
        let completed = SprayRecord(
            endTime: Date(timeIntervalSince1970: 1_600_000_000),
            sprayReference: "Dormancy 2023",
            tanks: [SprayTank(chemicals: [
                SprayChemical(
                    name: "Spray Seal",
                    ratePerHa: 2_000,
                    unit: .litres,
                    rateBasis: .wholeBlockArea,
                    savedChemicalId: Self.legacyChemicalId,
                    chemicalSnapshot: frozen
                )
            ])],
            isTemplate: false
        )
        let before = completed

        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.products[0].replaceProduct(with: sprayOil(), seedRate: nil)
        _ = try portalRow().applying(draft.portalPayload(updatedBy: nil))

        #expect(completed == before)
        let line = completed.tanks[0].chemicals[0]
        #expect(line.name == "Spray Seal")
        #expect(line.savedChemicalId == Self.legacyChemicalId)
        #expect(line.chemicalSnapshot?.activityGroupCodes == ["M1"])
        #expect(line.chemicalSnapshot?.productName == "Spray Seal")
        // P10 reporting reads the record's own stored basis, unchanged.
        #expect(line.reportedRateBasis == .wholeBlockArea)
        #expect(line.displayReportedRate == 2)
    }

    // MARK: - Local steps

    @Test("A local Program Step edit keeps its record identity and template flag")
    func localEditPreservesRecord() {
        let id = UUID()
        let step = localStep(id: id)
        var draft = SprayProgramStepDraft(step: step)
        draft.name = "EL12 Pre-Flowering (revised)"
        draft.products[0].rate = 1.5

        let updated = draft.applied(to: step.record)

        #expect(updated.id == id)
        #expect(updated.isTemplate)
        #expect(updated.vineyardId == Self.vineyardId)
        #expect(updated.tripId == step.record.tripId)
        #expect(updated.sprayReference == "EL12 Pre-Flowering (revised)")
        #expect(updated.tanks[0].chemicals[0].ratePerHa == 1_500)
        #expect(updated.tanks[0].chemicals[0].rateBasis == .wholeBlockArea)
    }

    /// A multi-tank local recipe must not be flattened into one tank by an
    /// editor that only ever shows a flat product list.
    @Test("Local products are written back into the tank they came from")
    func localMultiTankMappingIsPreserved() {
        let record = SprayRecord(
            sprayReference: "Two tank",
            tanks: [
                SprayTank(tankNumber: 1, chemicals: [SprayChemical(name: "A", ratePerHa: 1_000, unit: .litres)]),
                SprayTank(tankNumber: 2, chemicals: [SprayChemical(name: "B", ratePerHa: 2_000, unit: .litres)])
            ],
            isTemplate: true
        )
        var draft = SprayProgramStepDraft(step: SprayProgramStep(record: record, source: .local))
        draft.products[1].rate = 3

        let updated = draft.applied(to: record)

        #expect(updated.tanks.count == 2)
        #expect(updated.tanks[0].chemicals.map(\.name) == ["A"])
        #expect(updated.tanks[1].chemicals.map(\.name) == ["B"])
        #expect(updated.tanks[1].chemicals[0].ratePerHa == 3_000)
    }

    @Test("A local step's typed targets follow the edited wording")
    func localTargetsFollowTheWording() {
        let step = localStep()
        var draft = SprayProgramStepDraft(step: step)
        draft.targets = [SprayTargetTag(.powderyMildew), SprayTargetTag(.botrytis)]

        let updated = draft.applied(to: step.record)
        #expect(updated.applicationGeometry?.targets == [.powderyMildew, .botrytis])
        // A template never acquires geometry — it does not know where it is going.
        #expect(updated.applicationGeometry?.blocks == nil)
    }

    // MARK: - Validation

    @Test("A Program Step cannot be saved without a name")
    func nameIsRequired() throws {
        var draft = SprayProgramStepDraft(step: try portalStep())
        draft.name = "   "
        #expect(!draft.isValid)
        #expect(draft.validationError == "Give the Program Step a name.")

        draft.name = "Dormancy"
        #expect(draft.isValid)
    }

    @Test("Verbatim portal target wording is never narrowed to the typed set")
    func verbatimTargetWordingSurvives() throws {
        let draft = SprayProgramStepDraft(step: try portalStep())

        // "Phomopsis" has no typed case. It must still be stored and shown.
        #expect(draft.targetDisplay == "Phomopsis · Powdery Mildew")
        #expect(draft.recognisedTargets == [.powderyMildew])
        #expect(draft.portalPayload(updatedBy: nil).target == "Phomopsis · Powdery Mildew")
    }
}
