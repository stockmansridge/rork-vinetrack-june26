import Foundation
import Testing
@testable import VineTrack

/// LD-3.1 — an EXISTING Saved Chemical carrying the old register-taxonomy
/// wording must pick up the corrected label wording when the operator
/// deliberately re-verifies it.
///
/// # Why this file exists
///
/// LD-3 fixed the server: `chemical-info-lookup` now serves the wording the
/// approved label actually prints ("Blackspot", "Phomopsis Cane and Leaf
/// spot") instead of the register's pest taxonomy ("BLACK SPOT -
/// COLLETOTRICHUM ACUTATUM", "LEAF SPOT - ALTERNARIA CERCOSPORA"). That fix
/// only reaches a record already sitting in an operator's Chemical Store if
/// the refresh path REPLACES the stale authority-derived uses rather than
/// merging them — and a merge keyed on the use's own identity
/// (`crop|targetRaw`) would not have matched the renamed uses at all, leaving
/// a record showing five uses: three correct and two stale ghosts.
///
/// There is deliberately NO migration and NO launch-time rewrite. Existing
/// records correct themselves when, and only when, the operator re-verifies.
/// These tests drive the real production sequence for that:
///
/// ```text
/// ChemicalsManagementView  ⋯ row menu → "Re-verify"
///   → ChemicalReverifyFlowView.run()
///   → ChemicalInfoService.lookupStructured        (the Edge Function)
///   → ChemicalStructuredLookup.intelligence()     (candidate)
///   → ChemicalReverifyFlow.resolve                (classify)
///   → ChemicalReverification.apply                (reconcile)
///   → ChemicalReverifyFlow.accepted               (write shape)
///   → store.updateSavedChemical                   (persist)
///   → ChemicalReviewSession.make                  (reopen)
/// ```
///
/// Everything except the two I/O ends — the network call and the store write
/// — is exercised here as production runs it. `ChemicalReverifyFlowView` holds
/// no rule of its own by design, so this covers the real decision path rather
/// than a parallel test-only one.
struct ChemicalReverifyTargetWordingTests {

    private static let vineyardId = UUID(uuidString: "7B0F0C2E-1A44-4C0B-9E77-1B7C1D9A5E10")!
    private static let chemicalId = UUID(uuidString: "2C6E9A31-55B4-4F0E-9A2D-0E7C4B1A8F22")!

    // MARK: - The stale record, as it sits in a real Chemical Store today

    /// DITHANE RAINSHIELD NEO TEC FUNGICIDE, APVMA 59688, saved BEFORE LD-3.
    ///
    /// The four register-worded uses TestFlight was showing, plus the operator's
    /// own data: their notes, their pack pricing, their stock count, their
    /// application notes. A refresh is allowed to correct the label facts. It is
    /// not allowed to touch any of the rest.
    private func staleRecord() -> SavedChemical {
        let uses: [ChemicalRegisteredUse] = [
            ChemicalRegisteredUse(
                crop: "GRAPEVINE",
                targetRaw: "BLACK SPOT - COLLETOTRICHUM ACUTATUM",
                withholdingPeriodDays: 30,
                provenance: ["claim": "manufacturer_label", "withholding_period": "manufacturer_label"]
            ),
            ChemicalRegisteredUse(
                crop: "GRAPEVINE",
                targetRaw: "LEAF SPOT - ALTERNARIA CERCOSPORA",
                withholdingPeriodDays: 30,
                provenance: ["claim": "manufacturer_label", "withholding_period": "manufacturer_label"]
            ),
            ChemicalRegisteredUse(
                crop: "GRAPEVINE",
                targetRaw: "PHOMOPSIS CANE",
                rates: [
                    ChemicalLabelRate(
                        basis: .rangePer100Litres,
                        minValue: 150,
                        maxValue: 200,
                        unit: "g",
                        rawText: "150 to 200 g"
                    )
                ],
                withholdingPeriodDays: 30,
                provenance: [
                    "claim": "manufacturer_label",
                    "rates": "manufacturer_label",
                    "withholding_period": "manufacturer_label",
                ]
            ),
            ChemicalRegisteredUse(
                crop: "GRAPEVINE",
                targetRaw: "DOWNY MILDEW",
                withholdingPeriodDays: 30,
                provenance: ["claim": "manufacturer_label", "withholding_period": "manufacturer_label"]
            ),
        ]

        let intelligence = ChemicalIntelligence(
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Mancozeb",
                    concentration: 750,
                    concentrationUnit: .gramsPerKilogram,
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "M3"),
                    groupSource: .authoritativeClassification,
                    identitySource: .officialRegister
                )
            ],
            registration: ChemicalRegistration(
                countryCode: "AU",
                scheme: .apvma,
                registrationNumber: "59688",
                registrant: "UPL AUSTRALIA PTY LTD",
                registeredProductName: "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
                labelReference: "https://elabels.apvma.gov.au/59688ELBL.pdf"
            ),
            registeredUses: uses,
            productCategory: "fungicide"
        )

        return SavedChemical(
            id: Self.chemicalId,
            vineyardId: Self.vineyardId,
            name: "Dithane Rainshield Neo Tec Fungicide",
            unit: .kilograms,
            manufacturer: "UPL Australia Pty Ltd",
            notes: "Two drums left in the far shed. Ask Dave before opening the new pallet.",
            activeIngredient: "Mancozeb 750 g/kg",
            labelURL: "https://elabels.apvma.gov.au/59688ELBL.pdf",
            productCategory: "fungicide",
            productForm: "solid",
            packSize: 10,
            packUnit: "kg",
            pricePerPack: 148.50,
            inventoryQuantity: 3,
            inventoryUnit: "packs",
            applicationNotes: "Budburst spray — start on the western blocks.",
            chemicalIntelligence: intelligence
        )
    }

    // MARK: - What the corrected Edge Function now answers

    /// The LD-3 response for 59688: three uses, worded as the label prints
    /// them, the register taxonomy demoted to `register_target_raw` /
    /// `target_synonyms`, and Terra's 200 g/100 L still quarantined.
    private let correctedLookupJSON = """
    {
      "product_name": "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
      "product_category": "fungicide",
      "form_type": "solid",
      "product_url": null,
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "59688",
        "registrant": "UPL AUSTRALIA PTY LTD",
        "registered_product_name": "DITHANE RAINSHIELD NEO TEC FUNGICIDE",
        "label_reference": "https://elabels.apvma.gov.au/59688ELBL.pdf",
        "label_version": null
      },
      "active_ingredients": [
        {
          "name": "Mancozeb",
          "concentration": 750,
          "concentration_unit": "g/kg",
          "activity_group": {
            "scheme": "frac",
            "code": "M3",
            "common_name": "Multi-site / Dithiocarbamate"
          },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "activity_groups": ["M3"],
      "activity_group_scheme": "frac",
      "registered_uses": [
        {
          "crop": "GRAPEVINE",
          "target_raw": "Blackspot",
          "register_target_raw": "BLACK SPOT - COLLETOTRICHUM ACUTATUM",
          "rates": [],
          "withholding_period_days": 30,
          "provenance": { "claim": "manufacturer_label", "withholding_period": "manufacturer_label" }
        },
        {
          "crop": "GRAPEVINE",
          "target_raw": "Phomopsis Cane and Leaf spot",
          "register_target_raw": "PHOMOPSIS CANE",
          "target_synonyms": ["LEAF SPOT - ALTERNARIA CERCOSPORA"],
          "rates": [
            {
              "label": "",
              "basis": "range_per_100_litres",
              "min_value": 150,
              "max_value": 200,
              "unit": "g",
              "raw_text": "150 to 200 g"
            }
          ],
          "withholding_period_days": 30,
          "provenance": {
            "claim": "manufacturer_label",
            "rates": "manufacturer_label",
            "withholding_period": "manufacturer_label"
          }
        },
        {
          "crop": "GRAPEVINE",
          "target_raw": "Downy mildew",
          "register_target_raw": "DOWNY MILDEW",
          "rates": [],
          "withholding_period_days": 30,
          "provenance": { "claim": "manufacturer_label", "withholding_period": "manufacturer_label" }
        }
      ],
      "ai_suggested_uses": [
        {
          "crop": "Grapevines",
          "target_raw": "Downy mildew",
          "rates": [
            {
              "label": "",
              "basis": "per_100_litres",
              "value": 200,
              "unit": "g",
              "raw_text": "Grapevines — Blackspot; Downy mildew — 200 g per 100 L."
            }
          ]
        }
      ],
      "label_rate_bases": ["range_per_100_litres"],
      "field_provenance": {
        "registration": "official_register",
        "label_reference": "official_register",
        "active_ingredients": "official_register",
        "label_rates": "manufacturer_label",
        "withholding_periods": "manufacturer_label"
      },
      "match_source": "authoritative_candidate",
      "verification": {
        "status": "partially_verified",
        "verified_at": "2026-08-24T04:11:07.882Z",
        "sources": [
          {
            "kind": "official_register",
            "name": "APVMA PubCRIS",
            "reference": "https://portal.apvma.gov.au/pubcris?p=59688",
            "retrieved_at": "2026-08-24T04:11:07.882Z"
          },
          {
            "kind": "manufacturer_label",
            "name": "APVMA approved label",
            "reference": "https://elabels.apvma.gov.au/59688ELBL.pdf",
            "retrieved_at": "2026-08-24T04:11:07.882Z"
          }
        ],
        "conflicts": [],
        "unresolved_fields": []
      },
      "discovery": {
        "adapter": "apvma",
        "outcome": "resolved",
        "registration_number": "59688"
      },
      "activity_group_table_version": 3,
      "schema_version": 1
    }
    """

    // MARK: - Harness: the production sequence, minus the two I/O ends

    private func candidate() throws -> ChemicalIntelligence {
        try JSONDecoder()
            .decode(ChemicalStructuredLookup.self, from: Data(correctedLookupJSON.utf8))
            .intelligence()
    }

    /// Everything `ChemicalReverifyFlowView` does between the lookup replying
    /// and `store.updateSavedChemical` being handed a record.
    private func reverified(_ chemical: SavedChemical) throws -> SavedChemical {
        switch ChemicalReverifyFlow.resolve(chemical: chemical, candidate: try candidate()) {
        case let .changes(_, _, outcome):
            return ChemicalReverifyFlow.accepted(chemical, with: outcome)
        case let .current(_, refreshed):
            Issue.record("the corrected wording must register as a CHANGE, not a no-change result")
            return refreshed.map { ChemicalReverifyFlow.confirmed(chemical, with: $0) } ?? chemical
        case let .unusable(reason):
            Issue.record("the lookup was classified unusable: \(reason)")
            return chemical
        }
    }

    /// Persist and reopen, through the real Codable shape and session builder.
    private func reopened(_ chemical: SavedChemical) throws -> ChemicalReviewSession {
        let data = try JSONEncoder().encode(chemical)
        let reloaded = try JSONDecoder().decode(SavedChemical.self, from: data)
        return ChemicalReviewSession.make(chemical: reloaded, prefill: nil, fallbackCountry: "AU")
    }

    private func use(
        _ session: ChemicalReviewSession,
        target: String
    ) throws -> ChemicalManualUseDraft {
        try #require(
            session.chemistryDraft.uses.first { $0.targetRaw == target },
            "no use worded \"\(target)\" — got: \(session.chemistryDraft.uses.map(\.targetRaw))"
        )
    }

    // MARK: - 0. The action is actually reachable on this record

    @Test("Re-verify is offered on the stale record, so the correction has a route to it")
    func reverifyIsOfferedOnTheStaleRecord() {
        let chemical = staleRecord()
        #expect(ChemicalReverification.isOffered(for: chemical, fallbackCountry: "AU"))
        #expect(ChemicalReverification.unavailableReason(for: chemical, fallbackCountry: "AU") == nil)

        // And it re-checks the registration it already holds rather than
        // starting a fresh brand-name search.
        let plan = ChemicalReverification.plan(for: chemical, fallbackCountry: "AU")
        #expect(plan.registrationNumber == "59688")
        #expect(plan.countryCode == "AU")
        #expect(plan.lookupQuery.contains("59688"))
    }

    @Test("The stale wording is classified as a real change, not evidence-only")
    func staleWordingIsARealChange() throws {
        let diff = ChemicalIntelligenceDiffer.diff(
            current: ChemicalReverifyFlow.currentIntelligence(staleRecord()),
            candidate: try candidate()
        )
        #expect(!diff.isEmpty)
        #expect(!ChemicalReverification.isNoChangeResult(diff))
    }

    // MARK: - 1. The corrected three-use payload lands

    @Test("After refresh, reopening the record shows exactly the three label uses")
    func refreshReplacesTheStaleUses() throws {
        let session = try reopened(try reverified(staleRecord()))

        #expect(session.chemistryDraft.uses.count == 3)
        #expect(
            Set(session.chemistryDraft.uses.map(\.targetRaw))
                == ["Blackspot", "Downy mildew", "Phomopsis Cane and Leaf spot"]
        )
    }

    @Test("Each refreshed use carries its own rate and the label's 30-day WHP")
    func refreshedUsesKeepTheirOwnValues() throws {
        let session = try reopened(try reverified(staleRecord()))

        for target in ["Blackspot", "Downy mildew"] {
            let entry = try use(session, target: target)
            #expect(entry.rates.isEmpty, "\(target) must carry no registered rate")
            #expect(entry.withholdingPeriodDaysText == "30", "\(target) WHP")
        }

        let phomopsis = try use(session, target: "Phomopsis Cane and Leaf spot")
        #expect(phomopsis.rates.count == 1)
        let rate = try #require(phomopsis.rates.first)
        #expect(rate.basis == .rangePer100Litres)
        #expect(rate.minText == "150")
        #expect(rate.maxText == "200")
        #expect(rate.unit == "g")
        #expect(phomopsis.withholdingPeriodDaysText == "30")
        #expect(ChemicalManualEntry.displayRate(for: rate) == "150–200 g/100 L")
    }

    @Test("No register taxonomy remains operator-facing after the refresh")
    func taxonomyIsGoneFromTheOperatorFacingWording() throws {
        let session = try reopened(try reverified(staleRecord()))

        for draft in session.chemistryDraft.uses {
            #expect(
                !draft.targetRaw.localizedCaseInsensitiveContains("COLLETOTRICHUM"),
                "stale taxonomy survived: \(draft.targetRaw)"
            )
            #expect(
                !draft.targetRaw.localizedCaseInsensitiveContains("ALTERNARIA"),
                "stale taxonomy survived: \(draft.targetRaw)"
            )
            #expect(
                !draft.targetRaw.contains(" - "),
                "register \"<common> - <scientific>\" shape survived: \(draft.targetRaw)"
            )
        }
    }

    @Test("No rate moves between uses, and no AI rate becomes canonical")
    func noRateMovesAndNoAIRateIsAdopted() throws {
        let refreshed = try reverified(staleRecord())
        let uses = try #require(refreshed.chemicalIntelligence?.registeredUses)

        // Exactly one use owns a rate — the one printed cell.
        #expect(uses.filter { !$0.rates.isEmpty }.count == 1)
        #expect(uses.first { !$0.rates.isEmpty }?.targetRaw == "Phomopsis Cane and Leaf spot")

        // Terra's flat 200 g/100 L is nowhere in the canonical uses. The
        // Phomopsis RANGE legitimately ends at 200, so this looks for the
        // single-value shape the AI proposed, not merely the number.
        for entry in uses {
            for rate in entry.rates {
                #expect(
                    !(rate.basis == .per100Litres && rate.value == 200),
                    "the AI's flat 200 g/100 L became canonical on \(entry.targetRaw)"
                )
            }
        }
    }

    // MARK: - 2. Authority-owned facts refreshed; identity intact

    @Test("Product identity, chemistry and label reference all survive the refresh")
    func authorityIdentityIsPreserved() throws {
        let refreshed = try reverified(staleRecord())
        let session = try reopened(refreshed)

        #expect(session.chemistryDraft.registrationNumber == "59688")
        #expect(session.chemistryDraft.registrationScheme == .apvma)
        #expect(session.name == "Dithane Rainshield Neo Tec Fungicide")
        #expect(refreshed.manufacturer == "UPL Australia Pty Ltd")
        #expect(refreshed.labelURL == "https://elabels.apvma.gov.au/59688ELBL.pdf")

        #expect(session.chemistryDraft.actives.count == 1)
        let active = try #require(session.chemistryDraft.actives.first)
        #expect(active.name == "Mancozeb")
        #expect(active.concentrationText == "750")
        #expect(active.concentrationUnit == .gramsPerKilogram)
        #expect(active.scheme == .frac)
        #expect(active.groupCode == "M3")
    }

    // MARK: - 3. Operator-owned data is not collateral damage

    @Test("The operator's own fields are untouched by an authority refresh")
    func operatorOwnedFieldsArePreserved() throws {
        let before = staleRecord()
        let after = try reverified(before)

        // Identity and ownership.
        #expect(after.id == before.id)
        #expect(after.vineyardId == before.vineyardId)

        // Everything the operator typed or counted.
        #expect(after.notes == before.notes)
        #expect(after.applicationNotes == before.applicationNotes)
        #expect(after.inventoryQuantity == before.inventoryQuantity)
        #expect(after.inventoryUnit == before.inventoryUnit)
        #expect(after.pricePerPack == before.pricePerPack)
        #expect(after.packSize == before.packSize)
        #expect(after.packUnit == before.packUnit)
        #expect(after.isActive == before.isActive)
    }

    // MARK: - 4. History is evidence — P9/P10

    @Test("A completed spray record is byte-identical after the chemical is refreshed")
    func historicalSprayRecordIsUntouched() throws {
        // A completed application, frozen against the OLD product state: the
        // old display name, the old chemistry, and the rate actually used.
        let snapshot = ChemicalLineSnapshot(
            savedChemicalId: Self.chemicalId.uuidString,
            productName: "Dithane Rainshield Neo Tec Fungicide",
            activeIngredients: [
                ChemicalActiveIngredient(
                    name: "Mancozeb",
                    concentration: 750,
                    concentrationUnit: .gramsPerKilogram,
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "M3"),
                    groupSource: .authoritativeClassification,
                    identitySource: .officialRegister
                )
            ],
            activityGroupCodes: ["M3"],
            verificationStatus: .unverified,
            registrationIdentityKey: "AU:apvma:59688",
            countryCode: "AU",
            legacyChemicalGroup: "M3",
            capturedAt: Date(timeIntervalSince1970: 1_770_000_000)
        )
        let line = SprayChemical(
            id: UUID(uuidString: "9F1D2A44-6B0C-4E3A-8D55-77A1C0F3B921")!,
            name: "Dithane Rainshield Neo Tec Fungicide",
            volumePerTank: 0.525,
            ratePerHa: 0,
            ratePer100L: 150,
            costPerUnit: 0.01485,
            unit: .kilograms,
            rateBasis: .waterVolume,
            savedChemicalId: Self.chemicalId,
            chemicalSnapshot: snapshot
        )
        let record = SprayRecord(
            id: UUID(uuidString: "4A77E0B2-1C39-4D8E-B0A6-2F5C9D8E3311")!,
            vineyardId: Self.vineyardId,
            tanks: [
                SprayTank(
                    id: UUID(uuidString: "5B88F1C3-2D4A-4E9F-A1B7-3E6D0C9F4422")!,
                    tankNumber: 1,
                    waterVolume: 175,
                    sprayRatePerHa: 357.142857,
                    concentrationFactor: 1,
                    chemicals: [line]
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(record)

        // Run the entire refresh against the current Chemical Store record.
        let refreshedChemical = try reverified(staleRecord())
        #expect(refreshedChemical.chemicalIntelligence?.registeredUses.count == 3)

        // The historical record is not an input to, or an output of, any of it.
        let after = try encoder.encode(record)
        #expect(before == after, "refreshing today's chemical rewrote a completed spray record")

        // And spelled out: the frozen line still says what was applied.
        let frozen = try #require(record.tanks.first?.chemicals.first)
        #expect(frozen.name == "Dithane Rainshield Neo Tec Fungicide")
        #expect(frozen.ratePer100L == 150)
        #expect(frozen.rateBasis == .waterVolume)
        #expect(frozen.savedChemicalId == Self.chemicalId)
        #expect(frozen.chemicalSnapshot?.activityGroupCodes == ["M3"])
        #expect(frozen.chemicalSnapshot?.registrationIdentityKey == "AU:apvma:59688")
        #expect(frozen.chemicalSnapshot?.verificationStatus == .unverified)
    }

    // MARK: - 5. No silent bulk update

    @Test("Nothing corrects itself until the operator re-verifies")
    func staleRecordIsNotSelfCorrecting() throws {
        // Merely reading and reopening a stale record changes nothing: there is
        // no migration, no launch-time rewrite, no background refresh.
        let stale = staleRecord()
        let session = try reopened(stale)

        #expect(session.chemistryDraft.uses.count == 4)
        #expect(
            session.chemistryDraft.uses.contains {
                $0.targetRaw == "BLACK SPOT - COLLETOTRICHUM ACUTATUM"
            }
        )
    }
}
