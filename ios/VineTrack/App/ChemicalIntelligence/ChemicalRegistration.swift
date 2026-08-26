import Foundation

/// The national scheme a product is registered under.
///
/// Registration scheme + number is what makes a product identity real. Two
/// products can share a brand name across the Tasman and be different
/// registrations with different actives, different rates and different labels.
nonisolated enum ChemicalRegistrationScheme: String, Codable, Sendable, CaseIterable, Hashable {
    /// Australian Pesticides and Veterinary Medicines Authority.
    case apvma
    /// NZ Agricultural Compounds and Veterinary Medicines (MPI) register.
    case acvm
    /// NZ EPA hazardous substances approval (HSNO), where that is the
    /// identifier a label quotes.
    case nzEPA = "nz_epa"
    /// Any other national register — kept so additional countries slot in
    /// without a schema change.
    case other

    nonisolated var label: String {
        switch self {
        case .apvma: return "APVMA"
        case .acvm: return "ACVM"
        case .nzEPA: return "NZ EPA"
        case .other: return "Registration"
        }
    }

    /// The registers that apply in a country, in the order a lookup should try
    /// them. Empty for countries VineTrack has no register wired up for — the
    /// contract stays extensible without pretending coverage exists.
    static func schemes(forCountryCode code: String) -> [ChemicalRegistrationScheme] {
        switch code.uppercased() {
        case "AU": return [.apvma]
        case "NZ": return [.acvm, .nzEPA]
        default: return []
        }
    }
}

/// A country-scoped registered-product identity.
///
/// A `ChemicalRegistration` answers "what exact product is this?" — the
/// question the whole Chemical Intelligence stage exists to make answerable.
/// Without one, a chemical can never be more than partially verified.
nonisolated struct ChemicalRegistration: Codable, Sendable, Hashable {
    /// ISO country code the registration belongs to, e.g. `"AU"`, `"NZ"`.
    /// Upper-cased on the way in.
    var countryCode: String
    var scheme: ChemicalRegistrationScheme?
    /// The register's product number, e.g. an APVMA product number.
    var registrationNumber: String?
    /// The registrant/manufacturer of record, which can differ from the brand
    /// a grower knows the product by.
    var registrant: String?
    /// The exact registered product name, which can also differ from the name
    /// the operator typed.
    var registeredProductName: String?
    /// URL or document identifier of the label the information came from.
    ///
    /// The LEGACY single field. The server keeps it pointing at the
    /// authoritative document, so builds that predate the split below still
    /// show the approved label rather than nothing.
    var labelReference: String?
    /// The registrant/manufacturer-hosted label document.
    ///
    /// The PRIMARY "Open label" link for growers: it is the label they
    /// physically hold, and usually the more readable rendering. Never a
    /// marketing page — the server classifies those separately and a
    /// regulator-hosted URL offered here is reclassified rather than
    /// duplicated.
    var manufacturerLabelURL: String?
    /// The regulator's approved label (APVMA eLabels and equivalents).
    ///
    /// Authoritative for registration and always retained. A manufacturer
    /// document can lead in the UI but can never SUBSTITUTE for this one.
    var regulatorLabelURL: String?
    /// The registrant's own PRODUCT INFORMATION page (`manufacturer_product_url`).
    ///
    /// A third, genuinely separate concept from the two labels above. The
    /// backend has classified this URL as marketing rather than a label —
    /// `selectLabelReferences` refuses to let it occupy either label slot —
    /// and iOS must honour that separation: a product page is where a grower
    /// reads about a product, never what they spray by.
    ///
    /// Previously undecoded, so a page the resolver had found and classified
    /// arrived on device and was discarded.
    var manufacturerProductURL: String?
    /// Label version/approval date, so a future re-verification can tell that
    /// the official data has moved on.
    var labelVersion: String?

    init(
        countryCode: String,
        scheme: ChemicalRegistrationScheme? = nil,
        registrationNumber: String? = nil,
        registrant: String? = nil,
        registeredProductName: String? = nil,
        labelReference: String? = nil,
        manufacturerLabelURL: String? = nil,
        regulatorLabelURL: String? = nil,
        manufacturerProductURL: String? = nil,
        labelVersion: String? = nil
    ) {
        self.countryCode = ChemicalRegistration.normaliseCountry(countryCode)
        self.scheme = scheme
        self.registrationNumber = ChemicalRegistration.trimmed(registrationNumber)
        self.registrant = ChemicalRegistration.trimmed(registrant)
        self.registeredProductName = ChemicalRegistration.trimmed(registeredProductName)
        self.labelReference = ChemicalRegistration.trimmed(labelReference)
        self.manufacturerLabelURL = ChemicalRegistration.trimmed(manufacturerLabelURL)
        self.regulatorLabelURL = ChemicalRegistration.trimmed(regulatorLabelURL)
        self.manufacturerProductURL = ChemicalRegistration.trimmed(manufacturerProductURL)
        self.labelVersion = ChemicalRegistration.trimmed(labelVersion)
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case scheme
        case registrationNumber = "registration_number"
        case registrant
        case registeredProductName = "registered_product_name"
        case labelReference = "label_reference"
        case manufacturerLabelURL = "manufacturer_label_url"
        case regulatorLabelURL = "regulator_label_url"
        case manufacturerProductURL = "manufacturer_product_url"
        case labelVersion = "label_version"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        countryCode = ChemicalRegistration.normaliseCountry(
            try c.decodeIfPresent(String.self, forKey: .countryCode) ?? ""
        )
        if let raw = try c.decodeIfPresent(String.self, forKey: .scheme) {
            scheme = ChemicalRegistrationScheme(rawValue: raw) ?? .other
        } else {
            scheme = nil
        }
        registrationNumber = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .registrationNumber))
        registrant = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .registrant))
        registeredProductName = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .registeredProductName))
        labelReference = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .labelReference))
        manufacturerLabelURL = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .manufacturerLabelURL))
        regulatorLabelURL = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .regulatorLabelURL))
        // Additive and tolerant: absent from every server that predates the
        // split, and from any response where research classified no page.
        manufacturerProductURL = ChemicalRegistration.trimmed(
            (try? c.decodeIfPresent(String.self, forKey: .manufacturerProductURL)) ?? nil)
        labelVersion = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .labelVersion))
    }

    /// The label to lead with, and the one to keep beside it.
    ///
    /// Manufacturer first (task §2): it is the practical label. The regulator
    /// document is never dropped — it is what makes the record defensible.
    /// Falls back to `labelReference` so a server that has not been redeployed
    /// still renders a label rather than an empty section.
    nonisolated var primaryLabelURL: String? {
        manufacturerLabelURL ?? regulatorLabelURL ?? labelReference
    }

    /// The authoritative document, when it is not already the primary one.
    nonisolated var secondaryLabelURL: String? {
        guard manufacturerLabelURL != nil else { return nil }
        return regulatorLabelURL ?? labelReference
    }

    /// Whether this identity is strong enough to underwrite a Verified claim:
    /// a register, a number, and a country.
    nonisolated var isAuthoritativeIdentity: Bool {
        guard let scheme, scheme != .other else { return false }
        guard let registrationNumber, !registrationNumber.isEmpty else { return false }
        return !countryCode.isEmpty
    }

    /// `"APVMA 62764"` — for display next to the product name.
    nonisolated var displayIdentifier: String? {
        guard let registrationNumber, !registrationNumber.isEmpty else { return nil }
        guard let scheme else { return registrationNumber }
        return "\(scheme.label) \(registrationNumber)"
    }

    /// A stable key for "the same registered product".
    ///
    /// Country is part of the key on purpose: an AU registration and an NZ
    /// registration are never the same identity, even for an identically named
    /// product. This is what stops NZ rates being read off an AU label.
    nonisolated var identityKey: String? {
        guard let registrationNumber, !registrationNumber.isEmpty else { return nil }
        let schemeKey = scheme?.rawValue ?? "unknown"
        return "\(countryCode):\(schemeKey):\(registrationNumber.uppercased())"
    }

    /// ISO code → the display name the vineyard picker uses, for jurisdiction
    /// messaging ("Registered for Australia — current vineyard is New Zealand").
    /// Falls back to the (normalised) code itself so an unmapped country still
    /// reads honestly rather than blocking the message.
    static func displayName(forCountryCode code: String) -> String {
        let normalised = normaliseCountry(code)
        guard !normalised.isEmpty else { return "" }
        return displayNamesByCode[normalised] ?? normalised
    }

    static func normaliseCountry(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Known display names and aliases FIRST, so "uk" and "United Kingdom"
        // both land on the ISO code ("GB") rather than an accidental 2-letter
        // uppercase. Then accept a bare code as-is.
        if let code = ChemicalRegistration.countryCodesByName[trimmed.lowercased()] {
            return code
        }
        if trimmed.count == 2 { return trimmed.uppercased() }
        return trimmed.uppercased()
    }

    /// Display-name → ISO 3166-1 alpha-2 for every country the vineyard
    /// profile picker offers (`VineyardCountryCatalog`, Supported Vineyard
    /// Countries Contract v1), plus the approved convenience aliases.
    /// Identical resolution on Android.
    ///
    /// An unknown name falls through UPPERCASED, which can never equal a
    /// server-stamped ISO code — so the jurisdiction gate fails closed for
    /// unmapped countries instead of mis-matching them. No fuzzy matching.
    private static let countryCodesByName: [String: String] = {
        var map = VineyardCountryCatalog.codesByLowercasedName
        // Approved aliases only — each resolves to the SAME jurisdiction its
        // canonical name does. Never add guessing here.
        map["newzealand"] = "NZ"
        map["aotearoa"] = "NZ"
        map["great britain"] = "GB"
        map["uk"] = "GB"
        map["united states of america"] = "US"
        map["usa"] = "US"
        return map
    }()

    /// ISO code → canonical picker display name (aliases like "uk" or "usa"
    /// have one display name each). Sourced from `VineyardCountryCatalog`;
    /// identical table on Android.
    private static let displayNamesByCode: [String: String] =
        VineyardCountryCatalog.displayNamesByCode

    private static func trimmed(_ value: String?) -> String? {
        let t = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }
}
