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
    /// Stage LD-2 document-extraction provenance.
    ///
    /// Decoded so `document_url` can reach the ONE Official Label field. This
    /// key was previously discarded, which is why a lookup that had read the
    /// label could still arrive at the Review screen with a blank label link.
    /// It is not a second label field — `ChemicalLabelReference` folds it into
    /// the same `registration.labelReference` every other tier writes.
    let labelExtraction: ChemicalLabelExtraction?
    /// The registrant's own product information page, when the resolver found
    /// and CLASSIFIED one (`product_url` wire key).
    ///
    /// Additive: the server can discover a manufacturer product page through
    /// web research, and the client had no key to receive it, so it never
    /// reached the existing `SavedChemical.productURL`. Strictly separate from
    /// the Official Label — a product page is marketing, a label is evidence,
    /// and this value can never populate `labelReference`.
    let productURL: String?
    /// Uses the resolver researched but could NOT back with authoritative
    /// label evidence (`ai_suggested_uses` wire key).
    ///
    /// The server populates this instead of `registered_uses` when a product's
    /// identity resolves but no approved label was extracted — correct, and
    /// deliberately not weakened here. Without decoding it the operator saw an
    /// empty Registered Uses section even though rates, WHP, REI and
    /// restrictions had been found. Carried at `ai_interpretation` strength
    /// only: it fills the editable draft and never becomes label evidence.
    let aiSuggestedUses: [ChemicalRegisteredUse]

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
        case labelExtraction = "label_extraction"
        case productURL = "product_url"
        case aiSuggestedUses = "ai_suggested_uses"
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
        labelExtraction = (try? c.decodeIfPresent(
            ChemicalLabelExtraction.self, forKey: .labelExtraction
        )) ?? nil
        productURL = (try? c.decodeIfPresent(String.self, forKey: .productURL)) ?? nil
        aiSuggestedUses = ((try? c.decodeIfPresent(
            [ChemicalRegisteredUse].self, forKey: .aiSuggestedUses
        )) ?? []) ?? []
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
    /// The country this row's registration belongs to, when the server states
    /// one. Absent on servers that do not send it; search is country-scoped at
    /// the request, so absence reads as "the requested country".
    let countryCode: String?
    /// Master catalogue lifecycle: "candidate" | "approved" | "retired".
    /// Absent on servers that do not send it — sql/199's RLS already returns
    /// approved rows only, and `ChemicalSearchRanking` re-checks rather than
    /// assuming that will always be true.
    let reviewStatus: String?

    // MARK: - Server ranking (task §1)
    //
    // Ordering is decided by the edge function so iOS, Android and the Portal
    // cannot disagree about which product a query means. These carry the
    // server's DECISION and its stated reason; the app displays the order it
    // was given and never re-sorts on them.

    /// "approved_master" | "official_register" | "suggestion" | "weak_match".
    let rankTier: String?
    /// Server name-relevance verdict, e.g. "exact_name", "incidental".
    let rankRelevance: String?
    /// 0–100 readable projection of tier + relevance.
    let rankScore: Double?
    /// "<relevance>/<tier>", for diagnostics and support conversations.
    let rankReason: String?
    /// The row's position BEFORE ranking, so support can see that ranking
    /// actually changed something.
    let registerOrder: Int?

    /// True when the SERVER ordered this row.
    ///
    /// The reason string is the signal because it is the one field the server
    /// always sets when it ranks. Used solely to decide whether the deprecated
    /// on-device fallback ordering is needed.
    var isServerRanked: Bool {
        !((rankReason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
    }

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
        case countryCode = "country_code"
        case reviewStatus = "review_status"
        case rankTier = "rank_tier"
        case rankRelevance = "rank_relevance"
        case rankScore = "rank_score"
        case rankReason = "rank_reason"
        case registerOrder = "register_order"
    }

    init(
        name: String,
        activeIngredient: String = "",
        chemicalGroup: String = "",
        brand: String = "",
        primaryUse: String = "",
        modeOfAction: String = "",
        registrationNumber: String? = nil,
        source: String? = nil,
        countryCode: String? = nil,
        reviewStatus: String? = nil,
        rankTier: String? = nil,
        rankRelevance: String? = nil,
        rankScore: Double? = nil,
        rankReason: String? = nil,
        registerOrder: Int? = nil
    ) {
        self.name = name
        self.activeIngredient = activeIngredient
        self.chemicalGroup = chemicalGroup
        self.brand = brand
        self.primaryUse = primaryUse
        self.modeOfAction = modeOfAction
        self.registrationNumber = registrationNumber
        self.source = source
        self.countryCode = countryCode
        self.reviewStatus = reviewStatus
        self.rankTier = rankTier
        self.rankRelevance = rankRelevance
        self.rankScore = rankScore
        self.rankReason = rankReason
        self.registerOrder = registerOrder
    }

    /// Tolerant decoding: a row missing any optional field still decodes.
    /// Dropping a whole result because one key is absent is the same data-loss
    /// this flow exists to stop.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String {
            ((try? c.decodeIfPresent(String.self, forKey: key)) ?? nil) ?? ""
        }
        name = text(.name)
        activeIngredient = text(.activeIngredient)
        chemicalGroup = text(.chemicalGroup)
        brand = text(.brand)
        primaryUse = text(.primaryUse)
        modeOfAction = text(.modeOfAction)
        registrationNumber = try? c.decodeIfPresent(String.self, forKey: .registrationNumber)
        source = try? c.decodeIfPresent(String.self, forKey: .source)
        countryCode = try? c.decodeIfPresent(String.self, forKey: .countryCode)
        reviewStatus = try? c.decodeIfPresent(String.self, forKey: .reviewStatus)
        rankTier = (try? c.decodeIfPresent(String.self, forKey: .rankTier)) ?? nil
        rankRelevance = (try? c.decodeIfPresent(String.self, forKey: .rankRelevance)) ?? nil
        rankScore = (try? c.decodeIfPresent(Double.self, forKey: .rankScore)) ?? nil
        rankReason = (try? c.decodeIfPresent(String.self, forKey: .rankReason)) ?? nil
        registerOrder = (try? c.decodeIfPresent(Int.self, forKey: .registerOrder)) ?? nil
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
    /// The request outlived its own deadline.
    ///
    /// Distinguished from `network` because it is the one failure whose
    /// remedy is simply to ask again: the resolver's slow first pass caches
    /// its result server-side, so the retry answers from the cache.
    case timedOut

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
        case .timedOut:
            return "Reading the official register took longer than expected. "
                + "Tap the product again — the details are usually ready straight away on a second attempt."
        }
    }
}

nonisolated struct ChemicalInfoService: Sendable {

    /// How long a plain search may take.
    ///
    /// Search is DISCOVERY — a register candidate query and a ranked list. It
    /// does not fetch labels or run research, so it stays snappy on purpose:
    /// an operator typing a product name must not be made to wait on the
    /// budget the detail lookup needs.
    static let searchTimeout: TimeInterval = 30

    /// How long resolving ONE selected product may take.
    ///
    /// # Why this is not 30 seconds
    ///
    /// Resolving an identity is not a list query. On a product the resolver has
    /// not seen before it queries the national register, discovers and fetches
    /// the approved label PDF, extracts its Directions For Use table and runs a
    /// web-research pass — measured at ~55 s end to end for APVMA 59688.
    /// Against a 30 s deadline that request could only ever fail, and the
    /// failure was swallowed: the Review screen then rebuilt itself from the
    /// search row alone, which is why a register-confirmed product arrived with
    /// "Uncategorised", a default unit, no label link and no registered uses
    /// while the server had answered all four correctly.
    ///
    /// Raised to 180 s after the Dithane timeout audit. The register +
    /// label-fetch + DFU-extraction + web-research chain legitimately exceeds
    /// two minutes on a cold product, and the server-side cache that was
    /// supposed to make the retry instant is per-isolate and in-memory — so a
    /// second attempt frequently lands on a fresh isolate and pays the full
    /// cost again. Retrying against a deadline the work cannot fit inside just
    /// produces a second failure.
    static let structuredLookupTimeout: TimeInterval = 180

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
            "client": ChemicalLookupClientContext().wirePayload,
        ]
        if !country.isEmpty { payload["country"] = country }
        let data = try await postEdge(
            path: "chemical-info-lookup",
            payload: payload,
            timeout: ChemicalInfoService.searchTimeout
        )
        Self.recordDiagnostics(from: data)
        do {
            let decoded = try JSONDecoder().decode(ChemicalSearchResponse.self, from: data)
            return decoded.results
        } catch {
            throw ChemicalLookupError.parseFailed
        }
    }

    /// Decode and record the server's diagnostics envelope (task §14).
    ///
    /// Best-effort, and deliberately the ONLY place the envelope is read: a
    /// malformed or absent envelope costs the diagnostics and never the
    /// lookup, and no caller can start BRANCHING on diagnostics — which would
    /// defeat the parity guarantee the envelope exists to prove.
    private static func recordDiagnostics(from data: Data) {
        guard let envelope = try? JSONDecoder().decode(ChemicalDiagnosticsEnvelope.self, from: data),
              let diagnostics = envelope.diagnostics,
              !diagnostics.requestId.isEmpty
        else { return }
        print(diagnostics.logLine)
        Task { @MainActor in
            ChemicalLookupDiagnosticsRecorder.shared.record(diagnostics)
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
            "client": ChemicalLookupClientContext().wirePayload,
        ]
        if !country.isEmpty { payload["country"] = country }
        // Identity hint from a selected register candidate. Only ever a
        // POINTER: the server re-verifies name↔number against the official
        // register before anything binds.
        if let registrationNumber, !registrationNumber.isEmpty {
            payload["registrationNumber"] = registrationNumber
        }
        let data = try await postEdge(
            path: "chemical-info-lookup",
            payload: payload,
            timeout: ChemicalInfoService.structuredLookupTimeout
        )
        Self.recordDiagnostics(from: data)
        do {
            return try JSONDecoder().decode(ChemicalStructuredLookup.self, from: data)
        } catch {
            throw ChemicalLookupError.parseFailed
        }
    }

    // The `"info"` action is deliberately no longer called from iOS.
    //
    // It fed the editor's own "Search with AI" mapping, which wrote the legacy
    // free-text chemistry and never the structured sql/194 record — a second
    // pipeline producing a second answer for the same product. Product data now
    // arrives only through `searchChemicals` → `lookupStructured` →
    // `ChemicalReviewMerge`. The Edge Function still serves the action for other
    // clients; nothing here calls it.

    private func postEdge(
        path: String,
        payload: [String: Any],
        timeout: TimeInterval
    ) async throws -> Data {
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
        req.timeoutInterval = timeout
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session(timeout: timeout).data(for: req)
        } catch let error as URLError where error.code == .timedOut {
            // Reported as its own case so the caller can say "ask again"
            // instead of quietly falling back to a half-populated draft.
            throw ChemicalLookupError.timedOut
        } catch let error as URLError where error.code == .cancelled {
            // The operator left the screen. Their decision, not a fault:
            // surface it as cancellation so no error banner is raised for it.
            throw CancellationError()
        }
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

    /// A session whose deadline is the WHOLE request, not the idle gap.
    ///
    /// # Why `URLSession.shared` was the wrong tool
    ///
    /// `URLRequest.timeoutInterval` is a STALL timer: it measures the gap
    /// between bytes, and it was the only bound this code set. A structured
    /// lookup sends its request and then receives nothing at all until the
    /// server has finished the register + label + research chain, so the whole
    /// silent think-time counts as one idle gap. `URLSession.shared` also
    /// carries a fixed `timeoutIntervalForResource` that no per-request value
    /// can raise.
    ///
    /// Setting both bounds on a purpose-built configuration makes the deadline
    /// mean what the constant says it means.
    private static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }
}
