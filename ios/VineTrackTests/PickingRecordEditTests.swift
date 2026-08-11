import Foundation
import Testing
@testable import VineTrack

/// Cross-platform parity contract for EDITING Detailed picking records
/// (sql/180 UPDATE). The same rules are asserted by
/// `PickingRecordEditParityTest.kt` in the Android unit-test source set:
///
///  * an edit keeps the record id (update-in-place, never a duplicate),
///  * the client write payload NEVER carries `vintage` or `grape_value`
///    (both server-authoritative),
///  * cleared optional fields are sent as explicit nulls so the server
///    columns are cleared too (e.g. un-selling a pick),
///  * the historical sugar unit is preserved unless the sugar value itself
///    is re-entered,
///  * the local vintage mirror recomputes when the picked date changes,
///  * Block + Variety + Vintage totals (the actual yield) recompute after
///    an edit, and
///  * the planting-GROUP identity (`planting_group_key` +
///    `variety_allocation_ids` members + rootstock snapshot, sql/184)
///    round-trips exactly — identical sections share ONE group key, every
///    member allocation id is preserved under the group (never one
///    arbitrary id), and unlinked records stay unlinked (never guessed).
struct PickingRecordEditTests {

    private let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let blockA = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private let blockB = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return Calendar.current.date(from: components)!
    }

    private func makeRecord(
        id: UUID = UUID(),
        pickedAt: Date? = nil,
        vintage: Int = 2027,
        paddockId: UUID? = nil,
        varietyName: String = "Shiraz",
        plantingGroupKey: String? = nil,
        varietyAllocationIds: [UUID]? = nil,
        clone: String? = "PT23",
        rootstock: String? = nil,
        weightKg: Double = 850,
        sold: Bool = true
    ) -> PickingRecord {
        PickingRecord(
            id: id,
            vineyardId: vineyard,
            pickedAt: pickedAt ?? date(2027, 2, 10),
            vintage: vintage,
            paddockId: paddockId ?? blockA,
            paddockName: "Block A",
            varietyId: UUID(),
            varietyKey: "shiraz",
            varietyName: varietyName,
            plantingGroupKey: plantingGroupKey,
            varietyAllocationIds: varietyAllocationIds,
            clone: clone,
            rootstock: rootstock,
            weightKg: weightKg,
            sugarValue: 13.2,
            sugarUnit: "baume",
            ph: 3.45,
            taGPerL: 6.1,
            purpose: "Table wine",
            sold: sold,
            soldTo: sold ? "Winery Co" : nil,
            pricePerTonne: sold ? 1800 : nil,
            notes: "First pick"
        )
    }

    private func jsonObject(for payload: BackendPickingRecordUpsert) throws -> [String: Any] {
        let encoder = JSONEncoder()
        let data = try encoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object ?? [:]
    }

    // MARK: - Write payload rules

    @Test func upsertPayloadNeverCarriesServerAuthoritativeFields() throws {
        let record = makeRecord()
        let payload = BackendPickingRecord.upsert(from: record, createdBy: UUID(), clientUpdatedAt: Date())
        let json = try jsonObject(for: payload)

        #expect(json["vintage"] == nil)
        #expect(json["grape_value"] == nil)
        #expect(json["id"] != nil)
        #expect(json["picked_at"] != nil)
        #expect(json["client_updated_at"] != nil)
    }

    @Test func editThatClearsFieldsSendsExplicitNulls() throws {
        // Un-sell the pick and clear the clone: the upsert must carry explicit
        // nulls so the server columns are cleared, not left stale.
        var edited = makeRecord()
        edited.sold = false
        edited.soldTo = nil
        edited.pricePerTonne = nil
        edited.clone = nil

        let payload = BackendPickingRecord.upsert(from: edited, createdBy: nil, clientUpdatedAt: Date())
        let json = try jsonObject(for: payload)

        #expect(json["sold_to"] is NSNull)
        #expect(json["price_per_tonne"] is NSNull)
        #expect(json["clone"] is NSNull)
        #expect((json["sold"] as? Bool) == false)
    }

    @Test func editKeepsRecordIdentity() {
        let original = makeRecord()
        var edited = original
        edited.weightKg = 990
        edited.notes = "Corrected weight"

        #expect(edited.id == original.id)
        let payload = BackendPickingRecord.upsert(from: edited, createdBy: nil, clientUpdatedAt: Date())
        #expect(payload.id == original.id)
    }

    // MARK: - Sugar unit preservation

    @Test func editPreservesHistoricalSugarUnit() {
        // A record entered in Brix keeps Brix through unrelated edits even if
        // the vineyard preference is Baumé today.
        var record = makeRecord()
        record.sugarUnit = "brix"
        record.sugarValue = 22.5

        var edited = record
        edited.weightKg = 1200

        #expect(edited.sugarUnit == "brix")
        #expect(edited.sugarValue == 22.5)
        #expect(edited.sugarMeasurement == .brix)
    }

    @Test func clearingSugarValueClearsUnitTogether() {
        var edited = makeRecord()
        edited.sugarValue = nil
        edited.sugarUnit = nil
        #expect(edited.sugarMeasurement == nil)
    }

    // MARK: - Vintage mirror on date change

    @Test func vintageMirrorsDateChangeUnderJulySeasonStart() {
        // 1 July season start: a Feb 2027 pick is Vintage 2027; moving the
        // date to Aug 2027 crosses the season boundary → Vintage 2028.
        let before = VintageResolver.vintageYear(for: date(2027, 2, 10), seasonStartMonth: 7, seasonStartDay: 1)
        let after = VintageResolver.vintageYear(for: date(2027, 8, 10), seasonStartMonth: 7, seasonStartDay: 1)
        #expect(before == 2027)
        #expect(after == 2028)
    }

    // MARK: - Totals recompute after edit

    @Test func totalsRecomputeAfterWeightEdit() {
        let a = makeRecord(weightKg: 800)
        let b = makeRecord(weightKg: 200)
        let before = PickingYieldAggregator.detailedActualTonnes(
            records: [a, b], paddockId: blockA, varietyName: "Shiraz", vintage: 2027
        )
        #expect(before == 1.0)

        var edited = b
        edited.weightKg = 700
        let records = [a, b].map { $0.id == edited.id ? edited : $0 }
        let after = PickingYieldAggregator.detailedActualTonnes(
            records: records, paddockId: blockA, varietyName: "Shiraz", vintage: 2027
        )
        #expect(after == 1.5)
    }

    @Test func movingRecordToAnotherBlockMovesTheTotals() {
        let a = makeRecord(weightKg: 800)
        var moved = makeRecord(weightKg: 200)
        moved.paddockId = blockB
        moved.paddockName = "Block B"

        let records = [a, moved]
        let blockATotal = PickingYieldAggregator.detailedActualTonnes(
            records: records, paddockId: blockA, varietyName: "Shiraz", vintage: 2027
        )
        let blockBTotal = PickingYieldAggregator.detailedActualTonnes(
            records: records, paddockId: blockB, varietyName: "Shiraz", vintage: 2027
        )
        #expect(blockATotal == 0.8)
        #expect(blockBTotal == 0.2)
    }

    // MARK: - Planting-group identity (sql/184)

    @Test func upsertPayloadCarriesPlantingGroupIdentity() throws {
        // A multi-section group: BOTH member allocation ids travel under the
        // group key — never one arbitrary id.
        let memberOne = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let memberTwo = UUID(uuidString: "66666666-7777-4888-8999-AAAAAAAAAAAA")!
        let key = PlantingGroup.key(varietyName: "Pinot Noir", clone: "777", rootstock: "Richter 110")
        let record = makeRecord(
            varietyName: "Pinot Noir",
            plantingGroupKey: key,
            varietyAllocationIds: [memberOne, memberTwo],
            clone: "777",
            rootstock: "Richter 110"
        )
        let payload = BackendPickingRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())
        let json = try jsonObject(for: payload)

        #expect((json["planting_group_key"] as? String) == "pinot noir|777|richter 110")
        let members = (json["variety_allocation_ids"] as? [String])?.map { $0.lowercased() }
        #expect(members?.count == 2)
        #expect(members?.contains(memberOne.uuidString.lowercased()) == true)
        #expect(members?.contains(memberTwo.uuidString.lowercased()) == true)
        #expect((json["clone"] as? String) == "777")
        #expect((json["rootstock"] as? String) == "Richter 110")
    }

    @Test func clearingPlantingSendsExplicitNulls() throws {
        // Un-linking a pick ("Not specified") must clear all four planting
        // columns server-side, not leave them stale.
        var edited = makeRecord(
            plantingGroupKey: PlantingGroup.key(varietyName: "Shiraz", clone: "777", rootstock: "Richter 110"),
            varietyAllocationIds: [UUID()],
            clone: "777",
            rootstock: "Richter 110"
        )
        edited.plantingGroupKey = nil
        edited.varietyAllocationIds = nil
        edited.clone = nil
        edited.rootstock = nil

        let payload = BackendPickingRecord.upsert(from: edited, createdBy: nil, clientUpdatedAt: Date())
        let json = try jsonObject(for: payload)

        #expect(json["planting_group_key"] is NSNull)
        #expect(json["variety_allocation_ids"] is NSNull)
        #expect(json["clone"] is NSNull)
        #expect(json["rootstock"] is NSNull)
    }

    @Test func identicalSectionsShareOnePlantingGroupKey() {
        // The motivating case: one block, two Pinot Noir sections, BOTH
        // Clone 777 · Richter 110 — they are ONE planting group. The key is
        // case/whitespace-insensitive so client drift can never fork it.
        let a = PlantingGroup.key(varietyName: "Pinot Noir", clone: "777", rootstock: "Richter 110")
        let b = PlantingGroup.key(varietyName: " PINOT  Noir ", clone: "777 ", rootstock: "richter 110")
        #expect(a == b)
        #expect(a == "pinot noir|777|richter 110")

        // Different rootstock = different group.
        let c = PlantingGroup.key(varietyName: "Pinot Noir", clone: "777", rootstock: "Own roots")
        #expect(a != c)

        // nils normalise to empty segments.
        #expect(PlantingGroup.key(varietyName: "Chardonnay", clone: nil, rootstock: nil) == "chardonnay||")
    }

    @Test func memberAllocationIdsArePreservedNotCollapsed() throws {
        // A group spanning two physical sections must round-trip BOTH member
        // ids — representing the group by one member is forbidden.
        let members = [
            UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            UUID(uuidString: "66666666-7777-4888-8999-AAAAAAAAAAAA")!,
        ]
        let record = makeRecord(
            varietyName: "Pinot Noir",
            plantingGroupKey: PlantingGroup.key(varietyName: "Pinot Noir", clone: "777", rootstock: "Richter 110"),
            varietyAllocationIds: members,
            clone: "777",
            rootstock: "Richter 110"
        )
        #expect(record.varietyAllocationIds == members)

        let payload = BackendPickingRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())
        let json = try jsonObject(for: payload)
        #expect((json["variety_allocation_ids"] as? [String])?.count == 2)
    }

    @Test func linkedGroupWithoutMemberIdsSendsEmptyArrayNotNull() throws {
        // Legacy member allocations may have no minted ids — the group is
        // still linked: key set, members [] (not null).
        let record = makeRecord(
            varietyName: "Chardonnay",
            plantingGroupKey: PlantingGroup.key(varietyName: "Chardonnay", clone: nil, rootstock: nil),
            varietyAllocationIds: [],
            clone: nil,
            rootstock: nil
        )
        let payload = BackendPickingRecord.upsert(from: record, createdBy: nil, clientUpdatedAt: Date())
        let json = try jsonObject(for: payload)
        #expect((json["planting_group_key"] as? String) == "chardonnay||")
        #expect((json["variety_allocation_ids"] as? [String])?.isEmpty == true)
    }

    @Test func unlinkedHistoricalRecordStaysUnlinkedThroughUnrelatedEdits() throws {
        // Pre-184 rows have no group link. An unrelated edit (weight fix)
        // must keep them unlinked — never auto-matched/guessed.
        var edited = makeRecord(clone: "777", rootstock: nil)
        #expect(edited.plantingGroupKey == nil)
        #expect(edited.varietyAllocationIds == nil)
        edited.weightKg = 990

        let payload = BackendPickingRecord.upsert(from: edited, createdBy: nil, clientUpdatedAt: Date())
        let json = try jsonObject(for: payload)
        #expect(json["planting_group_key"] is NSNull)
        #expect(json["variety_allocation_ids"] is NSNull)
        #expect((json["clone"] as? String) == "777")
    }

    @Test func plantingGroupTotalsPartitionAndReconcileExactly() {
        // Yield Overview contract: one production row per planting group;
        // identical sections are ONE row; the unlinked bucket is last; and
        // the group rows always sum exactly to the variety total.
        let key777 = PlantingGroup.key(varietyName: "Pinot Noir", clone: "777", rootstock: "Richter 110")
        let key667 = PlantingGroup.key(varietyName: "Pinot Noir", clone: "667", rootstock: "Richter 110")
        let records = [
            makeRecord(varietyName: "Pinot Noir", plantingGroupKey: key777, clone: "777", rootstock: "Richter 110", weightKg: 2000),
            makeRecord(varietyName: "Pinot Noir", plantingGroupKey: key777, clone: "777", rootstock: "Richter 110", weightKg: 2140),
            makeRecord(varietyName: "Pinot Noir", plantingGroupKey: key667, clone: "667", rootstock: "Richter 110", weightKg: 2590),
            makeRecord(varietyName: "Pinot Noir", plantingGroupKey: nil, clone: nil, rootstock: nil, weightKg: 500)
        ]

        let groups = PickingYieldAggregator.plantingGroupTotals(for: records)
        #expect(groups.count == 3)
        #expect(groups[0].groupKey == key777)
        #expect(groups[0].pickCount == 2)
        #expect(abs(groups[0].actualYieldTonnes - 4.14) < 0.000001)
        #expect(groups[1].groupKey == key667)
        #expect(abs(groups[1].actualYieldTonnes - 2.59) < 0.000001)
        #expect(groups.last?.groupKey == nil)
        #expect(groups.last?.pickCount == 1)

        let groupSum = groups.reduce(0.0) { $0 + $1.totalWeightKg }
        let bucketSum = records.reduce(0.0) { $0 + $1.weightKg }
        #expect(abs(groupSum - bucketSum) < 0.000001)
    }

    @Test func grapeValueStaysDerivedNeverStored() {
        var edited = makeRecord(weightKg: 2000, sold: true)
        edited.pricePerTonne = 1500
        #expect(edited.grapeValue == 3000)
        edited.sold = false
        #expect(edited.grapeValue == nil)
    }
}
