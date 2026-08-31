import Foundation
import Testing
@testable import VineTrack

/// The server's default-rate options must reach the review screen.
///
/// # The defect these tests exist to prevent
///
/// The decode side landed first: `ChemicalStructuredLookup` learned to read
/// `default_rate_options`, and persistence learned to REFUSE any option without
/// a server twin. Between those two changes sat a gap nobody could see in a
/// build — the decoded options were never handed to the editor, so every option
/// on screen was one the device had grouped itself, and every attempt to
/// confirm a default was silently refused.
///
/// That is worse than the bug it replaced: the operator reads the label,
/// confirms 620 g/ha, taps Save, and the vineyard's chosen dose is simply not
/// there on the next spray. These tests hold the whole thread — lookup →
/// coordinator → editor → persisted slot — so the two halves cannot drift apart
/// again.
@MainActor
struct ChemicalServerOptionHandoffTests {

    private static let vineyardId = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!

    /// CHATEAU (APVMA 80647): one grapevine band, 560–700 g/ha, WHP 98.
    ///
    /// `rate_ids` are listed in an order that is NOT sorted, on purpose. The
    /// server minted `option_key` over these exact bytes in this exact order,
    /// so anything that tidies them breaks the pairing the key proves.
    private static let chateauLookupJSON = """
    {
      "name": "CHATEAU WDG HERBICIDE",
      "registration_number": "80647",
      "country_code": "AU",
      "registered_uses": [
        {
          "crop": "Grapevines",
          "target": "Annual broadleaf weeds",
          "direction_id": "dir_v1_chateau",
          "withholding_period_days": 98,
          "rates": [
            {
              "label": "All states",
              "basis": "range_per_hectare",
              "min_value": 560,
              "max_value": 700,
              "unit": "g",
              "raw_text": "560 - 700 g/ha",
              "rate_id": "rate_v1_zeta"
            }
          ]
        }
      ],
      "default_rate_options": {
        "per_hectare": [
          {
            "option_key": "default_option_v1_dd81178fa70649ce9a097ad840805834",
            "rate_ids": ["rate_v1_zeta", "rate_v1_alpha"],
            "basis": "per_hectare",
            "unit": "g",
            "min_value": 560,
            "max_value": 700,
            "direction_ids": ["dir_v1_chateau"],
            "targets": ["Annual broadleaf weeds"],
            "crops": ["Grapevines"]
          }
        ],
        "per_100_litres": []
      }
    }
    """

    /// The same product, from a server that has no options block at all.
    private static let optionlessLookupJSON = """
    {
      "name": "CHATEAU WDG HERBICIDE",
      "registration_number": "80647",
      "country_code": "AU",
      "registered_uses": [
        {
          "crop": "Grapevines",
          "target": "Annual broadleaf weeds",
          "rates": [
            {
              "label": "All states",
              "basis": "range_per_hectare",
              "min_value": 560,
              "max_value": 700,
              "unit": "g",
              "rate_id": "rate_v1_zeta"
            }
          ]
        }
      ]
    }
    """

    private func decode(_ json: String) throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    private func row(_ name: String = "CHATEAU WDG HERBICIDE") -> ChemicalSearchRow {
        ChemicalSearchRow(
            result: ChemicalSearchResult(
                name: name,
                brand: "Sumitomo Chemical Australia",
                registrationNumber: "80647",
                source: ChemicalSearchResult.officialRegisterSource
            ),
            tier: .officialRegister,
            existing: nil
        )
    }

    // MARK: - 1. Lookup → coordinator

    @Test("A lookup's server options survive decode with key and order intact")
    func lookupCarriesServerOptions() throws {
        let lookup = try decode(Self.chateauLookupJSON)
        let options = try #require(lookup.defaultRateOptions)
        let option = try #require(options.validOptions(.perHectare).first)

        #expect(option.optionKey == "default_option_v1_dd81178fa70649ce9a097ad840805834")
        // Verbatim: the server's order, not this client's idea of tidy.
        #expect(option.rateIds == ["rate_v1_zeta", "rate_v1_alpha"])
        #expect(option.unit == "g")
        #expect(option.minValue == 560)
        #expect(option.maxValue == 700)
    }

    @Test("Hand-off carries the server options to the review state")
    func handOffCarriesServerOptions() throws {
        let coordinator = ChemicalLookupCoordinator()
        let lookup = try decode(Self.chateauLookupJSON)
        coordinator.handOff(
            row(), lookup: lookup, country: "AU", existing: nil, vineyardId: Self.vineyardId
        )

        let carried = try #require(coordinator.reviewDefaultRateOptions)
        let option = try #require(carried.validOptions(.perHectare).first)
        #expect(option.optionKey == "default_option_v1_dd81178fa70649ce9a097ad840805834")
        #expect(option.rateIds == ["rate_v1_zeta", "rate_v1_alpha"])
        #expect(coordinator.reviewDraft != nil)
    }

    /// A degraded hand-off after a resolved one must not leave the previous
    /// product's identities behind: they would attach one label's register
    /// rates to a different product.
    @Test("A degraded hand-off clears any options carried by an earlier one")
    func degradedHandOffClearsServerOptions() throws {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: try decode(Self.chateauLookupJSON),
            country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        #expect(coordinator.reviewDefaultRateOptions != nil)

        coordinator.handOff(
            row("SWITCH FUNGICIDE"),
            lookup: nil,
            country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        #expect(coordinator.reviewDefaultRateOptions == nil)
    }

    @Test("Finishing the review clears the transient server options")
    func finishReviewClearsServerOptions() throws {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: try decode(Self.chateauLookupJSON),
            country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        #expect(coordinator.reviewDefaultRateOptions != nil)

        coordinator.finishReview()
        #expect(coordinator.reviewDefaultRateOptions == nil)
        #expect(coordinator.reviewDraft == nil)
    }

    // MARK: - 2. Coordinator → review session

    @Test("A review session built from a lookup offers the server's option")
    func sessionOffersServerOption() throws {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: try decode(Self.chateauLookupJSON),
            country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        let draft = try #require(coordinator.reviewDraft)

        let session = ChemicalReviewSession.make(
            chemical: nil,
            prefill: draft,
            fallbackCountry: "AU",
            serverDefaultRateOptions: coordinator.reviewDefaultRateOptions
        )

        let option = try #require(session.defaultRatePlan.group(.perHectare).options.first)
        let server = try #require(option.server)
        #expect(server.optionKey == "default_option_v1_dd81178fa70649ce9a097ad840805834")
        #expect(server.rateIds == ["rate_v1_zeta", "rate_v1_alpha"])
        #expect(option.isLabelRange)
    }

    /// The re-search path replaces the product, so it must replace the
    /// identities too rather than merging them.
    @Test("Re-searching a product adopts the new lookup's server options")
    func reSearchAdoptsNewServerOptions() throws {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: try decode(Self.chateauLookupJSON),
            country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        let reviewed = try #require(coordinator.reviewDraft)

        var session = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        #expect(session.serverDefaultRateOptions == nil)

        session.apply(
            reviewed: reviewed,
            serverDefaultRateOptions: coordinator.reviewDefaultRateOptions,
            fallbackCountry: "AU"
        )
        let option = try #require(session.defaultRatePlan.group(.perHectare).options.first)
        #expect(option.server?.optionKey == "default_option_v1_dd81178fa70649ce9a097ad840805834")
    }

    // MARK: - 3. The persisted slot

    @Test("Confirming the offered option persists the server identity verbatim")
    func confirmedDefaultCopiesServerIdentity() throws {
        let coordinator = ChemicalLookupCoordinator()
        let lookup = try decode(Self.chateauLookupJSON)
        coordinator.handOff(
            row(), lookup: lookup, country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        let draft = try #require(coordinator.reviewDraft)
        let session = ChemicalReviewSession.make(
            chemical: nil,
            prefill: draft,
            fallbackCountry: "AU",
            serverDefaultRateOptions: coordinator.reviewDefaultRateOptions
        )
        let option = try #require(session.defaultRatePlan.group(.perHectare).options.first)

        let stored = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option,
                basis: .perHectare,
                grapevineUses: session.grapevineUses,
                confirmedValue: 620
            )
        )

        #expect(stored.optionKey == "default_option_v1_dd81178fa70649ce9a097ad840805834")
        // Byte-for-byte, in the SERVER's order.
        #expect(stored.rateIds == ["rate_v1_zeta", "rate_v1_alpha"])
        #expect(stored.basis == "per_hectare")
        // The LABEL's unit, never the pack or inventory unit.
        #expect(stored.unit == "g")
        #expect(stored.value == 620)
        #expect(stored.minValue == 560)
        #expect(stored.maxValue == 700)
        #expect(stored.source == "operator")
    }

    @Test("The confirmed default survives save and reload unchanged")
    func confirmedDefaultRoundTrips() throws {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.handOff(
            row(),
            lookup: try decode(Self.chateauLookupJSON),
            country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        let draft = try #require(coordinator.reviewDraft)
        let session = ChemicalReviewSession.make(
            chemical: nil,
            prefill: draft,
            fallbackCountry: "AU",
            serverDefaultRateOptions: coordinator.reviewDefaultRateOptions
        )
        let option = try #require(session.defaultRatePlan.group(.perHectare).options.first)
        let slot = try #require(
            StoredChemicalDefaultRate.confirmed(
                option: option, basis: .perHectare,
                grapevineUses: session.grapevineUses, confirmedValue: 620
            )
        )
        let chemical = SavedChemical(
            name: "CHATEAU WDG HERBICIDE",
            defaultRates: StoredChemicalDefaultRates().withSlot(.perHectare, slot)
        )

        let data = try JSONEncoder().encode(chemical)
        let reloaded = try JSONDecoder().decode(SavedChemical.self, from: data)
        let reloadedSlot = try #require(reloaded.defaultRates?.perHectare)
        #expect(reloadedSlot.optionKey == "default_option_v1_dd81178fa70649ce9a097ad840805834")
        #expect(reloadedSlot.rateIds == ["rate_v1_zeta", "rate_v1_alpha"])
        #expect(reloadedSlot.value == 620)
        #expect(reloadedSlot.unit == "g")
    }

    // MARK: - 4. Fail closed

    /// A server with no options block leaves the operator with no canonical
    /// choice. That is a refusal with a visible consequence — the review screen
    /// reports the missing rate and offers the corrective actions — and it is
    /// strictly better than a key this device invented, which would look
    /// authoritative everywhere and match nothing.
    @Test("A lookup without server options offers nothing to confirm")
    func lookupWithoutServerOptionsFailsClosed() throws {
        let coordinator = ChemicalLookupCoordinator()
        let lookup = try decode(Self.optionlessLookupJSON)
        #expect(lookup.defaultRateOptions == nil)

        coordinator.handOff(
            row(), lookup: lookup, country: "AU", existing: nil, vineyardId: Self.vineyardId
        )
        #expect(coordinator.reviewDefaultRateOptions == nil)

        let draft = try #require(coordinator.reviewDraft)
        let session = ChemicalReviewSession.make(
            chemical: nil,
            prefill: draft,
            fallbackCountry: "AU",
            serverDefaultRateOptions: coordinator.reviewDefaultRateOptions
        )
        // The label rate is still on the record and still readable — only the
        // canonical CHOICE is unavailable.
        #expect(!session.grapevineUses.isEmpty)

        // Whatever the screen shows for display, nothing can be persisted.
        for option in session.defaultRatePlan.group(.perHectare).options {
            #expect(option.server == nil)
            #expect(
                StoredChemicalDefaultRate.confirmed(
                    option: option, basis: .perHectare, grapevineUses: session.grapevineUses
                ) == nil
            )
        }
    }

    /// Manual entry never went near the register, so it has no server answer.
    @Test("Manual entry carries no server options")
    func manualEntryHasNoServerOptions() {
        let coordinator = ChemicalLookupCoordinator()
        coordinator.showManualEntry = true
        #expect(coordinator.reviewDefaultRateOptions == nil)

        let session = ChemicalReviewSession.make(
            chemical: nil, prefill: nil, fallbackCountry: "AU"
        )
        #expect(session.serverDefaultRateOptions == nil)
    }

    /// A malformed option is discarded WHOLE, never repaired into something
    /// that looks canonical.
    @Test("A malformed server option is discarded rather than mended")
    func malformedServerOptionIsDiscarded() throws {
        let json = """
        {
          "name": "CHATEAU WDG HERBICIDE",
          "default_rate_options": {
            "per_hectare": [
              {
                "option_key": "default_option_v1_dd81178fa70649ce9a097ad840805834",
                "rate_ids": ["11111111-2222-3333-4444-555555555555"],
                "basis": "per_hectare",
                "unit": "g",
                "min_value": 560,
                "max_value": 700
              }
            ]
          }
        }
        """
        let lookup = try decode(json)
        let options = try #require(lookup.defaultRateOptions)
        // A UUID cites a row, not a printed direction, so the option is unusable.
        #expect(options.validOptions(.perHectare).isEmpty)
        #expect(options.isEmpty)
    }
}
