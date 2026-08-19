import Foundation
import Testing
@testable import VineTrack

/// VineTrack Supported Vineyard Countries — Contract v1.
///
/// The 30-row matrix below IS the cross-platform contract.
/// `VineyardCountryContractTest.kt` on Android asserts the identical matrix,
/// so both suites passing proves exact iOS/Android country-set parity. The
/// portal copy lives in `docs/vineyard-country-contract.md`. If this file and
/// that document ever disagree, fix the document.
struct VineyardCountryContractTests {

    /// (ISO 3166-1 alpha-2, canonical display name) in canonical picker
    /// order. Byte-identical matrix on Android.
    private static let contract: [(code: String, name: String)] = [
        ("AR", "Argentina"),
        ("AU", "Australia"),
        ("AT", "Austria"),
        ("BR", "Brazil"),
        ("BG", "Bulgaria"),
        ("CA", "Canada"),
        ("CL", "Chile"),
        ("CN", "China"),
        ("HR", "Croatia"),
        ("FR", "France"),
        ("GE", "Georgia"),
        ("DE", "Germany"),
        ("GR", "Greece"),
        ("HU", "Hungary"),
        ("IN", "India"),
        ("IE", "Ireland"),
        ("IL", "Israel"),
        ("IT", "Italy"),
        ("JP", "Japan"),
        ("MX", "Mexico"),
        ("NZ", "New Zealand"),
        ("PT", "Portugal"),
        ("RO", "Romania"),
        ("SI", "Slovenia"),
        ("ZA", "South Africa"),
        ("ES", "Spain"),
        ("CH", "Switzerland"),
        ("GB", "United Kingdom"),
        ("US", "United States"),
        ("UY", "Uruguay")
    ]

    @Test func canonicalCatalogueHasExactlyThirtyCountries() {
        #expect(Self.contract.count == 30)
        #expect(VineyardCountryCatalog.countries.count == 30)
        #expect(Set(VineyardCountryCatalog.countries.map { $0.code }).count == 30)
        #expect(Set(VineyardCountryCatalog.countries.map { $0.displayName }).count == 30)
    }

    @Test func pickerCatalogueMatchesContractExactly() {
        #expect(VineyardCountryCatalog.countries.map { $0.code } == Self.contract.map { $0.code })
        #expect(VineyardCountryCatalog.displayNames == Self.contract.map { $0.name })
    }

    @Test func everyDisplayNameResolvesToItsISOCode() {
        for entry in Self.contract {
            #expect(ChemicalRegistration.normaliseCountry(entry.name) == entry.code)
            #expect(ChemicalRegistration.normaliseCountry(entry.name.lowercased()) == entry.code)
            #expect(ChemicalRegistration.normaliseCountry(entry.name.uppercased()) == entry.code)
        }
    }

    @Test func everyISOCodeDisplaysItsCanonicalName() {
        for entry in Self.contract {
            #expect(ChemicalRegistration.displayName(forCountryCode: entry.code) == entry.name)
            #expect(ChemicalRegistration.normaliseCountry(entry.code) == entry.code)
            #expect(ChemicalRegistration.normaliseCountry(entry.code.lowercased()) == entry.code)
        }
    }

    @Test func approvedAliasesResolveToTheSameJurisdiction() {
        #expect(ChemicalRegistration.normaliseCountry("UK") == "GB")
        #expect(ChemicalRegistration.normaliseCountry("Great Britain") == "GB")
        #expect(ChemicalRegistration.normaliseCountry("USA") == "US")
        #expect(ChemicalRegistration.normaliseCountry("United States of America") == "US")
        #expect(ChemicalRegistration.normaliseCountry("Aotearoa") == "NZ")
        #expect(ChemicalRegistration.normaliseCountry("NewZealand") == "NZ")
    }

    @Test func unknownCountriesFailClosedWithNoLocaleFallback() {
        // Unknown names fall through UPPERCASED — never equal to a served
        // ISO-2 code, so every jurisdiction gate fails closed. No fuzzy
        // matching, no device-locale substitution.
        #expect(ChemicalRegistration.normaliseCountry("Atlantis") == "ATLANTIS")
        #expect(ChemicalRegistration.displayName(forCountryCode: "Atlantis") == "ATLANTIS")
        #expect(ChemicalRegistration.normaliseCountry("") == "")
        #expect(ChemicalRegistration.normaliseCountry("   ") == "")
        #expect(ChemicalRegistration.displayName(forCountryCode: "") == "")
    }

    @Test func vineyardCountrySupportDoesNotImplyChemicalRegisterSupport() {
        // The five Contract v1 additions are fully supported vineyard
        // countries with NO chemical register wired up: lookups stay honest
        // ("no verified registration available for this jurisdiction") and
        // must never fall back to GB/AU/etc.
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "IE").isEmpty)
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "BG").isEmpty)
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "HR").isEmpty)
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "SI").isEmpty)
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "GE").isEmpty)
        // The wired registers are untouched by Contract v1.
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "AU") == [.apvma])
        #expect(ChemicalRegistrationScheme.schemes(forCountryCode: "NZ") == [.acvm, .nzEPA])
        #expect(ChemicalRegistration.displayName(forCountryCode: "IE") == "Ireland")
    }
}
