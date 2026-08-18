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
    /// "master" | "ai_candidate" | "unresolved" | nil (pre-sql/199 server).
    let matchSource: String?
    /// Present only on master-served responses.
    let master: ChemicalMasterMatch?

    /// True when this lookup was served from an APPROVED master catalogue row
    /// and carries the reference the saved record should retain.
    var isMasterMatch: Bool { matchSource == "master" && master != nil }

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
        case matchSource = "match_source"
        case master
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
        // Additive sql/199 envelope — tolerant on both sides: an old server
        // sends neither key, and a malformed master block degrades to nil
        // (plain AI-candidate behaviour) rather than failing the lookup.
        matchSource = try? c.decodeIfPresent(String.self, forKey: .matchSource)
        master = try? c.decodeIfPresent(ChemicalMasterMatch.self, forKey: .master)
    }

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
            productCategory: productCategory ?? "",
            activityGroupTableVersion: max(activityGroupTableVersion, AuthoritativeActivityGroups.tableVersion),
            schemaVersion: max(schemaVersion, ChemicalIntelligence.currentSchemaVersion)
        )
    }
}

nonisolated struct ChemicalSearchResult: Identifiable, Codable, Sendable, Hashable {
    var id: String { name }
    let name: String
    let activeIngredient: String
    let chemicalGroup: String
    let brand: String
    let primaryUse: String
    let modeOfAction: String
}

nonisolated struct ChemicalSearchResponse: Codable, Sendable {
    let results: [ChemicalSearchResult]
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

    /// Resolves the country to use for AI localization.
    /// Prefers the explicit vineyard country; falls back to the device/user
    /// locale region (e.g. "AU", "NZ", "US") so AI search is always localized.
    static func resolveCountry(vineyardCountry: String?) -> String {
        let trimmed = (vineyardCountry ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if #available(iOS 16.0, *) {
            if let region = Locale.current.region?.identifier, !region.isEmpty {
                if let localized = Locale.current.localizedString(forRegionCode: region), !localized.isEmpty {
                    return localized
                }
                return region
            }
        } else if let code = Locale.current.regionCode, !code.isEmpty {
            if let localized = Locale.current.localizedString(forRegionCode: code), !localized.isEmpty {
                return localized
            }
            return code
        }
        return ""
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
    func lookupStructured(productName: String, country: String = "") async throws -> ChemicalStructuredLookup {
        var payload: [String: Any] = [
            "action": "structured",
            "productName": productName,
        ]
        if !country.isEmpty { payload["country"] = country }
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
