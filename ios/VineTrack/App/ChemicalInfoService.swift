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
