package com.rork.vinetrack.data

import com.rork.vinetrack.data.chemical.ChemicalRegistration
import com.rork.vinetrack.data.chemical.ChemicalRegistrationScheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * VineTrack Supported Vineyard Countries — Contract v1.
 *
 * The 30-row matrix below IS the cross-platform contract.
 * `VineyardCountryContractTests.swift` on iOS asserts the identical matrix,
 * so both suites passing proves exact iOS/Android country-set parity. The
 * portal copy lives in `docs/vineyard-country-contract.md`. If this file and
 * that document ever disagree, fix the document.
 */
class VineyardCountryContractTest {

    /**
     * (ISO 3166-1 alpha-2, canonical display name) in canonical picker
     * order. Byte-identical matrix on iOS.
     */
    private val contract: List<Pair<String, String>> = listOf(
        "AR" to "Argentina",
        "AU" to "Australia",
        "AT" to "Austria",
        "BR" to "Brazil",
        "BG" to "Bulgaria",
        "CA" to "Canada",
        "CL" to "Chile",
        "CN" to "China",
        "HR" to "Croatia",
        "FR" to "France",
        "GE" to "Georgia",
        "DE" to "Germany",
        "GR" to "Greece",
        "HU" to "Hungary",
        "IN" to "India",
        "IE" to "Ireland",
        "IL" to "Israel",
        "IT" to "Italy",
        "JP" to "Japan",
        "MX" to "Mexico",
        "NZ" to "New Zealand",
        "PT" to "Portugal",
        "RO" to "Romania",
        "SI" to "Slovenia",
        "ZA" to "South Africa",
        "ES" to "Spain",
        "CH" to "Switzerland",
        "GB" to "United Kingdom",
        "US" to "United States",
        "UY" to "Uruguay",
    )

    @Test
    fun canonicalCatalogueHasExactlyThirtyCountries() {
        assertEquals(30, contract.size)
        assertEquals(30, VineyardCountryCatalog.countries.size)
        assertEquals(30, VineyardCountryCatalog.countries.map { it.code }.toSet().size)
        assertEquals(30, VineyardCountryCatalog.countries.map { it.displayName }.toSet().size)
    }

    @Test
    fun pickerCatalogueMatchesContractExactly() {
        assertEquals(contract.map { it.first }, VineyardCountryCatalog.countries.map { it.code })
        assertEquals(contract.map { it.second }, VineyardCountryCatalog.displayNames)
    }

    @Test
    fun everyDisplayNameResolvesToItsIsoCode() {
        for ((code, name) in contract) {
            assertEquals(code, ChemicalRegistration.normaliseCountry(name))
            assertEquals(code, ChemicalRegistration.normaliseCountry(name.lowercase()))
            assertEquals(code, ChemicalRegistration.normaliseCountry(name.uppercase()))
        }
    }

    @Test
    fun everyIsoCodeDisplaysItsCanonicalName() {
        for ((code, name) in contract) {
            assertEquals(name, ChemicalRegistration.displayNameForCountryCode(code))
            assertEquals(code, ChemicalRegistration.normaliseCountry(code))
            assertEquals(code, ChemicalRegistration.normaliseCountry(code.lowercase()))
        }
    }

    @Test
    fun approvedAliasesResolveToTheSameJurisdiction() {
        assertEquals("GB", ChemicalRegistration.normaliseCountry("UK"))
        assertEquals("GB", ChemicalRegistration.normaliseCountry("Great Britain"))
        assertEquals("US", ChemicalRegistration.normaliseCountry("USA"))
        assertEquals("US", ChemicalRegistration.normaliseCountry("United States of America"))
        assertEquals("NZ", ChemicalRegistration.normaliseCountry("Aotearoa"))
        assertEquals("NZ", ChemicalRegistration.normaliseCountry("NewZealand"))
    }

    @Test
    fun unknownCountriesFailClosedWithNoLocaleFallback() {
        // Unknown names fall through UPPERCASED — never equal to a served
        // ISO-2 code, so every jurisdiction gate fails closed. No fuzzy
        // matching, no device-locale substitution.
        assertEquals("ATLANTIS", ChemicalRegistration.normaliseCountry("Atlantis"))
        assertEquals("ATLANTIS", ChemicalRegistration.displayNameForCountryCode("Atlantis"))
        assertEquals("", ChemicalRegistration.normaliseCountry(""))
        assertEquals("", ChemicalRegistration.normaliseCountry("   "))
        assertEquals("", ChemicalRegistration.displayNameForCountryCode(""))
    }

    @Test
    fun vineyardCountrySupportDoesNotImplyChemicalRegisterSupport() {
        // The five Contract v1 additions are fully supported vineyard
        // countries with NO chemical register wired up: lookups stay honest
        // ("no verified registration available for this jurisdiction") and
        // must never fall back to GB/AU/etc.
        assertTrue(ChemicalRegistrationScheme.schemesForCountry("IE").isEmpty())
        assertTrue(ChemicalRegistrationScheme.schemesForCountry("BG").isEmpty())
        assertTrue(ChemicalRegistrationScheme.schemesForCountry("HR").isEmpty())
        assertTrue(ChemicalRegistrationScheme.schemesForCountry("SI").isEmpty())
        assertTrue(ChemicalRegistrationScheme.schemesForCountry("GE").isEmpty())
        // The wired registers are untouched by Contract v1.
        assertEquals(
            listOf(ChemicalRegistrationScheme.APVMA),
            ChemicalRegistrationScheme.schemesForCountry("AU"),
        )
        assertEquals(
            listOf(ChemicalRegistrationScheme.ACVM, ChemicalRegistrationScheme.NZ_EPA),
            ChemicalRegistrationScheme.schemesForCountry("NZ"),
        )
        assertEquals("Ireland", ChemicalRegistration.displayNameForCountryCode("IE"))
    }
}
