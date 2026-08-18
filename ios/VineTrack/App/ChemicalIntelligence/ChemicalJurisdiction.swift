import Foundation

/// Jurisdiction enforcement for chemical lookups — the cross-country gate.
///
/// Product registration is country-scoped law. An AU label's rates,
/// withholding periods, re-entry statements and registered uses say NOTHING
/// about the GB product sharing the same brand name (Custodia APVMA 66541 vs
/// Custodia MAPP 16393 is the canonical pair). The server already scopes
/// master-catalogue matching to the requested country and stamps the AI
/// extraction's registration with the REQUESTED country — this gate is the
/// client's own last line, so a cross-country payload can never be consumed
/// even if a stale or misbehaving server serves one.
///
/// A rejection is handled exactly like a failed lookup: nothing is converted,
/// previewed, saved or linked. Mirrors `ChemicalJurisdiction.kt` on Android;
/// both are pinned by the GB Custodia counter-fixture in the Custodia parity
/// suites.
nonisolated enum ChemicalJurisdiction {

    /// Why this lookup response must not be consumed for the vineyard, or nil
    /// when it may be.
    ///
    /// - Parameters:
    ///   - lookup: the decoded `action=structured` response.
    ///   - requestCountry: the vineyard's country the lookup was keyed on
    ///     (code or display name; normalised here).
    static func rejectionReason(
        for lookup: ChemicalStructuredLookup,
        requestCountry: String
    ) -> String? {
        let request = ChemicalRegistration.normaliseCountry(requestCountry)

        // No vineyard country -> no jurisdiction -> nothing is consumable.
        // Which register a product must be checked against is a property of
        // where the VINEYARD is; guessing it verifies the wrong label.
        guard !request.isEmpty else {
            return "Set your vineyard's country before matching or verifying chemicals. Registrations, label rates and withholding periods are country-specific."
        }

        // A master catalogue row is a country-scoped identity by construction:
        // its identity key must belong to the vineyard's jurisdiction.
        if let key = lookup.master?.registrationIdentityKey {
            let keyCountry = ChemicalRegistration.normaliseCountry(
                String(key.split(separator: ":").first ?? "")
            )
            if !keyCountry.isEmpty, keyCountry != request {
                return "This is the \(keyCountry)-registered product (\(key)), not a \(request) registration. Its label does not apply to a \(request) vineyard."
            }
        }

        // The payload's own registration country must be the vineyard's. An
        // empty payload country is not a foreign claim — it reads as "no
        // registration established" and stays unverifiable via the evidence
        // gate ("country" in unresolved_fields).
        let payloadCountry = ChemicalRegistration.normaliseCountry(
            lookup.registration?.countryCode ?? ""
        )
        if !payloadCountry.isEmpty, payloadCountry != request {
            return "This product information is registered in \(payloadCountry), not \(request). Its label rates, withholding periods, re-entry statements and registered uses do not apply to a \(request) vineyard."
        }

        return nil
    }
}
