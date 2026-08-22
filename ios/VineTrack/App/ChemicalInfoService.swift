import Foundation

nonisolated enum LabelURLValidator {
    /// Sanitises a stored label URL. Strips known placeholder hosts and
    /// (when `requireDocumentPath` is true) brand homepages that the AI used
    /// to suggest as "labels". User-pasted URLs go through with
    /// `requireDocumentPath = false` so the operator can save any reachable
    /// link they trust.
    static func sanitize(_ raw: String, requireDocumentPath: Bool = false) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased() else { return "" }
        let placeholderHosts: Set<String> = [
            "example.com", "www.example.com",
            "example.org", "www.example.org",
            "example.net", "www.example.net",
            "placeholder.com", "www.placeholder.com",
            "yourdomain.com", "www.yourdomain.com",
            "domain.com", "www.domain.com",
            "manufacturer.com", "www.manufacturer.com",
            "website.com", "www.website.com",
            "company.com", "www.company.com",
            "test.com", "www.test.com",
            "localhost"
        ]
        if placeholderHosts.contains(host) { return "" }
        if !host.contains(".") { return "" }
        if requireDocumentPath {
            let path = url.path
            // Brand homepage / root URLs are never a valid label.
            if path.isEmpty || path == "/" { return "" }
        }
        return trimmed
    }
}

nonisolated struct ChemicalRateInfo: Codable, Sendable, Hashable {
    let label: String
    let value: Double
}

nonisolated struct ChemicalInfoResponse: Codable, Sendable {
    let activeIngredient: String
    let brand: String
    let chemicalGroup: String
    /// Server-validated direct URL to the official product label / SDS PDF.
    /// Empty when the AI was not confident and/or the URL failed live
    /// reachability validation on the edge function.
    let labelURL: String
    /// Optional manufacturer product/marketing page. Distinct from labelURL;
    /// never shown as a "Label" link in the UI.
    let productURL: String?
    /// Optional direct Safety Data Sheet URL (validated).
    let sdsURL: String?
    let primaryUse: String
    let ratesPerHectare: [ChemicalRateInfo]?
    let ratesPer100L: [ChemicalRateInfo]?
    let formType: String?
    let modeOfAction: String?

    var isLiquid: Bool {
        guard let form = formType?.lowercased() else { return true }
        return !form.contains("solid")
            && !form.contains("granul")
            && !form.contains("powder")
            && !form.contains("wettable")
            && !form.contains("dry")
            && !form.contains("wdg")
            && !form.contains("wg")
            && !form.contains("wp")
            && !form.contains("df")
    }

    var defaultUnit: ChemicalUnit {
        isLiquid ? .litres : .kilograms
    }
}

/// Reference to an approved Master Chemical Catalogue row (sql/199) that a
/// structured lookup was served from.
///
/// Carried through Match & Verify so the saved record can retain
/// `master_chemical_id` plus the catalogue revision its chemistry was copied
/// at (`master_source_revision`) — the provenance Re-verify later compares to
/// surface “Updated verified information available”. Never invented client
/// side; only ever decoded from a `match_source: "master"` response.
nonisolated struct ChemicalMasterMatch: Codable, Sendable, Hashable {
    let masterChemicalId: UUID
    let masterRevision: Int
    let catalogueStatus: String?
    let registrationIdentityKey: String?

    nonisolated enum CodingKeys: String, CodingKey {
        case masterChemicalId = "master_chemical_id"
        case masterRevision = "master_revision"
        case catalogueStatus = "catalogue_status"
        case registrationIdentityKey = "registration_identity_key"
    }

    init(
        masterChemicalId: UUID,
        masterRevision: Int,
        catalogueStatus: String? = nil,
        registrationIdentityKey: String? = nil
    ) {
        self.masterChemicalId = masterChemicalId
        self.masterRevision = masterRevision
        self.catalogueStatus = catalogueStatus
        self.registrationIdentityKey = registrationIdentityKey
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        masterChemicalId = try c.decode(UUID.self, forKey: .masterChemicalId)
        masterRevision = try c.decodeIfPresent(Int.self, forKey: .masterRevision) ?? 1
        catalogueStatus = try c.decodeIfPresent(String.self, forKey: .catalogueStatus)
        registrationIdentityKey = try c.decodeIfPresent(String.self, forKey: .registrationIdentityKey)
    }
}

/// The structured payload returned by the `structured` lookup action.
///
/// Deliberately a transport type: it is converted into `ChemicalIntelligence`
/// via `intelligence()` so that everything downstream reads one model.
nonisolated struct ChemicalStructuredLookup: Codable, Sendable {
    let productName: String?
    let productCategory: String?
    let formType: String?
    let registration: ChemicalRegistration?
    let activeIngredients: [ChemicalActiveIngredient]
    let activityGroups: [String]
    let registeredUses: [ChemicalRegisteredUse]
    let labelRateBases: [String]
    let verification: ChemicalVerification
    let activityGroupTableVersion: Int
    let schemaVersion: Int
    /// Per-field evidence tiers recorded by the resolver (`field_provenance`
    /// wire key). Carried verbatim into the stored intelligence; `nil` from
    /// servers that predate the key.
    let fieldProvenance: [String: String]?
    /// "master" | "authoritative_candidate" | "ai_candidate" | "unresolved"
    /// | nil (pre-sql/199 server). Stage 3 adds "authoritative_candidate":
    /// register-backed but NOT approved — handled exactly like an AI
    /// candidate everywhere except provenance display.
    let matchSource: String?
    /// Present only on master-served responses.
    let master: ChemicalMasterMatch?
    /// The resolver's UNVERIFIED reading, quarantined out of the canonical
    /// fields by the fail-closed gate.
    ///
    /// Decoded so the app can EXPLAIN a refusal. Dropping it was the reason
    /// Search could show "Mancozeb" and Verify could then say "No active
    /// ingredients were identified" with nothing on screen connecting the two.
    /// It is never merged into `intelligence()`.
    let aiSuggestion: ChemicalLookupAdvisory?
    /// The resolver's operator-facing next step when it could not verify.
    let guidance: String?
    /// What the jurisdiction's register actually did on this lookup.
    let discovery: ChemicalDiscoveryEnvelope?

    /// True when this lookup was served from an APPROVED master catalogue row
    /// and carries the reference the saved record should retain.
    ///
    /// Stage 3 hardening: an automatically generated CANDIDATE must never
    /// read as a master match — a master block carrying a non-approved
    /// `catalogue_status` is rejected outright. A missing status reads as
    /// approved (pre-Stage-3 servers only ever served approved rows here).
    var isMasterMatch: Bool {
        matchSource == "master" && master != nil
            && (master?.catalogueStatus ?? "approved") == "approved"
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case productName = "product_name"
        case productCategory = "product_category"
        case formType = "form_type"
        case registration
        case activeIngredients = "active_ingredients"
        case activityGroups = "activity_groups"
        case registeredUses = "registered_uses"
        case labelRateBases = "label_rate_bases"
        case verification
        case activityGroupTableVersion = "activity_group_table_version"
        case schemaVersion = "schema_version"
        case fieldProvenance = "field_provenance"
        case matchSource = "match_source"
        case master
        case aiSuggestion = "ai_suggestion"
        case guidance
        case discovery
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        productName = try c.decodeIfPresent(String.self, forKey: .productName)
        productCategory = try c.decodeIfPresent(String.self, forKey: .productCategory)
        formType = try c.decodeIfPresent(String.self, forKey: .formType)
        registration = try c.decodeIfPresent(ChemicalRegistration.self, forKey: .registration)
        activeIngredients = try c.decodeIfPresent([ChemicalActiveIngredient].self, forKey: .activeIngredients) ?? []
        activityGroups = try c.decodeIfPresent([String].self, forKey: .activityGroups) ?? []
        registeredUses = try c.decodeIfPresent([ChemicalRegisteredUse].self, forKey: .registeredUses) ?? []
        labelRateBases = try c.decodeIfPresent([String].self, forKey: .labelRateBases) ?? []
        verification = try c.decodeIfPresent(ChemicalVerification.self, forKey: .verification) ?? ChemicalVerification()
        activityGroupTableVersion = try c.decodeIfPresent(Int.self, forKey: .activityGroupTableVersion) ?? 0
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        // Additive LD-2 key — tolerant: malformed provenance degrades to nil
        // rather than failing the lookup.
        fieldProvenance = try? c.decodeIfPresent([String: String].self, forKey: .fieldProvenance)
        // Additive sql/199 envelope — tolerant on both sides: an old server
        // sends neither key, and a malformed master block degrades to nil
        // (plain AI-candidate behaviour) rather than failing the lookup.
        matchSource = try? c.decodeIfPresent(String.self, forKey: .matchSource)
        master = try? c.decodeIfPresent(ChemicalMasterMatch.self, forKey: .master)
        // Additive advisory keys. Tolerant on every one: they exist to explain
        // a refusal, so a malformed advisory must cost the explanation and
        // never the lookup itself.
        aiSuggestion = (try? c.decodeIfPresent(ChemicalLookupAdvisory.self, forKey: .aiSuggestion)) ?? nil
        guidance = (try? c.decodeIfPresent(String.self, forKey: .guidance)) ?? nil
        discovery = (try? c.decodeIfPresent(ChemicalDiscoveryEnvelope.self, forKey: .discovery)) ?? nil
    }

    /// True when the resolver established no chemistry at all.
    ///
    /// Distinct from "the product is not a real product": the register may
    /// simply have declined to confirm this identity.
    var establishedNoChemistry: Bool { activeIngredients.isEmpty }

    /// Converts the lookup into the single structured model.
    ///
    /// Every active's group is re-reconciled against the ON-DEVICE authoritative
    /// table as well as the server's. That is not redundant: it means a device
    /// running a newer classification table than the deployed edge function still
    /// catches a disagreement, and a compromised or stale server response can
    /// never quietly install a group the app itself would reject.
    func intelligence() -> ChemicalIntelligence {
        var verification = self.verification
        var actives: [ChemicalActiveIngredient] = []

        for active in activeIngredients {
            let outcome = AuthoritativeActivityGroups.reconcile(
                activeNamed: active.name,
                extracted: active.activityGroup,
                extractedSource: active.groupSource ?? .aiInterpretation
            )
            if let conflict = outcome.conflict {
                verification.addConflict(conflict)
            }
            var updated = active
            updated.activityGroup = outcome.group
            updated.groupSource = outcome.source
            actives.append(updated)
        }

        if !verification.sources.contains(where: { $0.kind == .authoritativeClassification }),
           actives.contains(where: { $0.hasAuthoritativeGroup }) {
            verification.sources.append(AuthoritativeActivityGroups.source(retrievedAt: Date()))
        }

        return ChemicalIntelligence(
            activeIngredients: actives,
            registration: registration,
            verification: verification,
            registeredUses: registeredUses,
            fieldProvenance: fieldProvenance,
            productCategory: productCategory ?? "",
            activityGroupTableVersion: max(activityGroupTableVersion, AuthoritativeActivityGroups.tableVersion),
            schemaVersion: max(schemaVersion, ChemicalIntelligence.currentSchemaVersion)
        )
    }
}

nonisolated struct ChemicalSearchResult: Identifiable, Codable, Sendable, Hashable {
    /// Two register rows can share one verbatim name (pack registrations),
    /// so the registration number joins the identity when present.
    var id: String {
        if let registrationNumber, !registrationNumber.isEmpty {
            return "\(name)#\(registrationNumber)"
        }
        return name
    }
    let name: String
    let activeIngredient: String
    let chemicalGroup: String
    let brand: String
    let primaryUse: String
    let modeOfAction: String
    /// Registration number carried by official-register CANDIDATE rows
    /// (additive; DISCOVERY only — a listing grants nothing). Selecting the
    /// candidate passes this back as the identity hint so the strict
    /// server-side resolver verifies that exact identity against the
    /// register before anything binds.
    let registrationNumber: String?
    /// "master" | "official_register" | nil (AI suggestion / older server).
    let source: String?

    /// Wire value for a row the jurisdiction's official register returned.
    static let officialRegisterSource: String = "official_register"
    /// Wire value for a row served from the approved master catalogue.
    static let masterSource: String = "master"

    /// Where this row came from, for display.
    ///
    /// Search is DISCOVERY: the same list mixes approved catalogue rows,
    /// official-register rows and AI suggestions, and until now they were drawn
    /// identically. An operator who cannot tell a register row from a guess has
    /// no way to anticipate that the guess will not survive verification, which
    /// is what made the Verify screen look like it had lost their data.
    var provenanceLabel: String {
        switch source {
        case ChemicalSearchResult.masterSource: return "Verified catalogue"
        case ChemicalSearchResult.officialRegisterSource: return "Official register"
        default: return "Unverified suggestion"
        }
    }

    /// True when this row is backed by a register or the approved catalogue,
    /// rather than being a model suggestion.
    var isAuthoritativeCandidate: Bool {
        source == ChemicalSearchResult.masterSource
            || source == ChemicalSearchResult.officialRegisterSource
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case name
        case activeIngredient
        case chemicalGroup
        case brand
        case primaryUse
        case modeOfAction
        case registrationNumber = "registration_number"
        case source
    }
}

nonisolated struct ChemicalSearchResponse: Codable, Sendable {
    let results: [ChemicalSearchResult]
}

/// What the structured resolver is asked about, once the operator has chosen.
///
/// A separate type because the rule it encodes is easy to break and invisible
/// when broken: **after an exact result is selected, the operator's typed query
/// is dead**. Someone searching "Dithaine rainshield" and tapping
/// "Dithane Rainshield" has told us the product's name; resolving the typo
/// instead would look up a product that does not exist and then honestly report
/// that it could not be verified.
///
/// Building it here rather than inline in the view is what lets that be a test
/// instead of a comment.
nonisolated struct ChemicalStructuredLookupRequest: Sendable, Hashable {
    /// The CANONICAL product name — from the selected candidate, never the
    /// search box.
    let productName: String
    let country: String
    /// The candidate's registration number, when it carried one. Only ever a
    /// POINTER: the resolver re-verifies name↔number against the register
    /// before anything binds, so passing it can sharpen an identity but can
    /// never assert one.
    let registrationNumber: String?

    /// Build the request for a selected search result.
    ///
    /// - Parameter fallbackQuery: used ONLY when the candidate has no usable
    ///   name, which a well-formed result never does.
    init(selected: ChemicalSearchResult, country: String, fallbackQuery: String = "") {
        let canonical = selected.name.trimmingCharacters(in: .whitespacesAndNewlines)
        productName = canonical.isEmpty
            ? fallbackQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            : canonical
        self.country = country
        let number = selected.registrationNumber?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Absent stays absent. Inventing a number would make the resolver
        // verify a registration nobody ever claimed.
        registrationNumber = (number?.isEmpty ?? true) ? nil : number
    }
}

nonisolated enum ChemicalLookupError: Error, LocalizedError, Sendable {
    case notConfigured
    case missingProviderKey
    case network(String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AI lookup is not configured. Please try again later."
        case .missingProviderKey:
            return "AI provider key is not set on the server. Ask an admin to configure OPENAI_API_KEY."
        case .network(let m):
            return "AI lookup failed: \(m)"
        case .parseFailed:
            return "AI returned an unexpected response. Please try again."
        }
    }
}

nonisolated struct ChemicalInfoService: Sendable {

    /// Resolves the jurisdiction country for chemical lookups.
    ///
    /// The vineyard profile is the ONLY source. Product registration is
    /// country-scoped law, and the phone's locale says where the DEVICE is set
    /// up, not where the vines grow — an AU-region phone managing an NZ
    /// vineyard must never silently check the APVMA register. When the
    /// vineyard has no country this returns empty and the lookup flows fail
    /// closed (search disabled, re-verify refused, nothing verifiable) instead
    /// of guessing. Mirrors the Android `ChemicalInfoService.resolveCountry`.
    static func resolveCountry(vineyardCountry: String?) -> String {
        (vineyardCountry ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func searchChemicals(query: String, country: String = "") async throws -> [ChemicalSearchResult] {
        var payload: [String: Any] = [
            "action": "search",
            "query": query,
        ]
        if !country.isEmpty { payload["country"] = country }
        let data = try await postEdge(path: "chemical-info-lookup", payload: payload)
        do {
            let decoded = try JSONDecoder().decode(ChemicalSearchResponse.self, from: data)
            return decoded.results
        } catch {
            throw ChemicalLookupError.parseFailed
        }
    }

    /// Structured Chemical Intelligence lookup (Phase 6).
    ///
    /// Returns actives, groups, registration, registered uses and label rate
    /// bases as MACHINE-READABLE fields, plus the verification evidence behind
    /// them. The server cross-checks every extracted activity group against the
    /// authoritative FRAC/HRAC/IRAC table before replying, so a disagreement
    /// arrives as a conflict rather than a silently overwritten value.
    ///
    /// The result is never `.verified`: the lookup can identify a candidate and
    /// classify its chemistry, but confirming product identity is a human step.
    /// Resolve a selected search candidate.
    ///
    /// The overload the Match flow uses, so the "canonical name, never the
    /// typed query" rule lives in one testable place.
    func lookupStructured(_ request: ChemicalStructuredLookupRequest) async throws -> ChemicalStructuredLookup {
        try await lookupStructured(
            productName: request.productName,
            country: request.country,
            registrationNumber: request.registrationNumber
        )
    }

    func lookupStructured(
        productName: String,
        country: String = "",
        registrationNumber: String? = nil
    ) async throws -> ChemicalStructuredLookup {
        var payload: [String: Any] = [
            "action": "structured",
            "productName": productName,
        ]
        if !country.isEmpty { payload["country"] = country }
        // Identity hint from a selected register candidate. Only ever a
        // POINTER: the server re-verifies name↔number against the official
        // register before anything binds.
        if let registrationNumber, !registrationNumber.isEmpty {
            payload["registrationNumber"] = registrationNumber
        }
        let data = try await postEdge(path: "chemical-info-lookup", payload: payload)
        do {
            return try JSONDecoder().decode(ChemicalStructuredLookup.self, from: data)
        } catch {
            throw ChemicalLookupError.parseFailed
        }
    }

    func lookupChemicalInfo(productName: String, country: String = "") async throws -> ChemicalInfoResponse {
        var payload: [String: Any] = [
            "action": "info",
            "productName": productName,
        ]
        if !country.isEmpty { payload["country"] = country }
        let data = try await postEdge(path: "chemical-info-lookup", payload: payload)
        do {
            return try JSONDecoder().decode(ChemicalInfoResponse.self, from: data)
        } catch {
            throw ChemicalLookupError.parseFailed
        }
    }

    private func postEdge(path: String, payload: [String: Any]) async throws -> Data {
        guard AppConfig.isSupabaseConfigured else { throw ChemicalLookupError.notConfigured }
        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(path)") else {
            throw ChemicalLookupError.network("Invalid edge function URL")
        }
        let anonKey = AppConfig.supabaseAnonKey
        guard !anonKey.isEmpty else { throw ChemicalLookupError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ChemicalLookupError.network("No HTTP response")
        }
        if (200..<300).contains(http.statusCode) { return data }

        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = obj["error"] as? String {
            if msg.contains("OPENAI_API_KEY") {
                throw ChemicalLookupError.missingProviderKey
            }
            throw ChemicalLookupError.network(msg)
        }
        throw ChemicalLookupError.network("HTTP \(http.statusCode)")
    }
}
