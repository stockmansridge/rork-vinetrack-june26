import Foundation

/// VineTrack Supported Vineyard Countries — Contract v1 (30 countries).
///
/// The single canonical mobile source for every vineyard country picker and
/// for jurisdiction country display/normalisation. Android mirrors this
/// catalogue in `VineyardCountryCatalog.kt`, the cross-platform matrix is
/// pinned by `VineyardCountryContractTests.swift` /
/// `VineyardCountryContractTest.kt`, and the portal copy lives in
/// `docs/vineyard-country-contract.md`. If code and that document ever
/// disagree, fix the document.
///
/// Contract rules:
///  * Vineyard profiles keep storing the canonical DISPLAY NAME (unchanged
///    storage contract since sql/001); jurisdiction logic normalises to
///    ISO 3166-1 alpha-2 via `ChemicalRegistration.normaliseCountry` and
///    persists codes only.
///  * Being a supported vineyard country does NOT imply VineTrack has an
///    authoritative chemical register wired for that jurisdiction
///    (`ChemicalRegistrationScheme.schemes(forCountryCode:)` is empty for
///    most). Such vineyards are fully supported — chemical lookups simply
///    cannot produce a verified same-country registration yet, and must
///    never fall back to another country's register.
///  * No fuzzy country guessing anywhere: unknown names stay unresolved.
nonisolated enum VineyardCountryCatalog {

    nonisolated struct Country: Hashable, Sendable {
        /// ISO 3166-1 alpha-2 code — the canonical jurisdiction identifier.
        let code: String
        /// The canonical picker display name.
        let displayName: String
    }

    /// All 30 supported vineyard countries in canonical picker order
    /// (alphabetical by display name). Byte-identical list on Android.
    static let countries: [Country] = [
        Country(code: "AR", displayName: "Argentina"),
        Country(code: "AU", displayName: "Australia"),
        Country(code: "AT", displayName: "Austria"),
        Country(code: "BR", displayName: "Brazil"),
        Country(code: "BG", displayName: "Bulgaria"),
        Country(code: "CA", displayName: "Canada"),
        Country(code: "CL", displayName: "Chile"),
        Country(code: "CN", displayName: "China"),
        Country(code: "HR", displayName: "Croatia"),
        Country(code: "FR", displayName: "France"),
        Country(code: "GE", displayName: "Georgia"),
        Country(code: "DE", displayName: "Germany"),
        Country(code: "GR", displayName: "Greece"),
        Country(code: "HU", displayName: "Hungary"),
        Country(code: "IN", displayName: "India"),
        Country(code: "IE", displayName: "Ireland"),
        Country(code: "IL", displayName: "Israel"),
        Country(code: "IT", displayName: "Italy"),
        Country(code: "JP", displayName: "Japan"),
        Country(code: "MX", displayName: "Mexico"),
        Country(code: "NZ", displayName: "New Zealand"),
        Country(code: "PT", displayName: "Portugal"),
        Country(code: "RO", displayName: "Romania"),
        Country(code: "SI", displayName: "Slovenia"),
        Country(code: "ZA", displayName: "South Africa"),
        Country(code: "ES", displayName: "Spain"),
        Country(code: "CH", displayName: "Switzerland"),
        Country(code: "GB", displayName: "United Kingdom"),
        Country(code: "US", displayName: "United States"),
        Country(code: "UY", displayName: "Uruguay")
    ]

    /// Picker display names in canonical order — the array every vineyard
    /// country picker must present.
    static let displayNames: [String] = countries.map(\.displayName)

    /// Lowercased canonical display name → ISO-2. Canonical names ONLY;
    /// the approved aliases (uk, usa, aotearoa, …) are layered on in
    /// `ChemicalRegistration`.
    static let codesByLowercasedName: [String: String] =
        Dictionary(uniqueKeysWithValues: countries.map { ($0.displayName.lowercased(), $0.code) })

    /// ISO-2 → canonical display name.
    static let displayNamesByCode: [String: String] =
        Dictionary(uniqueKeysWithValues: countries.map { ($0.code, $0.displayName) })
}
