import Foundation
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
        blockId: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
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
