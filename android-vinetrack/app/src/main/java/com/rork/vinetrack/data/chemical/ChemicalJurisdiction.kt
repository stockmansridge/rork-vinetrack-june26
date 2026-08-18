package com.rork.vinetrack.data.chemical

import com.rork.vinetrack.data.ChemicalInfoService
import com.rork.vinetrack.data.model.SavedChemical

/**
 * Where a Saved Chemical's registration stands relative to the vineyard
 * jurisdiction it is being used in.
 *
 * COMPUTED, never persisted — a record's registration identity is never
 * re-keyed by moving vineyards, and nothing here writes to the record.
 */
sealed class ChemicalJurisdictionSuitability {
    /** Registered in the vineyard's own country — its label facts apply here. */
    data object Compatible : ChemicalJurisdictionSuitability()

    /**
     * Registered under ANOTHER country's law. Name, actives and activity
     * groups stand; registered uses, label rates, withholding periods,
     * re-entry statements and restrictions are NOT vineyard-authoritative.
     */
    data class Mismatch(
        val registrationCountry: String,
        val vineyardCountry: String,
    ) : ChemicalJurisdictionSuitability()

    /**
     * One side has no country — a legacy/manual record, or an unset vineyard.
     * No label authority can be established either way.
     */
    data object Unknown : ChemicalJurisdictionSuitability()
}

/**
 * Jurisdiction enforcement for chemical lookups — the cross-country gate.
 *
 * Product registration is country-scoped law. An AU label's rates, withholding
 * periods, re-entry statements and registered uses say NOTHING about the GB
 * product sharing the same brand name (Custodia APVMA 66541 vs Custodia MAPP
 * 16393 is the canonical pair). The server already scopes master-catalogue
 * matching to the requested country and stamps the AI extraction's
 * registration with the REQUESTED country — this gate is the client's own
 * last line, so a cross-country payload can never be consumed even if a stale
 * or misbehaving server serves one.
 *
 * A rejection is handled exactly like a failed lookup: nothing is converted,
 * previewed, saved or linked. Mirrors `ChemicalJurisdiction.swift` on iOS —
 * both platforms are pinned by the GB Custodia counter-fixture in the
 * Custodia parity suites.
 */
object ChemicalJurisdiction {

    /**
     * Why this lookup response must not be consumed for the vineyard, or null
     * when it may be.
     *
     * @param lookup the decoded `action=structured` response.
     * @param requestCountry the vineyard's country the lookup was keyed on
     *   (code or display name; normalised here).
     */
    fun rejectionReason(
        lookup: ChemicalInfoService.ChemicalStructuredLookup,
        requestCountry: String,
    ): String? {
        val request = ChemicalRegistration.normaliseCountry(requestCountry)

        // No vineyard country -> no jurisdiction -> nothing is consumable.
        // Which register a product must be checked against is a property of
        // where the VINEYARD is; guessing it verifies the wrong label.
        if (request.isEmpty()) {
            return "Set your vineyard's country before matching or verifying chemicals. " +
                "Registrations, label rates and withholding periods are country-specific."
        }

        // A master catalogue row is a country-scoped identity by construction:
        // its identity key must belong to the vineyard's jurisdiction.
        val key = lookup.master?.registrationIdentityKey
        if (!key.isNullOrBlank()) {
            val keyCountry = ChemicalRegistration.normaliseCountry(key.substringBefore(":"))
            if (keyCountry.isNotEmpty() && keyCountry != request) {
                return "This is the $keyCountry-registered product ($key), not a $request " +
                    "registration. Its label does not apply to a $request vineyard."
            }
        }

        // The payload's own registration country must be the vineyard's. An
        // empty payload country is not a foreign claim — it reads as "no
        // registration established" and stays unverifiable via the evidence
        // gate ("country" in unresolved_fields).
        val payloadCountry = ChemicalRegistration.normaliseCountry(
            lookup.registration?.countryCode.orEmpty(),
        )
        if (payloadCountry.isNotEmpty() && payloadCountry != request) {
            return "This product information is registered in $payloadCountry, not $request. " +
                "Its label rates, withholding periods, re-entry statements and registered " +
                "uses do not apply to a $request vineyard."
        }

        return null
    }

    // ---- Saved Chemical suitability (registration identity vs vineyard) ----

    /**
     * Compare a stored registration's country with the CURRENT vineyard's.
     *
     * This is the read-side counterpart of [rejectionReason]: rejection stops
     * foreign payloads being consumed; suitability stops an already-saved
     * foreign registration being read as label authority for this vineyard.
     */
    fun suitability(
        registrationCountry: String?,
        vineyardCountry: String?,
    ): ChemicalJurisdictionSuitability {
        val registration = ChemicalRegistration.normaliseCountry(registrationCountry.orEmpty())
        val vineyard = ChemicalRegistration.normaliseCountry(vineyardCountry.orEmpty())
        if (registration.isEmpty() || vineyard.isEmpty()) {
            return ChemicalJurisdictionSuitability.Unknown
        }
        return if (registration == vineyard) {
            ChemicalJurisdictionSuitability.Compatible
        } else {
            ChemicalJurisdictionSuitability.Mismatch(registration, vineyard)
        }
    }

    /** Suitability of a Saved Chemical for the vineyard it is being viewed in. */
    fun suitability(
        chemical: SavedChemical,
        vineyardCountry: String?,
    ): ChemicalJurisdictionSuitability = suitability(
        registrationCountry = chemical.resolvedIntelligence.registration?.countryCode,
        vineyardCountry = vineyardCountry,
    )

    /** "Registered for Australia — current vineyard is New Zealand" */
    fun mismatchHeadline(registrationCountry: String, vineyardCountry: String): String {
        val registration = ChemicalRegistration.displayNameForCountryCode(registrationCountry)
        val vineyard = ChemicalRegistration.displayNameForCountryCode(vineyardCountry)
        return "Registered for $registration — current vineyard is $vineyard"
    }

    /** The banner body: what stands, what does not, and what to do next. */
    fun mismatchGuidance(registrationCountry: String, vineyardCountry: String): String {
        val registration = ChemicalRegistration.displayNameForCountryCode(registrationCountry)
        val vineyard = ChemicalRegistration.displayNameForCountryCode(vineyardCountry)
        return "Verify a $vineyard registration before using label-specific guidance. " +
            "The $registration label's registered uses, rates, withholding and re-entry " +
            "periods are not valid for this vineyard. Product name, actives and activity " +
            "groups are unaffected."
    }

    /**
     * Shown on Re-verify when the record's registration country differs from
     * the vineyard's: the re-check is still useful — it confirms what the
     * product IS — but it can never read as "verified for this vineyard".
     */
    fun reverifyForeignNote(registrationCountry: String, vineyardCountry: String): String {
        val registration = ChemicalRegistration.displayNameForCountryCode(registrationCountry)
        val vineyard = ChemicalRegistration.displayNameForCountryCode(vineyardCountry)
        return "Re-checking confirms the $registration registration this record holds. " +
            "It does not verify this product for $vineyard — verify a $vineyard " +
            "registration before using label-specific guidance here."
    }
}
