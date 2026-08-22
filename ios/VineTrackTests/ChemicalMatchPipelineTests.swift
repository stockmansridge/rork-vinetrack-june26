import Foundation
import Testing
@testable import VineTrack

/// Search → Match → Verify, as an evidence pipeline.
///
/// The reported defect: searching "Dithaine rainshield" returned
/// "Dithane Rainshield / BASF / AU / Mancozeb", and the Verify screen then said
/// "No active ingredients were identified" with nothing on screen reconciling
/// the two. The evidence was being withheld deliberately by the resolver's
/// fail-closed gate; what was missing was any way for the app to SAY so.
///
/// These tests exercise the real state transitions — decode the payloads the
/// edge function actually returns, then assert on what the flow holds — rather
/// than testing `ChemicalSearchResult` decoding in isolation.
struct ChemicalMatchPipelineTests {

    // MARK: - Fixtures

    private func decodeSearch(_ json: String) throws -> [ChemicalSearchResult] {
        try JSONDecoder().decode(ChemicalSearchResponse.self, from: Data(json.utf8)).results
    }

    private func decodeStructured(_ json: String) throws -> ChemicalStructuredLookup {
        try JSONDecoder().decode(ChemicalStructuredLookup.self, from: Data(json.utf8))
    }

    /// A. What the search endpoint returns for the reproduction. The row is an
    /// AI suggestion: no `source`, no `registration_number`, but it does carry
    /// a plausible active. That combination is the whole trap.
    private let dithaneSearchJSON = """
    {
      "results": [
        {
          "name": "Dithane Rainshield",
          "activeIngredient": "Mancozeb 750 g/kg",
          "chemicalGroup": "M3",
          "brand": "BASF",
          "primaryUse": "Fungicide",
          "modeOfAction": "Multi-site protectant"
        }
      ],
      "jurisdiction": { "resolved_country": "AU" }
    }
    """

    /// D. What the structured endpoint returns for that selection.
    ///
    /// The AU register was consulted and could not uniquely verify the product,
    /// so `quarantineUnverifiedAiFacts` emptied every canonical field and moved
    /// the model's reading into `ai_suggestion`. Note `registration` survives
    /// with only a country — which is what renders as "Likely match".
    private let dithaneStructuredJSON = """
    {
      "product_name": null,
      "product_category": "",
      "registration": {
        "country_code": "AU",
        "scheme": null,
        "registration_number": null,
        "registrant": null,
        "registered_product_name": null,
        "label_reference": null
      },
      "active_ingredients": [],
      "activity_groups": [],
      "registered_uses": [],
      "verification": {
        "status": "unverified",
        "sources": [],
        "conflicts": [],
        "unresolved_fields": ["active_ingredients", "registration_number"]
      },
      "match_source": "unresolved",
      "guidance": "We could not uniquely verify this product in the official register for Australia. Please refine the product name or registration number.",
      "ai_suggestion": {
        "note": "Unverified AI suggestion. The official register was consulted and could not uniquely verify this product.",
        "product_name": "Dithane Rainshield",
        "registrant": "BASF",
        "product_category": "fungicide",
        "active_ingredients": [
          { "name": "Mancozeb", "concentration": 750, "concentration_unit": "g/kg" }
        ]
      },
      "discovery": { "adapter": "apvma", "outcome": "unresolved" }
    }
    """

    /// A product the register DID confirm, with a registration number.
    private let confirmedSearchJSON = """
    {
      "results": [
        {
          "name": "Topas 100 EC",
          "activeIngredient": "Penconazole 100 g/L",
          "chemicalGroup": "3",
          "brand": "Syngenta",
          "primaryUse": "Fungicide",
          "modeOfAction": "DMI",
          "registration_number": "45557",
          "source": "official_register"
        }
      ]
    }
    """

    private let confirmedStructuredJSON = """
    {
      "product_name": "Topas 100 EC",
      "product_category": "fungicide",
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "45557",
        "registrant": "Syngenta Australia Pty Ltd",
        "registered_product_name": "Topas 100 EC Fungicide"
      },
      "active_ingredients": [
        {
          "name": "Penconazole",
          "concentration": 100,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "3", "common_name": "DMI" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "verification": {
        "status": "partially_verified",
        "sources": [
          { "kind": "official_register", "name": "APVMA PUBCRIS", "retrieved_at": "2026-08-20T00:00:00Z" }
        ],
        "conflicts": [],
        "unresolved_fields": []
      },
      "match_source": "authoritative_candidate",
      "discovery": { "adapter": "apvma", "outcome": "resolved" }
    }
    """

    /// A genuine two-active product spanning two schemes.
    private let multiActiveStructuredJSON = """
    {
      "product_name": "Combo Duo",
      "product_category": "insecticide",
      "registration": {
        "country_code": "AU",
        "scheme": "apvma",
        "registration_number": "88881",
        "registrant": "Example Crop Science"
      },
      "active_ingredients": [
        {
          "name": "Spinetoram",
          "concentration": 120,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "irac", "code": "5" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        },
        {
          "name": "Pyraclostrobin",
          "concentration": 200,
          "concentration_unit": "g/L",
          "activity_group": { "scheme": "frac", "code": "11" },
          "group_source": "authoritative_classification",
          "identity_source": "official_register"
        }
      ],
      "verification": {
        "status": "partially_verified",
        "sources": [
          { "kind": "official_register", "name": "APVMA PUBCRIS", "retrieved_at": "2026-08-20T00:00:00Z" }
        ],
        "conflicts": [],
        "unresolved_fields": []
      },
      "discovery": { "adapter": "apvma", "outcome": "resolved" }
    }
    """

    // MARK: - B/C. Selection boundary

    @Test("The selected canonical result drives the lookup, never the typed query")
    func selectionCarriesCanonicalIdentity() throws {
        let results = try decodeSearch(dithaneSearchJSON)
        let selected = try #require(results.first)

        // B. What iOS holds after selection.
        #expect(selected.name == "Dithane Rainshield")
        #expect(selected.activeIngredient == "Mancozeb 750 g/kg")
        #expect(selected.brand == "BASF")
        #expect(selected.registrationNumber == nil)
        #expect(selected.source == nil)
        #expect(!selected.isAuthoritativeCandidate)

        // C. What iOS sends. The typo is dead the moment an exact result is
        // chosen — resolving "Dithaine rainshield" would look up a product that
        // does not exist and then truthfully report it as unverifiable.
        let request = ChemicalStructuredLookupRequest(
            selected: selected,
            country: "AU",
            fallbackQuery: "Dithaine rainshield"
        )
        #expect(request.productName == "Dithane Rainshield")
        #expect(request.country == "AU")
        #expect(request.registrationNumber == nil)
    }

    @Test("A registration number on the selected candidate is carried into the request")
    func registrationNumberIsCarried() throws {
        let selected = try #require(try decodeSearch(confirmedSearchJSON).first)
        #expect(selected.source == ChemicalSearchResult.officialRegisterSource)
        #expect(selected.isAuthoritativeCandidate)
        #expect(selected.provenanceLabel == "Official register")

        let request = ChemicalStructuredLookupRequest(selected: selected, country: "AU")
        #expect(request.productName == "Topas 100 EC")
        #expect(request.registrationNumber == "45557")
    }

    @Test("An absent registration number is never invented")
    func absentRegistrationNumberStaysAbsent() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        #expect(ChemicalStructuredLookupRequest(selected: selected, country: "AU").registrationNumber == nil)

        // Blank and whitespace-only are absence too, not an empty identity.
        let blank = ChemicalSearchResult(
            name: "Something", activeIngredient: "", chemicalGroup: "", brand: "",
            primaryUse: "", modeOfAction: "", registrationNumber: "   ", source: nil
        )
        #expect(ChemicalStructuredLookupRequest(selected: blank, country: "AU").registrationNumber == nil)
    }

    @Test("Search rows are labelled by provenance so a guess never looks like a register hit")
    func searchRowsAreLabelledByProvenance() throws {
        let ai = try #require(try decodeSearch(dithaneSearchJSON).first)
        let register = try #require(try decodeSearch(confirmedSearchJSON).first)
        #expect(ai.provenanceLabel == "Unverified suggestion")
        #expect(register.provenanceLabel == "Official register")
    }

    // MARK: - E/F. The Dithane Rainshield regression

    @Test("Dithane Rainshield: the withheld evidence is preserved and explained, never promoted")
    func dithaneRainshieldRegression() throws {
        let selected = try #require(try decodeSearch(dithaneSearchJSON).first)
        let lookup = try decodeStructured(dithaneStructuredJSON)

        // E. What the client decodes. The canonical chemistry is genuinely
        // empty — the register declined to confirm this identity.
        #expect(lookup.activeIngredients.isEmpty)
        #expect(lookup.establishedNoChemistry)
        #expect(lookup.matchSource == "unresolved")

        // The advisory is no longer dropped. THIS is where Mancozeb used to
        // vanish: the resolver quarantined it here and iOS decoded nothing.
        let advisory = try #require(lookup.aiSuggestion)
        #expect(advisory.activeIngredientSummary == "Mancozeb")
        #expect(advisory.registrant == "BASF")
        #expect(advisory.productName == "Dithane Rainshield")
        #expect(lookup.guidance?.isEmpty == false)
        #expect(lookup.discovery?.outcome == "unresolved")
        #expect(lookup.discovery?.wasCheckedAndUnverified == true)

        // F. What intelligence() produces. The advisory is NOT merged: an
        // unverified reading must not become an active ingredient.
        let intel = lookup.intelligence()
        #expect(intel.activeIngredients.isEmpty)
        #expect(intel.activityGroups.isEmpty)
        #expect(intel.registeredUses.isEmpty)

        // No false upgrade. Country alone is not an identity.
        #expect(intel.registration?.registrationNumber == nil)
        #expect(intel.registration?.isAuthoritativeIdentity == false)
        #expect(!intel.hasEvidencedRegistration)
        #expect(intel.resolvedVerificationStatus == .unverified)

        // Canonical name falls back to the SELECTED result, never the typo.
        let displayed = intel.registration?.registeredProductName ?? selected.name
        #expect(displayed == "Dithane Rainshield")
        #expect(displayed != "Dithaine rainshield")

        // And the screen can now explain the gap instead of just showing one.
        let reason = ChemicalEvidenceWithholding.reason(
            discovery: lookup.discovery,
            hasEstablishedActives: !lookup.establishedNoChemistry,
            selectedSource: selected.source,
            selectedRegistrationNumber: selected.registrationNumber,
            registerName: "AU"
        )
        #expect(reason == .registerCheckedAndUnverified(registerName: "AU"))
    }

    @Test("A register row that will not re-verify is reported as a register disagreement")
    func registerCandidateThatFailsReVerificationIsDistinct() throws {
        let selected = try #require(try decodeSearch(confirmedSearchJSON).first)
        let lookup = try decodeStructured(dithaneStructuredJSON)

        // Search offered a register row; the strict resolver then refused the
        // same identity. That is the two contracts disagreeing about one
        // product, and it must not read like an AI guess failing to verify.
        let reason = ChemicalEvidenceWithholding.reason(
            discovery: lookup.discovery,
            hasEstablishedActives: false,
            selectedSource: selected.source,
            selectedRegistrationNumber: selected.registrationNumber
        )
        #expect(reason == .selectedRegisterCandidateNotReVerified(registrationNumber: "45557"))
    }

    @Test("An outage is not a disproof, and an unchecked jurisdiction is not either")
    func withholdingReasonsDistinguishOutageFromRefusal() {
        let unavailable = ChemicalDiscoveryEnvelope(
            adapter: "apvma", outcome: "source_unavailable",
            errorCategory: "timeout", discardedRegistrationHint: nil
        )
        #expect(ChemicalEvidenceWithholding.reason(
            discovery: unavailable, hasEstablishedActives: false,
            selectedSource: nil, selectedRegistrationNumber: nil
        ) == .registerUnavailable)

        let unsupported = ChemicalDiscoveryEnvelope(
            adapter: nil, outcome: "not_supported",
            errorCategory: nil, discardedRegistrationHint: nil
        )
        #expect(ChemicalEvidenceWithholding.reason(
            discovery: unsupported, hasEstablishedActives: false,
            selectedSource: nil, selectedRegistrationNumber: nil
        ) == .registerNotConsulted)
    }

    @Test("Nothing is explained away when the lookup actually established chemistry")
    func noWithholdingReasonWhenEvidenceExists() throws {
        let lookup = try decodeStructured(confirmedStructuredJSON)
        #expect(ChemicalEvidenceWithholding.reason(
            discovery: lookup.discovery,
            hasEstablishedActives: !lookup.establishedNoChemistry,
            selectedSource: ChemicalSearchResult.officialRegisterSource,
            selectedRegistrationNumber: "45557"
        ) == nil)
    }

    @Test("A malformed advisory costs the advisory, never the lookup")
    func malformedAdvisoryDegradesGracefully() throws {
        let lookup = try decodeStructured("""
        {
          "active_ingredients": [],
          "ai_suggestion": { "active_ingredients": "not-an-array" },
          "discovery": { "outcome": "unresolved" }
        }
        """)
        #expect(lookup.aiSuggestion?.activeIngredients.isEmpty == true)
        #expect(lookup.discovery?.wasCheckedAndUnverified == true)
    }

    @Test("A server with no advisory keys still decodes")
    func olderServerPayloadStillDecodes() throws {
        let lookup = try decodeStructured("""
        { "product_name": "Legacy", "active_ingredients": [] }
        """)
        #expect(lookup.aiSuggestion == nil)
        #expect(lookup.guidance == nil)
        #expect(lookup.discovery == nil)
        // No envelope means no explanation is available — and no explanation is
        // invented to fill the space.
        #expect(ChemicalEvidenceWithholding.reason(
            discovery: lookup.discovery, hasEstablishedActives: false,
            selectedSource: nil, selectedRegistrationNumber: nil
        ) == nil)
    }

    // MARK: - Confirmed registration path

    @Test("A confirmed registration decodes its actives, identity and provenance end to end")
    func confirmedRegistrationSurvivesTheWholePath() throws {
        let selected = try #require(try decodeSearch(confirmedSearchJSON).first)
        let request = ChemicalStructuredLookupRequest(selected: selected, country: "AU")
        #expect(request.registrationNumber == "45557")

        let intel = try decodeStructured(confirmedStructuredJSON).intelligence()

        #expect(intel.activeIngredients.map(\.name) == ["Penconazole"])
        #expect(intel.activeIngredients.first?.concentration == 100)
        #expect(intel.activeIngredients.first?.concentrationUnit == .gramsPerLitre)
        #expect(intel.registration?.registrationNumber == "45557")
        #expect(intel.registration?.isAuthoritativeIdentity == true)
        #expect(intel.hasEvidencedRegistration)
        #expect(intel.registration?.registrant == "Syngenta Australia Pty Ltd")

        // Register-backed identity earns Partially Verified — but never
        // Verified, which stays a human confirmation.
        #expect(intel.resolvedVerificationStatus != .verified)
        #expect(intel.resolvedVerificationStatus == .partiallyVerified)

        // Save retains the provenance.
        var chemical = SavedChemical(vineyardId: UUID())
        chemical.chemicalIntelligence = intel
        let projection = chemical.legacyProjection
        chemical.activeIngredient = projection.activeIngredient
        chemical.chemicalGroup = projection.chemicalGroup
        #expect(chemical.chemicalIntelligence?.registration?.registrationNumber == "45557")
        #expect(chemical.activeIngredient.localizedCaseInsensitiveContains("Penconazole"))
    }

    // MARK: - Multi-active / scheme integrity

    @Test("A two-active product keeps both actives with their own schemes")
    func multiActiveKeepsSchemeQualifiedGroups() throws {
        let intel = try decodeStructured(multiActiveStructuredJSON).intelligence()

        #expect(intel.activeIngredients.count == 2)
        #expect(intel.activityGroups.count == 2)

        let schemes = Set(intel.activityGroups.map(\.scheme))
        // Not collapsed into FRAC. IRAC 5 and FRAC 11 are unrelated
        // chemistries, and flattening them would let the resistance engine
        // compare an insecticide group against a fungicide group.
        #expect(schemes == Set([.irac, .frac]))
        #expect(intel.activityGroups.contains { $0.scheme == .irac && $0.code == "5" })
        #expect(intel.activityGroups.contains { $0.scheme == .frac && $0.code == "11" })

        // Each group stays bound to its own active.
        let spinetoram = try #require(intel.activeIngredients.first { $0.name == "Spinetoram" })
        let pyraclostrobin = try #require(intel.activeIngredients.first { $0.name == "Pyraclostrobin" })
        #expect(spinetoram.activityGroup?.scheme == .irac)
        #expect(pyraclostrobin.activityGroup?.scheme == .frac)
    }

    // MARK: - Fail closed

    @Test("A genuinely empty structured response stays unresolved rather than fabricating data")
    func emptyEvidenceFailsClosed() throws {
        let intel = try decodeStructured("""
        {
          "active_ingredients": [],
          "verification": { "status": "unverified", "sources": [], "conflicts": [], "unresolved_fields": [] },
          "discovery": { "adapter": "apvma", "outcome": "unresolved" }
        }
        """).intelligence()

        #expect(intel.activeIngredients.isEmpty)
        #expect(intel.activityGroups.isEmpty)
        #expect(intel.registration == nil)
        #expect(!intel.hasEvidencedRegistration)
        #expect(intel.resolvedVerificationStatus == .unverified)
        #expect(intel.isEmpty)
    }

    @Test("Verification status and knowing an active are independent facts")
    func statusAndChemistryAreIndependent() throws {
        // Actives established, identity not confirmed: Likely match WITH known
        // chemistry is a legitimate, truthful state.
        let intel = try decodeStructured("""
        {
          "product_name": "Partial Product",
          "registration": { "country_code": "AU", "registration_number": null },
          "active_ingredients": [
            {
              "name": "Sulfur",
              "activity_group": { "scheme": "frac", "code": "M2" },
              "group_source": "authoritative_classification"
            }
          ],
          "verification": { "status": "unverified", "sources": [], "conflicts": [], "unresolved_fields": ["registration_number"] }
        }
        """).intelligence()

        #expect(intel.activeIngredients.map(\.name) == ["Sulfur"])
        #expect(intel.registration?.isAuthoritativeIdentity == false)
        // Chemistry known, identity unconfirmed — and no upgrade for either.
        #expect(intel.resolvedVerificationStatus != .verified)
        #expect(intel.resolvedVerificationStatus != .partiallyVerified)
    }
}
