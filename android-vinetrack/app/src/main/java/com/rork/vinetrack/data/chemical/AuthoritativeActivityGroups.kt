package com.rork.vinetrack.data.chemical

/**
 * A curated, in-app classification of common viticultural active ingredients to
 * their FRAC / HRAC / IRAC activity groups.
 *
 * This is VineTrack's `AUTHORITATIVE_CLASSIFICATION` source. It exists so that
 * an AI extraction is never the only opinion in the room: whatever the lookup
 * says an active's group is, it is checked against this table, and a
 * disagreement becomes a visible conflict rather than a silent overwrite.
 *
 * Scope and honesty about it:
 * - Covers actives commonly used in Australian and New Zealand vineyards. An
 *   active that is absent is simply UNKNOWN here — absence is never read as
 *   "the extraction must be right".
 * - Activity group is a property of the ACTIVE, not of a brand, and it does not
 *   vary by country. That is why this table needs no country dimension while
 *   product identity emphatically does.
 * - Keyed by the active's ISO common name, lower-cased.
 *
 * Mirrors the iOS `AuthoritativeActivityGroups` and the `chemical-info-lookup`
 * edge function table so all three agree; [TABLE_VERSION] is stamped onto every
 * verification so a future re-verification can tell which revision judged a
 * product.
 */
object AuthoritativeActivityGroups {

    /**
     * Bump whenever the table changes. Persisted with each verification.
     *
     * v2 — herbicides migrated from the legacy alphabetical codes to the
     * CURRENT Australian/global numeric mode-of-action groups, with per-active
     * legacy equivalence (see [legacyCodesForActive]). Completed spray
     * snapshots are never rewritten: they keep the classification that was
     * current when they were recorded. Saved chemicals pick the current group
     * up through the normal Re-verify path.
     */
    const val TABLE_VERSION: Int = 2

    /** The source citation recorded when this table supplies a group. */
    fun source(retrievedAt: String? = null): ChemicalDataSource = ChemicalDataSource(
        kind = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
        name = "VineTrack activity group reference v$TABLE_VERSION (FRAC/HRAC/IRAC)",
        retrievedAt = retrievedAt,
    )

    /**
     * Look up an active's authoritative group.
     *
     * Returns null when the active is not in the table — which means "unknown",
     * never "unclassified". Callers must not treat null as permission to trust
     * an unverified extraction.
     */
    fun groupForActive(name: String): ChemicalActivityGroup? {
        val key = normalise(name)
        if (key.isEmpty()) return null
        table[key]?.let { return it }
        // Salt/ester forms are written many ways ("glyphosate isopropylamine").
        // Match the longest known active contained in the string so a
        // formulation suffix does not lose the classification.
        val best = table.keys
            .filter { it.length >= 5 && key.contains(it) }
            .maxByOrNull { it.length }
            ?: return null
        return table[best]
    }

    /** Whether the table has an opinion about this active at all. */
    fun knows(activeName: String): Boolean = groupForActive(activeName) != null

    /** Outcome of cross-checking an extracted group against the table. */
    data class Reconciliation(
        val group: ChemicalActivityGroup?,
        val source: ChemicalDataSourceKind?,
        val conflict: ChemicalVerificationConflict?,
    )

    /**
     * Cross-checks an extracted group against the authoritative table.
     *
     * The source-disagreement gate in one function:
     * - No authoritative opinion → returns the extracted group unchanged and no
     *   conflict, but the caller must NOT call the result authoritative.
     * - Agreement → the authoritative group wins (same code, better source).
     * - Disagreement → returns the AUTHORITATIVE group plus a conflict. The
     *   extracted value never silently survives.
     */
    fun reconcile(
        activeName: String,
        extracted: ChemicalActivityGroup?,
        extractedSource: ChemicalDataSourceKind,
    ): Reconciliation {
        val authoritative = groupForActive(activeName)
            ?: return Reconciliation(
                group = extracted,
                source = extracted?.let { extractedSource },
                conflict = null,
            )
        if (extracted == null || !extracted.isResistanceRelevant) {
            return Reconciliation(
                group = authoritative,
                source = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
                conflict = null,
            )
        }
        // Canonical identity, not string identity: a legacy code for this
        // active is the SAME classification, so it agrees rather than
        // conflicts. The CURRENT group is served either way — growers see
        // today's number, never the code a historical source happened to use.
        if (groupsAreEquivalent(activeName, extracted, authoritative)) {
            return Reconciliation(
                group = authoritative,
                source = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
                conflict = null,
            )
        }
        return Reconciliation(
            group = authoritative,
            source = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
            conflict = ChemicalVerificationConflict(
                field = "activity_group",
                activeIngredientName = activeName,
                extractedValue = extracted.displayLabel,
                authoritativeValue = authoritative.displayLabel,
                extractedSource = extractedSource,
                authoritativeSource = ChemicalDataSourceKind.AUTHORITATIVE_CLASSIFICATION,
            ),
        )
    }

    private fun normalise(raw: String): String =
        raw.trim().lowercase().replace("-", " ").replace("  ", " ")

    private fun frac(code: String, name: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.FRAC, code, name)

    private fun hrac(code: String, name: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.HRAC, code, name)

    /**
     * Every code a herbicide active was legitimately published under BEFORE
     * the current numeric classification.
     *
     * ## Why equivalence is per ACTIVE and never per letter
     *
     * Australia replaced the alphabetical herbicide mode-of-action codes with
     * the globally aligned NUMERIC system; labels carried numbers from 2022 and
     * the transition completed in 2024. A current label says "Group 14" where
     * an older one said "Group E" (old global HRAC) or "Group G" (old
     * Australian) — one classification, three vocabularies.
     *
     * The two legacy alphabets reuse the same characters for different
     * chemistries: "E" was PPO inhibitors globally but carbamates in Australia,
     * "G" was glyphosate globally but PPO inhibitors in Australia. A letter on
     * its own is therefore not decodable; a letter plus the active it was
     * printed for always is.
     *
     * Mirrored byte-for-byte in the edge function and on iOS.
     */
    private val LEGACY_HRAC_CODES: Map<String, List<String>> = mapOf(
        "glyphosate" to listOf("G", "M"),
        "glufosinate" to listOf("H", "N"),
        "glufosinate ammonium" to listOf("H", "N"),
        "paraquat" to listOf("D", "L"),
        "diquat" to listOf("D", "L"),
        "simazine" to listOf("C1", "C"),
        "diuron" to listOf("C2", "C"),
        "amitrole" to listOf("F3", "Q"),
        "oxyfluorfen" to listOf("E", "G"),
        "carfentrazone" to listOf("E", "G"),
        "flumioxazin" to listOf("E", "G"),
        "haloxyfop" to listOf("A"),
        "clethodim" to listOf("A"),
        "fluazifop" to listOf("A"),
        "sethoxydim" to listOf("A"),
        "propyzamide" to listOf("K1", "D"),
        "pendimethalin" to listOf("K1", "D"),
        "trifluralin" to listOf("K1", "D"),
        "isoxaben" to listOf("L", "O"),
        "indaziflam" to listOf("L", "O"),
        "metsulfuron methyl" to listOf("B"),
        "chlorsulfuron" to listOf("B"),
        "imazapyr" to listOf("B"),
        "2,4 d" to listOf("O", "I"),
        "mcpa" to listOf("O", "I"),
        "triclopyr" to listOf("O", "I"),
        "clopyralid" to listOf("O", "I"),
        "pelargonic acid" to listOf("Z"),
    )

    /**
     * Every herbicide active this table classifies, by its table key.
     *
     * Exposed so the shared contract tests can assert the RULE across the whole
     * herbicide table rather than spot-checking one product — a classification
     * that is only right for the active someone remembered to test is not a
     * classification anyone should trust.
     */
    val HERBICIDE_ACTIVE_NAMES: List<String>
        get() = table.entries
            .filter { it.value.scheme == ChemicalActivityGroupScheme.HRAC }
            .map { it.key }

    /**
     * Strip the decoration humans, labels and extractions put around a code so
     * `"Group 14"`, `"group14"` and `"14 (PPO inhibitor)"` all reduce to `14`.
     */
    fun normaliseCode(raw: String): String {
        var value = raw.trim().uppercase()
        for (prefix in listOf("GROUP ", "GROUP", "FRAC ", "HRAC ", "IRAC ", "MOA ", "CODE ")) {
            if (value.startsWith(prefix)) value = value.removePrefix(prefix).trim()
        }
        val paren = value.indexOf('(')
        if (paren >= 0) value = value.substring(0, paren).trim()
        return value.replace(" ", "")
    }

    /**
     * Legacy codes recorded for this active, normalised. Empty for actives with
     * no legacy alphabet (fungicides, insecticides) and for unknown actives.
     */
    fun legacyCodesForActive(name: String): List<String> {
        val key = normalise(name)
        if (key.isEmpty()) return emptyList()
        LEGACY_HRAC_CODES[key]?.let { return it.map(::normaliseCode) }
        // The same longest-contained-active rule [groupForActive] uses, so a
        // salt or ester form inherits its parent's legacy codes too.
        val best = LEGACY_HRAC_CODES.keys
            .filter { it.length >= 5 && key.contains(it) }
            .maxByOrNull { it.length }
            ?: return emptyList()
        return LEGACY_HRAC_CODES[best]?.map(::normaliseCode).orEmpty()
    }

    /**
     * Whether two classifications of the SAME active mean the same thing.
     *
     * This is the canonical-identity comparison the v2 migration turns on. A
     * label printed before the numeric realignment says "Group E" for exactly
     * the chemistry a current label calls "Group 14". Reporting those to a
     * grower as sources that disagree is a false alarm about a resistance group
     * — the one place in the app where a false alarm costs most trust.
     *
     * A genuine disagreement — a source calling flumioxazin a Group 2 — still
     * conflicts, which is the entire point of keeping the check.
     */
    fun groupsAreEquivalent(
        activeName: String,
        a: ChemicalActivityGroup?,
        b: ChemicalActivityGroup?,
    ): Boolean {
        if (a == null || b == null || a.scheme != b.scheme) return false
        val codeA = normaliseCode(a.code)
        val codeB = normaliseCode(b.code)
        if (codeA.isEmpty() || codeB.isEmpty()) return false
        if (codeA == codeB) return true
        if (a.scheme != ChemicalActivityGroupScheme.HRAC) return false
        val legacy = legacyCodesForActive(activeName)
        if (legacy.isEmpty()) return false
        val current = normaliseCode(groupForActive(activeName)?.code.orEmpty())
        if (current.isEmpty()) return false
        fun isCurrentOrLegacy(code: String) = code == current || legacy.contains(code)
        return isCurrentOrLegacy(codeA) && isCurrentOrLegacy(codeB)
    }

    private fun irac(code: String, name: String) =
        ChemicalActivityGroup.of(ChemicalActivityGroupScheme.IRAC, code, name)

    /** Active (lower-case ISO common name) → activity group. */
    private val table: Map<String, ChemicalActivityGroup> = mapOf(
        // ---- Fungicides (FRAC) ----
        "tebuconazole" to frac("3", "DMI / Triazole"),
        "myclobutanil" to frac("3", "DMI / Triazole"),
        "penconazole" to frac("3", "DMI / Triazole"),
        "triadimenol" to frac("3", "DMI / Triazole"),
        "tetraconazole" to frac("3", "DMI / Triazole"),
        "difenoconazole" to frac("3", "DMI / Triazole"),
        "propiconazole" to frac("3", "DMI / Triazole"),
        "flutriafol" to frac("3", "DMI / Triazole"),
        "triflumizole" to frac("3", "DMI / Imidazole"),
        "prochloraz" to frac("3", "DMI / Imidazole"),
        "fenarimol" to frac("3", "DMI / Pyrimidine"),
        "metalaxyl" to frac("4", "Phenylamide"),
        "metalaxyl m" to frac("4", "Phenylamide"),
        "mefenoxam" to frac("4", "Phenylamide"),
        "benalaxyl" to frac("4", "Phenylamide"),
        "spiroxamine" to frac("5", "Amine / Morpholine"),
        "dimethomorph" to frac("40", "CAA"),
        "mandipropamid" to frac("40", "CAA"),
        "benthiavalicarb" to frac("40", "CAA"),
        "iprovalicarb" to frac("40", "CAA"),
        "carbendazim" to frac("1", "MBC / Benzimidazole"),
        "thiophanate methyl" to frac("1", "MBC / Thiophanate"),
        "iprodione" to frac("2", "Dicarboximide"),
        "procymidone" to frac("2", "Dicarboximide"),
        "cyprodinil" to frac("9", "Anilinopyrimidine"),
        "pyrimethanil" to frac("9", "Anilinopyrimidine"),
        "mepanipyrim" to frac("9", "Anilinopyrimidine"),
        "azoxystrobin" to frac("11", "QoI / Strobilurin"),
        "trifloxystrobin" to frac("11", "QoI / Strobilurin"),
        "pyraclostrobin" to frac("11", "QoI / Strobilurin"),
        "kresoxim methyl" to frac("11", "QoI / Strobilurin"),
        "famoxadone" to frac("11", "QoI"),
        "fenamidone" to frac("11", "QoI"),
        "fludioxonil" to frac("12", "Phenylpyrrole"),
        "quinoxyfen" to frac("13", "Aza-naphthalene"),
        "boscalid" to frac("7", "SDHI"),
        "fluopyram" to frac("7", "SDHI"),
        "fluxapyroxad" to frac("7", "SDHI"),
        "penthiopyrad" to frac("7", "SDHI"),
        "isopyrazam" to frac("7", "SDHI"),
        "benzovindiflupyr" to frac("7", "SDHI"),
        "pydiflumetofen" to frac("7", "SDHI"),
        "fenhexamid" to frac("17", "Hydroxyanilide"),
        "cyazofamid" to frac("21", "QiI"),
        "amisulbrom" to frac("21", "QiI"),
        "metrafenone" to frac("U8", "Aryl-phenyl-ketone"),
        "pyriofenone" to frac("U8", "Aryl-phenyl-ketone"),
        "cyflufenamid" to frac("U6", "Phenyl-acetamide"),
        "proquinazid" to frac("13", "Quinazolinone"),
        "fluazinam" to frac("29", "Uncoupler"),
        "ametoctradin" to frac("45", "QoSI"),
        "oxathiapiprolin" to frac("49", "OSBPI"),
        "fluopicolide" to frac("43", "Benzamide"),
        "zoxamide" to frac("22", "Benzamide"),
        "phosphorous acid" to frac("P07", "Host defence induction"),
        "phosphonic acid" to frac("P07", "Host defence induction"),
        "potassium phosphonate" to frac("P07", "Host defence induction"),
        "fosetyl aluminium" to frac("P07", "Host defence induction"),
        "fosetyl al" to frac("P07", "Host defence induction"),
        "sulfur" to frac("M2", "Multi-site / Inorganic"),
        "sulphur" to frac("M2", "Multi-site / Inorganic"),
        "copper hydroxide" to frac("M1", "Multi-site / Copper"),
        "copper oxychloride" to frac("M1", "Multi-site / Copper"),
        "cuprous oxide" to frac("M1", "Multi-site / Copper"),
        "tribasic copper sulfate" to frac("M1", "Multi-site / Copper"),
        "mancozeb" to frac("M3", "Multi-site / Dithiocarbamate"),
        "metiram" to frac("M3", "Multi-site / Dithiocarbamate"),
        "propineb" to frac("M3", "Multi-site / Dithiocarbamate"),
        "ziram" to frac("M3", "Multi-site / Dithiocarbamate"),
        "thiram" to frac("M3", "Multi-site / Dithiocarbamate"),
        "captan" to frac("M4", "Multi-site / Phthalimide"),
        "folpet" to frac("M4", "Multi-site / Phthalimide"),
        "chlorothalonil" to frac("M5", "Multi-site / Chloronitrile"),
        "dithianon" to frac("M9", "Multi-site / Quinone"),

        // ---- Herbicides (current Australian/global numeric MoA groups) ----
        // Legacy equivalents live in LEGACY_HRAC_CODES, keyed by the same name.
        "glyphosate" to hrac("9", "EPSP synthase inhibitor"),
        "glufosinate" to hrac("10", "Glutamine synthetase inhibitor"),
        "glufosinate ammonium" to hrac("10", "Glutamine synthetase inhibitor"),
        "paraquat" to hrac("22", "PSI electron diverter"),
        "diquat" to hrac("22", "PSI electron diverter"),
        "simazine" to hrac("5", "PSII inhibitor (serine 264 binder)"),
        "diuron" to hrac("5", "PSII inhibitor (serine 264 binder)"),
        "amitrole" to hrac("34", "Lycopene cyclase inhibitor"),
        "oxyfluorfen" to hrac("14", "PPO inhibitor"),
        "carfentrazone" to hrac("14", "PPO inhibitor"),
        "flumioxazin" to hrac("14", "PPO inhibitor"),
        "haloxyfop" to hrac("1", "ACCase inhibitor"),
        "clethodim" to hrac("1", "ACCase inhibitor"),
        "fluazifop" to hrac("1", "ACCase inhibitor"),
        "sethoxydim" to hrac("1", "ACCase inhibitor"),
        "propyzamide" to hrac("3", "Microtubule assembly inhibitor"),
        "pendimethalin" to hrac("3", "Microtubule assembly inhibitor"),
        "trifluralin" to hrac("3", "Microtubule assembly inhibitor"),
        "isoxaben" to hrac("29", "Cellulose synthesis inhibitor"),
        "indaziflam" to hrac("29", "Cellulose synthesis inhibitor"),
        "metsulfuron methyl" to hrac("2", "ALS inhibitor"),
        "chlorsulfuron" to hrac("2", "ALS inhibitor"),
        "imazapyr" to hrac("2", "ALS inhibitor"),
        "2,4 d" to hrac("4", "Auxin mimic"),
        "mcpa" to hrac("4", "Auxin mimic"),
        "triclopyr" to hrac("4", "Auxin mimic"),
        "clopyralid" to hrac("4", "Auxin mimic"),
        "pelargonic acid" to hrac("0", "Unknown / non-selective contact"),

        // ---- Insecticides & miticides (IRAC) ----
        "chlorpyrifos" to irac("1B", "Organophosphate"),
        "methomyl" to irac("1A", "Carbamate"),
        "alpha cypermethrin" to irac("3A", "Pyrethroid"),
        "bifenthrin" to irac("3A", "Pyrethroid"),
        "lambda cyhalothrin" to irac("3A", "Pyrethroid"),
        "deltamethrin" to irac("3A", "Pyrethroid"),
        "esfenvalerate" to irac("3A", "Pyrethroid"),
        "imidacloprid" to irac("4A", "Neonicotinoid"),
        "thiamethoxam" to irac("4A", "Neonicotinoid"),
        "acetamiprid" to irac("4A", "Neonicotinoid"),
        "clothianidin" to irac("4A", "Neonicotinoid"),
        "spinetoram" to irac("5", "Spinosyn"),
        "spinosad" to irac("5", "Spinosyn"),
        "abamectin" to irac("6", "Avermectin"),
        "emamectin benzoate" to irac("6", "Avermectin"),
        "buprofezin" to irac("16", "Chitin biosynthesis inhibitor"),
        "methoxyfenozide" to irac("18", "Diacylhydrazine"),
        "tebufenozide" to irac("18", "Diacylhydrazine"),
        "etoxazole" to irac("10B", "Mite growth inhibitor"),
        "clofentezine" to irac("10A", "Mite growth inhibitor"),
        "hexythiazox" to irac("10A", "Mite growth inhibitor"),
        "propargite" to irac("12C", "METI / Sulfite ester"),
        "fenbutatin oxide" to irac("12B", "Organotin miticide"),
        "bifenazate" to irac("20D", "Mitochondrial complex III inhibitor"),
        "chlorantraniliprole" to irac("28", "Diamide"),
        "cyantraniliprole" to irac("28", "Diamide"),
        "flubendiamide" to irac("28", "Diamide"),
        "sulfoxaflor" to irac("4C", "Sulfoximine"),
        "spirotetramat" to irac("23", "Tetramic acid"),
        "spirodiclofen" to irac("23", "Tetronic acid"),
        "pyriproxyfen" to irac("7C", "Juvenile hormone mimic"),
        "indoxacarb" to irac("22A", "Oxadiazine"),
        "bacillus thuringiensis" to irac("11A", "Bt / Microbial disruptor"),
    )
}
