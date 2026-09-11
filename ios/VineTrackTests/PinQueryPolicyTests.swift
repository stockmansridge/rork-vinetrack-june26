import Foundation
import Foundation
import Testing
@testable import VineTrack

struct PinQueryPolicyTests {
    private func pin(
        mode: PinMode = .repairs,
        stage: String? = nil,
        completed: Bool = false,
        row: Int? = nil,
        segments: [ManualIssueSegment]? = nil,
        vineyardId: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        blockId: UUID? = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    ) -> VinePin {
        VinePin(
            vineyardId: vineyardId,
            latitude: -33.0,
            longitude: 149.0,
            heading: nil,
            buttonName: "Test",
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
        #expect(!filter.matches(pin(mode: .growth, stage: "unknown"), isELRecord: false))
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
