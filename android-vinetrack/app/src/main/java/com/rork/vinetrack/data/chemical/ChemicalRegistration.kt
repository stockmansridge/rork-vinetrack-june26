package com.rork.vinetrack.data.chemical

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
    @SerialName("label_reference") val labelReference: String? = null,
    /** Label version/approval date, so re-verification can see official data move on. */
    @SerialName("label_version") val labelVersion: String? = null,
) {
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
            labelVersion: String? = null,
        ): ChemicalRegistration = ChemicalRegistration(
            countryCode = normaliseCountry(countryCode),
            scheme = scheme,
            registrationNumber = registrationNumber?.trim()?.takeIf { it.isNotEmpty() },
            registrant = registrant?.trim()?.takeIf { it.isNotEmpty() },
            registeredProductName = registeredProductName?.trim()?.takeIf { it.isNotEmpty() },
            labelReference = labelReference?.trim()?.takeIf { it.isNotEmpty() },
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
         * profile picker offers, plus common aliases. Identical table on iOS.
         *
         * An unknown name falls through UPPERCASED, which can never equal a
         * server-stamped ISO code — so the jurisdiction gate fails closed for
         * unmapped countries instead of mis-matching them.
         */
        private val COUNTRY_CODES_BY_NAME: Map<String, String> = mapOf(
            "australia" to "AU",
            "argentina" to "AR",
            "austria" to "AT",
            "brazil" to "BR",
            "canada" to "CA",
            "chile" to "CL",
            "china" to "CN",
            "france" to "FR",
            "germany" to "DE",
            "greece" to "GR",
            "hungary" to "HU",
            "india" to "IN",
            "israel" to "IL",
            "italy" to "IT",
            "japan" to "JP",
            "mexico" to "MX",
            "new zealand" to "NZ",
            "newzealand" to "NZ",
            "aotearoa" to "NZ",
            "portugal" to "PT",
            "romania" to "RO",
            "south africa" to "ZA",
            "spain" to "ES",
            "switzerland" to "CH",
            "united kingdom" to "GB",
            "great britain" to "GB",
            "uk" to "GB",
            "united states" to "US",
            "united states of america" to "US",
            "usa" to "US",
            "uruguay" to "UY",
        )

        /**
         * Reverse of [COUNTRY_CODES_BY_NAME] for the CANONICAL picker names
         * only (aliases like "uk" or "usa" have one display name each).
         * Identical table on iOS.
         */
        private val DISPLAY_NAMES_BY_CODE: Map<String, String> = mapOf(
            "AU" to "Australia",
            "AR" to "Argentina",
            "AT" to "Austria",
            "BR" to "Brazil",
            "CA" to "Canada",
            "CL" to "Chile",
            "CN" to "China",
            "FR" to "France",
            "DE" to "Germany",
            "GR" to "Greece",
            "HU" to "Hungary",
            "IN" to "India",
            "IL" to "Israel",
            "IT" to "Italy",
            "JP" to "Japan",
            "MX" to "Mexico",
            "NZ" to "New Zealand",
            "PT" to "Portugal",
            "RO" to "Romania",
            "ZA" to "South Africa",
            "ES" to "Spain",
            "CH" to "Switzerland",
            "GB" to "United Kingdom",
            "US" to "United States",
            "UY" to "Uruguay",
        )
    }
}
