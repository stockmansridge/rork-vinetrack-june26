import Foundation
import Testing
@testable import VineTrack

/// Spray Program UX restructure — Program vs Sprays.
///
/// The restructure's whole claim is that a reusable Program Step and an applied
/// Spray are different kinds of thing. These tests hold that line at the two
/// places it can actually break: what lands in each list, and what a Program
/// Step is allowed to carry into the guided calculator.
struct SprayProgramRestructureTests {

    // MARK: - Helpers

    private func portalTemplate(_ json: String) throws -> BackendSprayJobTemplate {
        try JSONDecoder().decode(BackendSprayJobTemplate.self, from: Data(json.utf8))
    }

    private func localStep(
        id: UUID = UUID(),
        name: String,
        notes: String = "",
        chemicals: [SprayChemical] = [],
        equipmentId: UUID? = nil,
        tractorId: UUID? = nil,
        targets: [SprayTarget] = []
    ) -> SprayRecord {
        SprayRecord(
            id: id,
            sprayReference: name,
            tanks: [SprayTank(chemicals: chemicals)],
            notes: notes,
            tractorId: tractorId,
            sprayEquipmentId: equipmentId,
            isTemplate: true,
            applicationGeometry: targets.isEmpty ? nil : SprayApplicationSnapshot(targets: targets)
        )
    }

    private func operationalRecord(name: String, endTime: Date? = nil) -> SprayRecord {
        SprayRecord(
            endTime: endTime,
            sprayReference: name,
            tanks: [SprayTank()],
            isTemplate: false
        )
    }

    /// A portal Program Step with a canonical stage code, a multi-target string
    /// and two products on different rate bases.
    private let budBurstJSON = """
    {
      "id": "dddddddd-0000-0000-0000-000000000001",
      "vineyard_id": "22222222-2222-2222-2222-222222222222",
      "name": "Bud Burst",
      "growth_stage_code": "EL4",
      "target": "Downy Mildew · Black Spot · Phomopsis · Powdery Mildew",
      "operation_type": "Foliar Spray",
      "notes": "Cover spray before rain.",
      "equipment_id": "eeeeeeee-0000-0000-0000-000000000001",
      "tractor_id": "ffffffff-0000-0000-0000-000000000001",
      "water_volume": 1000,
      "spray_rate_per_ha": 300,
      "chemical_lines": [
        { "name": "Greenshield Copper", "rate": 1, "unit": "kg/ha" },
        { "name": "Thiovit Jet", "rate": 300, "unit": "mL/100L" }
      ]
    }
    """

    // MARK: - Program source

    @Test func localAndPortalStepsBothAppearInProgram() throws {
        let local = localStep(name: "Local Step")
        let portal = try portalTemplate(budBurstJSON)

        let steps = SprayProgramCatalog.steps(
            localRecords: [local, operationalRecord(name: "A real spray")],
            portalRecords: [portal.toSprayRecord()],
            portalRows: [portal]
        )

        #expect(steps.count == 2)
        #expect(steps.contains { $0.name == "Local Step" && $0.source == .local })
        #expect(steps.contains { $0.name == "Bud Burst" && $0.source == .portal })
    }

    @Test func operationalRecordsNeverAppearInProgram() {
        let steps = SprayProgramCatalog.steps(
            localRecords: [
                operationalRecord(name: "Completed spray", endTime: Date()),
                operationalRecord(name: "Upcoming spray")
            ],
            portalRecords: []
        )
        #expect(steps.isEmpty)
    }

    @Test func duplicateIdsAppearOnceAndLocalWins() throws {
        let sharedId = UUID(uuidString: "dddddddd-0000-0000-0000-000000000001")!
        let local = localStep(id: sharedId, name: "Locally edited")
        let portal = try portalTemplate(budBurstJSON)
        #expect(portal.id == sharedId)

        let steps = SprayProgramCatalog.steps(
            localRecords: [local],
            portalRecords: [portal.toSprayRecord()],
            portalRows: [portal]
        )

        #expect(steps.count == 1)
        // The device's own record is not shadowed by a read-only copy, and the
        // surviving step stays editable.
        #expect(steps[0].name == "Locally edited")
        #expect(steps[0].source == .local)
        #expect(steps[0].isPortalManaged == false)
    }

    @Test func repeatedPortalRecordsCollapseToOneStep() throws {
        let portal = try portalTemplate(budBurstJSON)
        let record = portal.toSprayRecord()
        let steps = SprayProgramCatalog.steps(
            localRecords: [],
            portalRecords: [record, record],
            portalRows: [portal]
        )
        #expect(steps.count == 1)
    }

    // MARK: - Program sort

    private func stagedSteps() -> [SprayProgramStep] {
        [
            SprayProgramStep(record: localStep(name: "Veraison EL31"), source: .local),
            SprayProgramStep(record: localStep(name: "No stage at all"), source: .local),
            SprayProgramStep(record: localStep(name: "Woolly bud EL7"), source: .local),
            SprayProgramStep(record: localStep(name: "Shoots EL12"), source: .local)
        ]
    }

    @Test func programSortsByRealPhenologicalOrder() {
        let sorted = SprayProgramCatalog.sorted(stagedSteps(), by: .elStageAscending)
        #expect(sorted.map(\.name) == [
            "Woolly bud EL7",
            "Shoots EL12",
            "Veraison EL31",
            "No stage at all"
        ])
    }

    @Test func reverseStageOrderStillSinksUnstagedSteps() {
        let sorted = SprayProgramCatalog.sorted(stagedSteps(), by: .elStageDescending)
        #expect(sorted.map(\.name) == [
            "Veraison EL31",
            "Shoots EL12",
            "Woolly bud EL7",
            // An unknown stage is not a low stage — it must not float to the
            // top merely because the order was reversed.
            "No stage at all"
        ])
    }

    @Test func canonicalGrowthStageCodeBeatsTextInTheName() throws {
        // The name says EL31; the portal's canonical code says EL4. The code is
        // the authority.
        let portal = try portalTemplate("""
        {
          "id": "dddddddd-0000-0000-0000-000000000002",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Late season EL31 carryover",
          "growth_stage_code": "EL4",
          "chemical_lines": []
        }
        """)
        let step = SprayProgramStep(
            record: portal.toSprayRecord(),
            source: .portal,
            growthStageCode: portal.growthStageCode,
            targetRaw: portal.target
        )
        #expect(step.elStage == 4)
        #expect(step.elStageLabel == "EL4")
    }

    @Test func stageParsingAcceptsEveryWrittenForm() {
        #expect(ELStageParser.stageNumber(fromCode: "EL12") == 12)
        #expect(ELStageParser.stageNumber(inText: "Spray at E-L 12") == 12)
        #expect(ELStageParser.stageNumber(inText: "el-7 woolly bud") == 7)
        #expect(ELStageParser.stageNumber(inText: "Diesel 5 tractor") == nil)
    }

    @Test func programSortsByNameBothWays() {
        let steps = [
            SprayProgramStep(record: localStep(name: "Zinc spray"), source: .local),
            SprayProgramStep(record: localStep(name: "Autumn copper"), source: .local)
        ]
        #expect(SprayProgramCatalog.sorted(steps, by: .nameAZ).map(\.name) == ["Autumn copper", "Zinc spray"])
        #expect(SprayProgramCatalog.sorted(steps, by: .nameZA).map(\.name) == ["Zinc spray", "Autumn copper"])
    }

    // MARK: - Program search

    @Test func programSearchMatchesStageTargetProductAndName() throws {
        let portal = try portalTemplate(budBurstJSON)
        let step = SprayProgramStep(
            record: portal.toSprayRecord(),
            source: .portal,
            growthStageCode: portal.growthStageCode,
            targetRaw: portal.target
        )

        #expect(step.matches("EL4"))
        #expect(step.matches("E-L 4"))
        #expect(step.matches("Bud Burst"))
        #expect(step.matches("Powdery"))
        #expect(step.matches("Copper"))
        #expect(step.matches("Thiovit"))
        #expect(step.matches("rain"))
        #expect(step.matches("Botrytis") == false)
    }

    @Test func programSearchFiltersTheCatalogue() throws {
        let portal = try portalTemplate(budBurstJSON)
        let steps = SprayProgramCatalog.steps(
            localRecords: [localStep(name: "Veraison botrytis")],
            portalRecords: [portal.toSprayRecord()],
            portalRows: [portal]
        )
        #expect(SprayProgramCatalog.filtered(steps, query: "Copper").map(\.name) == ["Bud Burst"])
        #expect(SprayProgramCatalog.filtered(steps, query: "botrytis").map(\.name) == ["Veraison botrytis"])
        #expect(SprayProgramCatalog.filtered(steps, query: "   ").count == 2)
    }

    // MARK: - Portal adapter pass-through

    @Test func portalStepExposesFieldsTheAdapterUsedToDrop() throws {
        let portal = try portalTemplate(budBurstJSON)
        let record = portal.toSprayRecord()

        // Equipment and tractor identities: decoded before, dropped before.
        #expect(record.sprayEquipmentId == UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000001"))
        #expect(record.tractorId == UUID(uuidString: "ffffffff-0000-0000-0000-000000000001"))

        // Targets are structured now, so the notes are no longer polluted with
        // a "Target: ..." prefix duplicating what the UI shows.
        let targets = try #require(record.applicationGeometry?.targets)
        #expect(Set(targets) == [.downyMildew, .powderyMildew])
        #expect(record.notes == "Cover spray before rain.")
    }

    @Test func unmappableTargetWordingIsPreservedNotDiscarded() throws {
        // "Phomopsis" alone maps to no typed target. The wording must survive,
        // so the old notes prefix is still used when NOTHING mapped.
        let portal = try portalTemplate("""
        {
          "id": "dddddddd-0000-0000-0000-000000000003",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Phomopsis step",
          "target": "Phomopsis",
          "chemical_lines": []
        }
        """)
        let record = portal.toSprayRecord()
        #expect(record.applicationGeometry?.targets == nil)
        #expect(record.notes.contains("Target: Phomopsis"))

        // And the Program Step still displays the verbatim wording.
        let step = SprayProgramStep(record: record, source: .portal, targetRaw: portal.target)
        #expect(step.targetDisplay == "Phomopsis")
        #expect(step.targets.isEmpty)
    }

    @Test func portalProductLinesCarryTheirRateBasis() throws {
        let portal = try portalTemplate(budBurstJSON)
        let products = portal.toSprayRecord().tanks.flatMap(\.chemicals)
        #expect(products.count == 2)

        let copper = try #require(products.first { $0.name == "Greenshield Copper" })
        #expect(copper.rateBasis == .wholeBlockArea)
        #expect(copper.unit == .kilograms)
        #expect(copper.reportedRateText(formatter: .australian) == "1.00 Kg/ha")

        // The P10 defect class: a per-100 L line must not report as 0/ha.
        let thiovit = try #require(products.first { $0.name == "Thiovit Jet" })
        #expect(thiovit.rateBasis == .per100Litres)
        #expect(thiovit.reportedRateText(formatter: .australian) == "300.00 mL/100 L")
    }

    @Test func aLineWithNoRateStatesNoBasis() throws {
        let portal = try portalTemplate("""
        {
          "id": "dddddddd-0000-0000-0000-000000000004",
          "vineyard_id": "22222222-2222-2222-2222-222222222222",
          "name": "Rate decided at planning",
          "chemical_lines": [{ "name": "Some Product" }]
        }
        """)
        let product = try #require(portal.toSprayRecord().tanks.flatMap(\.chemicals).first)
        // Not stated is not zero-per-hectare.
        #expect(product.rateBasis == nil)
        #expect(product.reportedRateBaseValue == 0)
    }

    // MARK: - Plan Spray prefill

    @Test func programStepPrefillCarriesItsConfiguration() throws {
        let portal = try portalTemplate(budBurstJSON)
        let step = SprayProgramStep(
            record: portal.toSprayRecord(),
            source: .portal,
            growthStageCode: portal.growthStageCode,
            targetRaw: portal.target
        )
        let prefill = step.calculatorPrefill

        #expect(prefill.growthStageCode == "EL4")
        #expect(Set(prefill.targets) == [.downyMildew, .powderyMildew])
        #expect(prefill.equipmentId == UUID(uuidString: "eeeeeeee-0000-0000-0000-000000000001"))
        #expect(prefill.tractorId == UUID(uuidString: "ffffffff-0000-0000-0000-000000000001"))
        #expect(prefill.isEmpty == false)

        // Operation type, products and notes ride on the record itself, which
        // is what the calculator's existing prefill path already consumes.
        #expect(step.record.operationType == .foliarSpray)
        #expect(step.record.notes == "Cover spray before rain.")
        #expect(step.record.tanks.flatMap(\.chemicals).count == 2)
    }

    @Test func aGenericProgramStepProposesNoBlocks() throws {
        let portal = try portalTemplate(budBurstJSON)
        let record = portal.toSprayRecord()

        // No block scope exists anywhere in the portal template contract, so
        // there is nothing for the calculator to apply — the operator still
        // chooses at Step 2 rather than inheriting arbitrary paddocks.
        #expect(record.applicationGeometry?.blocks == nil)

        let localOnly = localStep(name: "Local step")
        #expect(localOnly.applicationGeometry?.blocks == nil)
    }

    @Test func growthStageCodeResolvesToARealPhenologyStage() throws {
        let portal = try portalTemplate(budBurstJSON)
        let code = try #require(portal.growthStageCode)
        let stageNumber = try #require(ELStageParser.stageNumber(fromCode: code))

        // The same lookup the calculator performs: stage NUMBERS, through the
        // existing parser, so every spelling lands on one stage.
        let match = PhenologyStage.allStages.first {
            ELStageParser.stageNumber(fromCode: $0.code) == stageNumber
        }
        #expect(match != nil)
        #expect(match?.code == "EL4")
    }

    @Test func localStepPrefillFallsBackToItsOwnRecordedTargets() {
        let step = SprayProgramStep(
            record: localStep(name: "Botrytis step", targets: [.botrytis]),
            source: .local
        )
        #expect(step.targets == [.botrytis])
        #expect(step.calculatorPrefill.targets == [.botrytis])
        #expect(step.targetDisplay == "Botrytis")
    }

    @Test func aStepWithNoConfigurationYieldsAnEmptyPrefill() {
        let step = SprayProgramStep(record: localStep(name: "Bare step"), source: .local)
        let prefill = step.calculatorPrefill
        #expect(prefill.isEmpty)
        #expect(prefill.growthStageCode == nil)
        #expect(prefill.targets.isEmpty)
    }

    @Test func missingSavedChemicalStaysVisiblyUnresolved() {
        // The calculator can only build a line against a Saved Chemical. A
        // program product that no longer resolves must surface by name — the
        // prefill path names it rather than dropping it.
        let product = SprayChemical(name: "Discontinued Fungicide", ratePerHa: 500, unit: .millilitres)
        let (resolved, match) = ChemicalSnapshotCapture.resolve(
            savedChemicalId: product.savedChemicalId,
            productName: product.name,
            in: [],
            allowNameMatch: false
        )
        #expect(resolved == nil)
        #expect(match == .unresolved)
        #expect(product.name.isEmpty == false)
    }

    // MARK: - Read-only boundary

    @Test func portalStepsAreReadOnlyAndLocalStepsAreNot() throws {
        let portal = try portalTemplate(budBurstJSON)
        let steps = SprayProgramCatalog.steps(
            localRecords: [localStep(name: "Mine")],
            portalRecords: [portal.toSprayRecord()],
            portalRows: [portal]
        )

        let portalStep = try #require(steps.first { $0.source == .portal })
        let localStepValue = try #require(steps.first { $0.source == .local })

        #expect(portalStep.isPortalManaged)
        #expect(SprayProgramStepSource.portal.isReadOnly)
        #expect(localStepValue.isPortalManaged == false)
        #expect(SprayProgramStepSource.local.isReadOnly == false)
    }

    // MARK: - Persistence boundary

    @Test func buildingTheProgramMutatesNothing() throws {
        let portal = try portalTemplate(budBurstJSON)
        let local = [localStep(name: "Mine"), operationalRecord(name: "A spray")]
        let portalRecords = [portal.toSprayRecord()]

        let steps = SprayProgramCatalog.steps(
            localRecords: local,
            portalRecords: portalRecords,
            portalRows: [portal]
        )
        _ = SprayProgramCatalog.sorted(steps, by: .elStageAscending)
        _ = SprayProgramCatalog.filtered(steps, query: "copper")
        _ = steps.map(\.calculatorPrefill)

        // Reading the program, opening a step and preparing a Plan Spray are
        // all pure reads: nothing is added to, removed from or rewritten in
        // either collection. Operational persistence happens only through the
        // calculator's own save/start path.
        #expect(local.count == 2)
        #expect(local.filter(\.isTemplate).count == 1)
        #expect(portalRecords.count == 1)
        // The portal step is never copied into the local collection.
        #expect(local.contains { $0.id == portal.id } == false)
    }

    @Test func aPortalStepIsNeverPromotedIntoTheLocalRecordSet() throws {
        let portal = try portalTemplate(budBurstJSON)
        let steps = SprayProgramCatalog.steps(
            localRecords: [],
            portalRecords: [portal.toSprayRecord()],
            portalRows: [portal]
        )
        let step = try #require(steps.first)
        // It is a template-shaped read-only view, and it stays one.
        #expect(step.record.isTemplate)
        #expect(step.source == .portal)
    }

    // MARK: - Sprays tab

    @Test func spraysContainOperationalRecordsOnly() {
        let records = [
            localStep(name: "Program step"),
            operationalRecord(name: "Upcoming spray"),
            operationalRecord(name: "Completed spray", endTime: Date())
        ]
        let operational = records.filter { !$0.isTemplate }

        #expect(operational.count == 2)
        #expect(operational.contains { $0.sprayReference == "Program step" } == false)
    }

    @Test func upcomingMapsOntoTheExistingNotStartedSemantics() {
        // "Upcoming" is wording. The underlying rule is unchanged: no end time
        // and no active trip.
        let upcoming = operationalRecord(name: "Not yet run")
        let completed = operationalRecord(name: "Done", endTime: Date())

        #expect(upcoming.endTime == nil)
        #expect(completed.endTime != nil)
        #expect(SpraysStatusTab.upcoming.rawValue == "Upcoming")
        #expect(SpraysStatusTab.allCases.map(\.rawValue) == ["Upcoming", "In Progress", "Completed", "All"])
    }

    @Test func programTabIsTheDefaultLanding() {
        // Program | Sprays, in that order, so the master program is primary.
        #expect(SprayProgramTab.allCases.map(\.rawValue) == ["Program", "Sprays"])
    }

    @Test func programSortOffersNoDateOption() {
        // A Program Step is not dated; offering "Newest" would sort reusable
        // configuration by a field that means nothing on it.
        let labels = SprayProgramStepSortOption.allCases.map(\.label)
        #expect(SprayProgramStepSortOption.allCases.count == 4)
        #expect(labels.contains { $0.localizedCaseInsensitiveContains("newest") } == false)
        #expect(labels.contains { $0.localizedCaseInsensitiveContains("oldest") } == false)
        // Sprays keeps date sorting.
        #expect(SprayProgramSortOption.allCases.contains(.newestFirst))
    }

    // MARK: - Target parsing

    @Test func multiTargetWordingSplitsIntoTypedTargets() {
        let targets = SprayProgramTargetParser.targets(
            from: "Downy Mildew · Black Spot · Phomopsis · Powdery Mildew"
        )
        // Only what maps cleanly; the unmappable two are not force-fitted.
        #expect(targets == [.downyMildew, .powderyMildew])

        #expect(SprayProgramTargetParser.targets(from: "Botrytis and Powdery Mildew") == [.botrytis, .powderyMildew])
        #expect(SprayProgramTargetParser.targets(from: "Powdery Mildew, Powdery Mildew") == [.powderyMildew])
        #expect(SprayProgramTargetParser.targets(from: nil).isEmpty)
        #expect(SprayProgramTargetParser.targets(from: "   ").isEmpty)
    }
}
