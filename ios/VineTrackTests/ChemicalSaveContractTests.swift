import Foundation
import Testing

@testable import VineTrack

/// Task §10/§11 — resistance state, and the mandatory save contract.
///
/// Two rules are being protected at once, and they pull in opposite
/// directions:
///
/// 1. VineTrack must not store a chemical it cannot USE — no grapevine rate
///    means no spray calculation, and saving it as though it were ready is
///    how an unusable product reaches the Spray Tool.
/// 2. VineTrack must not invent regulatory information to satisfy its own
///    validation. WHP, REI and the manufacturer URL stay optional and stay
///    null, because a label that is silent is not an incomplete record.
struct ChemicalSaveContractTests {

    // MARK: - Fixtures

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

    private func grapeUse(rates: [ChemicalLabelRate]) -> ChemicalRegisteredUse {
        ChemicalRegisteredUse(crop: "Grapevines", targetRaw: "Grapevine scale", rates: rates)
    }

    private func intelligence(
        actives: [ChemicalActiveIngredient] = [
            ChemicalActiveIngredient(
                name: "Paraffinic oil",
                activityGroup: ChemicalActivityGroup(scheme: .notApplicable, code: "")
            )
        ],
        uses: [ChemicalRegisteredUse]? = nil,
        registration: ChemicalRegistration? = nil,
        category: String = "insecticide"
    ) -> ChemicalIntelligence {
        ChemicalIntelligence(
            activeIngredients: actives,
            registration: registration,
            verification: ChemicalVerification(),
            registeredUses: uses ?? [grapeUse(rates: [rate(2)])],
            productCategory: category
        )
    }

    private func evaluate(
        name: String = "HORTITROL WINTER OIL",
        category: String = "insecticide",
        intelligence intel: ChemicalIntelligence? = nil,
        intent: ChemicalSaveIntent = .sprayReady
    ) -> ChemicalSaveEvaluation {
        ChemicalSaveContract.evaluate(
            productName: name,
            productCategory: category,
            intelligence: intel ?? intelligence(),
            intent: intent
        )
    }

    private func codes(_ e: ChemicalSaveEvaluation) -> Set<ChemicalSaveViolationCode> {
        Set(e.violations.map(\.code))
    }

    // MARK: - Resistance state (§10)

    @Test("A missing activity group is unresolved, never not-applicable")
    func missingGroupIsUnresolved() {
        // The rule that matters most. An unclassified fungicide silently
        // marked group-free would be excluded from every resistance warning
        // it should raise.
        let active = ChemicalActiveIngredient(name: "Mystery active")
        #expect(ChemicalResistanceState.of(active) == .unresolved)
        #expect(ChemicalResistanceState.rollup([active]) == .unresolved)
    }

    @Test("An explicit not-applicable scheme is the ONLY route to not-applicable")
    func explicitAssertionOnly() {
        let wetter = ChemicalActiveIngredient(
            name: "Nonionic surfactant",
            activityGroup: ChemicalActivityGroup(scheme: .notApplicable, code: "")
        )
        #expect(ChemicalResistanceState.of(wetter) == .notApplicable)
        #expect(ChemicalResistanceState.rollup([wetter]) == .notApplicable)
    }

    @Test("A scheme with no code is half a record, not knowledge")
    func schemeWithoutCodeIsUnresolved() {
        let halfWritten = ChemicalActiveIngredient(
            name: "Half-written",
            activityGroup: ChemicalActivityGroup(scheme: .frac, code: "")
        )
        #expect(ChemicalResistanceState.of(halfWritten) == .unresolved)
    }

    @Test("A real scheme and code is classified")
    func classified() {
        let tebuconazole = ChemicalActiveIngredient(
            name: "Tebuconazole",
            activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3")
        )
        #expect(ChemicalResistanceState.of(tebuconazole) == .classified)
        #expect(ChemicalResistanceState.rollup([tebuconazole]) == .classified)
    }

    @Test("A half-classified mixture is unresolved, not classified")
    func partialMixtureIsUnresolved() {
        // Reporting it classified would tell the Planner it knows the whole
        // chemistry when it knows half of it.
        let known = ChemicalActiveIngredient(
            name: "Tebuconazole",
            activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3")
        )
        let unknown = ChemicalActiveIngredient(name: "Mystery active")
        #expect(ChemicalResistanceState.rollup([known, unknown]) == .unresolved)
    }

    @Test("A classified active plus an explicitly group-free one is classified")
    func fungicidePlusWetterIsClassified() {
        // The wetter has nothing to contribute and must not spoil the state.
        let fungicide = ChemicalActiveIngredient(
            name: "Tebuconazole",
            activityGroup: ChemicalActivityGroup(scheme: .frac, code: "3")
        )
        let wetter = ChemicalActiveIngredient(
            name: "Wetter",
            activityGroup: ChemicalActivityGroup(scheme: .notApplicable, code: "")
        )
        #expect(ChemicalResistanceState.rollup([fungicide, wetter]) == .classified)
    }

    @Test("No actives at all is unresolved — every pre-sql/194 record")
    func noActivesIsUnresolved() {
        #expect(ChemicalResistanceState.rollup([]) == .unresolved)
    }

    @Test("The wire values match the sql/210 CHECK constraint exactly")
    func wireValuesMatchSchema() {
        #expect(ChemicalResistanceState.classified.rawValue == "classified")
        #expect(ChemicalResistanceState.notApplicable.rawValue == "not_applicable")
        #expect(ChemicalResistanceState.unresolved.rawValue == "unresolved")
    }

    // MARK: - The happy path

    @Test("A complete record satisfies the contract")
    func completeRecordPasses() {
        let evaluation = evaluate()
        #expect(evaluation.isSatisfied, "\(evaluation.violations.map(\.code))")
        #expect(evaluation.hasUsableViticulturalRate)
        #expect(!evaluation.requiresRateConditionChoice)
    }

    // MARK: - Identity

    @Test("Product name is mandatory")
    func nameRequired() {
        #expect(codes(evaluate(name: "   ")).contains(.productNameMissing))
    }

    @Test("Product category is mandatory — the calculation needs the unit")
    func categoryRequired() {
        let intel = intelligence(category: "")
        #expect(codes(evaluate(category: "", intelligence: intel)).contains(.productCategoryMissing))
    }

    // MARK: - Actives

    @Test("A product with no actives is allowed — adjuvants are real products")
    func adjuvantWithoutActivesIsFine() {
        let intel = intelligence(actives: [])
        #expect(!codes(evaluate(intelligence: intel)).contains(.activeIngredientNameMissing))
    }

    @Test("A half-typed active row with no name is a fault")
    func namelessActiveIsFault() {
        let intel = intelligence(actives: [ChemicalActiveIngredient(name: "  ")])
        #expect(codes(evaluate(intelligence: intel)).contains(.activeIngredientNameMissing))
    }

    // MARK: - Grapevine use

    @Test("A grapevine use is mandatory")
    func grapevineUseRequired() {
        let intel = intelligence(uses: [])
        #expect(codes(evaluate(intelligence: intel)).contains(.grapevineUseMissing))
    }

    @Test("A label registered only on other crops does not satisfy the rule")
    func otherCropsDoNotCount() {
        let apples = ChemicalRegisteredUse(
            crop: "Apples", targetRaw: "Codling moth", rates: [rate(9)]
        )
        #expect(codes(evaluate(intelligence: intelligence(uses: [apples])))
            .contains(.grapevineUseMissing))
    }

    @Test("A product-level rate carrier is not a grapevine use claim")
    func rateCarrierIsNotAUse() {
        // A carrier holds rates with no crop and no target. Counting it as a
        // registered use would claim a grapevine registration nobody stated.
        let carrier = ChemicalRegisteredUse(crop: "", targetRaw: "", rates: [rate(2)])
        #expect(codes(evaluate(intelligence: intelligence(uses: [carrier])))
            .contains(.grapevineUseMissing))
    }

    // MARK: - The rate rule (§11)

    @Test("THE case: product and grapevine use found, but no rate extracted")
    func grapevineUseWithoutRateIsBlocked() {
        let intel = intelligence(uses: [grapeUse(rates: [])])
        let evaluation = evaluate(intelligence: intel)
        #expect(!evaluation.isSatisfied)
        #expect(codes(evaluation).contains(.usableRateMissing))
        #expect(!evaluation.hasUsableViticulturalRate)
        // The message tells the operator exactly what to do.
        #expect(evaluation.violations.first { $0.code == .usableRateMissing }?.message
            == "Rate not found — enter the rate from the label before saving.")
    }

    @Test("Verbatim wording is NOT a usable rate")
    func verbatimIsNotUsable() {
        let verbatim = ChemicalLabelRate(
            basis: .other, unit: "", rawText: "Apply as directed by an agronomist"
        )
        #expect(!ChemicalSaveContract.isUsable(verbatim))

        let intel = intelligence(uses: [grapeUse(rates: [verbatim])])
        let evaluation = evaluate(intelligence: intel)
        #expect(codes(evaluation).contains(.usableRateMissing))
        // …but the verbatim entry is not reported as malformed. It is a
        // faithful record of what the label says.
        #expect(!codes(evaluation).contains(.rateBasisUnrecognised))
    }

    @Test("A usable rate needs a unit, a recognised basis and a positive number")
    func usableRateRequirements() {
        #expect(ChemicalSaveContract.isUsable(rate(2)))
        #expect(!ChemicalSaveContract.isUsable(rate(2, unit: "")))
        #expect(!ChemicalSaveContract.isUsable(rate(0)))
        #expect(!ChemicalSaveContract.isUsable(rate(-2)))
        #expect(!ChemicalSaveContract.isUsable(
            ChemicalLabelRate(basis: .per100Litres, unit: "L")
        ))
    }

    @Test("A range rate needs both ends, in order")
    func rangeRequirements() {
        let good = ChemicalLabelRate(
            basis: .rangePer100Litres, minValue: 150, maxValue: 200, unit: "mL"
        )
        #expect(ChemicalSaveContract.isUsable(good))

        let openEnded = ChemicalLabelRate(
            basis: .rangePer100Litres, minValue: 150, unit: "mL"
        )
        #expect(!ChemicalSaveContract.isUsable(openEnded))

        let inverted = ChemicalLabelRate(
            basis: .rangePerHectare, minValue: 5, maxValue: 1, unit: "L"
        )
        #expect(!ChemicalSaveContract.isUsable(inverted))
        #expect(codes(evaluate(intelligence: intelligence(uses: [grapeUse(rates: [inverted])])))
            .contains(.rateRangeInverted))
    }

    @Test("Either rate basis satisfies the contract — /100 L is preferred, not required")
    func hectareOnlyIsComplete() {
        let hectare = rate(4, basis: .perHectare)
        let intel = intelligence(uses: [grapeUse(rates: [hectare])])
        #expect(evaluate(intelligence: intel).isSatisfied)
    }

    @Test("Both bases together satisfy the contract and neither is demanded")
    func bothBasesComplete() {
        let intel = intelligence(uses: [
            grapeUse(rates: [rate(2), rate(4, basis: .perHectare)])
        ])
        #expect(evaluate(intelligence: intel).isSatisfied)
    }

    // MARK: - Ambiguous conditions (§5 handoff)

    @Test("An ambiguous rate is usable but never auto-applied")
    func ambiguousIsUsableNotAutomatic() {
        let ambiguous = rate(2, ambiguous: true)
        #expect(ChemicalSaveContract.isUsable(ambiguous), "the number is authoritative")
        #expect(!ChemicalSaveContract.isAutoApplicable(ambiguous), "the association is not")
    }

    @Test("A use whose only rates are ambiguous saves, but flags a choice")
    func ambiguousUseSavesWithFlag() {
        let intel = intelligence(uses: [
            grapeUse(rates: [rate(2, ambiguous: true), rate(3, ambiguous: true)])
        ])
        let evaluation = evaluate(intelligence: intel)
        // The label really does state these rates, so the record is storable…
        #expect(evaluation.isSatisfied)
        // …but a calculation must ask which condition applies.
        #expect(evaluation.requiresRateConditionChoice)
    }

    @Test("One unambiguous rate clears the choice flag")
    func oneClearRateClearsFlag() {
        let intel = intelligence(uses: [
            grapeUse(rates: [rate(2, ambiguous: true), rate(4, basis: .perHectare)])
        ])
        #expect(!evaluate(intelligence: intel).requiresRateConditionChoice)
    }

    // MARK: - Verified intent

    @Test("A verified product needs registration identity and the official label")
    func verifiedNeedsIdentity() {
        let noIdentity = intelligence(registration: nil)
        let verified = codes(evaluate(intelligence: noIdentity, intent: .verified))
        #expect(verified.contains(.registrationIdentityMissing))
        #expect(verified.contains(.officialLabelMissing))

        // The same record is a perfectly good UNVERIFIED store entry.
        let sprayReady = codes(evaluate(intelligence: noIdentity, intent: .sprayReady))
        #expect(!sprayReady.contains(.registrationIdentityMissing))
        #expect(!sprayReady.contains(.officialLabelMissing))
    }

    @Test("A complete verified product passes")
    func verifiedComplete() {
        let registration = ChemicalRegistration(
            countryCode: "AU",
            registrationNumber: "50067",
            labelReference: "https://portal.apvma.gov.au/label/50067.pdf"
        )
        let intel = intelligence(registration: registration)
        #expect(evaluate(intelligence: intel, intent: .verified).isSatisfied)
    }

    // MARK: - What must NEVER be mandatory (§12)

    @Test("WHP is never required and stays null")
    func whpNeverRequired() {
        let use = ChemicalRegisteredUse(
            crop: "Grapevines",
            targetRaw: "Scale",
            rates: [rate(2)],
            withholdingPeriodDays: nil
        )
        let registration = ChemicalRegistration(
            countryCode: "AU",
            registrationNumber: "50067",
            labelReference: "https://x/y.pdf"
        )
        let intel = intelligence(uses: [use], registration: registration)
        #expect(evaluate(intelligence: intel, intent: .verified).isSatisfied,
                "a label that states no WHP is still a complete label")
        // The null survives — it is never coerced to a zero.
        #expect(intel.registeredUses.first?.withholdingPeriodDays == nil)
    }

    @Test("REI is never required and stays null")
    func reiNeverRequired() {
        let use = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Scale", rates: [rate(2)],
            reEntryPeriodHours: nil
        )
        let intel = intelligence(uses: [use])
        #expect(evaluate(intelligence: intel).isSatisfied)
        #expect(intel.registeredUses.first?.reEntryPeriodHours == nil)
    }

    @Test("A zero WHP is not treated as more complete than a null")
    func zeroIsNotRewarded() {
        // If it were, a future edit would start rewarding invented values.
        let withZero = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Scale", rates: [rate(2)],
            withholdingPeriodDays: 0, reEntryPeriodHours: 0
        )
        let withNull = ChemicalRegisteredUse(
            crop: "Grapevines", targetRaw: "Scale", rates: [rate(2)]
        )
        #expect(
            codes(evaluate(intelligence: intelligence(uses: [withZero])))
                == codes(evaluate(intelligence: intelligence(uses: [withNull])))
        )
    }

    @Test("An unstated WHP renders as nothing, never as '0 days'")
    func unstatedWhpRendersAsNothing() {
        // §12: a missing withholding period must not become "0 days".
        #expect(ChemicalWithholdingDisplay.text(
            days: nil, restrictions: nil, hasManufacturerLabelSource: true
        ) == nil)
    }

    @Test("A zero WHP only reads as 'not required' with label evidence behind it")
    func zeroWhpNeedsEvidence() {
        // With the label's own wording present.
        #expect(ChemicalWithholdingDisplay.text(
            days: 0,
            restrictions: "NOT REQUIRED WHEN USED AS DIRECTED",
            hasManufacturerLabelSource: false
        ) == "Not required when used as directed")

        // An AI-only or operator-typed zero has no such wording behind it.
        #expect(ChemicalWithholdingDisplay.text(
            days: 0, restrictions: nil, hasManufacturerLabelSource: false
        ) == "0 days")
    }

    // MARK: - Reporting quality

    @Test("Every violation is reported at once, not one field at a time")
    func allViolationsReported() {
        let empty = ChemicalIntelligence(
            activeIngredients: [],
            registration: nil,
            verification: ChemicalVerification(),
            registeredUses: [],
            productCategory: ""
        )
        let found = codes(evaluate(name: "", category: "", intelligence: empty, intent: .verified))
        #expect(found.contains(.productNameMissing))
        #expect(found.contains(.productCategoryMissing))
        #expect(found.contains(.grapevineUseMissing))
        #expect(found.contains(.registrationIdentityMissing))
        #expect(found.contains(.officialLabelMissing))
    }

    @Test("Several malformed rates produce one actionable message")
    func duplicateMessagesCollapse() {
        let messy = grapeUse(rates: [rate(0), rate(-1), rate(0, basis: .perHectare)])
        let invalid = evaluate(intelligence: intelligence(uses: [messy])).violations
            .filter { $0.code == .rateValueInvalid }
        #expect(invalid.count == 1, "the operator should not read the same sentence three times")
    }

    // MARK: - The baseline rule (never make it worse)

    @Test("A brand-new record must satisfy the contract in full")
    func newRecordFullyGated() {
        var session = ChemicalReviewSession()
        session.name = "New product"
        // No category, no grapevine use, no rate.
        #expect(!session.isValid)
        #expect(session.blockingViolations.contains { $0.code == .grapevineUseMissing })
    }

    @Test("A new record becomes valid once the contract is met")
    func newRecordBecomesValid() {
        var draft = ChemicalManualDraft(
            productName: "HORTITROL WINTER OIL",
            countryCode: "AU",
            productCategory: "insecticide"
        )
        draft.uses = [ChemicalManualUseDraft(
            crop: "Grapevines",
            targetRaw: "Grapevine scale",
            rates: [ChemicalManualRateDraft(
                basis: .per100Litres, valueText: "2", unit: "L"
            )]
        )]
        let session = ChemicalReviewSession(chemistryDraft: draft)
        #expect(session.isValid, "\(session.blockingViolations.map(\.code))")
    }

    @Test("An empty name always blocks, whatever the baseline says")
    func nameAlwaysBlocks() {
        let session = ChemicalReviewSession(
            chemistryDraft: ChemicalManualDraft(productName: "  "),
            baselineViolationCodes: Set(ChemicalSaveViolationCode.allCases)
        )
        #expect(!session.isValid)
    }

    @Test("A legacy record's pre-existing faults do not block editing it")
    func legacyRecordStaysEditable() {
        // A pre-Chemical-Intelligence product has no structured use and no
        // structured rate. Blocking Save would strand it: a record that cannot
        // be saved cannot be repaired, and the operator would lose the edit.
        let session = ChemicalReviewSession(
            chemistryDraft: ChemicalManualDraft(productName: "Old product"),
            baselineViolationCodes: [
                .productCategoryMissing, .grapevineUseMissing, .usableRateMissing
            ]
        )
        #expect(session.isValid, "a legacy record must remain repairable")
        // The faults are still reported — as guidance, not as a block.
        #expect(!session.carriedOverViolations.isEmpty)
        #expect(session.blockingViolations.isEmpty)
    }

    @Test("An edit cannot introduce a NEW violation on a legacy record")
    func editCannotDegradeFurther() {
        // The baseline forgives what was already wrong; it never forgives
        // something the operator breaks now.
        var session = ChemicalReviewSession(
            chemistryDraft: ChemicalManualDraft(
                productName: "Old product",
                productCategory: "insecticide"
            ),
            baselineViolationCodes: [.grapevineUseMissing, .usableRateMissing]
        )
        #expect(session.isValid)

        // Clearing the category is a NEW fault, absent from the baseline.
        session.chemistryDraft.productCategory = ""
        #expect(!session.isValid)
        #expect(session.blockingViolations.contains { $0.code == .productCategoryMissing })
    }

    @Test("A compliant record cannot be edited into non-compliance")
    func compliantRecordStaysCompliant() {
        var draft = ChemicalManualDraft(
            productName: "HORTITROL WINTER OIL",
            countryCode: "AU",
            productCategory: "insecticide"
        )
        draft.uses = [ChemicalManualUseDraft(
            crop: "Grapevines",
            targetRaw: "Grapevine scale",
            rates: [ChemicalManualRateDraft(basis: .per100Litres, valueText: "2", unit: "L")]
        )]
        var session = ChemicalReviewSession(chemistryDraft: draft)
        #expect(session.isValid)

        // Deleting the only rate must block, even mid-edit.
        session.chemistryDraft.uses[0].rates = []
        #expect(!session.isValid)
        #expect(session.blockingViolations.contains { $0.code == .usableRateMissing })
    }
}
