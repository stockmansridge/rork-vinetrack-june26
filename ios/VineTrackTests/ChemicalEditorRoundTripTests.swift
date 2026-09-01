import Foundation
import Testing

@testable import VineTrack

/// The editor round trip must not launder data (tasks §4, §5, §10, §11).
///
/// # Why this suite exists
///
/// Every protection built in the previous stages lives in the *decoded* model.
/// The editor is a second representation — `ChemicalManualDraft` — and anything
/// it fails to carry is silently destroyed the moment an operator opens a
/// record and presses Save. That is the most-travelled path in the whole
/// feature, so it is the one place a data-loss bug is guaranteed to be hit.
///
/// The specific defect found here: `ChemicalManualRateDraft` had no
/// `conditionIsAmbiguous` field at all. Ambiguous rates decoded correctly,
/// then became *confirmed* rates on the first save — destroying the §5
/// protection precisely when it mattered.
struct ChemicalEditorRoundTripTests {

    // MARK: - Helpers

    /// Rebuild the structured record the way Save does: draft → intelligence.
    private func persist(_ draft: ChemicalManualDraft) -> ChemicalIntelligence {
        ChemicalManualEntry.proposedIntelligence(from: draft, existing: nil)
    }

    /// Read a record into the editor, then write it straight back out.
    private func roundTrip(_ intelligence: ChemicalIntelligence) -> ChemicalIntelligence {
        var chemical = SavedChemical(name: "HORTITROL WINTER OIL")
        chemical.chemicalIntelligence = intelligence
        let draft = ChemicalManualEntry.draft(from: chemical, fallbackCountry: "AU")
        return persist(draft)
    }

    private func rate(
        _ value: Double,
        basis: ChemicalLabelRateBasis = .per100Litres,
        unit: String = "L",
        label: String = "",
        ambiguous: Bool = false
    ) -> ChemicalLabelRate {
        ChemicalLabelRate(
            label: label, basis: basis, value: value, unit: unit,
            conditionIsAmbiguous: ambiguous
        )
    }

    private func intelligence(
        actives: [ChemicalActiveIngredient] = [],
        rates: [ChemicalLabelRate]
    ) -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: actives,
            registration: nil,
            verification: ChemicalVerification(),
            registeredUses: [
                ChemicalRegisteredUse(
                    crop: "Grapevines", targetRaw: "Grapevine scale", rates: rates
                )
            ],
            productCategory: "insecticide"
        )
    }

    /// The grapevine use from a persisted record.
    private func grapeUse(_ intel: ChemicalIntelligence) throws -> ChemicalRegisteredUse {
        try #require(intel.registeredUses.statedUses.viticultural.first)
    }

    // MARK: - Ambiguity survives the round trip

    @Test("An ambiguous rate decodes into the editor as ambiguous")
    func ambiguousRateDecodesIntoDraft() throws {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ])
        let draft = ChemicalManualEntry.draft(from: chemical, fallbackCountry: "AU")
        let use = try #require(draft.uses.first { $0.isViticultural })

        #expect(use.rates.count == 2)
        #expect(use.rates.allSatisfy { $0.conditionIsAmbiguous })
        // Nothing has been resolved yet, so both still need an answer.
        #expect(use.rates.allSatisfy { $0.needsConditionChoice })
    }

    @Test("Saving without resolving the condition PRESERVES the ambiguity")
    func savingUnresolvedPreservesAmbiguity() throws {
        // The defect this suite was written for: open, save, and the flag was
        // gone — an unproven association silently became a confirmed one.
        let restored = roundTrip(intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ]))
        let use = try grapeUse(restored)

        #expect(use.rates.count == 2, "both rates must survive")
        #expect(use.rates.allSatisfy { $0.conditionIsAmbiguous },
                "opening and saving a record must not confirm what the label never stated")
        #expect(use.hasAmbiguousRateCondition)
    }

    @Test("Editing the VALUE does not clear the ambiguity")
    func editingValueDoesNotResolve() throws {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ])
        var draft = ChemicalManualEntry.draft(from: chemical, fallbackCountry: "AU")

        // Correcting a number says nothing about WHEN the rate applies.
        draft.uses[0].rates[0].valueText = "2.5"
        let use = try grapeUse(persist(draft))

        #expect(use.rates.contains { $0.value == 2.5 })
        #expect(use.rates.allSatisfy { $0.conditionIsAmbiguous },
                "changing a number must not resolve a condition")
    }

    @Test("Editing the UNIT does not clear the ambiguity")
    func editingUnitDoesNotResolve() throws {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ])
        var draft = ChemicalManualEntry.draft(from: chemical, fallbackCountry: "AU")

        draft.uses[0].rates[0].unit = "mL"
        let use = try grapeUse(persist(draft))
        #expect(use.rates.allSatisfy { $0.conditionIsAmbiguous },
                "changing a unit must not resolve a condition")
    }

    @Test("Changing the BASIS does not clear the ambiguity")
    func editingBasisDoesNotResolve() throws {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ])
        var draft = ChemicalManualEntry.draft(from: chemical, fallbackCountry: "AU")

        draft.uses[0].rates[0].basis = .perHectare
        let use = try grapeUse(persist(draft))
        #expect(use.rates.allSatisfy { $0.conditionIsAmbiguous })
    }

    @Test("Naming the condition CLEARS the ambiguity for that rate only")
    func namingConditionResolves() throws {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ])
        var draft = ChemicalManualEntry.draft(from: chemical, fallbackCountry: "AU")

        // Naming the condition IS the answer the flag asks for.
        draft.uses[0].rates[0].label = "Dilute spraying"
        let use = try grapeUse(persist(draft))

        let resolved = try #require(use.rates.first { $0.label == "Dilute spraying" })
        #expect(!resolved.conditionIsAmbiguous, "a named condition is a resolved condition")

        // The sibling is a separate question and stays open.
        let untouched = try #require(use.rates.first { $0.label.isEmpty })
        #expect(untouched.conditionIsAmbiguous,
                "resolving one rate must not silently resolve its siblings")
    }

    @Test("Whitespace is not a condition")
    func whitespaceDoesNotResolve() {
        let draft = ChemicalManualRateDraft(
            label: "   ", basis: .per100Litres, valueText: "2", unit: "L",
            conditionIsAmbiguous: true
        )
        #expect(!draft.isConditionResolved)
        #expect(draft.needsConditionChoice)
    }

    @Test("A rate that was never ambiguous is never reported as needing a choice")
    func unambiguousNeedsNothing() {
        let draft = ChemicalManualRateDraft(
            basis: .per100Litres, valueText: "2", unit: "L"
        )
        #expect(!draft.conditionIsAmbiguous)
        #expect(!draft.needsConditionChoice)
    }

    // MARK: - Multi-rate survival (§4)

    @Test("Multiple /100 L and /ha rates survive edit and save intact")
    func multiRateSurvivesRoundTrip() throws {
        let original = intelligence(rates: [
            rate(2, label: "Dilute spraying"),
            rate(3, label: "Concentrate spraying"),
            rate(4, basis: .perHectare, label: "Airblast"),
            ChemicalLabelRate(
                label: "Boom", basis: .rangePerHectare,
                minValue: 5, maxValue: 7, unit: "L"
            )
        ])
        let use = try grapeUse(roundTrip(original))

        #expect(use.rates.count == 4, "no rate may be lost in the round trip")
        #expect(use.ratesPer100L.count == 2)
        #expect(use.ratesPerHectare.count == 2)
        #expect(use.hasBothRateBases)

        // Each condition still belongs to its own rate.
        #expect(Set(use.rates.map(\.label))
            == ["Dilute spraying", "Concentrate spraying", "Airblast", "Boom"])

        // The range keeps both bounds — never flattened to a single value.
        let boom = try #require(use.rates.first { $0.label == "Boom" })
        #expect(boom.minValue == 5)
        #expect(boom.maxValue == 7)
        #expect(boom.value == nil)
    }

    @Test("The /100 L preference is presentation only — /ha still survives")
    func hectareRateIsNeverDiscarded() throws {
        let use = try grapeUse(roundTrip(intelligence(rates: [
            rate(2), rate(4, basis: .perHectare)
        ])))
        #expect(use.preferredRates.map(\.value) == [2], "/100 L leads")
        #expect(use.ratesPerHectare.map(\.value) == [4], "/ha is retained")
    }

    @Test("Two rates sharing a number under different conditions stay distinct")
    func sameNumberDifferentConditionsSurvive() throws {
        let use = try grapeUse(roundTrip(intelligence(rates: [
            rate(3, label: "Dilute spraying"),
            rate(3, label: "Concentrate spraying")
        ])))
        #expect(use.rates.count == 2, "collapsing these would delete a real distinction")
        #expect(Set(use.rates.map(\.id)).count == 2, "ids must not collide")
    }

    @Test("A verbatim-only rate survives with its wording")
    func verbatimRateSurvives() throws {
        let verbatim = ChemicalLabelRate(
            basis: .other, unit: "", rawText: "Apply as directed by an agronomist"
        )
        let use = try grapeUse(roundTrip(intelligence(rates: [verbatim])))
        #expect(use.rates.first?.rawText == "Apply as directed by an agronomist")
        // Still not a usable rate — the save contract must keep saying so.
        #expect(!use.hasUsableRate)
    }

    // MARK: - Resistance state (§10)

    @Test("A classified mixture keeps its state through edit and save")
    func classifiedStateSurvives() throws {
        let restored = roundTrip(intelligence(
            actives: [
                ChemicalActiveIngredient(
                    name: "Tebuconazole",
                    concentration: 200,
                    concentrationUnit: .gramsPerLitre,
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3")
                ),
                ChemicalActiveIngredient(
                    name: "Azoxystrobin",
                    concentration: 120,
                    concentrationUnit: .gramsPerLitre,
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "11")
                )
            ],
            rates: [rate(2)]
        ))

        #expect(ChemicalResistanceState.rollup(restored.activeIngredients) == .classified)
        #expect(restored.activeIngredients.count == 2)
        #expect(restored.activeIngredients.map(\.activityGroup?.code) == ["3", "11"])
        // Concentrations survive too — they are part of label identity.
        #expect(restored.activeIngredients.allSatisfy { $0.hasConcentration })
    }

    @Test("An explicit not-applicable active keeps not-applicable")
    func notApplicableStateSurvives() throws {
        let restored = roundTrip(intelligence(
            actives: [
                ChemicalActiveIngredient(
                    name: "Paraffinic oil",
                    activityGroup: ChemicalActivityGroup(scheme: .notApplicable, code: "")
                )
            ],
            rates: [rate(2)]
        ))
        #expect(ChemicalResistanceState.rollup(restored.activeIngredients) == .notApplicable)
    }

    @Test("An unclassified active stays UNRESOLVED, never not-applicable")
    func unresolvedNeverBecomesNotApplicable() throws {
        // The round trip must not turn honest ignorance into a positive
        // assertion that the product has no resistance group.
        let restored = roundTrip(intelligence(
            actives: [ChemicalActiveIngredient(name: "Mystery active")],
            rates: [rate(2)]
        ))
        #expect(ChemicalResistanceState.rollup(restored.activeIngredients) == .unresolved)
    }

    @Test("A half-classified mixture stays unresolved through the round trip")
    func partialMixtureStaysUnresolved() throws {
        let restored = roundTrip(intelligence(
            actives: [
                ChemicalActiveIngredient(
                    name: "Tebuconazole",
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3")
                ),
                ChemicalActiveIngredient(name: "Mystery active")
            ],
            rates: [rate(2)]
        ))
        #expect(ChemicalResistanceState.rollup(restored.activeIngredients) == .unresolved)
    }

    // MARK: - WHP / REI (§12)

    @Test("Null WHP and REI stay null through the round trip")
    func nullPeriodsStayNull() throws {
        let original = ChemicalIntelligence(
            activeIngredients: [],
            registration: nil,
            verification: ChemicalVerification(),
            registeredUses: [
                ChemicalRegisteredUse(
                    crop: "Grapevines", targetRaw: "Scale", rates: [rate(2)]
                )
            ],
            productCategory: "insecticide"
        )
        let use = try grapeUse(roundTrip(original))
        #expect(use.withholdingPeriodDays == nil, "a silent label must not become 0 days")
        #expect(use.reEntryPeriodHours == nil, "a silent label must not become 0 hours")
    }

    @Test("A stated zero WHP survives as zero, not as null")
    func statedZeroSurvives() throws {
        let original = ChemicalIntelligence(
            activeIngredients: [],
            registration: nil,
            verification: ChemicalVerification(),
            registeredUses: [
                ChemicalRegisteredUse(
                    crop: "Grapevines", targetRaw: "Scale", rates: [rate(2)],
                    withholdingPeriodDays: 0,
                    restrictions: "NOT REQUIRED WHEN USED AS DIRECTED"
                )
            ],
            productCategory: "insecticide"
        )
        let use = try grapeUse(roundTrip(original))
        // An authoritative zero is information and must not be erased either.
        #expect(use.withholdingPeriodDays == 0)
    }

    // MARK: - Session-level behaviour

    @Test("A session over an ambiguous record reports the pending choice")
    func sessionReportsPendingChoice() {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ])
        var session = ChemicalReviewSession.make(
            chemical: chemical, prefill: nil, fallbackCountry: "AU"
        )
        #expect(session.ratesNeedingConditionChoice == 2)

        // Naming one condition reduces the outstanding count by exactly one.
        session.chemistryDraft.uses[0].rates[0].label = "Dilute spraying"
        #expect(session.ratesNeedingConditionChoice == 1)
    }

    @Test("Ambiguous rates never block Save, but never auto-apply either")
    func ambiguityDoesNotBlockSave() {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(rates: [
            rate(2, ambiguous: true), rate(3, ambiguous: true)
        ])
        let session = ChemicalReviewSession.make(
            chemical: chemical, prefill: nil, fallbackCountry: "AU"
        )
        // The label genuinely states these rates, so the record is storable.
        #expect(session.isValid)
        // But a calculation must ask first.
        #expect(session.requiresRateConditionChoice)
    }

    @Test("The session exposes the resistance state the record will persist")
    func sessionExposesResistanceState() {
        var chemical = SavedChemical(name: "Product")
        chemical.chemicalIntelligence = intelligence(
            actives: [ChemicalActiveIngredient(name: "Mystery active")],
            rates: [rate(2)]
        )
        let session = ChemicalReviewSession.make(
            chemical: chemical, prefill: nil, fallbackCountry: "AU"
        )
        #expect(session.resistanceState == .unresolved)
    }

    // MARK: - Legacy repairability (§11 baseline rule)

    @Test("A legacy record's pre-existing faults stay repairable, not blocking")
    func legacyRecordRemainsRepairable() {
        // A pre-Chemical-Intelligence product: a name, a scalar rate, and no
        // structured use. Blocking Save would strand it — a record that cannot
        // be saved cannot be repaired.
        var legacy = SavedChemical(name: "Old product")
        legacy.ratePerHa = 2.5

        var session = ChemicalReviewSession.make(
            chemical: legacy, prefill: nil, fallbackCountry: "AU"
        )
        #expect(session.isValid, "\(session.blockingViolations.map(\.code))")
        #expect(!session.carriedOverViolations.isEmpty, "the gaps are still reported")
        #expect(session.blockingViolations.isEmpty)

        // Editing an unrelated field keeps it saveable.
        session.notes = "Bought from the co-op"
        #expect(session.isValid)
    }

    @Test("Carried-over issues are reported against their own section")
    func carriedOverIssuesAreLocalised() {
        var legacy = SavedChemical(name: "Old product")
        legacy.ratePerHa = 2.5
        let session = ChemicalReviewSession.make(
            chemical: legacy, prefill: nil, fallbackCountry: "AU"
        )
        // Each notice renders next to the section it concerns rather than as
        // one anonymous banner at the foot of the form.
        let useIssues = session.saveIssues(forField: "registered_uses")
        #expect(useIssues.contains { $0.violation.code == .grapevineUseMissing })
        #expect(useIssues.allSatisfy { $0.isCarriedOver })
    }

    @Test("A NEW fault on a legacy record still blocks")
    func newFaultOnLegacyRecordBlocks() {
        var legacy = SavedChemical(name: "Old product")
        legacy.ratePerHa = 2.5
        legacy.productCategory = "insecticide"
        var session = ChemicalReviewSession.make(
            chemical: legacy, prefill: nil, fallbackCountry: "AU"
        )
        #expect(session.isValid)

        // Clearing the name is a fault the record did not arrive with.
        session.name = "  "
        #expect(!session.isValid)
    }

    @Test("A brand-new record faces the full contract")
    func newRecordFacesFullContract() {
        var session = ChemicalReviewSession()
        session.name = "Brand new product"
        #expect(!session.isValid)
        #expect(session.blockingViolations.contains { $0.code == .grapevineUseMissing })
        // Nothing is forgiven, because there is no baseline to forgive.
        #expect(session.carriedOverViolations.isEmpty)
    }

    // MARK: - Idempotence

    @Test("A record read and written unchanged is unchanged")
    func roundTripIsIdempotent() throws {
        let original = intelligence(
            actives: [
                ChemicalActiveIngredient(
                    name: "Tebuconazole",
                    concentration: 200,
                    concentrationUnit: .gramsPerLitre,
                    activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3")
                )
            ],
            rates: [
                rate(2, label: "Dilute spraying"),
                rate(4, basis: .perHectare, label: "Airblast")
            ]
        )
        let once = roundTrip(original)
        let twice = roundTrip(once)

        // Second pass must be a no-op: a drifting round trip would rewrite a
        // grower's record every time they opened it.
        let a = try grapeUse(once)
        let b = try grapeUse(twice)
        #expect(a.rates.map(\.id) == b.rates.map(\.id))
        #expect(a.id == b.id)
        #expect(once.activeIngredients == twice.activeIngredients)
    }
}
