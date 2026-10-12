import Foundation
import Testing
@testable import VineTrack

@MainActor
struct SprayPlanningIntentTests {
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
         "full_tank_specification":"target_area","planning_tank_capacity_litres":1500,
         "planned_application_area_ha":3,"planning_calibrated_litres_per_hectare":500,
         "gross_area_ha":10,"total_carrier_litres":1500,"carrier_litres_per_hectare":500,"applied_litres_per_100m":14,
         "controller_litres_per_100m_travel":28,"effective_working_width_metres":5.6,"concentration_factor":1.2}
        """.utf8)
        let remote = try JSONDecoder().decode(BackendSprayRecord.self, from: data)
        let local = remote.toSprayRecord()
        #expect(local.applicationGeometry?.planningIntent?.configuration == .overRow)
        #expect(local.applicationGeometry?.planningResolution?.controllerLitresPer100mTravel == 28)
        #expect(local.applicationGeometry?.appliedLitresPer100m == 14)
        let payload = BackendSprayRecord.upsert(from: local, createdBy: nil, clientUpdatedAt: Date())
        #expect(payload.planningTankCapacityLitres == 1500)
        #expect(payload.operationalPlanningBlocker == SprayPlanningOperationalGate.migrationMessage)
        let job = try JSONDecoder().decode(BackendSprayJobTemplate.self, from: data)
        #expect(job.toSprayRecord().applicationGeometry?.planningIntent?.intendedTankLitres == 1500)
        let cache = try JSONDecoder().decode(BackendSprayJobTemplate.self, from: JSONEncoder().encode(job))
        #expect(cache.planningFields == job.planningFields)
        #expect(cache.toSprayRecord().applicationGeometry?.planningResolution == nil)
    }

    @Test func namedChemicalBlockerDoesNotBlockAreaOnlyMixes() {
        let dilute = SprayChemical(name: "Unverified sulphur", ratePer100L: 100)
        let record = SprayRecord(tanks: [SprayTank(concentrationFactor: 2, chemicals: [dilute])])
        #expect(record.operationalPlanningBlocker?.contains("Unverified sulphur") == true)
        let area = SprayChemical(name: "Area only", ratePerHa: 2000, rateBasis: .wholeBlockArea)
        #expect(SprayRecord(tanks: [SprayTank(concentrationFactor: 2, chemicals: [area])]).operationalPlanningBlocker == nil)
    }

    @Test func concentrateCannotBeApprovedByANumericFactor() {
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: 2, hasDiluteRateProducts: true) == SprayPlanningOperationalGate.concentrateMessage)
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: true, concentrationFactor: 1, hasDiluteRateProducts: false) == SprayPlanningOperationalGate.migrationMessage)
        #expect(SprayPlanningOperationalGate.blocker(hasPlanningIntent: false, concentrationFactor: 1, hasDiluteRateProducts: true) == nil)
    }

    @Test(arguments: [false, true])
    func persistedQueuedIntentAndUnverifiedConcentrateStayBlockedAcrossReplay(_ concentrated: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let store = MigratedDataStore(persistence: persistence)
        var snapshot = SprayApplicationSnapshot(carrierVolumeBasis: .litresPer100Metres, concentrationFactor: concentrated ? 2 : 1)
        if !concentrated { snapshot.planningIntent = SprayPlanningIntent(configuration: .overRow, method: .fullTank, fullTankSpecification: .targetArea, intendedTankLitres: 1000, targetAreaHa: 2) }
        let tanks: [SprayTank] = concentrated ? [SprayTank(concentrationFactor: 2, chemicals: [SprayChemical(ratePer100L: 100)])] : []
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
            #expect(error.message == (concentrated ? SprayPlanningOperationalGate.concentrateMessage : SprayPlanningOperationalGate.migrationMessage))
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
        #expect(object["planned_application_area_ha"] == nil)
        let old = BackendSprayRecord.upsert(from: SprayRecord(), createdBy: nil, clientUpdatedAt: Date())
        let legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        #expect(legacy["sprayer_configuration"] == nil)
    }
}

private actor PlanningReplayRepository: SprayRecordSyncRepositoryProtocol {
    var writeCalls: Int = 0
    func fetchAllSprayRecords(vineyardId: UUID) async throws -> [BackendSprayRecord] { [] }
    func fetchSprayRecords(vineyardId: UUID, since: Date?) async throws -> [BackendSprayRecord] { [] }
    func upsertSprayRecord(_ record: BackendSprayRecordUpsert) async throws { writeCalls += 1 }
    func upsertSprayRecords(_ records: [BackendSprayRecordUpsert]) async throws { writeCalls += 1 }
    func softDeleteSprayRecord(id: UUID) async throws { writeCalls += 1 }
}
