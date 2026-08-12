import XCTest
@testable import VineTrack

/// Contract tests for the Grape Varieties settings catalogue browser
/// (Varieties | Clones | Rootstocks) — cross-variety browsing, search, and
/// block-allocation usage matching. Mirrors `CloneRootstockBrowseTest.kt`
/// on Android so both platforms stay pinned to one contract.
final class CloneRootstockBrowseTests: XCTestCase {

    private let vineyardId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private var catalog: [SharedGrapeCloneCatalogEntry] {
        [
            SharedGrapeCloneCatalogEntry(key: "shiraz:pt23", varietyKey: "shiraz", displayName: "PT23", cloneCode: "PT23", selectionSystem: "Australian selection", sourceCountry: "Australia", aliases: ["PT 23"], sourceReference: nil),
            SharedGrapeCloneCatalogEntry(key: "shiraz:fps_07", varietyKey: "shiraz", displayName: "FPS 07", cloneCode: "FPS 07", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: [], sourceReference: nil),
            SharedGrapeCloneCatalogEntry(key: "cabernet_sauvignon:fps_07", varietyKey: "cabernet_sauvignon", displayName: "FPS 07", cloneCode: "FPS 07", selectionSystem: "FPS (UC Davis)", sourceCountry: "USA", aliases: [], sourceReference: nil),
            SharedGrapeCloneCatalogEntry(key: "pinot_noir:entav_115", varietyKey: "pinot_noir", displayName: "ENTAV-INRA 115", cloneCode: "115", selectionSystem: "ENTAV-INRA", sourceCountry: "France", aliases: ["Dijon 115"], sourceReference: nil),
            SharedGrapeCloneCatalogEntry(key: "pinot_noir:retired", varietyKey: "pinot_noir", displayName: "Retired", cloneCode: "Retired", selectionSystem: nil, sourceCountry: nil, aliases: [], sourceReference: nil, isActive: false)
        ]
    }

    private var customClones: [VineyardGrapeCloneRow] {
        [
            VineyardGrapeCloneRow(
                id: UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!,
                vineyardId: vineyardId,
                cloneKey: "custom:\(vineyardId.uuidString.lowercased()):shiraz:old_block_selection",
                varietyKey: "shiraz",
                displayName: "Old Block Selection",
                isCustom: true,
                isActive: true,
                createdAt: nil,
                updatedAt: nil
            ),
            VineyardGrapeCloneRow(
                id: UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!,
                vineyardId: vineyardId,
                cloneKey: "custom:\(vineyardId.uuidString.lowercased()):pinot_noir:hillside",
                varietyKey: "pinot_noir",
                displayName: "Hillside",
                isCustom: true,
                isActive: true,
                createdAt: nil,
                updatedAt: nil
            ),
            VineyardGrapeCloneRow(
                id: UUID(uuidString: "00000000-0000-4000-8000-0000000000c3")!,
                vineyardId: vineyardId,
                cloneKey: "custom:\(vineyardId.uuidString.lowercased()):shiraz:archived_pick",
                varietyKey: "shiraz",
                displayName: "Archived Pick",
                isCustom: true,
                isActive: false,
                createdAt: nil,
                updatedAt: nil
            )
        ]
    }

    private var rootstocks: [SharedRootstockCatalogEntry] {
        [
            SharedRootstockCatalogEntry(key: "1103_paulsen", canonicalName: "1103 Paulsen", displayName: "1103 Paulsen", aliases: ["1103P", "Paulsen"], parentage: "V. berlandieri × V. rupestris", sourceReference: nil),
            SharedRootstockCatalogEntry(key: "ramsey", canonicalName: "Ramsey", displayName: "Ramsey", aliases: ["Salt Creek"], parentage: "V. champinii", sourceReference: nil)
        ]
    }

    private var customRootstocks: [VineyardRootstockRow] {
        [
            VineyardRootstockRow(
                id: UUID(uuidString: "00000000-0000-4000-8000-0000000000d1")!,
                vineyardId: vineyardId,
                rootstockKey: "custom:\(vineyardId.uuidString.lowercased()):trial_stock_7",
                displayName: "Trial Stock 7",
                isCustom: true,
                isActive: true,
                createdAt: nil,
                updatedAt: nil
            )
        ]
    }

    // MARK: - Browsing across all varieties

    func testBrowseAllVarietiesReturnsEveryActiveClone() {
        let all = CloneRootstockBrowse.systemClones(catalog, varietyKey: nil)
        XCTAssertEqual(all.count, 4)
        XCTAssertFalse(all.contains { $0.key == "pinot_noir:retired" })

        let custom = CloneRootstockBrowse.customClones(customClones, varietyKey: nil)
        XCTAssertEqual(custom.map { $0.displayName }, ["Old Block Selection", "Hillside"])
    }

    func testBrowseScopesToOneVariety() {
        let shiraz = CloneRootstockBrowse.systemClones(catalog, varietyKey: "shiraz")
        XCTAssertEqual(Set(shiraz.map { $0.key }), ["shiraz:pt23", "shiraz:fps_07"])

        let custom = CloneRootstockBrowse.customClones(customClones, varietyKey: "pinot_noir")
        XCTAssertEqual(custom.map { $0.displayName }, ["Hillside"])
    }

    func testBrowseSearchMatchesCodeAndAliasCaseInsensitive() {
        // Alias "PT 23" (with space).
        XCTAssertEqual(
            CloneRootstockBrowse.systemClones(catalog, varietyKey: nil, query: "pt 23").map { $0.key },
            ["shiraz:pt23"]
        )
        // Code match across two varieties — identity is never collapsed.
        XCTAssertEqual(CloneRootstockBrowse.systemClones(catalog, varietyKey: nil, query: "fps").count, 2)
        // Alias "Dijon 115".
        XCTAssertEqual(
            CloneRootstockBrowse.systemClones(catalog, varietyKey: nil, query: "dijon").map { $0.key },
            ["pinot_noir:entav_115"]
        )
        // Custom by name.
        XCTAssertEqual(
            CloneRootstockBrowse.customClones(customClones, varietyKey: nil, query: "old block").map { $0.displayName },
            ["Old Block Selection"]
        )
    }

    func testRootstockBrowseMatchesAliasAndParentage() {
        XCTAssertEqual(
            CloneRootstockBrowse.systemRootstocks(rootstocks, query: "salt creek").map { $0.key },
            ["ramsey"]
        )
        XCTAssertEqual(
            CloneRootstockBrowse.systemRootstocks(rootstocks, query: "champinii").map { $0.key },
            ["ramsey"]
        )
        XCTAssertEqual(
            CloneRootstockBrowse.customRootstocks(customRootstocks, query: "trial").map { $0.displayName },
            ["Trial Stock 7"]
        )
    }

    // MARK: - Allocation usage matching

    func testUsageMatchesByStableKey() {
        let pt23 = catalog.first { $0.key == "shiraz:pt23" }!
        let names = CloneRootstockBrowse.cloneMatchNames(pt23)
        XCTAssertTrue(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: "shiraz:pt23", allocationCloneText: "PT23",
            entryKey: "shiraz:pt23", matchNames: names
        ))
        // Different key never matches — even with colliding display text.
        XCTAssertFalse(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: "shiraz:fps_07", allocationCloneText: "PT23",
            entryKey: "shiraz:pt23", matchNames: names
        ))
    }

    func testLegacyTextMatchesOnlyWhenKeyAbsent() {
        let pt23 = catalog.first { $0.key == "shiraz:pt23" }!
        let names = CloneRootstockBrowse.cloneMatchNames(pt23)
        // Free-text legacy row (no key) matches canonically via the alias.
        XCTAssertTrue(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: nil, allocationCloneText: "pt 23",
            entryKey: "shiraz:pt23", matchNames: names
        ))
        XCTAssertTrue(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: nil, allocationCloneText: "PT23",
            entryKey: "shiraz:pt23", matchNames: names
        ))
        // Unrelated text does not.
        XCTAssertFalse(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: nil, allocationCloneText: "BVRC12",
            entryKey: "shiraz:pt23", matchNames: names
        ))
        // Blank text does not.
        XCTAssertFalse(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: nil, allocationCloneText: "  ",
            entryKey: "shiraz:pt23", matchNames: names
        ))
        XCTAssertFalse(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: nil, allocationCloneText: nil,
            entryKey: "shiraz:pt23", matchNames: names
        ))
    }

    func testSentinelsNeverMatchCatalogueRecords() {
        let pt23 = catalog.first { $0.key == "shiraz:pt23" }!
        let names = CloneRootstockBrowse.cloneMatchNames(pt23)
        XCTAssertFalse(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: CloneRootstockSentinels.massSelectionKey,
            allocationCloneText: CloneRootstockSentinels.massSelectionDisplay,
            entryKey: "shiraz:pt23", matchNames: names
        ))

        let ramsey = rootstocks.first { $0.key == "ramsey" }!
        let rootstockNames = CloneRootstockBrowse.rootstockMatchNames(ramsey)
        XCTAssertFalse(CloneRootstockBrowse.allocationUsesRootstock(
            allocationRootstockKey: CloneRootstockSentinels.ownRootsKey,
            allocationRootstockText: CloneRootstockSentinels.ownRootsDisplay,
            entryKey: "ramsey", matchNames: rootstockNames
        ))
    }

    func testRootstockUsageMatchesKeyAndLegacyText() {
        let ramsey = rootstocks.first { $0.key == "ramsey" }!
        let names = CloneRootstockBrowse.rootstockMatchNames(ramsey)
        XCTAssertTrue(CloneRootstockBrowse.allocationUsesRootstock(
            allocationRootstockKey: "ramsey", allocationRootstockText: nil,
            entryKey: "ramsey", matchNames: names
        ))
        // Legacy alias text.
        XCTAssertTrue(CloneRootstockBrowse.allocationUsesRootstock(
            allocationRootstockKey: nil, allocationRootstockText: "Salt Creek",
            entryKey: "ramsey", matchNames: names
        ))
        // Different key with colliding text never matches.
        XCTAssertFalse(CloneRootstockBrowse.allocationUsesRootstock(
            allocationRootstockKey: "1103_paulsen", allocationRootstockText: "Ramsey",
            entryKey: "ramsey", matchNames: names
        ))
    }

    func testCustomRecordUsageMatchesItsVineyardKey() {
        let row = customClones[0]
        XCTAssertTrue(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: row.cloneKey, allocationCloneText: row.displayName,
            entryKey: row.cloneKey, matchNames: [row.displayName]
        ))
        // Legacy text naming the custom clone (no key) also counts.
        XCTAssertTrue(CloneRootstockBrowse.allocationUsesClone(
            allocationCloneKey: nil, allocationCloneText: "old block selection",
            entryKey: row.cloneKey, matchNames: [row.displayName]
        ))
    }
}
