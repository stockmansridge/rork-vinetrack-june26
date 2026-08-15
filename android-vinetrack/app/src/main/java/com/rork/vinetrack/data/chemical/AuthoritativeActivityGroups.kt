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

    /** Bump whenever the table changes. Persisted with each verification. */
    const val TABLE_VERSION: Int = 1

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
        if (extracted.scheme == authoritative.scheme && extracted.code == authoritative.code) {
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

        // ---- Herbicides (HRAC) ----
        "glyphosate" to hrac("G", "EPSP synthase inhibitor"),
        "glufosinate" to hrac("H", "Glutamine synthetase inhibitor"),
        "glufosinate ammonium" to hrac("H", "Glutamine synthetase inhibitor"),
        "paraquat" to hrac("D", "PSI electron diverter"),
        "diquat" to hrac("D", "PSI electron diverter"),
        "simazine" to hrac("C1", "PSII inhibitor"),
        "diuron" to hrac("C2", "PSII inhibitor"),
        "amitrole" to hrac("F3", "Carotenoid biosynthesis inhibitor"),
        "oxyfluorfen" to hrac("E", "PPO inhibitor"),
        "carfentrazone" to hrac("E", "PPO inhibitor"),
        "flumioxazin" to hrac("E", "PPO inhibitor"),
        "haloxyfop" to hrac("A", "ACCase inhibitor"),
        "clethodim" to hrac("A", "ACCase inhibitor"),
        "fluazifop" to hrac("A", "ACCase inhibitor"),
        "sethoxydim" to hrac("A", "ACCase inhibitor"),
        "propyzamide" to hrac("K1", "Microtubule assembly inhibitor"),
        "pendimethalin" to hrac("K1", "Microtubule assembly inhibitor"),
        "trifluralin" to hrac("K1", "Microtubule assembly inhibitor"),
        "isoxaben" to hrac("L", "Cellulose synthesis inhibitor"),
        "indaziflam" to hrac("L", "Cellulose synthesis inhibitor"),
        "metsulfuron methyl" to hrac("B", "ALS inhibitor"),
        "chlorsulfuron" to hrac("B", "ALS inhibitor"),
        "imazapyr" to hrac("B", "ALS inhibitor"),
        "2,4 d" to hrac("O", "Synthetic auxin"),
        "mcpa" to hrac("O", "Synthetic auxin"),
        "triclopyr" to hrac("O", "Synthetic auxin"),
        "clopyralid" to hrac("O", "Synthetic auxin"),
        "pelargonic acid" to hrac("Z", "Unknown / non-selective contact"),

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
