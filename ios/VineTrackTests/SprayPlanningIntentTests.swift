import Foundation
import Testing
@testable import VineTrack

@MainActor
struct SprayPlanningIntentTests {
    @Test func fourPlanningCombinationsRetainFrozenOutputsAndAdvisoryCFBehindGate() throws {
        for pass in SprayPassConfiguration.allCases {
            for method in SprayPlanningMethod.allCases {
                let intent = SprayPlanningIntent(configuration: pass, method: method,
                    fullTankSpecification: method == .fullTank ? .targetArea : nil,
                    intendedTankLitres: method == .fullTank ? 1500 : nil,
                    targetAreaHa: method == .fullTank ? 3 : nil, calibratedLitresPerHectare: 500)
                let output = try #require(intent.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 1000))
                #expect(intent.frozenResolutionBlocker(output) == nil)
                #expect(output.concentrationFactor == 2)
                #expect(output.intendedLitres == (method == .fullTank ? 1500 : 5000))
                var snapshot = SprayApplicationSnapshot(grossAreaHa: 10)
                snapshot.planningIntent = intent
                snapshot.planningResolution = output
                let restored = try JSONDecoder().decode(SprayApplicationSnapshot.self, from: JSONEncoder().encode(snapshot))
                #expect(restored == snapshot)
                #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: output.concentrationFactor, hasDiluteRateProducts: true) == nil)
                let record = SprayRecord(applicationGeometry: restored)
                #expect(record.operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
                #expect(BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date()).operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
                let bad = SprayPlanningResolution(intendedLitres: output.intendedLitres, plannedAreaHa: output.plannedAreaHa,
                    litresPerHectare: output.litresPerHectare, physicalRowLitresPer100m: output.physicalRowLitresPer100m,
                    controllerLitresPer100mTravel: 999, effectiveWorkingWidthMetres: output.effectiveWorkingWidthMetres, concentrationFactor: 2)
                #expect(intent.frozenResolutionBlocker(bad) != nil)
            }
        }
    }

    @Test func byAreaMeasuredRowCarrierIsNotRewrittenAsGrossAreaVolume() throws {
        let intent = SprayPlanningIntent(configuration: .overRow, method: .byArea, calibratedLitresPerHectare: 500)
        let output = try #require(intent.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 1000))
        let frozen = SprayPlanningResolution(intendedLitres: 4800, plannedAreaHa: output.plannedAreaHa,
            litresPerHectare: output.litresPerHectare, physicalRowLitresPer100m: output.physicalRowLitresPer100m,
            controllerLitresPer100mTravel: output.controllerLitresPer100mTravel,
            effectiveWorkingWidthMetres: output.effectiveWorkingWidthMetres, concentrationFactor: output.concentrationFactor)
        #expect(intent.frozenResolutionBlocker(frozen) == nil)
        #expect(frozen.intendedLitres == 4800)
    }

    @Test func labelUncertaintyAloneDoesNotBlockSaveOrStart() {
        let dilute = SprayChemical(name: "Unverified sulphur", ratePer100L: 100)
        let record = SprayRecord(tanks: [SprayTank(concentrationFactor: 2, chemicals: [dilute])])
        #expect(record.operationalPlanningBlocker == nil)
        #expect(SprayPlanningOperationalGate.tankConfirmationBlocker(current: record, captured: record) == nil)
        #expect(BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date()).operationalPlanningBlocker == nil)
    }

    @Test func aboveReferenceLabelReviewIsAdvisoryWithoutChangingCF() {
        #expect(SprayCarrierConversion.concentrationFactor(dilute: 713, actual: 750) == 1)
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: 1, hasDiluteRateProducts: true) == nil)
        #expect(SprayPlanningOperationalGate.warningProducts([" Sulphur ", "Sulphur", "", "Copper"]) == ["Copper", "Sulphur"])
        #expect(!SprayPlanningOperationalGate.warningMessage.contains("blocked"))
        #expect(SprayPassConfiguration.standardPass.title == "Single Row")
        #expect(SprayPassConfiguration.standardPass.rawValue == "standard_pass")
        #expect(SprayPlanningMethod.fullTank.title == "Only Full Tanks")
        #expect(SprayPlanningMethod.fullTank.rawValue == "full_tank")
    }

    @Test func regionalDecimalPlanningEntryRefusesPartialAndNonfiniteValues() {
        #expect(SprayControllerRateEntry.parse(" 3,00 ") == 3)
        #expect(SprayControllerRateEntry.parse("1500.") == 1500)
        for text in ["", ".", "1..2", "NaN", "inf"] { #expect(SprayControllerRateEntry.parse(text) == nil) }
    }

    @Test func bothControllerRatesPreservePhysicalApplication() throws {
        for rate in [500.0, 600.0] {
            for pass in SprayPassConfiguration.allCases {
                let travel = try #require(SprayControllerRateEntry.displayed(rate, basis: .litresPer100Metres, configuration: pass, spacing: 2.8))
                let expected = (rate == 500 ? 14.0 : 16.8) * pass.rowEquivalents
                #expect(abs(travel - expected) < 0.00000001)
                #expect(abs((SprayControllerRateEntry.canonical(travel, basis: .litresPer100Metres, configuration: pass, spacing: 2.8) ?? 0) - rate) < 0.00000001)
            }
        }
    }

    @Test func delayedTankConfirmationRequiresCurrentFrozenRecipe() {
        let captured = SprayRecord(sprayReference: "Original frozen mix")
        #expect(SprayPlanningOperationalGate.tankConfirmationBlocker(current: captured, captured: captured) == nil)
        var changed = captured
        var geometry = SprayApplicationSnapshot()
        geometry.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank,
            fullTankSpecification: .targetArea, intendedTankLitres: 1500, targetAreaHa: 3)
        changed.applicationGeometry = geometry
        #expect(changed.id == captured.id)
        #expect(SprayPlanningOperationalGate.tankConfirmationBlocker(current: changed, captured: captured) != nil)
        #expect(SprayPlanningOperationalGate.tankConfirmationBlocker(current: nil, captured: captured) != nil)
        #expect(SprayPlanningOperationalGate.tankConfirmationBlocker(current: changed, captured: changed) == SprayPlanningOperationalGate.migrationMessage)
    }

    @Test func clearedPlanningSurvivesDiskReloadAndEncodesOnlyPlanningNulls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var snapshot = SprayApplicationSnapshot(grossAreaHa: 10, rowSpacingMetres: 2.8, totalCarrierLitres: 1500)
        snapshot.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1500, targetAreaHa: 3)
        snapshot.planningResolution = snapshot.planningIntent?.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 500)
        let cleared = snapshot.clearingPlanning()
        #expect(cleared.grossAreaHa == snapshot.grossAreaHa)
        #expect(cleared.totalCarrierLitres == snapshot.totalCarrierLitres)
        #expect(cleared.planningIntent == nil && cleared.planningResolution == nil)
        let file = directory.appendingPathComponent("snapshot.json")
        try JSONEncoder().encode(cleared).write(to: file, options: .atomic)
        let reloaded = try JSONDecoder().decode(SprayApplicationSnapshot.self, from: Data(contentsOf: file))
        #expect(reloaded == cleared)
        #expect(reloaded.templateConfiguration()?.planningFieldsCleared == true)
        let record = SprayRecord(sprayReference: "Retained name", notes: "Retained notes", applicationGeometry: reloaded)
        let payload = BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        for key in ["sprayer_configuration", "spray_planning_method", "full_tank_specification", "planning_input_provenance", "planning_intended_tank_litres", "planning_target_area_ha", "planning_calibrated_litres_per_hectare", "planned_application_area_ha", "resolved_planning_carrier_litres", "resolved_planning_litres_per_hectare", "resolved_planning_physical_row_litres_per_100m", "resolved_planning_concentration_factor", "controller_litres_per_100m_travel", "effective_working_width_metres"] {
            #expect(object[key] is NSNull)
        }
        #expect(object["notes"] as? String == "Retained notes")
        #expect(object["gross_area_ha"] as? Double == 10)
        #expect(object["planningFieldsCleared"] == nil)
        #expect(record.operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
        #expect(payload.operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
    }

    @Test func templateEditorPreservesPlanningAndDeclaresOnlyDeliberateChanges() throws {
        var snapshot = SprayApplicationSnapshot(carrierVolumeBasis: .litresPerHectare,
            carrierLitresPerHectare: 500, sprayHeadTarget: .fullCanopy)
        snapshot.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1500, targetAreaHa: 3,
            inputProvenance: SprayPlanningInputProvenance(tankText: "1,500", areaText: "3.00", rateText: "28", volumeUnit: "litres", areaUnit: "hectares", rateAreaUnit: "100m_travel", countryCode: "NZ"))
        let record = SprayRecord(sprayReference: "Synthetic step", isTemplate: true, applicationGeometry: snapshot)
        var draft = SprayProgramStepDraft(step: SprayProgramStep(record: record, source: .local))
        draft.notes = "Unrelated edit"
        let unchanged = draft.applied(to: record)
        #expect(unchanged.applicationGeometry?.planningIntent == snapshot.planningIntent)
        #expect(unchanged.applicationGeometry?.planningResolution == nil)
        #expect(unchanged.applicationGeometry?.carrierVolumeBasis == snapshot.carrierVolumeBasis)
        #expect(unchanged.applicationGeometry?.carrierLitresPerHectare == snapshot.carrierLitresPerHectare)
        #expect(unchanged.applicationGeometry?.sprayHeadTarget == snapshot.sprayHeadTarget)
        #expect(draft.portalPayload(updatedBy: nil).planningFields == nil)
        draft.planningIntent?.targetAreaHa = 2
        #expect(draft.portalPayload(updatedBy: nil).planningFields?.planningTargetAreaHa == 2)
        draft.planningIntent = nil
        let payload = draft.portalPayload(updatedBy: nil)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(object["planning_target_area_ha"] is NSNull)
        #expect(object["resolved_planning_carrier_litres"] == nil)
        #expect(draft.applied(to: record).applicationGeometry?.planningFieldsCleared == true)
        #expect(draft.applied(to: record).applicationGeometry?.carrierLitresPerHectare == snapshot.carrierLitresPerHectare)
        #expect(draft.applied(to: record).applicationGeometry?.sprayHeadTarget == snapshot.sprayHeadTarget)
    }

    @Test func portalAdapterPreservesTheCanonicalFrozenChemicalSnapshot() throws {
        let snapshot = ChemicalLineSnapshot(productName: "Synthetic sulphur", activityGroupCodes: ["M2"], verificationStatus: .unverified)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        let rowObject: [String: Any] = ["id": UUID().uuidString, "vineyard_id": UUID().uuidString, "name": "Synthetic step",
            "chemical_lines": [["name": "Synthetic sulphur", "rate": 45, "unit": "mL/100L", "chemical_snapshot": object]]]
        let row = try JSONDecoder().decode(BackendSprayJobTemplate.self, from: JSONSerialization.data(withJSONObject: rowObject))
        #expect(row.toSprayRecord().tanks.first?.chemicals.first?.chemicalSnapshot == snapshot)
        let draft = SprayProgramStepDraft(step: SprayProgramStep(record: row.toSprayRecord(), source: .portal))
        #expect(draft.chemicalLines().first?.chemicalSnapshot == snapshot)
    }

    @Test func sharedProgramReplacementAndClearingPreserveEveryNonPlanningPatchField() throws {
        let row = try JSONDecoder().decode(BackendSprayJobTemplate.self, from: Data("""
        {"id":"dddddddd-0000-0000-0000-0000000000a1","vineyard_id":"22222222-2222-2222-2222-222222222222",
         "name":"Synthetic step","status":"draft","is_template":true,"notes":"Keep notes",
         "water_volume":1500,"spray_rate_per_ha":500,"concentration_factor":1,"chemical_lines":[],
         "sprayer_configuration":"over_row_two_rows","spray_planning_method":"full_tank",
         "full_tank_specification":"target_area","planning_intended_tank_litres":1500,"planning_target_area_ha":3}
        """.utf8))
        var draft = SprayProgramStepDraft(step: SprayProgramStep(record: row.toSprayRecord(), source: .portal))
        let original = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft.portalPayload(updatedBy: nil))) as? NSDictionary)
        draft.planningIntent = SprayPlanningIntent(configuration: .standardPass, method: .fullTank,
            fullTankSpecification: .calibratedRate, intendedTankLitres: 1200, calibratedLitresPerHectare: 600)
        let replacement = draft.portalPayload(updatedBy: nil)
        let replacedRow = row.applying(replacement)
        #expect(replacedRow.planningFields.planningTargetAreaHa == nil)
        #expect(replacedRow.planningFields.planningCalibratedLitresPerHectare == 600)
        #expect(replacedRow.toSprayRecord().applicationGeometry?.planningResolution == nil)
        draft.planningIntent = nil
        let cleared = draft.portalPayload(updatedBy: nil)
        let clearedObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        let keys = ["sprayer_configuration", "spray_planning_method", "full_tank_specification", "planning_input_provenance", "planning_intended_tank_litres", "planning_target_area_ha", "planning_calibrated_litres_per_hectare"]
        for key in keys { #expect(clearedObject[key] is NSNull) }
        let nonPlanning = clearedObject.filter { !keys.contains($0.key) } as NSDictionary
        #expect(nonPlanning == original)
        let clearedRow = replacedRow.applying(cleared)
        #expect(clearedRow.id == row.id && clearedRow.vineyardId == row.vineyardId)
        #expect(clearedRow.status == row.status && clearedRow.waterVolume == row.waterVolume)
        #expect(clearedRow.sprayRatePerHa == row.sprayRatePerHa && clearedRow.concentrationFactor == row.concentrationFactor)
        #expect(clearedRow.notes == row.notes && clearedRow.chemicalLines == row.chemicalLines)
        #expect(clearedRow.toSprayRecord().applicationGeometry?.planningIntent == nil)
    }

    @Test func clearingOnlyChangesPlanningKeysInCompleteRecordProjection() throws {
        var snapshot = SprayApplicationSnapshot(grossAreaHa: 10, rowSpacingMetres: 2.8, totalCarrierLitres: 1500)
        snapshot.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank,
            fullTankSpecification: .targetArea, intendedTankLitres: 1500, targetAreaHa: 3)
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let record = SprayRecord(date: time, startTime: time, sprayReference: "Keep name", notes: "Keep notes", applicationGeometry: snapshot)
        var cleared = record
        cleared.applicationGeometry = snapshot.clearingPlanning()
        let before = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: time))) as? [String: Any])
        let after = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BackendSprayRecord.upsert(from: cleared, createdBy: nil, clientUpdatedAt: time))) as? [String: Any])
        let keys = Set(["sprayer_configuration", "spray_planning_method", "full_tank_specification", "planning_input_provenance", "planning_intended_tank_litres", "planning_target_area_ha", "planning_calibrated_litres_per_hectare", "planned_application_area_ha", "resolved_planning_carrier_litres", "resolved_planning_litres_per_hectare", "resolved_planning_physical_row_litres_per_100m", "resolved_planning_concentration_factor", "controller_litres_per_100m_travel", "effective_working_width_metres"])
        #expect((before.filter { !keys.contains($0.key) } as NSDictionary) == (after.filter { !keys.contains($0.key) } as NSDictionary))
        for key in keys { #expect(after[key] is NSNull) }
        #expect(cleared.id == record.id && cleared.tanks == record.tanks)
    }

    @Test func selectedControllerEntryConvertsToOnePhysicalRateAcrossConfigurationChanges() throws {
        let standard = try #require(SprayControllerRateEntry.canonical(16.8, basis: .litresPer100Metres, configuration: .standardPass, spacing: 2.8))
        #expect(abs(standard - 600) < 0.00000001)
        let over = try #require(SprayControllerRateEntry.displayed(standard, basis: .litresPer100Metres, configuration: .overRow, spacing: 2.8))
        #expect(abs(over - 33.6) < 0.00000001)
        let restored = try #require(SprayControllerRateEntry.canonical(over, basis: .litresPer100Metres, configuration: .overRow, spacing: 2.8))
        #expect(abs(restored - standard) < 0.00000001)
        #expect(SprayControllerRateEntry.displayed(restored, basis: .litresPerHectare, configuration: .standardPass, spacing: nil) == restored)
        #expect(SprayControllerRateEntry.canonical(16.8, basis: .litresPer100Metres, configuration: .overRow, spacing: nil) == nil)
        #expect(SprayControllerRateEntry.canonical(0, basis: .litresPerHectare, configuration: nil, spacing: nil) == nil)
    }

    @Test func passConfigurationKeepsPhysicalRowRateAndChangesTravelRateOnly() throws {
        let standard = SprayPlanningIntent(configuration: .standardPass, method: .byArea, calibratedLitresPerHectare: 500)
        var over = standard
        over.configuration = .overRow
        let a = try #require(standard.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 500))
        let b = try #require(over.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 500))
        #expect(a.physicalRowLitresPer100m == 14)
        #expect(b.physicalRowLitresPer100m == 14)
        #expect(a.controllerLitresPer100mTravel == 14)
        #expect(b.controllerLitresPer100mTravel == 28)
        #expect(b.effectiveWorkingWidthMetres == 5.6)
        #expect(a.intendedLitres == b.intendedLitres)
    }

    @Test func targetAreaAndCalibratedRateResolveSameFullTank() throws {
        let target = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1000, targetAreaHa: 2)
        let rate = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .calibratedRate, intendedTankLitres: 1000, calibratedLitresPerHectare: 500)
        let a = try #require(target.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 1000))
        let b = try #require(rate.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 1000))
        #expect(a == b)
        #expect(a.plannedAreaHa == 2)
        #expect(a.concentrationFactor == 2)
    }

    @Test func invalidOrExcessiveIntentNeverBecomesCoverage() {
        for area in [0.0, -1, 11, Double.nan, Double.infinity] {
            let intent = SprayPlanningIntent(configuration: .standardPass, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1000, targetAreaHa: area)
            #expect(intent.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 500) == nil)
        }
        #expect(SprayPlanningIntent().resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 500) == nil)
    }

    @Test func fullTankUsesExistingChemicalEngineWithoutInventedBlockAttribution() throws {
        var input = SprayGuidedInputs()
        input.blocks = [SprayBlockInput(blockId: "A", grossAreaHectares: 10, mappedRowLengthMetres: 35714.285714, rowSpacingMetres: 2.8)]
        input.targets = [.powderyMildew]
        input.sprayHeadTarget = .fullCanopy
        input.isGrowthStageResolved = true
        input.isEquipmentSelected = true
        input.isEquipmentConfirmed = true
        input.tankCapacityLitres = 1000
        input.canopy = .prefilled(size: .medium, density: .high)
        input.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1000, targetAreaHa: 2)
        input.products = [SprayProductLineInput(productId: "area", name: "Area product", unit: "L", basis: .wholeBlockArea, rate: 3)]
        let flow = SprayGuidedFlow(inputs: input)
        #expect(flow.isComplete)
        #expect(flow.plan.totalCarrierLitres == 1000)
        #expect(flow.plan.productLines.first?.totalQuantity == 6)
        #expect(flow.plan.grossAreaHectares == 10)
        #expect(flow.plan.treatedAreaHectares == nil)
        let snapshot = try #require(flow.snapshot)
        #expect(snapshot.blocks == nil)
        #expect(snapshot.canonicalRowLengthMetres == nil)
        #expect(snapshot.planningResolution?.plannedAreaHa == 2)
        #expect(flow.operationalBlocker == SprayPlanningOperationalGate.migrationMessage)
        input.products = [SprayProductLineInput(productId: "row", name: "Row product", unit: "L", basis: .per100Metres, rate: 1)]
        #expect(!SprayGuidedFlow(inputs: input).isComplete)
        input.planningIntent?.intendedTankLitres = 1001
        #expect(SprayGuidedFlow(inputs: input).planningResolution == nil)
    }

    @Test func byAreaCardsReadTheExistingMappedRowCarrierRatherThanInventingAnotherTotal() throws {
        var input = SprayGuidedInputs()
        input.blocks = [SprayBlockInput(blockId: "A", grossAreaHectares: 10, mappedRowLengthMetres: 10_000, rowSpacingMetres: 2.8)]
        input.canopy = .prefilled(size: .medium, density: .high)
        input.carrierBasis = .litresPer100Metres
        input.sprayVolumeChoice = .useCustomSprayerRate
        input.customSprayerBasis = .litresPer100Metres
        input.customSprayerRate = 10
        input.planningIntent = SprayPlanningIntent(configuration: .standardPass, method: .byArea)
        let flow = SprayGuidedFlow(inputs: input)
        #expect(flow.carrier?.totalLitres == 1000)
        #expect(flow.planningResolution?.intendedLitres == 1000)
        input.carrierBasis = .manualTotalVolume
        input.tankCapacityLitres = 1000
        input.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1000, targetAreaHa: 2)
        #expect(SprayGuidedFlow(inputs: input).planningResolution?.intendedLitres == 1000)
    }

    @Test func localSnapshotRoundTripPreservesIntentBasisAndFrozenOutputs() throws {
        var snapshot = SprayApplicationSnapshot(rowSpacingMetres: 2.8, carrierVolumeBasis: .litresPer100Metres, totalCarrierLitres: 1000, concentrationFactor: 2)
        snapshot.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1000, targetAreaHa: 2)
        snapshot.planningIntent?.inputProvenance = SprayPlanningInputProvenance(tankText: "264.172052", areaText: "4.9421076",
            rateText: "", volumeUnit: "gallons", areaUnit: "acres", rateAreaUnit: "acre", countryCode: "US")
        snapshot.planningResolution = snapshot.planningIntent?.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 1000)
        let data = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(SprayApplicationSnapshot.self, from: data)
        #expect(restored == snapshot)
        #expect(restored.withBlocks(nil)?.planningResolution == snapshot.planningResolution)
        #expect(restored.templateConfiguration()?.planningIntent == snapshot.planningIntent)
        #expect(restored.templateConfiguration()?.planningResolution == nil)
        let historical = try JSONDecoder().decode(SprayApplicationSnapshot.self, from: Data("{\"carrierVolumeBasis\":\"l_per_ha\",\"totalCarrierLitres\":500}".utf8))
        #expect(historical.planningIntent == nil)
        #expect(historical.planningResolution == nil)
        #expect(historical.totalCarrierLitres == 500)
    }

    @Test func acceptanceNumbersAndTamperedFullTankResolution() throws {
        let standard = SprayPlanningIntent(configuration: .standardPass, method: .byArea, calibratedLitresPerHectare: 600)
        let a = try #require(standard.resolve(selectedAreaHa: 3, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 600))
        var over = standard; over.configuration = .overRow
        let b = try #require(over.resolve(selectedAreaHa: 3, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 600))
        #expect(abs((a.controllerLitresPer100mTravel ?? 0) - 16.8) < 0.00000001)
        #expect(abs((b.controllerLitresPer100mTravel ?? 0) - 33.6) < 0.00000001)
        let target = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1500, targetAreaHa: 3)
        let resolved = try #require(target.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 600))
        #expect(resolved.litresPerHectare == 500)
        #expect(target.fullTankExecutionBlocker(resolution: resolved, selectedGrossAreaHa: 10) == nil)
        let tampered = SprayPlanningResolution(intendedLitres: 1500, plannedAreaHa: 3, litresPerHectare: 600,
            physicalRowLitresPer100m: 16.8, controllerLitresPer100mTravel: 33.6, effectiveWorkingWidthMetres: 5.6, concentrationFactor: 1)
        #expect(target.fullTankExecutionBlocker(resolution: tampered, selectedGrossAreaHa: 10) != nil)
        let calibrated = SprayPlanningIntent(configuration: .standardPass, method: .fullTank, fullTankSpecification: .calibratedRate, intendedTankLitres: 1500, calibratedLitresPerHectare: 600)
        #expect(calibrated.resolve(selectedAreaHa: 10, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 600)?.plannedAreaHa == 2.5)
        #expect(SprayPlanningIntent().fullTankExecutionBlocker(resolution: nil, selectedGrossAreaHa: nil) == nil)
    }

    @Test func flatWireRecordAndSharedTemplatePreserveFrozenPlanning() throws {
        let id = UUID(), vineyard = UUID()
        let data = Data("""
        {"id":"\(id)","vineyard_id":"\(vineyard)","name":"Draft",
         "sprayer_configuration":"over_row_two_rows","spray_planning_method":"full_tank",
         "full_tank_specification":"target_area","planning_intended_tank_litres":1500,
         "planning_target_area_ha":3,"planned_application_area_ha":3,"planning_calibrated_litres_per_hectare":500,
         "resolved_planning_carrier_litres":1500,"resolved_planning_litres_per_hectare":500,
         "resolved_planning_physical_row_litres_per_100m":14,"resolved_planning_concentration_factor":1.2,
         "gross_area_ha":10,"total_carrier_litres":1500,"carrier_litres_per_hectare":500,"applied_litres_per_100m":14,
         "controller_litres_per_100m_travel":28,"effective_working_width_metres":5.6,"concentration_factor":1.2}
        """.utf8)
        let remote = try JSONDecoder().decode(BackendSprayRecord.self, from: data)
        let local = remote.toSprayRecord()
        #expect(local.applicationGeometry?.planningIntent?.configuration == .overRow)
        #expect(local.applicationGeometry?.planningResolution?.controllerLitresPer100mTravel == 28)
        #expect(local.applicationGeometry?.appliedLitresPer100m == 14)
        let payload = BackendSprayRecord.upsert(from: local, createdBy: nil, clientUpdatedAt: Date())
        #expect(payload.planningIntendedTankLitres == 1500)
        #expect(payload.operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
        let job = try JSONDecoder().decode(BackendSprayJobTemplate.self, from: data)
        #expect(job.toSprayRecord().applicationGeometry?.planningIntent?.intendedTankLitres == 1500)
        let cache = try JSONDecoder().decode(BackendSprayJobTemplate.self, from: JSONEncoder().encode(job))
        #expect(cache.planningFields == job.planningFields)
        #expect(cache.toSprayRecord().applicationGeometry?.planningResolution == nil)
    }

    @Test func v2ProjectionSeparatesInputsOutputsAndClearsStaleResolution() throws {
        let provenance = SprayPlanningInputProvenance(tankText: " 1500.00 ", areaText: "", rateText: "600.00",
            volumeUnit: "litres", areaUnit: "hectares", rateAreaUnit: "hectare", countryCode: "AU")
        let intent = SprayPlanningIntent(configuration: .standardPass, method: .fullTank, fullTankSpecification: .calibratedRate,
            intendedTankLitres: 1500, calibratedLitresPerHectare: 600, inputProvenance: provenance)
        let output = try #require(intent.resolve(selectedAreaHa: 8, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 713))
        let fields = SprayPlanningWireFields(intent: intent, resolution: output)
        #expect(fields.planningTargetAreaHa == nil)
        #expect(fields.plannedApplicationAreaHa == 2.5)
        #expect(fields.intent?.targetAreaHa == nil)
        #expect(fields.resolution() == output)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fields)) as? [String: Any])
        #expect(object.count == 14)
        #expect(object["planning_tank_capacity_litres"] == nil)
        #expect(object["planning_target_area_ha"] is NSNull)
        let raw = try #require(object["planning_input_provenance"] as? [String: Any])
        #expect(raw["schema_version"] as? Int == 1)
        #expect(raw["tank_text"] as? String == " 1500.00 ")
        let edited = SprayPlanningWireFields(intent: SprayPlanningIntent(configuration: .overRow, method: .byArea))
        let patch = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any])
        #expect(patch["full_tank_specification"] is NSNull)
        #expect(patch["resolved_planning_carrier_litres"] is NSNull)
        #expect(edited.resolution() == nil)
        #expect(SprayPlanningWireFields(intent: nil).resolution() == nil)
        let template = SprayPlanningWireFields(intent: intent, resolution: output, isTemplate: true)
        #expect(template.plannedApplicationAreaHa == nil)
        #expect(template.resolvedPlanningCarrierLitres == nil)
    }

    @Test func wireProvenanceUsesCapturedCountryForDistinctGallons() throws {
        for (country, unit) in [("US", "us_gallons"), ("CA", "us_gallons"), ("GB", "imperial_gallons")] {
            let original = SprayPlanningInputProvenance(tankText: "123.000", areaText: " 3 ", rateText: "",
                volumeUnit: "gallons", areaUnit: "acres", rateAreaUnit: "acre", countryCode: country)
            let wire = SprayPlanningWireProvenance(original)
            #expect(wire.volumeUnit == unit)
            let reopened = try JSONDecoder().decode(SprayPlanningWireProvenance.self, from: JSONEncoder().encode(wire))
            #expect(reopened.local.tankText == original.tankText)
            #expect(reopened.local.volumeUnit == unit)
            #expect(reopened.local.countryCode == country)
        }
    }

    @Test func complianceIsPerTankAndRejectsUnknownInvalidOrAmbiguousDiluteEvidence() {
        let dilute = SprayChemical(name: "Dilute product", ratePer100L: 100)
        let area = SprayChemical(name: "Area product", ratePerHa: 2, rateBasis: .wholeBlockArea)
        let mixed = [SprayTank(concentrationFactor: 1, chemicals: [dilute]), SprayTank(concentrationFactor: 4, chemicals: [area])]
        #expect(SprayRecord(tanks: mixed).operationalPlanningBlocker == nil)
        for factor in [0.0, -1.0, 0.9, Double.infinity, Double.nan] {
            #expect(SprayRecord(tanks: [SprayTank(concentrationFactor: factor, chemicals: [dilute])]).operationalPlanningBlocker?.contains("Dilute product") == true)
        }
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: nil, hasDiluteRateProducts: true) != nil)
        let ambiguous = SprayChemical(name: "Ambiguous", ratePerHa: 1, ratePer100L: 1)
        #expect(SprayRecord(tanks: [SprayTank(concentrationFactor: 1, chemicals: [ambiguous])]).operationalPlanningBlocker?.contains("Ambiguous") == true)
    }

    @Test func canopyComparisonHasMinimumOneWithoutAuthorisingConcentrate() throws {
        for (rate, factor) in [(750.0, 1.0), (500.0, 1.426)] {
            let intent = SprayPlanningIntent(configuration: .overRow, method: .byArea, calibratedLitresPerHectare: rate)
            let resolved = try #require(intent.resolve(selectedAreaHa: 8, physicalRowSpacingMetres: 2.8, diluteLitresPerHectare: 713))
            #expect(abs(resolved.concentrationFactor - factor) < 0.00000001)
        }
    }

    @Test func namedChemicalBlockerDoesNotBlockAreaOnlyMixes() {
        let dilute = SprayChemical(name: "Unverified sulphur", ratePer100L: 100)
        let record = SprayRecord(tanks: [SprayTank(concentrationFactor: 2, chemicals: [dilute])])
        #expect(record.operationalPlanningBlocker == nil)
        let area = SprayChemical(name: "Area only", ratePerHa: 2000, rateBasis: .wholeBlockArea)
        #expect(SprayRecord(tanks: [SprayTank(concentrationFactor: 2, chemicals: [area])]).operationalPlanningBlocker == nil)
    }

    @Test func concentrateCannotBeApprovedByANumericFactor() {
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: 2, hasDiluteRateProducts: true) == nil)
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: true, concentrationFactor: 1, hasDiluteRateProducts: false) == SprayPlanningOperationalGate.migrationMessage)
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: 1, hasDiluteRateProducts: true) == nil)
    }

    @Test(arguments: [0, 1, 2])
    func persistedQueuedIntentAndInvalidFactorStayBlockedAcrossReplay(_ scenario: Int) async throws {
        let invalidFactor = scenario == 1
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        var snapshot = SprayApplicationSnapshot(carrierVolumeBasis: .litresPer100Metres, concentrationFactor: invalidFactor ? 0.9 : 1)
        if !invalidFactor { snapshot.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1000, targetAreaHa: 2) }
        if scenario == 2 { snapshot = snapshot.clearingPlanning() }
        let tanks: [SprayTank] = invalidFactor ? [SprayTank(concentrationFactor: 0.9, chemicals: [SprayChemical(ratePer100L: 100)])] : []
        let eventTime = Date(timeIntervalSince1970: 1_800_000_000)
        let record = SprayRecord(date: eventTime, startTime: eventTime, tanks: tanks, applicationGeometry: snapshot)
        store.selectedVineyardId = record.vineyardId
        // Seed the exact pre-existing pending record; ordinary new writes are gated.
        store.applyRemoteSprayRecordUpsert(record)
        let repository = PlanningReplayRepository()
        let metadata = SprayRecordSyncMetadata(persistence: persistence)
        let service = SprayRecordSyncService(repository: repository, metadata: metadata)
        let auth = NewBackendAuthService()
        service.configure(store: store, auth: auth)
        service.markSprayRecordDirty(record.id)
        do {
            try await service.pushLocalSprayRecords(vineyardId: record.vineyardId)
            Issue.record("Blocked planning record unexpectedly replayed")
        } catch let error as SprayPlanningAdmissionError {
            #expect(error.message == (invalidFactor ? SprayPlanningOperationalGate.concentrateMessage : SprayPlanningOperationalGate.migrationMessage))
        }
        let calls = await repository.writeCalls
        #expect(calls == 0)
        #expect(service.isPendingUpsert(record.id))
        #expect(SprayRecordSyncMetadata(persistence: persistence).isUpsertFailed(record.id))
        #expect(SprayRepository(persistence: persistence).loadRecords(for: record.vineyardId).first == record)
        #expect(!store.addSprayRecord(record))
        #expect(!store.updateSprayRecord(record))
        #expect(store.sprayRecords == [record])
    }

    @Test func backendMappingProjectsReviewedFieldsButTransportAdmissionStaysDisabled() throws {
        var snapshot = SprayApplicationSnapshot()
        snapshot.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank)
        let record = SprayRecord(applicationGeometry: snapshot)
        let upsert = BackendSprayRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())
        #expect(upsert.operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
        #expect(record.operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(upsert)) as? [String: Any])
        #expect(object["planningIntent"] == nil)
        #expect(object["sprayer_configuration"] as? String == "over_row_two_rows")
        #expect(object["planned_application_area_ha"] is NSNull)
        #expect(object["resolved_planning_carrier_litres"] is NSNull)
        let old = BackendSprayRecord.upsert(from: SprayRecord(), createdBy: nil, clientUpdatedAt: Date())
        let legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(legacy["sprayer_configuration"] == nil)
    }
}

@MainActor private final class PlanningReplayRepository: SprayRecordSyncRepositoryProtocol {
    var writeCalls: Int = 0
    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord] { [] }
    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord] { [] }
    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws { writeCalls += 1 }
    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws { writeCalls += 1 }
    func softDeleteSprayRecord(id: UUID) async throws { writeCalls += 1 }
}
