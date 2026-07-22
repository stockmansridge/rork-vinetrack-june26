import Foundation
import Supabase
import Auth

// MARK: - Public model

/// Soil profile suggestion returned by the `nsw-seed-soil-lookup` Supabase
/// Edge Function. The NSW SEED API key and endpoint live server-side — the
/// iOS app only invokes the Edge Function with the signed-in user's JWT.
nonisolated struct NSWSeedSoilSuggestion: Sendable, Hashable {
    let irrigationSoilClass: String?
    let confidence: String?
    let soilLandscape: String?
    let soilLandscapeCode: String?
    let australianSoilClassification: String?
    let australianSoilClassificationCode: String?
    let landSoilCapability: String?
    let landSoilCapabilityClass: Int?
    let sourceFeatureId: String?
    let sourceName: String?
    let sourceDataset: String?
    let sourceEndpoint: String?
    let countryCode: String?
    let regionCode: String?
    let lookupLatitude: Double?
    let lookupLongitude: Double?
    let modelVersion: String?
    let matchedKeywords: [String]
    let disclaimer: String?
    let rawAttributes: [String: Any]?

    func hash(into hasher: inout Hasher) {
        hasher.combine(irrigationSoilClass)
        hasher.combine(sourceFeatureId)
        hasher.combine(lookupLatitude)
        hasher.combine(lookupLongitude)
    }

    static func == (lhs: NSWSeedSoilSuggestion, rhs: NSWSeedSoilSuggestion) -> Bool {
        lhs.irrigationSoilClass == rhs.irrigationSoilClass &&
        lhs.confidence == rhs.confidence &&
        lhs.soilLandscape == rhs.soilLandscape &&
        lhs.sourceFeatureId == rhs.sourceFeatureId &&
        lhs.lookupLatitude == rhs.lookupLatitude &&
        lhs.lookupLongitude == rhs.lookupLongitude
    }
}

/// Result of a paddock lookup. `found == false` means the centroid is outside
/// NSW SEED coverage (or no polygon intersected the point).
nonisolated struct NSWSeedSoilLookupResult: Sendable {
    let found: Bool
    let paddockId: UUID?
    let suggestion: NSWSeedSoilSuggestion?
    let message: String?
    let disclaimer: String?
    let rawResponse: [String: Any]?
}

// MARK: - Errors

nonisolated enum NSWSeedSoilLookupError: Error, LocalizedError, Sendable {
    case notConfigured
    case notAuthenticated
    case notAuthorised
    case unsupportedCountry(String?)
    case paddockMissingPolygon
    case paddockNotFound
    case missingEndpoint
    case upstreamError(Int, String?)
    case decoding(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Backend is not configured."
        case .notAuthenticated:
            return "You must be signed in to fetch NSW SEED soil data."
        case .notAuthorised:
            return "You don't have access to fetch NSW SEED soil data for this vineyard."
        case .unsupportedCountry(let c):
            if let c, !c.isEmpty {
                return "NSW SEED lookup is only available for Australian vineyards (current country: \(c))."
            }
            return "NSW SEED lookup is only available for Australian vineyards."
        case .paddockMissingPolygon:
            return "This block has no boundary polygon yet. Draw the block boundary before fetching NSW SEED soil data."
        case .paddockNotFound:
            return "Block not found."
        case .missingEndpoint:
            return "NSW SEED soil landscape endpoint is not configured on the server."
        case .upstreamError(let status, let msg):
            if let msg, !msg.isEmpty {
                return "NSW SEED service unavailable (HTTP \(status)): \(msg)"
            }
            return "NSW SEED service unavailable (HTTP \(status))."
        case .decoding(let msg):
            return "Could not read NSW SEED response: \(msg)"
        case .network(let msg):
            return "NSW SEED request failed: \(msg)"
        }
    }
}

// MARK: - Service

/// Calls the `nsw-seed-soil-lookup` Supabase Edge Function. The NSW SEED API
/// key and endpoint URL live in Supabase secrets — they are never read or
/// stored on device.
nonisolated struct NSWSeedSoilLookupService: Sendable {
    static let functionName = "nsw-seed-soil-lookup"

    func lookupPaddockSoil(
        vineyardId: UUID,
        paddockId: UUID,
        persist: Bool = false
    ) async throws -> NSWSeedSoilLookupResult {
        let payload: [String: Any] = [
            "action": "lookup_paddock_soil",
            "vineyardId": vineyardId.uuidString.lowercased(),
            "paddockId": paddockId.uuidString.lowercased(),
            "persist": persist,
        ]
        let body = try await invoke(payload: payload)
        return parsePaddockResult(body, paddockId: paddockId)
    }

    // MARK: - Parsing

    private func parsePaddockResult(_ body: [String: Any], paddockId: UUID) -> NSWSeedSoilLookupResult {
        let found = (body["found"] as? Bool) ?? (body["suggestion"] != nil)
        let suggestion = (body["suggestion"] as? [String: Any]).map(parseSuggestion)
        let message = body["message"] as? String
        let disclaimer = body["disclaimer"] as? String ?? suggestion?.disclaimer
        return NSWSeedSoilLookupResult(
            found: found,
            paddockId: paddockId,
            suggestion: suggestion,
            message: message,
            disclaimer: disclaimer,
            rawResponse: body
        )
    }

    private func parseSuggestion(_ dict: [String: Any]) -> NSWSeedSoilSuggestion {
        func str(_ k: String) -> String? { dict[k] as? String }
        func dbl(_ k: String) -> Double? {
            if let d = dict[k] as? Double { return d }
            if let i = dict[k] as? Int { return Double(i) }
            if let n = dict[k] as? NSNumber { return n.doubleValue }
            if let s = dict[k] as? String { return Double(s) }
            return nil
        }
        let keywords = (dict["matched_keywords"] as? [String]) ?? []
        let lscClass: Int? = {
            if let i = dict["land_soil_capability_class"] as? Int { return i }
            if let d = dict["land_soil_capability_class"] as? Double { return Int(d) }
            if let n = dict["land_soil_capability_class"] as? NSNumber { return n.intValue }
            return nil
        }()
        return NSWSeedSoilSuggestion(
            irrigationSoilClass: str("irrigation_soil_class"),
            confidence: str("confidence"),
            soilLandscape: str("soil_landscape"),
            soilLandscapeCode: str("soil_landscape_code"),
            australianSoilClassification: str("australian_soil_classification"),
            australianSoilClassificationCode: str("australian_soil_classification_code"),
            landSoilCapability: str("land_soil_capability"),
            landSoilCapabilityClass: lscClass,
            sourceFeatureId: str("source_feature_id"),
            sourceName: str("source_name"),
            sourceDataset: str("source_dataset"),
            sourceEndpoint: str("source_endpoint"),
            countryCode: str("country_code"),
            regionCode: str("region_code"),
            lookupLatitude: dbl("lookup_latitude"),
            lookupLongitude: dbl("lookup_longitude"),
            modelVersion: str("model_version"),
            matchedKeywords: keywords,
            disclaimer: str("disclaimer"),
            rawAttributes: dict["raw_attributes"] as? [String: Any]
        )
    }

    // MARK: - Edge Function call

    private func invoke(payload: [String: Any]) async throws -> [String: Any] {
        let provider = SupabaseClientProvider.shared
        guard provider.isConfigured else { throw NSWSeedSoilLookupError.notConfigured }

        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/\(Self.functionName)") else {
            throw NSWSeedSoilLookupError.network("Invalid edge function URL")
        }

        let session = try? await provider.client.auth.session
        guard let token = session?.accessToken, !token.isEmpty else {
            throw NSWSeedSoilLookupError.notAuthenticated
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw NSWSeedSoilLookupError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw NSWSeedSoilLookupError.network("No HTTP response")
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let reason = body["reason"] as? String
        let errorMessage = body["error"] as? String

        switch http.statusCode {
        case 200..<300:
            return body
        case 401:
            throw NSWSeedSoilLookupError.notAuthenticated
        case 403:
            throw NSWSeedSoilLookupError.notAuthorised
        case 400:
            switch reason {
            case "unsupported_country":
                throw NSWSeedSoilLookupError.unsupportedCountry(body["country"] as? String)
            case "paddock_missing_polygon":
                throw NSWSeedSoilLookupError.paddockMissingPolygon
            default:
                throw NSWSeedSoilLookupError.upstreamError(http.statusCode, errorMessage ?? reason)
            }
        case 404:
            throw NSWSeedSoilLookupError.paddockNotFound
        case 503:
            if reason == "missing_soil_landscape_endpoint" {
                throw NSWSeedSoilLookupError.missingEndpoint
            }
            throw NSWSeedSoilLookupError.upstreamError(http.statusCode, errorMessage)
        default:
            throw NSWSeedSoilLookupError.upstreamError(http.statusCode, errorMessage ?? reason)
        }
    }
}
