package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalActiveIngredient
import com.rork.vinetrack.data.chemical.ChemicalActivityGroup
import com.rork.vinetrack.data.chemical.ChemicalActivityGroupScheme
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import com.rork.vinetrack.data.chemical.ChemicalResistanceState
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSaveEvaluation
import com.rork.vinetrack.data.chemical.ChemicalSaveIntent
import com.rork.vinetrack.data.chemical.ChemicalSaveViolationCode
import com.rork.vinetrack.data.chemical.ChemicalVerification
import com.rork.vinetrack.data.model.SavedChemical
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Resistance state, and the mandatory save contract — the ANDROID half of a
 * cross-platform agreement.
 *
 * # What this file is actually for
 *
 * Android's Save button used to be `name.isNotEmpty()`. iOS gated on the whole
 * contract. So a chemical with a product name and nothing else — no category,
 * no grapevine use, no usable rate — was refused on an iPhone and written by
 * an Android phone, into the same shared store. The server caught it later,
 * which meant the two clients disagreed in front of the operator and only one
 * of them was right.
 *
 * Every fixture below is transcribed from `ChemicalSaveContractTests.swift`
 * — the same product, the same rates, the same expectations — because the
 * claim being tested is not "Android works". It is "Android and iOS apply the
 * SAME contract". A test that invented its own Android fixtures could pass
 * while the two platforms still disagreed, which is precisely the failure this
 * file exists to make impossible.
 *
 * Two rules are being protected at once, and they pull in opposite directions:
 *
 * 1. VineTrack must not store a chemical it cannot USE — no grapevine rate
 *    means no spray calculation, and saving it as though it were ready is how
 *    an unusable product reaches the Spray Tool.
 * 2. VineTrack must not invent regulatory information to satisfy its own
 *    validation. WHP, REI and the manufacturer URL stay optional and stay
 *    null, because a label that is silent is not an incomplete record.
 */
class ChemicalSaveContractTest {

    // ---- Fixtures (transcribed from the iOS suite) ----

    private fun rate(
        value: Double,
        basis: ChemicalLabelRateBasis = ChemicalLabelRateBasis.PER_100_LITRES,
        unit: String = "L",
        label: String = "",
        ambiguous: Boolean = false,
    ) = ChemicalLabelRate(
        label = label,
        basis = basis,
        value = value,
        unit = unit,
        conditionAmbiguous = ambiguous,
    )

    private fun grapeUse(rates: List<ChemicalLabelRate>) = ChemicalRegisteredUse(
        crop = "Grapevines",
        targetRaw = "Grapevine scale",
        rates = rates,
    )

    private fun intelligence(
        actives: List<ChemicalActiveIngredient> = listOf(
            ChemicalActiveIngredient(
                name = "Paraffinic oil",
                activityGroup = ChemicalActivityGroup(
                    scheme = ChemicalActivityGroupScheme.NOT_APPLICABLE,
                    code = "",
                ),
            ),
        ),
        uses: List<ChemicalRegisteredUse>? = null,
        registration: ChemicalRegistration? = null,
        category: String = "insecticide",
    ) = ChemicalIntelligence(
        activeIngredients = actives,
        registration = registration,
        verification = ChemicalVerification(),
        registeredUses = uses ?: listOf(grapeUse(listOf(rate(2.0)))),
        productCategory = category,
    )

    private fun evaluate(
        name: String = "HORTITROL WINTER OIL",
        category: String = "insecticide",
        intelligence: ChemicalIntelligence? = null,
        intent: ChemicalSaveIntent = ChemicalSaveIntent.SPRAY_READY,
    ): ChemicalSaveEvaluation = ChemicalSaveContract.evaluate(
        productName = name,
        productCategory = category,
        intelligence = intelligence ?: intelligence(),
        intent = intent,
    )

    private fun codes(e: ChemicalSaveEvaluation): Set<ChemicalSaveViolationCode> =
        e.violations.map { it.code }.toSet()

    // ---- Resistance state ----

    @Test
    fun `a missing activity group is unresolved, never not-applicable`() {
        // The rule that matters most. An unclassified fungicide silently marked
        // group-free would be excluded from every resistance warning it should
        // raise.
        val active = ChemicalActiveIngredient(name = "Mystery active")
        assertEquals(ChemicalResistanceState.UNRESOLVED, ChemicalResistanceState.of(active))
        assertEquals(
            ChemicalResistanceState.UNRESOLVED,
            ChemicalResistanceState.rollup(listOf(active)),
        )
    }

    @Test
    fun `an explicit not-applicable scheme is the ONLY route to not-applicable`() {
        val wetter = ChemicalActiveIngredient(
            name = "Nonionic surfactant",
            activityGroup = ChemicalActivityGroup(
                scheme = ChemicalActivityGroupScheme.NOT_APPLICABLE,
                code = "",
            ),
        )
        assertEquals(ChemicalResistanceState.NOT_APPLICABLE, ChemicalResistanceState.of(wetter))
        assertEquals(
            ChemicalResistanceState.NOT_APPLICABLE,
            ChemicalResistanceState.rollup(listOf(wetter)),
        )
    }

    @Test
    fun `a scheme with no code is half a record, not knowledge`() {
        val halfWritten = ChemicalActiveIngredient(
            name = "Half-written",
            activityGroup = ChemicalActivityGroup(
                scheme = ChemicalActivityGroupScheme.FRAC,
                code = "",
            ),
        )
        assertEquals(ChemicalResistanceState.UNRESOLVED, ChemicalResistanceState.of(halfWritten))
    }

    @Test
    fun `a real scheme and code is classified`() {
        val tebuconazole = ChemicalActiveIngredient(
            name = "Tebuconazole",
            activityGroup = ChemicalActivityGroup(
                scheme = ChemicalActivityGroupScheme.FRAC,
                code = "3",
            ),
        )
        assertEquals(ChemicalResistanceState.CLASSIFIED, ChemicalResistanceState.of(tebuconazole))
        assertEquals(
            ChemicalResistanceState.CLASSIFIED,
            ChemicalResistanceState.rollup(listOf(tebuconazole)),
        )
    }

    @Test
    fun `a half-classified mixture is unresolved, not classified`() {
        // Reporting it classified would tell the Planner it knows the whole
        // chemistry when it knows half of it.
        val known = ChemicalActiveIngredient(
            name = "Tebuconazole",
            activityGroup = ChemicalActivityGroup(
                scheme = ChemicalActivityGroupScheme.FRAC,
                code = "3",
            ),
        )
        val unknown = ChemicalActiveIngredient(name = "Mystery active")
        assertEquals(
            ChemicalResistanceState.UNRESOLVED,
            ChemicalResistanceState.rollup(listOf(known, unknown)),
        )
    }

    @Test
    fun `a classified active plus an explicitly group-free one is classified`() {
        // The wetter has nothing to contribute and must not spoil the state.
        val fungicide = ChemicalActiveIngredient(
            name = "Tebuconazole",
            activityGroup = ChemicalActivityGroup(
                scheme = ChemicalActivityGroupScheme.FRAC,
                code = "3",
            ),
        )
        val wetter = ChemicalActiveIngredient(
            name = "Wetter",
            activityGroup = ChemicalActivityGroup(
                scheme = ChemicalActivityGroupScheme.NOT_APPLICABLE,
                code = "",
            ),
        )
        assertEquals(
            ChemicalResistanceState.CLASSIFIED,
            ChemicalResistanceState.rollup(listOf(fungicide, wetter)),
        )
    }

    @Test
    fun `no actives at all is unresolved`() {
        assertEquals(ChemicalResistanceState.UNRESOLVED, ChemicalResistanceState.rollup(emptyList()))
    }

    @Test
    fun `the wire values match the sql 210 CHECK constraint exactly`() {
        assertEquals("classified", ChemicalResistanceState.CLASSIFIED.raw)
        assertEquals("not_applicable", ChemicalResistanceState.NOT_APPLICABLE.raw)
        assertEquals("unresolved", ChemicalResistanceState.UNRESOLVED.raw)
    }

    // ---- B. The happy path: a valid researched chemical is saveable ----

    @Test
    fun `B - a complete researched record satisfies the contract`() {
        val evaluation = evaluate()
        assertTrue(evaluation.violations.map { it.code }.toString(), evaluation.isSatisfied)
        assertTrue(evaluation.hasUsableViticulturalRate)
        assertFalse(evaluation.requiresRateConditionChoice)
    }

    // ---- A. Name only ----

    @Test
    fun `A - a product name and nothing else is NOT saveable`() {
        // The exact record Android used to accept: the operator typed a name
        // into the form and the Save button lit up. iOS refused the same
        // record, so one phone wrote what the other would not.
        val nameOnly = ChemicalIntelligence()
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "HORTITROL WINTER OIL",
            productCategory = "",
            intelligence = nameOnly,
        )
        assertFalse(evaluation.isSatisfied)
        assertEquals(
            setOf(
                ChemicalSaveViolationCode.PRODUCT_CATEGORY_MISSING,
                ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING,
            ),
            codes(evaluation),
        )
        assertFalse(evaluation.hasUsableViticulturalRate)
    }

    @Test
    fun `A - a brand-new chemical has an empty baseline so the full contract applies`() {
        // This is what makes "name only" actually unsaveable in the form: a
        // record with no history has nothing to carry over, so every violation
        // blocks. Mirrors iOS `ChemicalReviewSession.baselineViolationCodes`.
        val baseline = ChemicalSaveContract.baselineViolationCodes(null, "AU")
        assertTrue(baseline.isEmpty())

        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Anything",
            productCategory = "",
            intelligence = ChemicalIntelligence(),
        )
        assertEquals(
            evaluation.violations,
            ChemicalSaveContract.blockingViolations(evaluation, baseline),
        )
    }

    @Test
    fun `product name is mandatory`() {
        assertTrue(
            codes(evaluate(name = "   "))
                .contains(ChemicalSaveViolationCode.PRODUCT_NAME_MISSING),
        )
    }

    @Test
    fun `product category is mandatory - the calculation needs the unit`() {
        val intel = intelligence(category = "")
        assertTrue(
            codes(evaluate(category = "", intelligence = intel))
                .contains(ChemicalSaveViolationCode.PRODUCT_CATEGORY_MISSING),
        )
    }

    // ---- Actives ----

    @Test
    fun `a product with no actives is allowed - adjuvants are real products`() {
        val intel = intelligence(actives = emptyList())
        assertFalse(
            codes(evaluate(intelligence = intel))
                .contains(ChemicalSaveViolationCode.ACTIVE_INGREDIENT_NAME_MISSING),
        )
    }

    @Test
    fun `a half-typed active row with no name is a fault`() {
        val intel = intelligence(actives = listOf(ChemicalActiveIngredient(name = "  ")))
        assertTrue(
            codes(evaluate(intelligence = intel))
                .contains(ChemicalSaveViolationCode.ACTIVE_INGREDIENT_NAME_MISSING),
        )
    }

    // ---- D. Missing grapevine use ----

    @Test
    fun `D - a grapevine use is mandatory`() {
        val intel = intelligence(uses = emptyList())
        assertTrue(
            codes(evaluate(intelligence = intel))
                .contains(ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING),
        )
    }

    @Test
    fun `D - a label registered only on other crops does not satisfy the rule`() {
        val apples = ChemicalRegisteredUse(
            crop = "Apples",
            targetRaw = "Codling moth",
            rates = listOf(rate(9.0)),
        )
        assertTrue(
            codes(evaluate(intelligence = intelligence(uses = listOf(apples))))
                .contains(ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING),
        )
    }

    @Test
    fun `D - a product-level rate carrier is not a grapevine use claim`() {
        // A carrier holds rates with no crop and no target. Counting it as a
        // registered use would claim a grapevine registration nobody stated.
        val carrier = ChemicalRegisteredUse(crop = "", targetRaw = "", rates = listOf(rate(2.0)))
        assertTrue(
            codes(evaluate(intelligence = intelligence(uses = listOf(carrier))))
                .contains(ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING),
        )
    }

    // ---- C. Missing usable rate ----

    @Test
    fun `C - product and grapevine use found, but no rate extracted`() {
        val intel = intelligence(uses = listOf(grapeUse(emptyList())))
        val evaluation = evaluate(intelligence = intel)
        assertFalse(evaluation.isSatisfied)
        assertTrue(codes(evaluation).contains(ChemicalSaveViolationCode.USABLE_RATE_MISSING))
        assertFalse(evaluation.hasUsableViticulturalRate)
        // The message tells the operator exactly what to do — and is the same
        // sentence, character for character, that iOS shows.
        assertEquals(
            "Rate not found — enter the rate from the label before saving.",
            evaluation.violations
                .first { it.code == ChemicalSaveViolationCode.USABLE_RATE_MISSING }
                .message,
        )
    }

    @Test
    fun `C - verbatim wording is NOT a usable rate`() {
        val verbatim = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.OTHER,
            unit = "",
            rawText = "Apply as directed by an agronomist",
        )
        assertFalse(ChemicalSaveContract.isUsable(verbatim))

        val intel = intelligence(uses = listOf(grapeUse(listOf(verbatim))))
        val evaluation = evaluate(intelligence = intel)
        assertTrue(codes(evaluation).contains(ChemicalSaveViolationCode.USABLE_RATE_MISSING))
        // …but the verbatim entry is not reported as malformed. It is a
        // faithful record of what the label says.
        assertFalse(codes(evaluation).contains(ChemicalSaveViolationCode.RATE_BASIS_UNRECOGNISED))
    }

    @Test
    fun `C - a usable rate needs a unit, a recognised basis and a positive number`() {
        assertTrue(ChemicalSaveContract.isUsable(rate(2.0)))
        assertFalse(ChemicalSaveContract.isUsable(rate(2.0, unit = "")))
        assertFalse(ChemicalSaveContract.isUsable(rate(0.0)))
        assertFalse(ChemicalSaveContract.isUsable(rate(-2.0)))
        assertFalse(
            ChemicalSaveContract.isUsable(
                ChemicalLabelRate(basis = ChemicalLabelRateBasis.PER_100_LITRES, unit = "L"),
            ),
        )
    }

    @Test
    fun `C - a range rate needs both ends, in order`() {
        val good = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            minValue = 150.0,
            maxValue = 200.0,
            unit = "mL",
        )
        assertTrue(ChemicalSaveContract.isUsable(good))

        val openEnded = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.RANGE_PER_100_LITRES,
            minValue = 150.0,
            unit = "mL",
        )
        assertFalse(ChemicalSaveContract.isUsable(openEnded))

        val inverted = ChemicalLabelRate(
            basis = ChemicalLabelRateBasis.RANGE_PER_HECTARE,
            minValue = 5.0,
            maxValue = 1.0,
            unit = "L",
        )
        assertFalse(ChemicalSaveContract.isUsable(inverted))
        assertTrue(
            codes(evaluate(intelligence = intelligence(uses = listOf(grapeUse(listOf(inverted))))))
                .contains(ChemicalSaveViolationCode.RATE_RANGE_INVERTED),
        )
    }

    @Test
    fun `either rate basis satisfies the contract`() {
        val hectare = rate(4.0, basis = ChemicalLabelRateBasis.PER_HECTARE)
        val intel = intelligence(uses = listOf(grapeUse(listOf(hectare))))
        assertTrue(evaluate(intelligence = intel).isSatisfied)
    }

    @Test
    fun `both bases together satisfy the contract and neither is demanded`() {
        val intel = intelligence(
            uses = listOf(
                grapeUse(listOf(rate(2.0), rate(4.0, basis = ChemicalLabelRateBasis.PER_HECTARE))),
            ),
        )
        assertTrue(evaluate(intelligence = intel).isSatisfied)
    }

    // ---- Ambiguous conditions ----

    @Test
    fun `an ambiguous rate is usable but never auto-applied`() {
        val ambiguous = rate(2.0, ambiguous = true)
        assertTrue("the number is authoritative", ChemicalSaveContract.isUsable(ambiguous))
        assertFalse(
            "the association is not",
            ChemicalSaveContract.isAutoApplicable(ambiguous),
        )
    }

    @Test
    fun `a use whose only rates are ambiguous saves, but flags a choice`() {
        val intel = intelligence(
            uses = listOf(
                grapeUse(listOf(rate(2.0, ambiguous = true), rate(3.0, ambiguous = true))),
            ),
        )
        val evaluation = evaluate(intelligence = intel)
        // The label really does state these rates, so the record is storable…
        assertTrue(evaluation.isSatisfied)
        // …but a calculation must ask which condition applies.
        assertTrue(evaluation.requiresRateConditionChoice)
    }

    @Test
    fun `one unambiguous rate clears the choice flag`() {
        val intel = intelligence(
            uses = listOf(
                grapeUse(
                    listOf(
                        rate(2.0, ambiguous = true),
                        rate(4.0, basis = ChemicalLabelRateBasis.PER_HECTARE),
                    ),
                ),
            ),
        )
        assertFalse(evaluate(intelligence = intel).requiresRateConditionChoice)
    }

    // ---- Verified intent ----

    @Test
    fun `a verified product needs registration identity and the official label`() {
        val noIdentity = intelligence(registration = null)
        val verified = codes(
            evaluate(intelligence = noIdentity, intent = ChemicalSaveIntent.VERIFIED),
        )
        assertTrue(verified.contains(ChemicalSaveViolationCode.REGISTRATION_IDENTITY_MISSING))
        assertTrue(verified.contains(ChemicalSaveViolationCode.OFFICIAL_LABEL_MISSING))

        // The same record is a perfectly good UNVERIFIED store entry.
        val sprayReady = codes(
            evaluate(intelligence = noIdentity, intent = ChemicalSaveIntent.SPRAY_READY),
        )
        assertFalse(sprayReady.contains(ChemicalSaveViolationCode.REGISTRATION_IDENTITY_MISSING))
        assertFalse(sprayReady.contains(ChemicalSaveViolationCode.OFFICIAL_LABEL_MISSING))
    }

    @Test
    fun `a complete verified product passes`() {
        val registration = ChemicalRegistration(
            countryCode = "AU",
            registrationNumber = "50067",
            labelReference = "https://portal.apvma.gov.au/label/50067.pdf",
        )
        val intel = intelligence(registration = registration)
        assertTrue(
            evaluate(intelligence = intel, intent = ChemicalSaveIntent.VERIFIED).isSatisfied,
        )
    }

    // ---- What must NEVER be mandatory ----

    @Test
    fun `WHP and REI are never required and stay null`() {
        // A label that states no withholding period is not an incomplete
        // record, and demanding a number would manufacture regulatory
        // information — the opposite of this feature's job.
        val use = ChemicalRegisteredUse(
            crop = "Grapevines",
            targetRaw = "Scale",
            rates = listOf(rate(2.0)),
            withholdingPeriodDays = null,
            reEntryPeriodHours = null,
        )
        val evaluation = evaluate(intelligence = intelligence(uses = listOf(use)))
        assertTrue(evaluation.isSatisfied)
    }

    @Test
    fun `a manufacturer URL is never mandatory`() {
        val registration = ChemicalRegistration(
            countryCode = "AU",
            scheme = ChemicalRegistrationScheme.APVMA,
            registrationNumber = "50067",
            labelReference = "https://portal.apvma.gov.au/label/50067.pdf",
            manufacturerLabelUrl = null,
            manufacturerProductUrl = null,
        )
        assertTrue(
            evaluate(
                intelligence = intelligence(registration = registration),
                intent = ChemicalSaveIntent.VERIFIED,
            ).isSatisfied,
        )
    }

    // ---- E. Manual entry, and the "never make it worse" baseline ----

    @Test
    fun `E - a legacy record keeps its existing faults as guidance, not as a block`() {
        // A pre-Chemical-Intelligence product has no structured grapevine use
        // and no structured rate. Applied flatly the contract would strand it:
        // an operator opening it to fix a typo or update a price would find
        // Save permanently disabled and would lose the edit. A record that
        // cannot be saved cannot be repaired.
        val legacy = SavedChemical(
            id = "legacy-1",
            vineyardId = "v1",
            name = "Old Fungicide",
            activeIngredient = "Azoxystrobin 250 g/L",
            chemicalGroup = "11",
            productCategory = "fungicide",
        )
        val baseline = ChemicalSaveContract.baselineViolationCodes(legacy, "AU")
        assertTrue(baseline.contains(ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING))

        // Re-measured after an unrelated edit, the same faults are carried
        // over rather than blocking.
        val evaluation = ChemicalSaveContract.evaluate(
            productName = legacy.name,
            productCategory = "fungicide",
            intelligence = ChemicalIntelligence(productCategory = "fungicide"),
        )
        assertTrue(ChemicalSaveContract.blockingViolations(evaluation, baseline).isEmpty())
        assertEquals(
            evaluation.violations,
            ChemicalSaveContract.carriedOverViolations(evaluation, baseline),
        )
    }

    @Test
    fun `E - a compliant chemical can never be edited INTO non-compliance`() {
        // The other half of the baseline rule. A record that arrived complete
        // has an empty baseline, so removing its grapevine use blocks Save.
        val complete = intelligence()
        val baseline = ChemicalSaveContract.evaluate(
            productName = "HORTITROL WINTER OIL",
            productCategory = "insecticide",
            intelligence = complete,
        ).violations.map { it.code }.toSet()
        assertTrue(baseline.isEmpty())

        val gutted = evaluate(intelligence = intelligence(uses = emptyList()))
        val blocking = ChemicalSaveContract.blockingViolations(gutted, baseline)
        assertTrue(
            blocking.map { it.code }.contains(ChemicalSaveViolationCode.GRAPEVINE_USE_MISSING),
        )
    }

    @Test
    fun `E - manual entry remains possible - a hand-entered product can satisfy the contract`() {
        // Manual fallback must never become impossible. A product the operator
        // types in full — category, grapevine use, rate — is saveable without
        // any lookup, registration number or label URL, exactly as on iOS.
        val handEntered = ChemicalIntelligence(
            activeIngredients = listOf(ChemicalActiveIngredient(name = "Sulfur")),
            registration = null,
            registeredUses = listOf(
                ChemicalRegisteredUse(
                    crop = "Grapes",
                    targetRaw = "Powdery mildew",
                    rates = listOf(rate(300.0, unit = "g")),
                ),
            ),
            productCategory = "fungicide",
        )
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Shed Sulfur",
            productCategory = "fungicide",
            intelligence = handEntered,
        )
        assertTrue(evaluation.violations.map { it.code }.toString(), evaluation.isSatisfied)
        // Unverified, but complete: identity is not a spray-readiness rule.
        assertTrue(evaluation.hasUsableViticulturalRate)
    }
}
