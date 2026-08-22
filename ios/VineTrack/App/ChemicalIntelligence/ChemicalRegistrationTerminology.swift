import Foundation

/// What a registration identifier is CALLED where the vineyard farms.
///
/// # Why this is not one generic field
///
/// "Registration Number" means nothing to a grower. The number they can
/// actually find is the one printed on the drum in front of them, and it has a
/// name: in Australia it is the APVMA number, in New Zealand the ACVM number.
/// Asking for "Registration Number" asks them to translate jargon into their
/// own label, and most will simply leave it blank — which is how a field ends
/// up looking mandatory, empty and useless at the same time.
///
/// So the identifier is only ever shown under its jurisdiction's own name, and
/// only in jurisdictions VineTrack actually supports. Where no scheme is
/// wired up, the field is hidden rather than shown generically: an operator
/// cannot supply a number for a register that does not exist here, and
/// pretending otherwise invites them to type something meaningless into an
/// identity field the matcher depends on.
///
/// The identifier itself never leaves the data model — see
/// `ChemicalRegistration`. It stays essential internally for telling
/// similarly-named products apart, matching the official register, linking to
/// the Master Catalogue, re-verification and refusing cross-country identity
/// matches. None of that requires it to be prominent in the grower's workflow.
nonisolated enum ChemicalRegistrationTerminology {

    /// How one jurisdiction words its registration identifier.
    nonisolated struct Terms: Sendable, Hashable {
        /// The editable field's label, e.g. `"APVMA Registration Number"`.
        let fieldLabel: String
        /// The compact read-only prefix, e.g. `"APVMA registration"`.
        let compactLabel: String
        /// Plain-language explanation of what the number is and why VineTrack
        /// wants it.
        let helpText: String
        /// Example value, so the shape of the number is obvious.
        let placeholder: String
        /// Registers that may be selected for this country.
        let schemes: [ChemicalRegistrationScheme]
    }

    private static let australia = Terms(
        fieldLabel: "APVMA Registration Number",
        compactLabel: "APVMA registration",
        helpText: "The APVMA registration number is the unique number printed on an Australian registered chemical product label. VineTrack uses it to identify the exact registered product and match it with official product information.",
        placeholder: "e.g. 34540",
        schemes: [.apvma]
    )

    private static let newZealand = Terms(
        fieldLabel: "ACVM Registration Number",
        compactLabel: "ACVM registration",
        helpText: "The ACVM registration number is the unique number shown on a New Zealand registered chemical product label. VineTrack uses it to identify the exact registered product and match it with official product information.",
        placeholder: "e.g. P1234",
        // A New Zealand label may quote an EPA/HSNO approval instead, so that
        // register stays selectable. ACVM is the name the field leads with
        // because it is the one most labels print.
        schemes: [.acvm, .nzEPA]
    )

    /// The wording for a country, or `nil` where VineTrack supports no
    /// register — in which case the registration identifier must not be shown
    /// in the normal operator UI at all.
    static func terms(forCountryCode code: String) -> Terms? {
        switch ChemicalRegistration.normaliseCountry(code) {
        case "AU": return australia
        case "NZ": return newZealand
        default: return nil
        }
    }

    /// Whether a registration identifier may be surfaced for this country.
    static func isSupported(countryCode: String) -> Bool {
        terms(forCountryCode: countryCode) != nil
    }

    /// The compact read-only line for the Review screen.
    ///
    /// - `"APVMA registration: 34540"` when an identifier is on record.
    /// - `"Registration not confirmed"` when none was found — a statement of
    ///   fact, not a prompt. Nobody is asked to go and find one.
    /// - `nil` outside a supported jurisdiction, where the concept would only
    ///   be noise.
    static func compactLine(
        countryCode: String,
        registrationNumber: String?
    ) -> String? {
        guard let terms = terms(forCountryCode: countryCode) else { return nil }
        guard let number = registrationNumber?.trimmedNonEmpty else {
            return "Registration not confirmed"
        }
        return "\(terms.compactLabel): \(number)"
    }
}
