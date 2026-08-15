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
    var labelReference: String?
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
        labelVersion: String? = nil
    ) {
        self.countryCode = ChemicalRegistration.normaliseCountry(countryCode)
        self.scheme = scheme
        self.registrationNumber = ChemicalRegistration.trimmed(registrationNumber)
        self.registrant = ChemicalRegistration.trimmed(registrant)
        self.registeredProductName = ChemicalRegistration.trimmed(registeredProductName)
        self.labelReference = ChemicalRegistration.trimmed(labelReference)
        self.labelVersion = ChemicalRegistration.trimmed(labelVersion)
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case scheme
        case registrationNumber = "registration_number"
        case registrant
        case registeredProductName = "registered_product_name"
        case labelReference = "label_reference"
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
        labelVersion = ChemicalRegistration.trimmed(
            try c.decodeIfPresent(String.self, forKey: .labelVersion))
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

    static func normaliseCountry(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Accept both a code and a display name; store the code.
        if trimmed.count == 2 { return trimmed.uppercased() }
        switch trimmed.lowercased() {
        case "australia": return "AU"
        case "new zealand", "newzealand", "aotearoa": return "NZ"
        default: return trimmed.uppercased()
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        let t = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty ?? true) ? nil : t
    }
}
