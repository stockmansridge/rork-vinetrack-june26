package com.rork.vinetrack.data.chemical

/**
 * A state/territory a registered rate is conditioned on.
 *
 * # Why the jurisdiction is read out of the condition text
 *
 * Australian labels condition rates BY STATE, and the state IS the condition
 * that distinguishes `2 L/100 L` from `3 L/100 L` on one product. The
 * manufacturer-label parser already binds that STATE column into each rate's
 * condition (`ingestion/manufacturer_label.ts`), and it deliberately adds no
 * new rate field for it — the condition string is the contract.
 *
 * So this reads what the server wrote, and never invents a restriction. A
 * rate whose condition names no state is not "restricted to nowhere"; it is
 * simply unrestricted, and must stay eligible everywhere.
 *
 * Mirrors the iOS `ChemicalRateJurisdiction` exactly.
 */
enum class ChemicalRateJurisdiction(val raw: String, val displayName: String) {
    NSW("NSW", "NSW"),
    VIC("VIC", "Vic"),
    QLD("QLD", "Qld"),
    SA("SA", "SA"),
    WA("WA", "WA"),
    TAS("TAS", "Tasmania"),
    NT("NT", "NT"),
    ACT("ACT", "ACT"),
    ;

    /** The country whose register conditions rates on this jurisdiction. */
    val countryCode: String get() = "AU"

    companion object {
        /** Full names as labels print them, lower-cased for matching. */
        private val fullNames: Map<String, ChemicalRateJurisdiction> = mapOf(
            "new south wales" to NSW,
            "victoria" to VIC,
            "queensland" to QLD,
            "south australia" to SA,
            "western australia" to WA,
            "tasmania" to TAS,
            "northern territory" to NT,
            "australian capital territory" to ACT,
        )

        /** Abbreviations, including the punctuated forms labels use. */
        private val abbreviations: Map<String, ChemicalRateJurisdiction> = mapOf(
            "NSW" to NSW, "VIC" to VIC, "QLD" to QLD, "SA" to SA,
            "WA" to WA, "TAS" to TAS, "TASSIE" to TAS, "NT" to NT, "ACT" to ACT,
        )

        /**
         * Read the vineyard's own jurisdiction from free text.
         *
         * Returns null for anything it cannot recognise, which is the correct
         * answer: an unrecognised jurisdiction must never silently become a
         * different one, because that would recommend another state's rate.
         */
        fun parse(raw: String?): ChemicalRateJurisdiction? {
            val trimmed = raw?.trim().orEmpty()
            if (trimmed.isEmpty()) return null
            fullNames[trimmed.lowercase()]?.let { return it }
            val squashed = trimmed.uppercase().filter { it.isLetter() }
            return abbreviations[squashed]
        }

        /**
         * Every jurisdiction a rate condition names.
         *
         * An EMPTY result means the condition named none — the rate is not
         * state-restricted. That is emphatically different from "applies
         * nowhere", and conflating the two would hide every unconditioned rate
         * on the label.
         *
         * Matching is whole-token so `WA` is never found inside `WATER` and
         * `SA` is never found inside `SEASON`; the multi-word full names are
         * matched against the whole string separately.
         */
        fun mentioned(text: String?): List<ChemicalRateJurisdiction> {
            if (text.isNullOrEmpty()) return emptyList()
            val seen = mutableSetOf<ChemicalRateJurisdiction>()

            val lowered = text.lowercase()
            for ((name, jurisdiction) in fullNames) {
                if (lowered.contains(name)) seen.add(jurisdiction)
            }

            // Whole tokens only. `/`, `,`, `&`, `.` and spaces all separate
            // the state list a label prints in one cell ("NSW, Vic, Qld / SA & WA").
            for (token in text.uppercase().split { !it.isLetter() }) {
                abbreviations[token]?.let { seen.add(it) }
            }

            // Deterministic order so a condition summary reads the same every
            // time it is drawn.
            return entries.filter(seen::contains)
        }

        private fun String.split(isSeparator: (Char) -> Boolean): List<String> =
            buildList {
                val current = StringBuilder()
                for (char in this@split) {
                    if (isSeparator(char)) {
                        if (current.isNotEmpty()) {
                            add(current.toString())
                            current.clear()
                        }
                    } else {
                        current.append(char)
                    }
                }
                if (current.isNotEmpty()) add(current.toString())
            }
    }
}
