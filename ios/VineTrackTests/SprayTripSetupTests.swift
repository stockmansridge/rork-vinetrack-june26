import Foundation
import Testing
@testable import VineTrack

/// Start Trip, and the Resume Program picker behind it.
///
/// Two claims worth defending:
///
///  1. Start Trip offers exactly two doors, and "start from the program" is one
///     door rather than two that an operator has to choose between;
///  2. the Resume picker is the vineyard's PROGRAM, in phenological order —
///     not a list of sprays that already happened, and not a list sorted by
///     which sprayer was used.
struct SprayTripSetupTests {

    // MARK: - Fixtures

    private static let vineyardId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private func localStep(
        _ name: String,
        operation: OperationType = .foliarSpray
    ) -> SprayProgramStep {
        SprayProgramStep(
            record: SprayRecord(
                id: UUID(),
                vineyardId: Self.vineyardId,
                sprayReference: name,
                tanks: [SprayTank(chemicals: [
                    SprayChemical(name: "Wettable Sulphur", ratePerHa: 3_000, unit: .grams, rateBasis: .wholeBlockArea)
                ])],
                isTemplate: true,
                operationType: operation
            ),
            source: .local
        )
    }

    private func portalStep(
        _ name: String,
        code: String?,
        id: UUID = UUID(),
        operation: OperationType = .foliarSpray
    ) -> SprayProgramStep {
        SprayProgramStep(
            record: SprayRecord(
                id: id,
                vineyardId: Self.vineyardId,
                sprayReference: name,
                tanks: [],
                isTemplate: true,
                operationType: operation
            ),
            source: .portal,
            growthStageCode: code
        )
    }

    // MARK: - 1. Start Trip has exactly two options

    @Test("Start Trip offers exactly two choices, Resume first and One-off second")
    func startTripHasTwoOptionsInOrder() {
        let options = SprayTripSetupOption.presentationOrder

        #expect(options.count == 2)
        #expect(options[0] == .resumeProgram)
        #expect(options[1] == .oneOffSpray)
        #expect(options[0].title == "Resume a Spray Program")
        #expect(options[1].title == "One-off Spray")

        // No third case can be added without this failing.
        #expect(Set(SprayTripSetupOption.allCases) == Set(options))
    }

    @Test("Plan from Program is not a Start Trip option, but survives as Program wording")
    func planFromProgramIsAbsentFromStartTrip() {
        let titles = SprayTripSetupOption.presentationOrder.map(\.title)
        #expect(!titles.contains(SprayProgramTerminology.planFromProgram))
        #expect(!titles.contains { $0.localizedCaseInsensitiveContains("Plan from Program") })

        // Program → Program Step → Plan Spray still exists elsewhere; only the
        // Start Trip entry point lost its separate card.
        #expect(SprayProgramTerminology.planFromProgram == "Plan from Program")
    }

    @Test("Resume states how much program there is to resume")
    func resumeSubtitleReflectsProgramSize() {
        #expect(SprayTripSetupOption.resumeProgram.subtitle(programStepCount: 0)
            .localizedCaseInsensitiveContains("No Program Steps yet"))
        #expect(SprayTripSetupOption.resumeProgram.subtitle(programStepCount: 7)
            .contains("7"))
    }

    // MARK: - 2. Numeric E-L ordering

    @Test("Program Steps sort numerically by E-L, so EL7 precedes EL9 precedes EL12")
    func stagesSortNumerically() {
        let steps = [
            portalStep("Bunch Closing", code: "EL12"),
            portalStep("Budburst", code: "E-L 4"),
            portalStep("Two Leaves", code: "EL9"),
            portalStep("First Leaf", code: "EL7"),
            portalStep("Winter", code: "EL1")
        ]
        let sections = SprayProgramCatalog.groupedByStage(steps)
        #expect(sections.map(\.stage) == [1, 4, 7, 9, 12])

        // The failure this guards: alphabetically, "EL12" < "EL7".
        let stages = sections.compactMap(\.stage)
        let el7 = try? #require(stages.firstIndex(of: 7))
        let el12 = try? #require(stages.firstIndex(of: 12))
        #expect((el7 ?? 0) < (el12 ?? 0))
    }

    @Test("A step with no resolvable stage sorts into a final section")
    func unstagedStepsSortLast() {
        let steps = [
            localStep("General Clean-Up"),
            portalStep("Bunch Closing", code: "EL12"),
            portalStep("Winter", code: "EL1")
        ]
        let sections = SprayProgramCatalog.groupedByStage(steps)

        #expect(sections.map(\.stage) == [1, 12, nil])
        #expect(sections.last?.title == "E-L Stage Not Set")
        #expect(sections.last?.steps.map(\.name) == ["General Clean-Up"])
    }

    @Test("Steps at the same stage are ordered by name")
    func sameStageOrdersByName() {
        let steps = [
            portalStep("Zinc Foliar", code: "EL12"),
            portalStep("Anti-Botrytis", code: "EL12"),
            portalStep("Mildew Cover", code: "EL12")
        ]
        let sections = SprayProgramCatalog.groupedByStage(steps)
        #expect(sections.count == 1)
        #expect(sections[0].steps.map(\.name) == ["Anti-Botrytis", "Mildew Cover", "Zinc Foliar"])
    }

    @Test("A legacy local step falls back to the existing text parser, never an invented stage")
    func legacyLocalStepsUseTheExistingFallback() {
        let steps = [
            localStep("EL12 Pre-Flowering"),
            localStep("Dormant Oil"),
            portalStep("Budburst", code: "EL4")
        ]
        let sections = SprayProgramCatalog.groupedByStage(steps)

        #expect(sections.map(\.stage) == [4, 12, nil])
        // "Dormant Oil" names no stage, and none is guessed for it.
        #expect(sections.last?.steps.map(\.name) == ["Dormant Oil"])
    }

    // MARK: - 3. Section headings

    @Test("Headings are the E-L number plus VineTrack's existing description")
    func headingsUseCanonicalDescriptions() {
        let sections = SprayProgramCatalog.groupedByStage([
            portalStep("Winter Clean", code: "EL1"),
            portalStep("Budburst", code: "EL4"),
            portalStep("Two Leaves", code: "EL9")
        ])

        #expect(sections[0].title == "E-L Stage 1 / Winter bud")
        #expect(sections[1].title == "E-L Stage 4 / Budburst; leaf tips visible")
        #expect(sections[2].title == "E-L Stage 9 / 2 to 3 leaves separated; shoots 2-4 cm long")

        // The descriptions come from the phenology table, not a second copy.
        for section in sections {
            #expect(section.stageDescription == SprayProgramCatalog.stageDescription(for: section.stage))
        }
        // A bare "EL9" is never the heading.
        #expect(!sections.contains { $0.title == "EL9" })
    }

    @Test("A stage with no description in the table degrades to the number alone")
    func unknownStageNumberStillReadsHonestly() {
        let sections = SprayProgramCatalog.groupedByStage([portalStep("Odd", code: "EL99")])
        #expect(sections.first?.title == "E-L Stage 99")
    }

    // MARK: - 4. Not grouped by application method

    @Test("Sections are stages, never application methods")
    func notGroupedByApplicationMethod() {
        let steps = [
            portalStep("Banded Herbicide", code: "EL4", operation: .bandedSpray),
            portalStep("Budburst Cover", code: "EL4", operation: .foliarSpray),
            portalStep("Mildew Cover", code: "EL12", operation: .foliarSpray)
        ]
        let sections = SprayProgramCatalog.groupedByStage(steps)

        // Two stages, not two methods — and EL4's two different methods stay
        // together because they happen at the same point in the season.
        #expect(sections.count == 2)
        #expect(sections[0].steps.count == 2)

        let methodNames = Set(OperationType.allCases.map(\.rawValue))
        for section in sections {
            #expect(!methodNames.contains(section.title))
            #expect(section.title.hasPrefix("E-L Stage"))
        }
    }

    // MARK: - 5. Sources, dedup and offline

    @Test("Both local and portal Program Steps appear, deduplicated by id")
    func bothSourcesAppearAndDeduplicate() {
        let sharedId = UUID()
        let local = SprayRecord(
            id: sharedId,
            vineyardId: Self.vineyardId,
            sprayReference: "Local Wins",
            tanks: [],
            isTemplate: true
        )
        let portalDuplicate = SprayRecord(
            id: sharedId,
            vineyardId: Self.vineyardId,
            sprayReference: "Portal Copy",
            tanks: [],
            isTemplate: true
        )
        let portalOnly = SprayRecord(
            id: UUID(),
            vineyardId: Self.vineyardId,
            sprayReference: "Portal Only",
            tanks: [],
            isTemplate: true
        )

        let steps = SprayProgramCatalog.steps(
            localRecords: [local],
            portalRecords: [portalDuplicate, portalOnly]
        )

        #expect(steps.count == 2)
        #expect(steps.contains { $0.name == "Local Wins" && $0.source == .local })
        #expect(steps.contains { $0.name == "Portal Only" && $0.source == .portal })
        // A record the device owns is never shadowed by a portal copy.
        #expect(!steps.contains { $0.name == "Portal Copy" })
    }

    @Test("Completed spray records are not Program Steps and cannot reach the picker")
    func completedRecordsAreExcluded() {
        let completed = SprayRecord(
            id: UUID(),
            vineyardId: Self.vineyardId,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_007_200),
            sprayReference: "Bunch Closing 12 Nov",
            tanks: [],
            isTemplate: false
        )
        let programStep = SprayRecord(
            id: UUID(),
            vineyardId: Self.vineyardId,
            sprayReference: "Bunch Closing",
            tanks: [],
            isTemplate: true
        )

        let steps = SprayProgramCatalog.steps(
            localRecords: [completed, programStep],
            portalRecords: []
        )
        #expect(steps.map(\.name) == ["Bunch Closing"])
    }

    @Test("The cached portal Program still groups when the device is offline")
    func cachedPortalProgramWorksOffline() {
        // `templateRecords` is the offline cache the service hydrates from disk;
        // the catalog reads it exactly as it reads a fresh sync.
        let cached = [
            SprayRecord(id: UUID(), vineyardId: Self.vineyardId, sprayReference: "Cached EL7",
                        tanks: [], isTemplate: true),
            SprayRecord(id: UUID(), vineyardId: Self.vineyardId, sprayReference: "Cached EL12",
                        tanks: [], isTemplate: true)
        ]
        let rows = [
            BackendSprayJobTemplate(id: cached[0].id, vineyardId: Self.vineyardId,
                                    name: "Cached EL7", growthStageCode: "EL7"),
            BackendSprayJobTemplate(id: cached[1].id, vineyardId: Self.vineyardId,
                                    name: "Cached EL12", growthStageCode: "EL12")
        ]

        let sections = SprayProgramCatalog.groupedByStage(
            SprayProgramCatalog.steps(localRecords: [], portalRecords: cached, portalRows: rows)
        )
        #expect(sections.map(\.stage) == [7, 12])
    }

    @Test("Selecting a Program Step prefills without mutating the step")
    func selectionDoesNotMutateTheStep() {
        let step = portalStep("Bunch Closing", code: "EL12")
        let before = step

        let prefill = step.calculatorPrefill
        #expect(prefill.growthStageCode == "EL12")

        // The picker hands back a value; nothing writes through it.
        #expect(step == before)
        #expect(step.record.sprayReference == before.record.sprayReference)
    }

    @Test("Searching the picker still groups by stage")
    func filteringPreservesStageGrouping() {
        let steps = [
            portalStep("Mildew Cover", code: "EL12"),
            portalStep("Budburst Cover", code: "EL4"),
            portalStep("Zinc Foliar", code: "EL9")
        ]
        let sections = SprayProgramCatalog.groupedByStage(
            SprayProgramCatalog.filtered(steps, query: "Cover")
        )
        #expect(sections.map(\.stage) == [4, 12])
        #expect(sections.flatMap { $0.steps }.count == 2)
    }
}
