package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalAddFromSprayRouting
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateBasis
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateDisplay
import com.rork.vinetrack.data.chemical.ChemicalDefaultRateValidity
import com.rork.vinetrack.data.chemical.ChemicalIntelligence
import com.rork.vinetrack.data.chemical.ChemicalLabelRate
import com.rork.vinetrack.data.chemical.ChemicalLabelRateBasis
import com.rork.vinetrack.data.chemical.ChemicalLookupAdvisory
import com.rork.vinetrack.data.chemical.ChemicalRegisteredUse
import com.rork.vinetrack.data.chemical.ChemicalReverifyFlow
import com.rork.vinetrack.data.chemical.ChemicalSaveContract
import com.rork.vinetrack.data.chemical.ChemicalSaveViolationCode
import com.rork.vinetrack.data.chemical.ChemicalSprayDefaultHandoff
import com.rork.vinetrack.data.chemical.ChemicalVineyardScope
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRate
import com.rork.vinetrack.data.chemical.StoredChemicalDefaultRates
import com.rork.vinetrack.data.chemical.clearedDefaultRates
import com.rork.vinetrack.data.model.ChemicalRate
import com.rork.vinetrack.data.model.SavedChemical
import com.rork.vinetrack.data.SprayCalculator
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The targeted correction to the Android chemical release.
 *
 * Each test here stands for a specific way the shipped build could still put a
 * wrong number in a tank or a wrong product on a screen:
 *
 *  * other-crop label directions reachable from a vineyard record
 *  * "check for updates" appending a product instead of checking it
 *  * a rate picker offering unconfirmed legacy rows past the confirmed default
 *  * a malformed persisted default being read as a confirmed dose
 *  * the Save BUTTON enforcing a contract the save FUNCTION did not
 *
 * The routing and validity rules are asserted against the same objects the
 * screens call, not against re-implementations of them. Where a rule can only
 * live in Compose, it is pinned at the SOURCE boundary instead — a weaker
 * assertion, stated as such, rather than a comment claiming the work was done.
 */
class ChemicalTargetedCorrectionTest {

    /**
     * The SHARED client's configuration, mirrored exactly.
     *
     * `explicitNulls = false` is the whole reason the cleared contract has to
     * be an explicit empty document: under it a null column is dropped from
     * the request entirely, so "clear my default" sent as null would arrive as
     * "change nothing" and the stale rate would stay live. Asserting with any
     * other configuration would test a request this app never sends.
     */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
        explicitNulls = false
    }

    /**
     * Source with comments removed.
     *
     * The re-verify sheet's own comment explains, by name, the two writes that
     * were deleted from it. A raw text search therefore finds
     * `updateSavedChemical` in the very file that proves it is gone — so the
     * assertion has to look at code, not prose.
     */
    private fun codeOnly(source: String): String = source
        .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), "")
        .lines()
        .filterNot { it.trimStart().startsWith("//") }
        .joinToString("\n")

    // ---- Fixtures ----------------------------------------------------------

    private fun slot(
        value: Double? = null,
        unit: String = "L",
        basis: ChemicalDefaultRateBasis = ChemicalDefaultRateBasis.PER_HECTARE,
        optionKey: String = "default_option_v1_abc",
        rateIds: List<String> = listOf("rate_v1_a"),
        minValue: Double? = null,
        maxValue: Double? = null,
        source: String = StoredChemicalDefaultRate.SOURCE_OPERATOR,
        basisRaw: String = basis.raw,
    ) = StoredChemicalDefaultRate(
        optionKey = optionKey,
        rateIds = rateIds,
        basis = basisRaw,
        unit = unit,
        value = value,
        minValue = minValue,
        maxValue = maxValue,
        source = source,
    )

    private fun defaults(
        perHectare: StoredChemicalDefaultRate? = null,
        per100Litres: StoredChemicalDefaultRate? = null,
        version: Int = StoredChemicalDefaultRates.DEFAULT_RATES_VERSION,
    ) = StoredChemicalDefaultRates(
        version = version,
        perHectare = perHectare,
        per100Litres = per100Litres,
    )

    private fun grapeUse(vararg rates: ChemicalLabelRate) = ChemicalRegisteredUse(
        crop = "GRAPEVINES",
        targetRaw = "Powdery mildew",
        rates = rates.toList(),
    )

    private fun otherCropUse(crop: String) = ChemicalRegisteredUse(
        crop = crop,
        targetRaw = "Brown rot",
        rates = listOf(
            ChemicalLabelRate(
                basis = ChemicalLabelRateBasis.PER_HECTARE,
                value = 9.0,
                unit = "L",
                rateId = "rate_v1_$crop",
            ),
        ),
    )

    private fun chemical(
        id: String = "chem-1",
        unit: String = "Litres",
        rates: List<ChemicalRate> = emptyList(),
        ratePerHa: Double = 0.0,
        defaultRates: StoredChemicalDefaultRates? = null,
        registeredUses: List<ChemicalRegisteredUse>? = null,
    ) = SavedChemical(
        id = id,
        vineyardId = "vineyard-1",
        name = "Example Fungicide",
        unit = unit,
        rates = rates,
        ratePerHa = ratePerHa,
        defaultRates = defaultRates,
        registeredUses = registeredUses,
    )

    /** Source of a file in the Android module, whatever the test working dir. */
    private fun moduleSource(relative: String): String {
        val candidates = listOf(
            File(relative),
            File("app/$relative"),
            File("android-vinetrack/app/$relative"),
            File("../app/$relative"),
        )
        val found = candidates.firstOrNull { it.exists() }
            ?: error("source not found for $relative (cwd=${File(".").absolutePath})")
        return found.readText()
    }

    /** Every Kotlin source file in the app's main source set. */
    private fun mainSources(): List<File> {
        val roots = listOf(
            File("src/main/java"),
            File("app/src/main/java"),
            File("android-vinetrack/app/src/main/java"),
        )
        val root = roots.firstOrNull { it.isDirectory }
            ?: error("main source root not found (cwd=${File(".").absolutePath})")
        return root.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
    }

    // =========================================================================
    // 1  No other-crop label data on customer screens
    // =========================================================================

    @Test
    fun `1 - no customer Android route renders other-crop label directions`() {
        // A vineyard record must not put peach, citrus, turf or cereal
        // directions in front of an operator: a withholding period read off
        // the wrong crop is a compliance figure applied to the wrong plant.
        val banned = listOf(
            "Other crops on this label",
            "Hide other crops on this label",
            "showOtherCropUses",
        )
        val offenders = mainSources().filter { file ->
            val text = file.readText()
            banned.any { text.contains(it) }
        }
        assertEquals(
            "customer routes must not disclose other-crop label data: " +
                offenders.joinToString { it.name },
            emptyList<String>(),
            offenders.map { it.name },
        )
    }

    @Test
    fun `1b - the store editor scopes its display intelligence to the vineyard`() {
        // The scoping itself, asserted on the object the screen calls.
        val uses = listOf(grapeUse(), otherCropUse("PEACHES"), otherCropUse("CITRUS"))
        val scoped = ChemicalVineyardScope.scoped(
            ChemicalIntelligence(registeredUses = uses, productCategory = "fungicide"),
        )
        assertEquals(1, scoped.registeredUses.size)
        assertEquals("GRAPEVINES", scoped.registeredUses.first().crop)
        // And the screen genuinely routes through it before rendering or
        // evaluating the contract.
        val screen = moduleSource("src/main/java/com/rork/vinetrack/ui/screens/ChemicalsScreen.kt")
        assertTrue(
            "the editor must scope display intelligence",
            screen.contains("ChemicalVineyardScope.scoped("),
        )
        assertTrue(
            "the editor must render the scoped operational set",
            screen.contains("ChemicalVineyardScope.operationalUses("),
        )
    }

    // =========================================================================
    // 2-3, 18  Add-from-spray routing
    // =========================================================================

    @Test
    fun `2 - declining a duplicate appends no line and disarms the snapshot`() {
        // "No, keep it as it is" closes the register flow having looked up
        // nothing and written nothing. It must also leave no armed append
        // behind, or the next product created anywhere lands in this tank.
        val outcome = ChemicalAddFromSprayRouting.onRegisterFlowClosed(created = false)

        assertFalse("must not append a spray line", outcome.appendLine)
        assertTrue("must disarm the pending append", outcome.disarmSnapshot)
        assertTrue(outcome.closeRegisterFlow)
        assertFalse(outcome.openReverify)
        assertFalse(outcome.openManualEntry)
    }

    @Test
    fun `3 - accepting a duplicate opens re-verification and appends nothing`() {
        // The defect this replaces: "Yes, check for updates" appended the
        // stored record instead of checking it, so the operator asked whether
        // their information was current and got a spray line, with the stored
        // information left exactly as stale as it was.
        val outcome = ChemicalAddFromSprayRouting.onCheckForUpdates()

        assertTrue("must open the canonical re-verification", outcome.openReverify)
        assertFalse("must NOT append the stored record", outcome.appendLine)
        assertTrue(outcome.closeRegisterFlow)
        assertTrue(
            "a check that creates nothing must disarm the append",
            outcome.disarmSnapshot,
        )
    }

    @Test
    fun `3b - the spray screen routes check-for-updates into the re-verify sheet`() {
        val screen = moduleSource(
            "src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt",
        )
        assertTrue(
            "check-for-updates must use the shared routing decision",
            screen.contains("ChemicalAddFromSprayRouting.onCheckForUpdates()"),
        )
        assertTrue(
            "the spray flow must open the canonical re-verify sheet",
            screen.contains("ChemicalReverifySheet("),
        )
        assertTrue(
            "the accepted draft must open in the ordinary editor",
            screen.contains("pendingIntelligence = draft.intelligence"),
        )
    }

    @Test
    fun `18 - cancelling add-from-spray clears the id snapshot`() {
        // Disarmed on every terminal path that created nothing.
        assertTrue(ChemicalAddFromSprayRouting.onRegisterFlowClosed(false).disarmSnapshot)
        assertTrue(ChemicalAddFromSprayRouting.onManualEntryClosed(false).disarmSnapshot)
        assertTrue(ChemicalAddFromSprayRouting.onReverifyClosed().disarmSnapshot)
        assertTrue(ChemicalAddFromSprayRouting.onCheckForUpdates().disarmSnapshot)

        // Kept armed ONLY while deliberately transferring to manual entry,
        // which is still on its way to creating the product.
        assertFalse(ChemicalAddFromSprayRouting.onEnterManually().disarmSnapshot)
        assertFalse(ChemicalAddFromSprayRouting.onManualEntryClosed(true).disarmSnapshot)
        assertFalse(ChemicalAddFromSprayRouting.onRegisterFlowClosed(true).disarmSnapshot)

        // A disarmed snapshot appends nothing, however many products appear.
        assertNull(ChemicalAddFromSprayRouting.createdId(null, listOf("a", "b", "c")))
        // An armed one appends the product that was not there before - by id,
        // never by name and never "the first in the store".
        assertEquals(
            "new",
            ChemicalAddFromSprayRouting.createdId(setOf("a", "b"), listOf("a", "b", "new")),
        )
        assertNull(ChemicalAddFromSprayRouting.createdId(setOf("a", "b"), listOf("a", "b")))
    }

    // =========================================================================
    // 4-7  Re-verification
    // =========================================================================

    @Test
    fun `4 - the re-verify sheet contains no write of any kind`() {
        // "Keep what I have" writes nothing because the sheet CANNOT write:
        // it holds no view model and calls no repository.
        val sheet = codeOnly(
            moduleSource("src/main/java/com/rork/vinetrack/ui/screens/ChemicalReverifySheet.kt"),
        )
        listOf(
            "updateSavedChemical",
            "createSavedChemical",
            "vm.",
            "AppViewModel",
        ).forEach { forbidden ->
            assertFalse(
                "the re-verify sheet must not be able to write ($forbidden)",
                sheet.contains(forbidden),
            )
        }
    }

    @Test
    fun `5 and 6 - an accepted update is a draft on the ORIGINAL saved id`() {
        val stored = chemical(
            id = "chem-original",
            registeredUses = listOf(
                grapeUse(
                    ChemicalLabelRate(
                        basis = ChemicalLabelRateBasis.PER_HECTARE,
                        value = 2.0,
                        unit = "L",
                        rateId = "rate_v1_a",
                    ),
                ),
            ),
        )
        val candidate = ChemicalIntelligence(
            registeredUses = listOf(
                grapeUse(
                    ChemicalLabelRate(
                        basis = ChemicalLabelRateBasis.PER_HECTARE,
                        value = 3.0,
                        unit = "L",
                        rateId = "rate_v1_b",
                    ),
                ),
            ),
            productCategory = "fungicide",
        )

        val result = ChemicalReverifyFlow.resolve(stored, candidate, "2026-08-31T00:00:00Z")
        assertTrue(
            "expected Changes, got ${result::class.simpleName}",
            result is ChemicalReverifyFlow.Result.Changes,
        )
        val changes = result as ChemicalReverifyFlow.Result.Changes

        val draft = ChemicalReverifyFlow.draftFor(stored, changes.outcome)
        // 6: the SAME record is updated. Nothing is matched by name and no
        // second product is ever inserted.
        assertEquals("chem-original", draft.chemical.id)
        // 5: a draft is an in-memory object. Producing it performed no write -
        // the editor's explicit Save is the only thing that does.
        assertNotNull(draft.intelligence)
    }

    @Test
    fun `7 - the checking phase states the lookup duration honestly`() {
        val notice = ChemicalLookupAdvisory.CHECKING_TEXT
        assertEquals(
            "We're checking the official registration and reading the product label " +
                "for grapevine uses and rates. This can take a few minutes.",
            notice,
        )
        // No invented progress: a bar that stalls at 90% is a worse lie than a
        // slow spinner.
        assertFalse(notice.contains("%"))

        val sheet = moduleSource(
            "src/main/java/com/rork/vinetrack/ui/screens/ChemicalReverifySheet.kt",
        )
        assertTrue(
            "the Checking phase must show the duration advisory",
            sheet.contains("ChemicalLookupAdvisory.CHECKING_TEXT"),
        )
        assertTrue(
            "and keep the reassurance that nothing is saved yet",
            sheet.contains("not changed until you accept an update"),
        )
    }

    // =========================================================================
    // 8-11  The picker reads default_rates, never the legacy columns
    // =========================================================================

    @Test
    fun `8 - a 560 g per ha default on a Kg product hands over 560 g`() {
        val chem = chemical(
            unit = "Kg",
            ratePerHa = 999.0,
            rates = listOf(
                ChemicalRate(id = "r1", label = "Per Ha", value = 999.0, basis = "per_hectare"),
            ),
            defaultRates = defaults(perHectare = slot(value = 560.0, unit = "g")),
        )

        val choices = ChemicalSprayDefaultHandoff.choicesFor(chem)
        assertEquals(1, choices.size)
        // The amount and the unit travel together. 560 read against the pack
        // unit would be "560 Kg/ha" - the same number, a thousandfold apart.
        assertEquals(560.0, choices[0].rate, 0.0001)
        assertEquals("g", choices[0].unit)
        assertEquals(SprayCalculator.RateBasis.PER_HECTARE, choices[0].basis)

        val prefill = ChemicalSprayDefaultHandoff.prefillFor(chem)
        assertNotNull(prefill)
        assertEquals(560.0, prefill!!.rate, 0.0001)
        assertEquals("g", prefill.unit)

        assertEquals("560 g/ha", ChemicalDefaultRateDisplay.line(chem))
    }

    @Test
    fun `9 - two confirmed bases offer both and select neither`() {
        val chem = chemical(
            defaultRates = defaults(
                perHectare = slot(value = 2.0, unit = "L"),
                per100Litres = slot(
                    value = 150.0,
                    unit = "g",
                    basis = ChemicalDefaultRateBasis.PER_100_LITRES,
                ),
            ),
        )

        val choices = ChemicalSprayDefaultHandoff.choicesFor(chem)
        assertEquals(2, choices.size)
        assertEquals("2 L/ha", "${choices[0].rate.toInt()} ${choices[0].unit}/ha")
        assertEquals(SprayCalculator.RateBasis.PER_100L, choices[1].basis)

        // Per-hectare and per-100 L are different ways of dosing the same
        // spray. Choosing for the operator would silently decide how the mix
        // is built, so nothing is prefilled.
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(chem))
    }

    @Test
    fun `10 - a structured product exposes no legacy rate choice`() {
        // Registered uses, so structured - but no confirmed default at all.
        val chem = chemical(
            ratePerHa = 999.0,
            rates = listOf(
                ChemicalRate(id = "r1", label = "Per Ha", value = 999.0, basis = "per_hectare"),
            ),
            registeredUses = listOf(grapeUse()),
            defaultRates = null,
        )

        assertFalse(
            "a structured product is never legacy, however empty its default",
            ChemicalSprayDefaultHandoff.isLegacyRateRecord(chem),
        )
        assertTrue(ChemicalSprayDefaultHandoff.choicesFor(chem).isEmpty())
        assertNull(ChemicalSprayDefaultHandoff.prefillFor(chem))
        assertEquals(
            ChemicalDefaultRateDisplay.CONFIRMATION_REQUIRED,
            ChemicalDefaultRateDisplay.line(chem),
        )
    }

    @Test
    fun `10b - an empty or malformed default does not make a product legacy`() {
        val emptyDoc = chemical(registeredUses = listOf(grapeUse()), defaultRates = defaults())
        assertFalse(ChemicalSprayDefaultHandoff.isLegacyRateRecord(emptyDoc))

        val malformed = chemical(
            registeredUses = listOf(grapeUse()),
            defaultRates = defaults(perHectare = slot(value = 2.0, rateIds = emptyList())),
        )
        assertFalse(ChemicalSprayDefaultHandoff.isLegacyRateRecord(malformed))
        assertTrue(ChemicalSprayDefaultHandoff.choicesFor(malformed).isEmpty())
    }

    @Test
    fun `11 - a genuinely legacy record keeps its compatibility picker`() {
        val legacy = chemical(
            unit = "Litres",
            ratePerHa = 2.0,
            rates = listOf(
                ChemicalRate(id = "r1", label = "Per Ha", value = 2.0, basis = "per_hectare"),
            ),
            registeredUses = null,
            defaultRates = null,
        )

        assertTrue(ChemicalSprayDefaultHandoff.isLegacyRateRecord(legacy))
        // No structured line is invented for it, so the screen keeps showing
        // the legacy figures rather than demanding a confirmation that would
        // strand an old record.
        assertNull(ChemicalDefaultRateDisplay.line(legacy))
        assertFalse(ChemicalDefaultRateDisplay.needsConfirmation(legacy))

        val screen = moduleSource(
            "src/main/java/com/rork/vinetrack/ui/screens/SprayCalculatorScreen.kt",
        )
        assertTrue(
            "the legacy picker must be gated on the legacy test",
            screen.contains("ChemicalSprayDefaultHandoff.isLegacyRateRecord(chem)"),
        )
        assertTrue(
            "the structured picker must build from the canonical helper",
            screen.contains("ChemicalSprayDefaultHandoff.choicesFor(chem)"),
        )
    }

    // =========================================================================
    // 12-15  Portal-identical validation of a persisted slot
    // =========================================================================

    private fun assertUnusable(message: String, doc: StoredChemicalDefaultRates) {
        val chem = chemical(defaultRates = doc, registeredUses = listOf(grapeUse()))
        assertNull(
            "$message must not validate",
            ChemicalDefaultRateValidity.validSlot(doc, ChemicalDefaultRateBasis.PER_HECTARE),
        )
        assertNull(
            "$message must not prefill",
            ChemicalSprayDefaultHandoff.prefillFor(chem),
        )
        assertTrue(
            "$message must offer no choice",
            ChemicalSprayDefaultHandoff.choicesFor(chem).isEmpty(),
        )
        assertNull(
            "$message must not display as a confirmed rate",
            ChemicalDefaultRateDisplay.slotDisplay(doc, ChemicalDefaultRateBasis.PER_HECTARE),
        )
    }

    @Test
    fun `12 - an unsupported root version is never read`() {
        assertUnusable(
            "a version 2 document",
            defaults(perHectare = slot(value = 2.0), version = 2),
        )
        assertUnusable(
            "a version 0 document",
            defaults(perHectare = slot(value = 2.0), version = 0),
        )
    }

    @Test
    fun `13 - a scalar carrying bounds is a contradiction, not a dose`() {
        // Reads as "exactly 620" and "anywhere in 560-700" at once. A reader
        // that picks one is guessing which half was meant.
        assertUnusable(
            "a scalar with bounds",
            defaults(
                perHectare = slot(value = 620.0, unit = "g", minValue = 560.0, maxValue = 700.0),
            ),
        )
    }

    @Test
    fun `14 - a slot filed under the wrong basis is never applied`() {
        // A per-100 L rate stored in the per-hectare slot would be sprayed per
        // hectare.
        assertUnusable(
            "a per_100_litres slot in the per_hectare position",
            defaults(
                perHectare = slot(
                    value = 150.0,
                    unit = "g",
                    basisRaw = ChemicalDefaultRateBasis.PER_100_LITRES.raw,
                ),
            ),
        )
    }

    @Test
    fun `15 - malformed identities, units, sources and amounts are all rejected`() {
        assertUnusable("an empty citation list", defaults(perHectare = slot(value = 2.0, rateIds = emptyList())))
        assertUnusable(
            "a UUID citation",
            defaults(perHectare = slot(value = 2.0, rateIds = listOf("8f14e45f-ceea-467a-9575"))),
        )
        assertUnusable(
            "a blank citation",
            defaults(perHectare = slot(value = 2.0, rateIds = listOf("rate_v1_a", " "))),
        )
        assertUnusable(
            "a bare prefix citation",
            defaults(perHectare = slot(value = 2.0, rateIds = listOf("rate_v1_"))),
        )
        assertUnusable(
            "an unminted option key",
            defaults(perHectare = slot(value = 2.0, optionKey = "option-42")),
        )
        assertUnusable(
            "a bare prefix option key",
            defaults(perHectare = slot(value = 2.0, optionKey = "default_option_v1_")),
        )
        assertUnusable(
            "an unsupported unit",
            defaults(perHectare = slot(value = 2.0, unit = "sachets")),
        )
        assertUnusable("a blank unit", defaults(perHectare = slot(value = 2.0, unit = " ")))
        assertUnusable(
            "an unattributable source",
            defaults(perHectare = slot(value = 2.0, source = "inferred")),
        )
        assertUnusable("a zero amount", defaults(perHectare = slot(value = 0.0)))
        assertUnusable("a negative amount", defaults(perHectare = slot(value = -2.0)))
        assertUnusable("a NaN amount", defaults(perHectare = slot(value = Double.NaN)))
        assertUnusable(
            "an infinite amount",
            defaults(perHectare = slot(value = Double.POSITIVE_INFINITY)),
        )
        assertUnusable(
            "a lone lower bound",
            defaults(perHectare = slot(minValue = 560.0, unit = "g")),
        )
        assertUnusable(
            "a lone upper bound",
            defaults(perHectare = slot(maxValue = 700.0, unit = "g")),
        )
        assertUnusable(
            "an inverted range",
            defaults(perHectare = slot(minValue = 700.0, maxValue = 560.0, unit = "g")),
        )
        assertUnusable("an entirely empty amount", defaults(perHectare = slot()))
    }

    @Test
    fun `15b - an unnarrowed band validates but is never a confirmed dose`() {
        // The shape is legal; it simply is not a decision. It must not prefill
        // and must not display as this vineyard's rate.
        val doc = defaults(perHectare = slot(minValue = 560.0, maxValue = 700.0, unit = "g"))
        val valid = ChemicalDefaultRateValidity.validSlot(doc, ChemicalDefaultRateBasis.PER_HECTARE)
        assertNotNull("a true range is a valid stored shape", valid)
        assertNull("but it records no confirmed dose", valid!!.scalar)

        assertNull(
            ChemicalDefaultRateValidity.confirmedScalar(doc, ChemicalDefaultRateBasis.PER_HECTARE),
        )
        assertNull(
            ChemicalDefaultRateDisplay.slotDisplay(doc, ChemicalDefaultRateBasis.PER_HECTARE),
        )
        assertTrue(
            ChemicalSprayDefaultHandoff.choicesFor(
                chemical(defaultRates = doc, registeredUses = listOf(grapeUse())),
            ).isEmpty(),
        )
    }

    @Test
    fun `15c - a well-formed scalar is accepted, so the gate is not vacuous`() {
        val doc = defaults(perHectare = slot(value = 2.0, unit = "L"))
        val valid = ChemicalDefaultRateValidity.validSlot(doc, ChemicalDefaultRateBasis.PER_HECTARE)
        assertNotNull(valid)
        assertEquals(2.0, valid!!.scalar!!, 0.0001)
        assertEquals("L", valid.unit)
        // Both readers agree, which is the whole point of one shared gate.
        assertEquals("2 L/ha", ChemicalDefaultRateDisplay.slotDisplay(doc, ChemicalDefaultRateBasis.PER_HECTARE))
        assertNotNull(
            ChemicalSprayDefaultHandoff.prefillFor(doc, ChemicalDefaultRateBasis.PER_HECTARE),
        )
        // `recommended` is accepted vocabulary alongside `operator`.
        val recommended = defaults(
            perHectare = slot(value = 2.0, source = StoredChemicalDefaultRate.SOURCE_RECOMMENDED),
        )
        assertNotNull(
            ChemicalDefaultRateValidity.validSlot(recommended, ChemicalDefaultRateBasis.PER_HECTARE),
        )
    }

    // =========================================================================
    // 16-17  The write function enforces the stale-default contract
    // =========================================================================

    @Test
    fun `16 - a stale default blocks the write function, not only the button`() {
        val uses = listOf(
            grapeUse(
                ChemicalLabelRate(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    value = 2.0,
                    unit = "L",
                    rateId = "rate_v1_new",
                ),
            ),
        )
        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example Fungicide",
            productCategory = "fungicide",
            intelligence = ChemicalIntelligence(
                registeredUses = uses,
                productCategory = "fungicide",
            ),
            staleDefaultBases = listOf(ChemicalDefaultRateBasis.PER_HECTARE),
        )
        assertTrue(
            "a stale default must be a violation",
            evaluation.violations.any {
                it.code == ChemicalSaveViolationCode.DEFAULT_RATE_STALE
            },
        )

        // The button and the write function must compute the SAME thing. They
        // did not: save() omitted the stale bases entirely, so it evaluated a
        // contract in which the stale rate was fine.
        val screen = codeOnly(
            moduleSource("src/main/java/com/rork/vinetrack/ui/screens/ChemicalsScreen.kt"),
        )
        assertEquals(
            "both the rendered gate and save() must pass the stale bases",
            2,
            Regex("staleDefaultBases = unresolvedStaleBases").findAll(screen).count(),
        )
        assertEquals(
            "both must compute the unresolved set the same way",
            2,
            Regex("""staleDefaultBases\.filter \{""").findAll(screen).count(),
        )
    }

    @Test
    fun `17 - clearing the stale slot permits Save and writes an explicit empty v1`() {
        val cleared = clearedDefaultRates()
        assertNull(cleared.slot(ChemicalDefaultRateBasis.PER_HECTARE))
        assertNull(cleared.slot(ChemicalDefaultRateBasis.PER_100_LITRES))
        assertTrue(cleared.isEmpty)

        // Explicit, never omitted: the REST client drops nulls, so an omitted
        // column would leave the stale default live on the server.
        assertEquals("""{"version":1}""", json.encodeToString(cleared))

        // With the slot cleared there is no unresolved stale basis left, so the
        // contract no longer blocks the write.
        val uses = listOf(
            grapeUse(
                ChemicalLabelRate(
                    basis = ChemicalLabelRateBasis.PER_HECTARE,
                    value = 2.0,
                    unit = "L",
                    rateId = "rate_v1_new",
                ),
            ),
        )
        val unresolved = listOf(ChemicalDefaultRateBasis.PER_HECTARE)
            .filter { cleared.slot(it) != null }
        assertTrue("clearing resolves the staleness", unresolved.isEmpty())

        val evaluation = ChemicalSaveContract.evaluate(
            productName = "Example Fungicide",
            productCategory = "fungicide",
            intelligence = ChemicalIntelligence(
                registeredUses = uses,
                productCategory = "fungicide",
            ),
            staleDefaultBases = unresolved,
        )
        assertFalse(
            evaluation.violations.any {
                it.code == ChemicalSaveViolationCode.DEFAULT_RATE_STALE
            },
        )
    }
}
