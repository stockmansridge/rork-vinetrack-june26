package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.VineyardCountryCatalog
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The national scheme a product is registered under.
 *
 * Registration scheme + number is what makes a product identity real. Two
 * products can share a brand name across the Tasman and be different
 * registrations with different actives, different rates and different labels.
 */
@Serializable
enum class ChemicalRegistrationScheme(val raw: String, val label: String) {
    /** Australian Pesticides and Veterinary Medicines Authority. */
    @SerialName("apvma")
    APVMA("apvma", "APVMA"),

    /** NZ Agricultural Compounds and Veterinary Medicines (MPI) register. */
    @SerialName("acvm")
    ACVM("acvm", "ACVM"),

    /** NZ EPA hazardous substances approval (HSNO). */
    @SerialName("nz_epa")
    NZ_EPA("nz_epa", "NZ EPA"),

    /** Any other national register — kept so more countries slot in later. */
    @SerialName("other")
    OTHER("other", "Registration"),
    ;

    companion object {
        fun from(raw: String?): ChemicalRegistrationScheme? {
            val v = raw?.trim()?.lowercase()?.takeIf { it.isNotEmpty() } ?: return null
            return entries.firstOrNull { it.raw == v } ?: OTHER
        }

        /**
         * The registers that apply in a country, in the order a lookup should try
         * them. Empty for countries VineTrack has no register wired up for — the
         * contract stays extensible without pretending coverage exists.
         */
        fun schemesForCountry(code: String): List<ChemicalRegistrationScheme> =
            when (code.uppercase()) {
                "AU" -> listOf(APVMA)
                "NZ" -> listOf(ACVM, NZ_EPA)
                else -> emptyList()
            }
    }
}

/**
 * A country-scoped registered-product identity.
 *
 * Answers "what exact product is this?" — the question the whole Chemical
 * Intelligence stage exists to make answerable. Without one, a chemical can
 * never be more than partially verified.
 */
@Serializable
data class ChemicalRegistration(
    /** ISO country code, e.g. `"AU"`, `"NZ"`. */
    @SerialName("country_code") val countryCode: String = "",
    val scheme: ChemicalRegistrationScheme? = null,
    @SerialName("registration_number") val registrationNumber: String? = null,
    /** The registrant of record, which can differ from the brand a grower knows. */
    val registrant: String? = null,
    /** The exact registered product name, which can differ from what was typed. */
    @SerialName("registered_product_name") val registeredProductName: String? = null,
    /**
     * URL or document identifier of the label the information came from.
     *
     * The LEGACY single field. The server keeps it pointing at the
     * authoritative document, so builds that predate the split below still show
     * the approved label rather than nothing.
     */
    @SerialName("label_reference") val labelReference: String? = null,
    /**
     * The registrant/manufacturer-hosted label document.
     *
     * The PRIMARY "Open label" link for growers: it is the label they
     * physically hold, and usually the more readable rendering. Never a
     * marketing page — the server classifies those separately and a
     * regulator-hosted URL offered here is reclassified rather than duplicated.
     *
     * Previously undecoded on Android, so a label the resolver had found and
     * validated arrived on device and was silently discarded — and discarded
     * again on every save. Mirrors iOS `ChemicalRegistration.manufacturerLabelURL`.
     */
    @SerialName("manufacturer_label_url") val manufacturerLabelUrl: String? = null,
    /**
     * The regulator's approved label (APVMA eLabels and equivalents).
     *
     * Authoritative for registration and always retained. A manufacturer
     * document can lead in the UI but can never SUBSTITUTE for this one — the
     * three link concepts stay separate forever.
     * Mirrors iOS `ChemicalRegistration.regulatorLabelURL`.
     */
    @SerialName("regulator_label_url") val regulatorLabelUrl: String? = null,
    /**
     * The registrant's own PRODUCT INFORMATION page.
     *
     * A third, genuinely separate concept from the two labels above. The
     * backend has classified this URL as MARKETING rather than a label, and
     * Android must honour that separation: a product page is where a grower
     * reads about a product, never what they spray by.
     * Mirrors iOS `ChemicalRegistration.manufacturerProductURL`.
     */
    @SerialName("manufacturer_product_url") val manufacturerProductUrl: String? = null,
    /** Label version/approval date, so re-verification can see official data move on. */
    @SerialName("label_version") val labelVersion: String? = null,
) {
    /**
     * The label to lead with, and the one to keep beside it.
     *
     * Manufacturer first: it is the practical label. The regulator document is
     * never dropped — it is what makes the record defensible. Falls back to
     * [labelReference] so a server that has not been redeployed still renders a
     * label rather than an empty section. Identical resolution on iOS.
     */
    val primaryLabelUrl: String?
        get() = manufacturerLabelUrl ?: regulatorLabelUrl ?: labelReference

    /** The authoritative document, when it is not already the primary one. */
    val secondaryLabelUrl: String?
        get() = if (manufacturerLabelUrl == null) null else regulatorLabelUrl ?: labelReference
    /**
     * Whether this identity is strong enough to underwrite a Verified claim:
     * a register, a number, and a country.
     */
    val isAuthoritativeIdentity: Boolean
        get() = scheme != null &&
            scheme != ChemicalRegistrationScheme.OTHER &&
            !registrationNumber.isNullOrBlank() &&
            countryCode.isNotEmpty()

    /** `"APVMA 62764"` — for display next to the product name. */
    val displayIdentifier: String?
        get() {
            val number = registrationNumber?.takeIf { it.isNotBlank() } ?: return null
            return scheme?.let { "${it.label} $number" } ?: number
        }

    /**
     * A stable key for "the same registered product".
     *
     * Country is part of the key on purpose: an AU registration and an NZ
     * registration are never the same identity, even for an identically named
     * product. This is what stops NZ rates being read off an AU label.
     */
    val identityKey: String?
        get() {
            val number = registrationNumber?.takeIf { it.isNotBlank() } ?: return null
            return "$countryCode:${scheme?.raw ?: "unknown"}:${number.uppercase()}"
        }

    companion object {
        fun of(
            countryCode: String,
            scheme: ChemicalRegistrationScheme? = null,
            registrationNumber: String? = null,
            registrant: String? = null,
            registeredProductName: String? = null,
            labelReference: String? = null,
            manufacturerLabelUrl: String? = null,
            regulatorLabelUrl: String? = null,
            manufacturerProductUrl: String? = null,
            labelVersion: String? = null,
        ): ChemicalRegistration = ChemicalRegistration(
            countryCode = normaliseCountry(countryCode),
            scheme = scheme,
            registrationNumber = registrationNumber?.trim()?.takeIf { it.isNotEmpty() },
            registrant = registrant?.trim()?.takeIf { it.isNotEmpty() },
            registeredProductName = registeredProductName?.trim()?.takeIf { it.isNotEmpty() },
            labelReference = labelReference?.trim()?.takeIf { it.isNotEmpty() },
            manufacturerLabelUrl = manufacturerLabelUrl?.trim()?.takeIf { it.isNotEmpty() },
            regulatorLabelUrl = regulatorLabelUrl?.trim()?.takeIf { it.isNotEmpty() },
            manufacturerProductUrl = manufacturerProductUrl?.trim()?.takeIf { it.isNotEmpty() },
            labelVersion = labelVersion?.trim()?.takeIf { it.isNotEmpty() },
        )

        /**
         * ISO code → the display name the vineyard picker uses, for
         * jurisdiction messaging ("Registered for Australia — current vineyard
         * is New Zealand"). Falls back to the (normalised) code itself so an
         * unmapped country still reads honestly rather than blocking the
         * message.
         */
        fun displayNameForCountryCode(code: String): String {
            val normalised = normaliseCountry(code)
            if (normalised.isEmpty()) return ""
            return DISPLAY_NAMES_BY_CODE[normalised] ?: normalised
        }

        /** Accepts both a code and a display name; stores the code. */
        fun normaliseCountry(raw: String): String {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return ""
            // Known display names and aliases FIRST, so "uk" and "United
            // Kingdom" both land on the ISO code ("GB") rather than an
            // accidental 2-letter uppercase. Then accept a bare code as-is.
            COUNTRY_CODES_BY_NAME[trimmed.lowercase()]?.let { return it }
            if (trimmed.length == 2) return trimmed.uppercase()
            return trimmed.uppercase()
        }

        /**
         * Display-name → ISO 3166-1 alpha-2 for every country the vineyard
         * profile picker offers ([VineyardCountryCatalog], Supported Vineyard
         * Countries Contract v1), plus the approved convenience aliases.
         * Identical resolution on iOS.
         *
         * An unknown name falls through UPPERCASED, which can never equal a
         * server-stamped ISO code — so the jurisdiction gate fails closed for
         * unmapped countries instead of mis-matching them. No fuzzy matching.
         */
        private val COUNTRY_CODES_BY_NAME: Map<String, String> =
            VineyardCountryCatalog.codesByLowercaseName + mapOf(
                // Approved aliases only — each resolves to the SAME
                // jurisdiction its canonical name does. Never add guessing.
                "newzealand" to "NZ",
                "aotearoa" to "NZ",
                "great britain" to "GB",
                "uk" to "GB",
                "united states of america" to "US",
                "usa" to "US",
            )

        /**
         * ISO code → canonical picker display name (aliases like "uk" or
         * "usa" have one display name each). Sourced from
         * [VineyardCountryCatalog]; identical table on iOS.
         */
        private val DISPLAY_NAMES_BY_CODE: Map<String, String> =
            VineyardCountryCatalog.displayNamesByCode
    }
}
