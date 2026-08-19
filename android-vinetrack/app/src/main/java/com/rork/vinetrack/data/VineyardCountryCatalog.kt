package com.rork.vinetrack.data

/**
 * VineTrack Supported Vineyard Countries — Contract v1 (30 countries).
 *
 * The single canonical mobile source for every vineyard country picker and
 * for jurisdiction country display/normalisation. iOS mirrors this catalogue
 * in `VineyardCountryCatalog.swift`, the cross-platform matrix is pinned by
 * `VineyardCountryContractTest.kt` / `VineyardCountryContractTests.swift`,
 * and the portal copy lives in `docs/vineyard-country-contract.md`. If code
 * and that document ever disagree, fix the document.
 *
 * Contract rules:
 *  * Vineyard profiles keep storing the canonical DISPLAY NAME (unchanged
 *    storage contract since sql/001); jurisdiction logic normalises to
 *    ISO 3166-1 alpha-2 via
 *    [com.rork.vinetrack.data.chemical.ChemicalRegistration.normaliseCountry]
 *    and persists codes only.
 *  * Being a supported vineyard country does NOT imply VineTrack has an
 *    authoritative chemical register wired for that jurisdiction
 *    (`ChemicalRegistrationScheme.schemesForCountry` is empty for most).
 *    Such vineyards are fully supported — chemical lookups simply cannot
 *    produce a verified same-country registration yet, and must never fall
 *    back to another country's register.
 *  * No fuzzy country guessing anywhere: unknown names stay unresolved.
 */
object VineyardCountryCatalog {

    data class Country(
        /** ISO 3166-1 alpha-2 code — the canonical jurisdiction identifier. */
        val code: String,
        /** The canonical picker display name. */
        val displayName: String,
    )

    /**
     * All 30 supported vineyard countries in canonical picker order
     * (alphabetical by display name). Byte-identical list on iOS.
     */
    val countries: List<Country> = listOf(
        Country("AR", "Argentina"),
        Country("AU", "Australia"),
        Country("AT", "Austria"),
        Country("BR", "Brazil"),
        Country("BG", "Bulgaria"),
        Country("CA", "Canada"),
        Country("CL", "Chile"),
        Country("CN", "China"),
        Country("HR", "Croatia"),
        Country("FR", "France"),
        Country("GE", "Georgia"),
        Country("DE", "Germany"),
        Country("GR", "Greece"),
        Country("HU", "Hungary"),
        Country("IN", "India"),
        Country("IE", "Ireland"),
        Country("IL", "Israel"),
        Country("IT", "Italy"),
        Country("JP", "Japan"),
        Country("MX", "Mexico"),
        Country("NZ", "New Zealand"),
        Country("PT", "Portugal"),
        Country("RO", "Romania"),
        Country("SI", "Slovenia"),
        Country("ZA", "South Africa"),
        Country("ES", "Spain"),
        Country("CH", "Switzerland"),
        Country("GB", "United Kingdom"),
        Country("US", "United States"),
        Country("UY", "Uruguay"),
    )

    /**
     * Picker display names in canonical order — the list every vineyard
     * country picker must present.
     */
    val displayNames: List<String> = countries.map { it.displayName }

    /**
     * Lowercased canonical display name → ISO-2. Canonical names ONLY; the
     * approved aliases (uk, usa, aotearoa, …) are layered on in
     * [com.rork.vinetrack.data.chemical.ChemicalRegistration].
     */
    val codesByLowercaseName: Map<String, String> =
        countries.associate { it.displayName.lowercase() to it.code }

    /** ISO-2 → canonical display name. */
    val displayNamesByCode: Map<String, String> =
        countries.associate { it.code to it.displayName }
}
