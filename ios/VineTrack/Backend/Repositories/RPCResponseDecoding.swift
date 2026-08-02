//
//  RPCResponseDecoding.swift
//  VineTrack
//
//  Strict-but-diagnosable decoding for Supabase RPC responses.
//
//  `PostgrestResponse.value` throws a bare `DecodingError`, whose
//  `localizedDescription` is the useless "The data couldn't be read because it
//  isn't in the correct format." — the exact message the Grant Unlimited screen
//  was showing. Decoding through `RPCDecoding` instead keeps the raw body so a
//  failure reports: RPC name, HTTP status, coding path, offending key, the
//  expected Swift type, the JSON type actually received, and a sanitised body.
//
//  It is deliberately tolerant of *shape* (rows vs single object vs wrapped
//  object) and of timestamp formats, but NOT of types: models still declare
//  their real types, and legitimately-nullable server fields stay optional.
//

import Foundation

// MARK: - Failure

/// A decode failure that carries everything support needs, while the UI shows
/// only `errorDescription`.
nonisolated struct RPCDecodingFailure: Error, LocalizedError, Sendable {
    let endpoint: String
    let status: Int?
    /// Full, sanitised technical report. Safe to log and to copy into a ticket.
    let diagnostics: String

    var errorDescription: String? {
        "The server sent \(endpoint) in an unexpected format. Tap Retry — if it keeps happening, send diagnostics to support."
    }
}

// MARK: - Decoding

nonisolated enum RPCDecoding {

    /// Decoder that accepts every timestamp shape PostgREST can emit:
    /// ISO8601 with/without fractional seconds and Postgres' space-separated
    /// `2026-08-01 04:05:06+00`.
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = flexibleDate(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised timestamp format: \(raw)"
            )
        }
        return decoder
    }()

    static func flexibleDate(from raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }

        let formats = [
            "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ",
            "yyyy-MM-dd HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    /// Keys a Postgres function may use when it returns a JSON envelope
    /// instead of a row set.
    private static let envelopeKeys = ["rows", "data", "items", "result", "results", "records", "vineyards"]

    /// Decodes a row set, tolerating: a JSON array (normal `returns table`),
    /// a single JSON object (`returns json`), or a one-key envelope around the
    /// array. Any other shape throws a fully-diagnosed `RPCDecodingFailure`.
    static func rows<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        status: Int? = nil,
        endpoint: String
    ) throws -> [T] {
        // Empty body / SQL NULL are a valid EMPTY result, not malformed data.
        let trimmed = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if data.isEmpty || trimmed.isEmpty || trimmed == "null" { return [] }

        var firstError: Error?

        do { return try decoder.decode([T].self, from: data) } catch { firstError = error }

        // Single object (RPC returning `json` / `setof` with one row).
        if let single = try? decoder.decode(T.self, from: data) { return [single] }

        // Envelope: {"rows": [...]} and friends.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in envelopeKeys {
                guard let nested = object[key] else { continue }
                if nested is NSNull { return [] }
                if let nestedData = try? JSONSerialization.data(withJSONObject: nested),
                   let decoded = try? decoder.decode([T].self, from: nestedData) {
                    return decoded
                }
            }
        }

        throw failure(for: firstError, data: data, status: status, endpoint: endpoint, expecting: "[\(T.self)]")
    }

    /// Builds the full diagnostic report for a failed decode.
    static func failure(
        for error: Error?,
        data: Data,
        status: Int?,
        endpoint: String,
        expecting: String
    ) -> RPCDecodingFailure {
        var lines: [String] = [
            "rpc: \(endpoint)",
            "http_status: \(status.map(String.init) ?? "unknown")",
            "expected: \(expecting)",
        ]

        if let error {
            if let described = BackendErrorDiagnostics.decodingDescription(error, endpoint: endpoint) {
                lines.append(described)
            } else {
                lines.append("error: \(BackendErrorDiagnostics.sanitise(String(describing: error)))")
            }
            if let decodingError = error as? DecodingError,
               let context = context(of: decodingError),
               let actual = BackendErrorDiagnostics.actualValueType(in: data, at: context.codingPath) {
                lines.append("actual_json_type: \(actual)")
            }
        } else {
            lines.append("error: response shape did not match any supported form")
        }

        lines.append("top_level_json_type: \(topLevelType(of: data))")
        lines.append("body: \(BackendErrorDiagnostics.responsePreview(data))")

        return RPCDecodingFailure(endpoint: endpoint, status: status, diagnostics: lines.joined(separator: "\n"))
    }

    private static func context(of error: DecodingError) -> DecodingError.Context? {
        switch error {
        case let .keyNotFound(_, context): return context
        case let .typeMismatch(_, context): return context
        case let .valueNotFound(_, context): return context
        case let .dataCorrupted(context): return context
        @unknown default: return nil
        }
    }

    private static func topLevelType(of data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return "not-json" }
        if object is [Any] { return "array" }
        if object is [String: Any] { return "object" }
        return "scalar"
    }
}

// MARK: - Tolerant scalars

/// Decodes a UUID whether the server sent a UUID string, an uppercase string,
/// or a `{"uuid": "..."}`-style wrapper. Never silently invents an id.
nonisolated struct FlexibleUUID: Decodable, Sendable, Hashable {
    let value: UUID

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let uuid = try? container.decode(UUID.self) {
            value = uuid
            return
        }
        let raw = try container.decode(String.self)
        guard let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespaces)) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID, received the string \"\(raw)\""
            )
        }
        value = uuid
    }
}

/// Decodes an integer that PostgREST may emit as a JSON number **or** as a
/// string (`bigint` over some drivers) — without turning every field into text.
nonisolated struct FlexibleInt: Decodable, Sendable, Hashable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) { value = int; return }
        if let double = try? container.decode(Double.self) { value = Int(double); return }
        let raw = try container.decode(String.self)
        guard let int = Int(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a whole number, received the string \"\(raw)\""
            )
        }
        value = int
    }
}
