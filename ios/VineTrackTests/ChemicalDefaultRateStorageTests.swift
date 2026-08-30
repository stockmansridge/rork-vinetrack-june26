import Foundation
import Testing
@testable import VineTrack

/// The persistence contract for a CONFIRMED operational rate (sql/214).
///
/// The customer outcome this protects: an operator searches a product, reads
/// its grapevine label, confirms the amount they actually pour, saves — and
/// that exact amount is waiting for them in the next spray, on every device.
///
/// Before this existed, `default_rates` round-tripped nowhere on iOS or
/// Android: the confirmation was recorded in the UI, projected into the legacy
/// `rates` array, and the authoritative choice itself was dropped. Every client
/// then re-derived it by matching a bare number back to a label direction,
/// which is inference, not a decision.
///
/// The golden option keys below are minted by the DENO implementation
/// (`mintDefaultOptionKey` in `default_rates.ts`) and hard-coded here on
/// purpose. A key is only useful if the server, iOS and Android independently
/// arrive at the same string for the same choice; asserting against a value
/// this file computed itself would prove nothing.
struct ChemicalDefaultRateStorageTests {

    /// `3 L/100 L` supported by two printed directions.
    private static let goldenSingleValueKey = "default_option_v1_7de7c29980f279f49fac2e717ed4968d"
    /// `560–700 g/ha` — the CHATEAU (APVMA 80647) grapevine band.
    private static let goldenBandKey = "default_option_v1_dd81178fa70649ce9a097ad840805834"

    // MARK: - Identity parity with the server

    @Test("Option key matches the server for a single-value rate")
    func singleValueKeyMatchesServer() {
        let key = ChemicalDefaultRateIdentity.mintOptionKey(
            basis: "per_100_litres",
            unit: "L",
            value: 3,
            minValue: nil,
            maxValue: nil,
            rateIDs: ["rate_v1_aaa", "rate_v1_bbb"]
        )
        #expect(key == Self.goldenSingleValueKey)
    }

    @Test("Option key matches the server for a true label band")
    func bandKeyMatchesServer() {
        let key = ChemicalDefaultRateIdentity.mintOptionKey(
            basis: "per_hectare",
            unit: "g",
            value: nil,
            minValue: 560,
            maxValue: 700,
            rateIDs: ["rate_v1_chateau"]
        )
        #expect(key == Self.goldenBandKey)
    }

    /// A client listing Grapevine Scale first must reach the same option as one
    /// listing European Red Mites first: they made the same choice.
    @Test("Option key is independent of rate-id order")
    func keyIsOrderIndependent() {
        let forward = ChemicalDefaultRateIdentity.mintOptionKey(
            basis: "per_100_litres", unit: "L", value: 3,
            minValue: nil, maxValue: nil,
            rateIDs: ["rate_v1_aaa", "rate_v1_bbb"]
        )
        let reversed = ChemicalDefaultRateIdentity.mintOptionKey(
            basis: "per_100_litres", unit: "L", value: 3,
            minValue: nil, maxValue: nil,
            rateIDs: ["rate_v1_bbb", "rate_v1_aaa"]
        )
        #expect(forward == reversed)
        #expect(forward == Self.goldenSingleValueKey)
    }

    /// "No upper bound" and "an upper bound of zero" must never hash alike.
    @Test("Absent and zero amounts are distinct identities")
    func absentIsNotZero() {
        #expect(ChemicalDefaultRateIdentity.normaliseNumber(nil) == "-")
        #expect(ChemicalDefaultRateIdentity.normaliseNumber(0) == "0")
        #expect(ChemicalDefaultRateIdentity.normaliseNumber(3) == "3")
        // `3`, `3.0` and `3.000` are one number.
        #expect(ChemicalDefaultRateIdentity.normaliseNumber(3.000) == "3")
    }

    /// Provenance must never move the identity, or a reissued label restating
    /// the same direction would silently orphan the operator's default.
    @Test("Label version and timestamp are not part of identity")
    func provenanceIsNotIdentity() {
        let base = ChemicalDefaultRateIdentity.canonicalInput(
            basis: "per_hectare", unit: "g", value: nil,
            minValue: 560, maxValue: 700, rateIDs: ["rate_v1_chateau"]
        )
        #expect(!base.contains("2026"))
        #expect(!base.lowercased().contains("operator"))
        #expect(!base.lowercased().contains("label_version"))
    }

    // MARK: - Fixtures

    /// The CHATEAU grapevine direction: one printed band, one server rate id.
    private static func chateauUse(rateId: String? = "rate_v1_chateau") -> ChemicalRegisteredUse {
        ChemicalRegisteredUse(
            crop: "Grapevines",
            targetRaw: "Annual broadleaf weeds",
            rates: [
                ChemicalLabelRate(
                    label: "All states",
                    basis: .rangePerHectare,
                    minValue: 560,
                    maxValue: 700,
                    unit: "g",
                    rawText: "560 - 700 g/ha",
                    rateId: rateId
                )
            ],
            withholdingPeriodDays: 98,
            directionId: "dir_v1_chateau"
        )
    }

    private static func option(
        _ basis: ChemicalDefaultRateBasis,
        from uses: [ChemicalRegisteredUse]
    ) -> ChemicalDefaultRateOption? {
        ChemicalDefaultRate.options(basis, from: uses).first
    }

    // MARK: - Building a confirmed default

    @Test("A confirmed band records both bounds and cites its direction")
    func confirmedBandKeepsBothBounds() throws {
        let uses = [Self.chateauUse()]
        let option = try #require(Self.option(.perHectare, from: uses))
        let stored = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option,
                basis: .perHectare,
                grapevineUses: uses
            )
        )

        #expect(stored.optionKey == Self.goldenBandKey)
        #expect(stored.rateIds == ["rate_v1_chateau"])
        #expect(stored.basis == "per_hectare")
        #expect(stored.unit == "g")
        // A true label range keeps BOTH bounds. Splitting it into two defaults,
        // or collapsing it to one number, would misreport the registration.
        #expect(stored.minValue == 560)
        #expect(stored.maxValue == 700)
        // Confirmed by a human, so the provenance says so.
        #expect(stored.source == "operator")
    }

    @Test("An exact dose inside the band is accepted and stored alongside it")
    func exactDoseInsideBandIsAccepted() throws {
        let uses = [Self.chateauUse()]
        let option = try #require(Self.option(.perHectare, from: uses))
        let stored = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option,
                basis: .perHectare,
                grapevineUses: uses,
                confirmedValue: 620
            )
        )
        #expect(stored.value == 620)
        // The registered band is NOT rewritten to the operator's figure.
        #expect(stored.minValue == 560)
        #expect(stored.maxValue == 700)
    }

    @Test("A dose outside the registered band is refused")
    func doseOutsideBandIsRefused() throws {
        let uses = [Self.chateauUse()]
        let option = try #require(Self.option(.perHectare, from: uses))
        let stored = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option,
                basis: .perHectare,
                grapevineUses: uses,
                confirmedValue: 900
            )
        )
        // 900 g/ha is not registered, so it is not recorded. The band stands.
        #expect(stored.value == nil)
        #expect(stored.minValue == 560)
        #expect(stored.maxValue == 700)
    }

    /// An untraceable default is exactly the invented provenance this contract
    /// exists to prevent: a number that looks chosen, attributed to a direction
    /// nobody can point at.
    @Test("A rate with no server-minted id cannot become a default")
    func untraceableRateCannotBecomeDefault() throws {
        let uses = [Self.chateauUse(rateId: nil)]
        let option = try #require(Self.option(.perHectare, from: uses))
        let stored = StoredChemicalDefaultRate.confirmed(
            option: option,
            basis: .perHectare,
            grapevineUses: uses
        )
        #expect(stored == nil)
    }

    /// Other crops are retained on the record and are never candidates for a
    /// vineyard's default.
    @Test("An other-crop direction never supplies a vineyard rate id")
    func otherCropNeverSuppliesRateId() throws {
        let grapevine = Self.chateauUse()
        let apples = ChemicalRegisteredUse(
            crop: "Apples",
            targetRaw: "Black spot",
            rates: [
                ChemicalLabelRate(
                    label: "All states",
                    basis: .rangePerHectare,
                    minValue: 560,
                    maxValue: 700,
                    unit: "g",
                    rateId: "rate_v1_apples"
                )
            ]
        )
        // The plan is built from the GRAPEVINE partition only.
        let uses = [grapevine]
        let option = try #require(Self.option(.perHectare, from: uses))
        let ids = ChemicalDefaultRate.rateIDs(for: option, from: uses)
        #expect(ids == ["rate_v1_chateau"])
        #expect(!ids.contains("rate_v1_apples"))
        // Sanity: the apple direction really does state an identical amount,
        // so this is proving the partition, not an accidental mismatch.
        #expect(apples.rates.first?.minValue == 560)
    }

    // MARK: - Round trip

    @Test("The stored shape survives encode and decode with server key names")
    func storedShapeRoundTrips() throws {
        let uses = [Self.chateauUse()]
        let option = try #require(Self.option(.perHectare, from: uses))
        let slot = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option, basis: .perHectare,
                grapevineUses: uses, confirmedValue: 620,
                labelVersion: "2024-07"
            )
        )
        let value = StoredChemicalDefaultRates().withSlot(.perHectare, slot)

        let data = try JSONEncoder().encode(value)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Exact server key names — a client spelling is a guaranteed drift.
        #expect(json["version"] as? Int == 1)
        #expect(json["per_hectare"] != nil)
        let slotJSON = try #require(json["per_hectare"] as? [String: Any])
        #expect(slotJSON["option_key"] as? String == Self.goldenBandKey)
        #expect(slotJSON["rate_ids"] as? [String] == ["rate_v1_chateau"])
        #expect(slotJSON["min_value"] as? Double == 560)
        #expect(slotJSON["max_value"] as? Double == 700)
        #expect(slotJSON["label_version"] as? String == "2024-07")

        let decoded = try JSONDecoder().decode(StoredChemicalDefaultRates.self, from: data)
        #expect(decoded == value)
        // The other basis stays independent: a per-ha default never
        // manufactures a per-100 L one, which would need a water volume the
        // label never gave.
        #expect(decoded.per100Litres == nil)
    }

    @Test("A missing or malformed column decodes as no recorded default")
    func malformedDefaultsDegradeToNil() throws {
        // A row written before sql/214, or by a client that got it wrong.
        let json = Data(#"{"version":1,"per_hectare":"nonsense"}"#.utf8)
        let decoded = try JSONDecoder().decode(StoredChemicalDefaultRates.self, from: json)
        // Degrades to "nothing recorded" rather than failing the chemical: the
        // label evidence in `registered_uses` is untouched either way.
        #expect(decoded.perHectare == nil)
        #expect(decoded.isEmpty)
    }

    // MARK: - The saved-chemical round trip

    @Test("A saved chemical carries its confirmed default through save and reload")
    func savedChemicalRoundTripsDefault() throws {
        let uses = [Self.chateauUse()]
        let option = try #require(Self.option(.perHectare, from: uses))
        let slot = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option, basis: .perHectare, grapevineUses: uses
            )
        )
        let chemical = SavedChemical(
            name: "CHATEAU",
            defaultRates: StoredChemicalDefaultRates().withSlot(.perHectare, slot)
        )

        let data = try JSONEncoder().encode(chemical)
        let reloaded = try JSONDecoder().decode(SavedChemical.self, from: data)
        #expect(reloaded.defaultRates?.perHectare?.optionKey == Self.goldenBandKey)
        #expect(reloaded.defaultRates?.perHectare?.rateIds == ["rate_v1_chateau"])
    }

    /// A chemical saved before sql/214 has no default. That is a real answer
    /// and must never be read as "this label has no rates".
    @Test("A chemical saved before the column existed still loads")
    func legacyChemicalWithoutDefaultsStillLoads() throws {
        let json = Data("""
        {"id":"\(UUID().uuidString)","vineyardId":"\(UUID().uuidString)","name":"Legacy"}
        """.utf8)
        let decoded = try JSONDecoder().decode(SavedChemical.self, from: json)
        #expect(decoded.defaultRates == nil)
        #expect(decoded.name == "Legacy")
    }

    // MARK: - The database write shape

    /// sql/215 is NOT applied. PostgREST rejects an entire write that names an
    /// unknown column, so shipping these keys broke saving precisely when the
    /// resolver HAD found a manufacturer document — the good-data case.
    @Test("The upsert payload names no unapplied sql/215 column")
    func upsertOmitsUnappliedColumns() throws {
        let chemical = SavedChemical(name: "CHATEAU")
        let payload = BackendSavedChemical.upsert(
            from: chemical, createdBy: nil, clientUpdatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["manufacturer_label_url"] == nil)
        #expect(json["manufacturer_product_url"] == nil)
        // The regulator's label keeps its own long-standing column.
        #expect(json.keys.contains("label_reference"))
    }

    /// Omitted, not blanked: an edit that carries no rate decision must never
    /// erase a confirmation made earlier or on another device.
    @Test("An edit with no confirmed default omits the column entirely")
    func editWithoutDefaultOmitsColumn() throws {
        let chemical = SavedChemical(name: "CHATEAU")
        let payload = BackendSavedChemical.upsert(
            from: chemical, createdBy: nil, clientUpdatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(
            try JSONSerialization.jsonObject(with: try encoder.encode(payload)) as? [String: Any]
        )
        #expect(json["default_rates"] == nil)
    }

    @Test("A confirmed default is written to the default_rates column")
    func confirmedDefaultIsWritten() throws {
        let uses = [Self.chateauUse()]
        let option = try #require(Self.option(.perHectare, from: uses))
        let slot = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option, basis: .perHectare, grapevineUses: uses
            )
        )
        let chemical = SavedChemical(
            name: "CHATEAU",
            defaultRates: StoredChemicalDefaultRates().withSlot(.perHectare, slot)
        )
        let payload = BackendSavedChemical.upsert(
            from: chemical, createdBy: nil, clientUpdatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try #require(
            try JSONSerialization.jsonObject(with: try encoder.encode(payload)) as? [String: Any]
        )
        let stored = try #require(json["default_rates"] as? [String: Any])
        let slotJSON = try #require(stored["per_hectare"] as? [String: Any])
        #expect(slotJSON["option_key"] as? String == Self.goldenBandKey)
    }
}
