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
///  * the local vintage mirror recomputes when the picked date changes, and
///  * Block + Variety + Vintage totals (the actual yield) recompute after
///    an edit.
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
        clone: String? = "PT23",
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
            clone: clone,
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

    @Test func grapeValueStaysDerivedNeverStored() {
        var edited = makeRecord(weightKg: 2000, sold: true)
        edited.pricePerTonne = 1500
        #expect(edited.grapeValue == 3000)
        edited.sold = false
        #expect(edited.grapeValue == nil)
    }
}
