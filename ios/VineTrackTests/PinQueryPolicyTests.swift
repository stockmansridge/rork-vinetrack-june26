import Foundation
import Testing
@testable import VineTrack

struct PinQueryPolicyTests {
    private func pin(
        id: UUID = UUID(),
        name: String = "Test",
        mode: PinMode = .repairs,
        stage: String? = nil,
        completed: Bool = false,
        row: Int? = nil,
        segments: [ManualIssueSegment]? = nil,
        vineyardId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        blockId: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
        timestamp: Date = Date()
    ) -> VinePin {
        VinePin(
            id: id,
            vineyardId: vineyardId,
            latitude: -33.0,
            longitude: 149.0,
            heading: nil,
            buttonName: name,
            buttonColor: "blue",
            side: nil,
            mode: mode,
            paddockId: blockId,
            timestamp: timestamp,
            isCompleted: completed,
            growthStageCode: stage,
            pinRowNumber: row,
            rowSegments: segments
        )
    }

    @Test func defaultFilterExcludesELAndCompletedPins() {
        let filter = PinQueryFilter()
        #expect(filter.matches(pin()))
        #expect(!filter.matches(pin(stage: "EL12")))
        #expect(!filter.matches(pin(completed: true)))
    }

    @Test func categoryTapsSelectExactlyTheIntendedCategory() {
        #expect(PinQueryPolicy.categories(for: nil) == Set(PinCategoryFilter.allCases))
        #expect(PinQueryPolicy.categories(for: .repairs) == [.repairs])
        #expect(PinQueryPolicy.categories(for: .growth) == [.growth])
        #expect(PinQueryPolicy.categories(for: .manualIssues) == [.manualIssues])
        let repairs = PinQueryFilter(categories: PinQueryPolicy.categories(for: .repairs))
        #expect(repairs.matches(pin(mode: .repairs)))
        #expect(!repairs.matches(pin(mode: .growth)))
    }

    private func visiblePins(
        _ pins: [VinePin],
        type: PinTypeFilter,
        selectedELStageCodes: Set<String> = []
    ) -> [VinePin] {
        let authoritativeELPinIds = Set(pins.compactMap { $0.growthStageCode == nil ? nil : $0.id })
        let source = type.isCurrentELStage
            ? PinQueryPolicy.currentELSelection(from: pins, authoritativeELPinIds: authoritativeELPinIds).pins
            : pins
        let query = PinQueryPolicy.filter(
            for: type,
            selectedELStageCodes: selectedELStageCodes,
            completion: .both
        )
        return source.filter { pin in
            query.matches(pin, isELRecord: authoritativeELPinIds.contains(pin.id))
        }
    }

    private var mixedTypePins: [VinePin] {
        [
            pin(name: "Repair", mode: .repairs),
            pin(name: "Ordinary Growth", mode: .growth),
            pin(name: "Manual Issue", mode: .manualIssue),
            pin(name: "EL12", mode: .growth, stage: "EL12"),
            pin(name: "EL18", mode: .growth, stage: "EL18")
        ]
    }

    @Test func allToELStagesReturnsOnlyELPinsAndDeselectsAll() {
        let mode = PinTypeFilter.all.selection(afterTapping: .elStages)
        #expect(mode == .elStages)
        #expect(mode != .all)
        #expect(visiblePins(mixedTypePins, type: mode).map(\.buttonName) == ["EL12", "EL18"])
        #expect(PinQueryPolicy.filter(for: mode).categories.isEmpty)
    }

    @Test func allToCurrentELReturnsOnlyHighestELPinAndDeselectsAll() {
        let mode = PinTypeFilter.all.selection(afterTapping: .currentELStage)
        #expect(mode == .currentELStage)
        #expect(mode != .all)
        #expect(visiblePins(mixedTypePins, type: mode).map(\.buttonName) == ["EL18"])
        #expect(PinQueryPolicy.filter(for: mode).categories.isEmpty)
    }

    @Test func elStagesToAllRestoresOrdinaryDataset() {
        let mode = PinTypeFilter.elStages.selection(afterTapping: .all)
        #expect(mode == .all)
        #expect(visiblePins(mixedTypePins, type: mode).map(\.buttonName) == ["Repair", "Ordinary Growth", "Manual Issue"])
        #expect(!PinQueryPolicy.filter(for: mode).includesELStages)
    }

    @Test func currentELToRepairsReturnsOnlyRepairPins() {
        let mode = PinTypeFilter.currentELStage.selection(afterTapping: .repairs)
        #expect(mode == .repairs)
        #expect(!mode.includesELStages)
        #expect(visiblePins(mixedTypePins, type: mode).map(\.buttonName) == ["Repair"])
    }

    @Test func elStagesToCurrentELDisablesAllOtherTypes() {
        let mode = PinTypeFilter.elStages.selection(afterTapping: .currentELStage)
        #expect(mode == .currentELStage)
        #expect(mode != .all && mode != .elStages)
        #expect(visiblePins(mixedTypePins, type: mode).map(\.buttonName) == ["EL18"])
    }

    @Test func filterSheetIndividualELStageActivatesELModeAndNarrowsStage() {
        let mode = PinTypeFilter.repairs.selection(afterTapping: .elStages)
        let query = PinQueryPolicy.filter(for: mode, selectedELStageCodes: ["EL18"], completion: .both)
        #expect(mode == .elStages)
        #expect(mode != .all && mode != .currentELStage)
        #expect(query.categories.isEmpty)
        #expect(visiblePins(mixedTypePins, type: mode, selectedELStageCodes: ["EL18"]).map(\.buttonName) == ["EL18"])
    }

    @Test func everyMainChipProducesExactlyOneTopLevelSelection() {
        for current in PinTypeFilter.allCases {
            for requested in PinTypeFilter.allCases {
                let selected = current.selection(afterTapping: requested)
                #expect(PinTypeFilter.allCases.filter { $0 == selected }.count == 1)
            }
        }
        #expect(PinTypeFilter.elStages.selection(afterTapping: .elStages) == .all)
        #expect(PinTypeFilter.currentELStage.selection(afterTapping: .currentELStage) == .all)
    }

    @Test func selectedELStagesMatchExactRecognizedIdentity() {
        let filter = PinQueryFilter(
            categories: PinQueryPolicy.categories(for: .growth),
            includesELStages: true,
            selectedELStageCodes: ["EL12"]
        )
        #expect(filter.matches(pin(mode: .growth, stage: "EL12"), isELRecord: true))
        #expect(!filter.matches(pin(mode: .growth, stage: "EL13"), isELRecord: true))
        #expect(!filter.matches(pin(mode: .growth, stage: "unknown"), isELRecord: true))
        #expect(filter.matches(pin(mode: .growth, stage: nil), isELRecord: false))
    }

    @Test func unknownELIdentityNeverBecomesOrdinaryGrowth() {
        let unknown = pin(mode: .growth, stage: "unknown")
        let growthOnly = PinQueryFilter(categories: [.growth])
        #expect(!growthOnly.matches(unknown, isELRecord: true))
        let allEL = PinQueryFilter(categories: [.growth], includesELStages: true)
        #expect(allEL.matches(unknown, isELRecord: true))
        let exactEL = PinQueryFilter(categories: [.growth], includesELStages: true, selectedELStageCodes: ["EL12"])
        #expect(!exactEL.matches(unknown, isELRecord: true))
    }

    @Test func unknownELIdentityStillHonoursEveryCompletionSelection() {
        let open = pin(mode: .growth, stage: "unknown")
        let done = pin(mode: .growth, stage: "unknown", completed: true)
        let notDone = PinQueryFilter(includesELStages: true, completion: .notDone)
        let completed = PinQueryFilter(includesELStages: true, completion: .done)
        let both = PinQueryFilter(includesELStages: true, completion: .both)
        #expect(notDone.matches(open, isELRecord: true))
        #expect(!notDone.matches(done, isELRecord: true))
        #expect(!completed.matches(open, isELRecord: true))
        #expect(completed.matches(done, isELRecord: true))
        #expect(both.matches(open, isELRecord: true))
        #expect(both.matches(done, isELRecord: true))
    }

    @Test func currentELSelectsTheOnlyStageInABlock() {
        let stage = pin(name: "EL 18", mode: .growth, stage: "EL18")
        let result = PinQueryPolicy.currentELSelection(from: [stage], authoritativeELPinIds: [stage.id])
        #expect(result.pins.map(\.id) == [stage.id])
        #expect(result.stageByBlockId[stage.paddockId!] == 18)
    }

    @Test func currentELSelectsOnlyTheHighestNumericStage() {
        let stages = [15, 18, 21].map { pin(name: "EL \($0)", mode: .growth, stage: "EL\($0)") }
        let result = PinQueryPolicy.currentELSelection(from: stages, authoritativeELPinIds: Set(stages.map(\.id)))
        #expect(result.pins.map(\.growthStageCode) == ["EL21"])
    }

    @Test func currentELPreservesEveryPinTiedAtTheMaximum() {
        let stages = [15, 21, 21].map { pin(name: "EL \($0)", mode: .growth, stage: "EL\($0)") }
        let result = PinQueryPolicy.currentELSelection(from: stages, authoritativeELPinIds: Set(stages.map(\.id)))
        #expect(result.pins.map(\.id) == Array(stages.suffix(2)).map(\.id))
    }

    @Test func currentELUsesNumericOrdering() {
        let nine = pin(name: "EL 9", mode: .growth, stage: "EL9")
        let ten = pin(name: "EL 10", mode: .growth, stage: "EL10")
        let result = PinQueryPolicy.currentELSelection(from: [nine, ten], authoritativeELPinIds: [nine.id, ten.id])
        #expect(result.pins.map(\.id) == [ten.id])
        #expect(result.stageByBlockId[nine.paddockId!] == 10)
    }

    @Test func currentELCalculatesEachBlockIndependently() {
        let blockA = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let blockB = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let stages = [
            pin(name: "A18", mode: .growth, stage: "EL18", blockId: blockA),
            pin(name: "A21", mode: .growth, stage: "EL21", blockId: blockA),
            pin(name: "B25", mode: .growth, stage: "EL25", blockId: blockB),
            pin(name: "B27", mode: .growth, stage: "EL27", blockId: blockB)
        ]
        let result = PinQueryPolicy.currentELSelection(from: stages, authoritativeELPinIds: Set(stages.map(\.id)))
        #expect(result.pins.map(\.buttonName) == ["A21", "B27"])
        #expect(result.stageByBlockId == [blockA: 21, blockB: 27])
    }

    @Test func currentELIgnoresMalformedUnlinkedAndNonGrowthPins() {
        let valid = pin(name: "valid", mode: .growth, stage: "EL18")
        let malformed = pin(name: "malformed", mode: .growth, stage: "ELbanana")
        let missing = pin(name: "missing", mode: .growth, stage: nil)
        let unlinked = pin(name: "unlinked", mode: .growth, stage: "EL21", blockId: nil)
        let ordinary = pin(name: "ordinary", mode: .repairs, stage: "EL21")
        let pins = [valid, malformed, missing, unlinked, ordinary]
        let result = PinQueryPolicy.currentELSelection(from: pins, authoritativeELPinIds: Set(pins.map(\.id)))
        #expect(result.pins.map(\.id) == [valid.id])
    }

    @Test func currentELReturnsNothingForBlocksWithoutValidELPins() {
        let ordinary = pin(name: "Canopy check", mode: .growth, stage: nil)
        let result = PinQueryPolicy.currentELSelection(from: [ordinary], authoritativeELPinIds: [])
        #expect(result.pins.isEmpty)
        #expect(result.stageByBlockId.isEmpty)
    }

    @Test func currentELMapLabelsAreUniquePerBlockAndDisappearWhenDisabled() {
        let stages = [15, 21, 21].map { pin(name: "EL \($0)", mode: .growth, stage: "EL\($0)") }
        let result = PinQueryPolicy.currentELSelection(from: stages, authoritativeELPinIds: Set(stages.map(\.id)))
        #expect(result.pins.count == 2)
        #expect(PinQueryPolicy.currentELBlockLabels(selection: result, isActive: true) == [stages[0].paddockId!: "EL 21"])
        #expect(PinQueryPolicy.currentELBlockLabels(selection: result, isActive: false).isEmpty)
    }

    @Test func previousVintageEL43CannotSuppressCurrentVintageEL12() {
        let currentWindow = SeasonWindow.window(vintage: 2026, seasonStartMonth: 7, seasonStartDay: 1, timeZone: .gmt)
        let previous = pin(id: UUID(), name: "previous-43", mode: .growth, stage: "EL43", timestamp: currentWindow.start.addingTimeInterval(-86_400))
        let current10 = pin(id: UUID(), name: "current-10", mode: .growth, stage: "EL10", timestamp: currentWindow.start.addingTimeInterval(86_400))
        let current12 = pin(id: UUID(), name: "current-12", mode: .growth, stage: "EL12", timestamp: currentWindow.start.addingTimeInterval(172_800))
        let pins = [previous, current10, current12]
        let result = PinQueryPolicy.currentELSelection(from: pins, authoritativeELPinIds: Set(pins.map(\.id)), seasonWindow: currentWindow)
        #expect(result.pins.map(\.id) == [current12.id])
        #expect(result.stageByBlockId[current12.paddockId!] == 12)
    }

    @Test func historicalVintageSelectionCalculatesWithinThatVintage() {
        let historicalWindow = SeasonWindow.window(vintage: 2025, seasonStartMonth: 7, seasonStartDay: 1, timeZone: .gmt)
        let historical = pin(id: UUID(), name: "historical-43", mode: .growth, stage: "EL43", timestamp: historicalWindow.start.addingTimeInterval(86_400))
        let current = pin(id: UUID(), name: "current-12", mode: .growth, stage: "EL12", timestamp: historicalWindow.endExclusive.addingTimeInterval(86_400))
        let pins = [historical, current]
        let result = PinQueryPolicy.currentELSelection(from: pins, authoritativeELPinIds: Set(pins.map(\.id)), seasonWindow: historicalWindow)
        #expect(result.pins.map(\.id) == [historical.id])
        #expect(result.stageByBlockId[historical.paddockId!] == 43)
    }

    @Test func allVintagesUsesConfiguredCurrentWindowForCurrentEL() {
        let configuredCurrentWindow = SeasonWindow.window(vintage: 2026, seasonStartMonth: 7, seasonStartDay: 1, timeZone: .gmt)
        let previous = pin(id: UUID(), name: "previous-43", mode: .growth, stage: "EL43", timestamp: configuredCurrentWindow.start.addingTimeInterval(-86_400))
        let current = pin(id: UUID(), name: "current-12", mode: .growth, stage: "EL12", timestamp: configuredCurrentWindow.start.addingTimeInterval(86_400))
        let result = PinQueryPolicy.currentELSelection(from: [previous, current], authoritativeELPinIds: [previous.id, current.id], seasonWindow: configuredCurrentWindow)
        #expect(result.pins.map(\.id) == [current.id])
    }

    @Test func canonicalEL21OverridesStalePinEL18() {
        let stale = pin(id: UUID(), mode: .growth, stage: "EL18")
        let result = PinQueryPolicy.currentELSelection(from: [stale], authoritativeELPinIds: [stale.id], authoritativeStageCodeByPinId: [stale.id: "EL21"])
        #expect(result.pins.first?.growthStageCode == "EL21")
        #expect(result.stageByBlockId[stale.paddockId!] == 21)
    }

    @Test func canonicalBlockBOverridesStalePinBlockA() {
        let blockA = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let blockB = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let stale = pin(id: UUID(), mode: .growth, stage: "EL21", blockId: blockA)
        let result = PinQueryPolicy.currentELSelection(from: [stale], authoritativeELPinIds: [stale.id], authoritativeBlockIdByPinId: [stale.id: blockB])
        #expect(result.pins.first?.paddockId == blockB)
        #expect(result.stageByBlockId == [blockB: 21])
    }

    @Test func canonicalEL18CorrectionCannotBeatCanonicalEL21() {
        let stale27 = pin(id: UUID(), name: "stale-27", mode: .growth, stage: "EL27")
        let actual21 = pin(id: UUID(), name: "actual-21", mode: .growth, stage: "EL21")
        let pins = [stale27, actual21]
        let result = PinQueryPolicy.currentELSelection(from: pins, authoritativeELPinIds: Set(pins.map(\.id)), authoritativeStageCodeByPinId: [stale27.id: "EL18", actual21.id: "EL21"])
        #expect(result.pins.map(\.id) == [actual21.id])
        #expect(result.stageByBlockId[actual21.paddockId!] == 21)
    }

    @Test func tiedCanonicalMaximumRetainsBothPinsAndOneBlockLabel() {
        let staleBlock = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let canonicalBlock = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let first = pin(id: UUID(), mode: .growth, stage: "EL18", blockId: staleBlock)
        let second = pin(id: UUID(), mode: .growth, stage: "EL21", blockId: canonicalBlock)
        let pins = [first, second]
        let result = PinQueryPolicy.currentELSelection(
            from: pins,
            authoritativeELPinIds: Set(pins.map(\.id)),
            authoritativeStageCodeByPinId: [first.id: "EL21", second.id: "EL21"],
            authoritativeBlockIdByPinId: [first.id: canonicalBlock, second.id: canonicalBlock]
        )
        #expect(result.pins.map(\.id) == [first.id, second.id])
        #expect(result.pins.allSatisfy { $0.paddockId == canonicalBlock && $0.growthStageCode == "EL21" })
        #expect(PinQueryPolicy.currentELBlockLabels(selection: result, isActive: true) == [canonicalBlock: "EL 21"])
    }

    @Test func authoritativeELNamesStayOutOfIssueGrowthOptionsAndSelectionsAreCleaned() {
        let elId = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let pins = [
            pin(name: "Broken post", mode: .repairs),
            pin(name: "Canopy check", mode: .growth),
            pin(id: elId, name: "E-L 12", mode: .growth)
        ]
        let names = PinQueryPolicy.ordinaryFilterNames(pins, authoritativeELPinIds: [elId])
        #expect(names == ["Broken post", "Canopy check"])
        #expect(PinQueryPolicy.cleanedNameSelection(["Broken post", "E-L 12"], availableNames: names) == ["Broken post"])
    }

    @Test func headingQualificationDoesNotDependOnRowAvailability() {
        #expect(PinQueryPolicy.qualifiedHeading(45, isQualified: true) == 45)
        #expect(PinQueryPolicy.qualifiedHeading(45, isQualified: false) == nil)
        #expect(PinQueryPolicy.qualifiedHeading(.nan, isQualified: true) == nil)
        let estimated = PinQueryPolicy.TravelContext(
            vineyardId: UUID(),
            blockId: UUID(),
            row: 13.5,
            heading: 45,
            isEstimated: true
        )
        #expect(estimated.isEstimated)
        #expect(estimated.heading == 45)
    }

    @Test func usableRowUsesAttachedOrRecordedSegmentsButNeverLegacyRow() {
        #expect(PinQueryPolicy.usableRow(pin(row: 8)) == 8)
        #expect(PinQueryPolicy.usableRow(pin(segments: [ManualIssueSegment(row: 4, segment: 2)])) == 4)
        let legacy = VinePin(latitude: 0, longitude: 0, heading: nil, buttonName: "Legacy", buttonColor: "blue", side: nil, mode: .repairs, rowNumber: 22)
        #expect(PinQueryPolicy.usableRow(legacy) == nil)
    }

    @Test func travelContextRequiresFreshMatchingVineyardAndSeparatelyQualifiedHeading() {
        let vineyard = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let block = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let now = Date(timeIntervalSince1970: 100)
        func context(vineyardId: UUID = vineyard, observedAt: Date = Date(timeIntervalSince1970: 95), headingQualified: Bool = true) -> PinQueryPolicy.TravelContext? {
            PinQueryPolicy.qualifiedTravelContext(
                selectedVineyardId: vineyard,
                contextVineyardId: vineyardId,
                blockId: block,
                row: 12.5,
                isRowQualified: true,
                rowConfirmedAt: observedAt,
                locationObservedAt: observedAt,
                heading: 90,
                isHeadingQualified: headingQualified,
                now: now
            )
        }
        #expect(context(vineyardId: other) == nil)
        #expect(context(observedAt: Date(timeIntervalSince1970: 80)) == nil)
        #expect(context(headingQualified: false)?.heading == nil)
        #expect(context()?.heading == 90)
    }

    @Test func nearestRowSortUsesDistanceWithinCurrentBlock() {
        let vineyard = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let block = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let rows = [pin(row: 14, vineyardId: vineyard, blockId: block), pin(row: 11, vineyardId: vineyard, blockId: block), pin(row: 13, vineyardId: vineyard, blockId: block)]
        let ordered = PinQueryPolicy.nearestRowOrdered(rows, currentRow: 12.5, currentVineyardId: vineyard, currentBlockId: block, blockNames: [block: "A"])
        #expect(ordered.compactMap(PinQueryPolicy.usableRow) == [13, 14, 11])
    }

    @Test func nearestRowNeverComparesRowsAcrossBlocks() {
        let vineyard = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let current = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let rows = [pin(row: 12, vineyardId: vineyard, blockId: other), pin(row: 30, vineyardId: vineyard, blockId: current), pin(row: 2, vineyardId: vineyard, blockId: other)]
        let ordered = PinQueryPolicy.nearestRowOrdered(rows, currentRow: 12.5, currentVineyardId: vineyard, currentBlockId: current, blockNames: [current: "B", other: "A"])
        #expect(ordered.map(\.paddockId) == [current, other, other])
        #expect(ordered.compactMap(PinQueryPolicy.usableRow) == [30, 2, 12])
    }

    @Test @MainActor func backgroundNotesFlushPreservesNewerUnrelatedFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let repository = PinRepository(persistence: persistence)
        let original = pin(completed: false)
        var newer = original
        newer.isCompleted = true
        newer.photoPath = "newer/photo.jpg"
        try persistence.saveOrThrow([newer], key: PinRepository.storageKey)

        _ = try repository.updateNotesDurably(pinId: original.id, vineyardId: original.vineyardId, notes: "background draft")

        let saved = repository.loadAll().first
        #expect(saved?.notes == "background draft")
        #expect(saved?.isCompleted == true)
        #expect(saved?.photoPath == "newer/photo.jpg")
    }

    @Test @MainActor func failedNotesFlushRetainsDraftAcrossStoreRecreationUntilRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let original = pin()
        try persistence.saveOrThrow([original], key: PinRepository.storageKey)
        let store = MigratedDataStore(persistence: persistence)
        persistence.durableSaveFailureForTesting = { key in
            key == PinRepository.storageKey
                ? NSError(domain: "PinNotesDraftTests", code: 1)
                : nil
        }

        #expect(throws: (any Error).self) {
            try store.updatePinNotesDurably(pinId: original.id, vineyardId: original.vineyardId, notes: "retained failure")
        }
        let recreated = MigratedDataStore(persistence: persistence)
        #expect(recreated.pendingPinNotesDraft(pinId: original.id, vineyardId: original.vineyardId)?.notes == "retained failure")
        #expect(PinRepository(persistence: persistence).loadAll().first?.notes == nil)

        persistence.durableSaveFailureForTesting = nil
        _ = try recreated.updatePinNotesDurably(pinId: original.id, vineyardId: original.vineyardId, notes: "retained failure")
        #expect(recreated.pendingPinNotesDraft(pinId: original.id, vineyardId: original.vineyardId) == nil)
        #expect(PinRepository(persistence: persistence).loadAll().first?.notes == "retained failure")
    }

    @Test @MainActor func successfulNotesWritePublishesSyncBeforeFailedCleanupAndRetryClearsRecovery() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        var original = pin(completed: true, row: 27)
        original.photoPath = "preserved/photo.jpg"
        try persistence.saveOrThrow([original], key: PinRepository.storageKey)

        let store = MigratedDataStore(persistence: persistence)
        store.selectedVineyardId = original.vineyardId
        store.pins = [original]
        var syncNotifications: [UUID] = []
        store.onPinChanged = { syncNotifications.append($0) }
        var draftWrites = 0
        persistence.durableSaveFailureForTesting = { key in
            guard key == PinNotesDraftStore.storageKey else { return nil }
            draftWrites += 1
            return draftWrites == 2
                ? NSError(domain: "PinNotesCleanupTests", code: 1)
                : nil
        }

        let firstOutcome = try store.updatePinNotesDurably(
            pinId: original.id,
            vineyardId: original.vineyardId,
            notes: "saved before cleanup"
        )
        #expect(firstOutcome == .savedCleanupPending)
        #expect(syncNotifications == [original.id])
        #expect(store.pins.first?.notes == "saved before cleanup")
        #expect(store.pendingPinNotesDraft(pinId: original.id, vineyardId: original.vineyardId)?.notes == "saved before cleanup")
        let savedBeforeRetry = try #require(PinRepository(persistence: persistence).loadAll().first)
        #expect(savedBeforeRetry.notes == "saved before cleanup")

        persistence.durableSaveFailureForTesting = nil
        let reopened = MigratedDataStore(persistence: persistence)
        reopened.selectedVineyardId = original.vineyardId
        reopened.pins = [savedBeforeRetry]
        let retryOutcome = try reopened.updatePinNotesDurably(
            pinId: original.id,
            vineyardId: original.vineyardId,
            notes: "saved before cleanup"
        )
        #expect(retryOutcome == .saved)
        #expect(reopened.pendingPinNotesDraft(pinId: original.id, vineyardId: original.vineyardId) == nil)
        #expect(PinRepository(persistence: persistence).loadAll().first == savedBeforeRetry)
    }

    @Test @MainActor func vineyardSwitchNotesFlushUsesOriginalIdentityAndReportsFailure() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceStore(directory: directory)
        let repository = PinRepository(persistence: persistence)
        let original = pin()
        try persistence.saveOrThrow([original], key: PinRepository.storageKey)
        let otherVineyard = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!

        #expect(throws: PinRepository.CacheReadError.self) {
            _ = try repository.updateNotesDurably(pinId: original.id, vineyardId: otherVineyard, notes: "wrong")
        }
        _ = try repository.updateNotesDurably(pinId: original.id, vineyardId: original.vineyardId, notes: "switch draft")
        #expect(repository.loadAll().first?.notes == "switch draft")
    }
}
