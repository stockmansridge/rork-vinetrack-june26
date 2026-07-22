import Foundation

nonisolated struct FuelLookupResult: Sendable {
    let fuelUsageLPerHour: Double
    let confidence: String?
    let notes: String?
    let matchedBrand: String?
    let matchedModel: String?
    let matchedYearRange: String?

    /// True when the AI returned no usable identification — either an empty
    /// `matchedModel` echo or a `low` confidence label. Callers should treat
    /// these as "no reliable match" and let the user enter fuel rate manually.
    var isReliableMatch: Bool {
        let hasModelEcho = !(matchedModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let lowConfidence = (confidence ?? "").lowercased() == "low"
        return hasModelEcho && !lowConfidence
    }
}

/// Errors specific to the tractor fuel lookup workflow. We distinguish
/// transient network/API unavailability from "AI returned but couldn't
/// identify the tractor" so the UI can show the right message.
nonisolated enum TractorLookupError: Error, LocalizedError, Sendable {
    case notConfigured
    case missingProviderKey
    case unavailable(String)      // network/API failure — retain user input
    case noReliableMatch(String?) // AI ran but couldn't identify

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Tractor lookup is not configured. Please try again later."
        case .missingProviderKey:
            return "AI provider key is not set on the server. Ask an admin to configure OPENAI_API_KEY."
        case .unavailable(let m):
            return "Tractor lookup is unavailable right now. You can still enter the tractor manually. (\(m))"
        case .noReliableMatch(let m):
            return m ?? "We couldn’t find a reliable tractor match."
        }
    }
}

nonisolated struct TractorFuelLookupService: Sendable {

    func lookupFuelUsage(brand: String, model: String, year: Int? = nil) async throws -> FuelLookupResult {
        guard AppConfig.isSupabaseConfigured else { throw TractorLookupError.notConfigured }
        let base = AppConfig.supabaseURL.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/functions/v1/tractor-fuel-lookup") else {
            throw TractorLookupError.unavailable("Invalid edge function URL")
        }
        let anonKey = AppConfig.supabaseAnonKey
        guard !anonKey.isEmpty else { throw TractorLookupError.notConfigured }

        var payload: [String: Any] = [
            "brand": brand,
            "model": model,
        ]
        if let year { payload["year"] = year }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            // URLSession errors are connectivity/transport failures — lookup
            // is unavailable, but the user's entered data must be retained.
            throw TractorLookupError.unavailable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TractorLookupError.unavailable("No HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["error"] as? String {
                if msg.contains("OPENAI_API_KEY") {
                    throw TractorLookupError.missingProviderKey
                }
                // 502 with "Could not determine fuel usage" → AI couldn't
                // identify; everything else is treated as service unavailable.
                if http.statusCode == 502, msg.localizedCaseInsensitiveContains("determine") {
                    throw TractorLookupError.noReliableMatch(nil)
                }
                throw TractorLookupError.unavailable(msg)
            }
            throw TractorLookupError.unavailable("HTTP \(http.statusCode)")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = (obj["fuelUsageLPerHour"] as? Double)
                ?? (obj["fuelUsageLPerHour"] as? NSNumber)?.doubleValue,
              value > 0 else {
            throw TractorLookupError.noReliableMatch(nil)
        }
        return FuelLookupResult(
            fuelUsageLPerHour: value,
            confidence: obj["confidence"] as? String,
            notes: obj["notes"] as? String,
            matchedBrand: obj["matchedBrand"] as? String,
            matchedModel: obj["matchedModel"] as? String,
            matchedYearRange: obj["matchedYearRange"] as? String
        )
    }
}
