import XCTest
@testable import VineTrack

/// Contract tests for the shared Clone + Rootstock catalogues (sql/182).
/// The same behaviours are asserted by `CloneRootstockCatalogTest.kt` on
/// Android so both platforms stay pinned to one contract.
final class CloneRootstockCatalogTests: XCTestCase {

    // MARK: - Clone catalogue: variety ownership

    func testCloneLookupIsScopedToVariety() {
        let shiraz = BuiltInCloneCatalog.entries(forVarietyKey: "shiraz")
        XCTAssertFalse(shiraz.isEmpty, "Shiraz must have seeded clones")
        XCTAssertTrue(shiraz.allSatisfy { $0.varietyKey == "shiraz" })
        XCTAssertTrue(shiraz.contains { $0.key == "shiraz:pt23" })

        // A Shiraz clone never surfaces under Chardonnay.
        let chardonnay = BuiltInCloneCatalog.entries(forVarietyKey: "chardonnay")
        XCTAssertFalse(chardonnay.contains { $0.key.hasPrefix("shiraz:") })
        XCTAssertTrue(chardonnay.contains { $0.key == "chardonnay:gin_gin" })
    }

    func testSelectionSystemIdentityIsNeverCollapsed() {
        // FPS 07 exists for BOTH Shiraz and Cabernet Sauvignon as distinct
        // records — visible number alone never collapses clone identity.
        let fps07 = BuiltInCloneCatalog.entries.filter {
            $0.cloneCode == "FPS 07" && $0.selectionSystem == "FPS (UC Davis)"
        }
        XCTAssertGreaterThanOrEqual(fps07.count, 2)
        XCTAssertEqual(Set(fps07.map { $0.key }).count, fps07.count, "keys must be unique")

        // No ENTAV record carries an FPS code.
        XCTAssertFalse(BuiltInCloneCatalog.entries.contains {
            $0.selectionSystem == "ENTAV-INRA" && $0.cloneCode.hasPrefix("FPS")
        })
    }

    func testEveryCloneKeyEmbedsItsVariety() {
        for entry in BuiltInCloneCatalog.entries {
            XCTAssertTrue(
                entry.key.hasPrefix("\(entry.varietyKey):"),
                "\(entry.key) must be prefixed by its variety key"
            )
        }
        XCTAssertEqual(
            Set(BuiltInCloneCatalog.entries.map { $0.key }).count,
            BuiltInCloneCatalog.entries.count,
            "clone keys must be globally unique"
        )
    }

    // MARK: - Legacy text matching (suggestion only)

    func testLegacyCloneTextMatchesWithinVariety() {
        // "MV6" typed on a Pinot Noir block matches the catalogue record.
        let match = BuiltInCloneCatalog.entry(matching: "mv6", varietyKey: "pinot_noir")
        XCTAssertEqual(match?.key, "pinot_noir:mv6")

        // Alias matching: "Dijon 115" resolves to ENTAV-INRA 115.
        let alias = BuiltInCloneCatalog.entry(matching: "Dijon 115", varietyKey: "pinot_noir")
        XCTAssertEqual(alias?.key, "pinot_noir:entav_115")

        // The same text under the WRONG variety matches nothing.
        XCTAssertNil(BuiltInCloneCatalog.entry(matching: "mv6", varietyKey: "chardonnay"))
    }

    // MARK: - Rootstock catalogue: independent of variety

    func testRootstockCatalogueIsIndependentAndSearchable() {
        let keys = Set(BuiltInRootstockCatalog.entries.map { $0.key })
        XCTAssertGreaterThanOrEqual(keys.count, 20)
        XCTAssertEqual(keys.count, BuiltInRootstockCatalog.entries.count, "keys unique")
        for expected in ["101_14", "1103_paulsen", "110_richter", "140_ruggeri", "ramsey", "so4", "dog_ridge", "freedom", "harmony", "schwarzmann"] {
            XCTAssertTrue(keys.contains(expected), "missing rootstock \(expected)")
        }

        // Alias matching: "Salt Creek" is Ramsey; "1103P" is 1103 Paulsen.
        XCTAssertEqual(BuiltInRootstockCatalog.entry(matching: "Salt Creek")?.key, "ramsey")
        XCTAssertEqual(BuiltInRootstockCatalog.entry(matching: "1103P")?.key, "1103_paulsen")
        XCTAssertNil(BuiltInRootstockCatalog.entry(matching: "definitely not a rootstock"))
    }

    // MARK: - Sentinels

    func testSentinelsAreNotCatalogueRecords() {
        XCTAssertEqual(CloneRootstockSentinels.massSelectionKey, "mass_selection")
        XCTAssertEqual(CloneRootstockSentinels.ownRootsKey, "own_roots")
        XCTAssertFalse(BuiltInCloneCatalog.entries.contains { $0.key == CloneRootstockSentinels.massSelectionKey })
        XCTAssertFalse(BuiltInRootstockCatalog.entries.contains { $0.key == CloneRootstockSentinels.ownRootsKey })
    }

    // MARK: - Allocation round-trip (keys + snapshots)

    func testAllocationEncodesCloneAndRootstockKeys() throws {
        let allocation = PaddockVarietyAllocation(
            varietyId: UUID(),
            percent: 50,
            name: "Shiraz / Syrah",
            varietyKey: "shiraz",
            clone: "PT23",
            rootstock: "1103 Paulsen",
            cloneKey: "shiraz:pt23",
            rootstockKey: "1103_paulsen"
        )
        let data = try JSONEncoder().encode(allocation)
        let decoded = try JSONDecoder().decode(PaddockVarietyAllocation.self, from: data)
        XCTAssertEqual(decoded.cloneKey, "shiraz:pt23")
        XCTAssertEqual(decoded.rootstockKey, "1103_paulsen")
        XCTAssertEqual(decoded.clone, "PT23")
        XCTAssertEqual(decoded.rootstock, "1103 Paulsen")

        // The wire format uses camelCase keys per the sql/182 contract.
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"cloneKey\""))
        XCTAssertTrue(json.contains("\"rootstockKey\""))
    }

    func testAllocationDecodesSnakeCaseKeysAndOwnRoots() throws {
        let json = """
        {
            "id": "6A8B0F3E-1111-4222-8333-444455556666",
            "varietyId": "6A8B0F3E-1111-4222-8333-444455556667",
            "percent": 100,
            "name": "Pinot Noir",
            "variety_key": "pinot_noir",
            "clone": "MV6",
            "clone_key": "pinot_noir:mv6",
            "rootstock": "Own roots",
            "rootstock_key": "own_roots"
        }
        """
        let decoded = try JSONDecoder().decode(
            PaddockVarietyAllocation.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.cloneKey, "pinot_noir:mv6")
        XCTAssertEqual(decoded.rootstockKey, CloneRootstockSentinels.ownRootsKey)
        XCTAssertEqual(decoded.varietyKey, "pinot_noir")
    }

    /// Legacy allocations with free text and no keys stay valid — the text
    /// is preserved and no key is invented.
    func testLegacyFreeTextAllocationIsPreserved() throws {
        let json = """
        {
            "id": "6A8B0F3E-1111-4222-8333-444455556666",
            "varietyId": "6A8B0F3E-1111-4222-8333-444455556667",
            "percent": 70,
            "name": "Shiraz",
            "clone": "old vine selection",
            "rootstock": "unknown mix"
        }
        """
        let decoded = try JSONDecoder().decode(
            PaddockVarietyAllocation.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.clone, "old vine selection")
        XCTAssertEqual(decoded.rootstock, "unknown mix")
        XCTAssertNil(decoded.cloneKey)
        XCTAssertNil(decoded.rootstockKey)

        // Round-trip keeps the legacy text untouched.
        let reencoded = try JSONDecoder().decode(
            PaddockVarietyAllocation.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(reencoded.clone, "old vine selection")
        XCTAssertNil(reencoded.cloneKey)
    }

    // MARK: - Multiple allocations of the same variety

    func testSameVarietyTwiceWithDifferentCloneAndRootstock() throws {
        let varietyId = UUID()
        let a = PaddockVarietyAllocation(
            varietyId: varietyId, percent: 50, name: "Shiraz", varietyKey: "shiraz",
            clone: "PT23", rootstock: "1103 Paulsen",
            cloneKey: "shiraz:pt23", rootstockKey: "1103_paulsen"
        )
        let b = PaddockVarietyAllocation(
            varietyId: varietyId, percent: 50, name: "Shiraz", varietyKey: "shiraz",
            clone: "BVRC12", rootstock: "Ramsey",
            cloneKey: "shiraz:bvrc12", rootstockKey: "ramsey"
        )
        let data = try JSONEncoder().encode([a, b])
        let decoded = try JSONDecoder().decode([PaddockVarietyAllocation].self, from: data)
        XCTAssertEqual(decoded.count, 2, "same-variety allocations must never merge")
        XCTAssertNotEqual(decoded[0].cloneKey, decoded[1].cloneKey)
        XCTAssertNotEqual(decoded[0].rootstockKey, decoded[1].rootstockKey)
        XCTAssertEqual(decoded[0].varietyKey, decoded[1].varietyKey)
    }
}
