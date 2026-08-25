import Foundation

/// The client half of the production lookup diagnostics contract (task §14).
///
/// # Why the client identifies itself
///
/// "Portal resolves Hortitrol winter oil to APVMA 50067, iOS resolves it to
/// 33182" cannot be investigated from the server logs alone unless each
/// request says which client asked and which build it was running. Two
/// requests that look identical in the log may be a shipped build and a
/// TestFlight build reading two different servers.
///
/// Every field here is OBSERVATIONAL. The server must never branch on it:
/// a lookup that answers differently because iOS asked would defeat the
/// parity guarantee this exists to prove.
nonisolated struct ChemicalLookupClientContext: Sendable, Hashable {
    /// Wire value for this platform. Fixed string, never derived from the
    /// device, so a simulator, an iPad and a phone all report `ios`.
    static let platform: String = "ios"

    let appVersion: String
    let appBuild: String
    /// A per-request id generated on the CLIENT, echoed by the server as
    /// `correlation_id`. Lets a screenshot from an operator be joined to a
    /// server log line without asking them to read a UUID off a console.
    let correlationId: String

    init(
        appVersion: String = AppBuildInfo.version,
        appBuild: String = AppBuildInfo.buildNumber,
        correlationId: String = UUID().uuidString
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.correlationId = correlationId
    }

    /// The `client` block sent with every lookup request.
    var wirePayload: [String: String] {
        [
            "platform": Self.platform,
            "app_version": appVersion,
            "app_build": appBuild,
            "correlation_id": correlationId
        ]
    }
}

/// One candidate as the SERVER ordered it.
///
/// Decode-only. This type exists to READ what the server decided; an encoder
/// would invite a future caller to send diagnostics back up, and a client that
/// can write its own diagnostics can no longer be used to prove parity.
nonisolated struct ChemicalLookupCandidateDiagnostic: Decodable, Sendable, Hashable {
    let registrationNumber: String?
    let name: String
    let source: String
    let score: Double?
    let reason: String?

    nonisolated enum CodingKeys: String, CodingKey {
        case registrationNumber, name, source, score, reason
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        registrationNumber = (try? c.decodeIfPresent(String.self, forKey: .registrationNumber)) ?? nil
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        source = ((try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil) ?? ""
        score = (try? c.decodeIfPresent(Double.self, forKey: .score)) ?? nil
        reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? nil
    }

    init(registrationNumber: String?, name: String, source: String, score: Double?, reason: String?) {
        self.registrationNumber = registrationNumber
        self.name = name
        self.source = source
        self.score = score
        self.reason = reason
    }
}

/// The server's diagnostics envelope, decoded verbatim.
///
/// Decoding is TOLERANT throughout: a diagnostics envelope that failed to
/// parse must never fail a lookup. Diagnostics explain an answer; they are
/// never part of one.
///
/// Decode-only, for the same reason as the candidate rows above.
nonisolated struct ChemicalLookupDiagnostics: Decodable, Sendable, Hashable {
    let requestId: String
    let correlationId: String?
    let clientPlatform: String
    let lookupVersion: String
    let projectRef: String
    let action: String
    let requestedCountry: String
    let resolvedCountryCode: String?
    let query: String
    /// Candidate registration numbers IN SERVED ORDER — the field a parity
    /// comparison actually turns on.
    let candidateRegistrationNumbers: [String?]
    let candidates: [ChemicalLookupCandidateDiagnostic]
    let selectedRegistration: String?
    let lookupMethod: String
    let cache: String
    let durationMs: Int
    let degraded: [String]

    nonisolated enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case correlationId = "correlation_id"
        case client
        case server
        case action
        case country
        case query
        case candidateRegistrationNumbers = "candidate_registration_numbers"
        case candidates
        case selectedRegistration = "selected_registration"
        case lookupMethod = "lookup_method"
        case cache
        case durationMs = "duration_ms"
        case degraded
    }

    nonisolated enum ClientKeys: String, CodingKey {
        case platform
    }

    nonisolated enum ServerKeys: String, CodingKey {
        case lookupVersion = "lookup_version"
        case projectRef = "project_ref"
    }

    nonisolated enum CountryKeys: String, CodingKey {
        case requested
        case resolvedCode = "resolved_code"
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requestId = ((try? c.decodeIfPresent(String.self, forKey: .requestId)) ?? nil) ?? ""
        correlationId = (try? c.decodeIfPresent(String.self, forKey: .correlationId)) ?? nil

        let client = try? c.nestedContainer(keyedBy: ClientKeys.self, forKey: .client)
        clientPlatform = ((try? client?.decodeIfPresent(String.self, forKey: .platform)) ?? nil) ?? ""

        let server = try? c.nestedContainer(keyedBy: ServerKeys.self, forKey: .server)
        lookupVersion = ((try? server?.decodeIfPresent(String.self, forKey: .lookupVersion)) ?? nil) ?? "unknown"
        projectRef = ((try? server?.decodeIfPresent(String.self, forKey: .projectRef)) ?? nil) ?? "unknown"

        action = ((try? c.decodeIfPresent(String.self, forKey: .action)) ?? nil) ?? ""

        let country = try? c.nestedContainer(keyedBy: CountryKeys.self, forKey: .country)
        requestedCountry = ((try? country?.decodeIfPresent(String.self, forKey: .requested)) ?? nil) ?? ""
        resolvedCountryCode = (try? country?.decodeIfPresent(String.self, forKey: .resolvedCode)) ?? nil

        query = ((try? c.decodeIfPresent(String.self, forKey: .query)) ?? nil) ?? ""
        candidateRegistrationNumbers = ((try? c.decodeIfPresent(
            [String?].self, forKey: .candidateRegistrationNumbers
        )) ?? nil) ?? []
        candidates = ((try? c.decodeIfPresent(
            [ChemicalLookupCandidateDiagnostic].self, forKey: .candidates
        )) ?? nil) ?? []
        selectedRegistration = (try? c.decodeIfPresent(String.self, forKey: .selectedRegistration)) ?? nil
        lookupMethod = ((try? c.decodeIfPresent(String.self, forKey: .lookupMethod)) ?? nil) ?? ""
        cache = ((try? c.decodeIfPresent(String.self, forKey: .cache)) ?? nil) ?? ""
        durationMs = ((try? c.decodeIfPresent(Int.self, forKey: .durationMs)) ?? nil) ?? 0
        degraded = ((try? c.decodeIfPresent([String].self, forKey: .degraded)) ?? nil) ?? []
    }

    /// A one-line parity fingerprint.
    ///
    /// Two platforms running the same query against the same server must
    /// produce the SAME string. Comparing these is the whole of the §14
    /// candidate-parity check, which is why it deliberately contains the
    /// server build and the ordered registrations and nothing that varies
    /// per client (no request id, no duration, no platform).
    var parityFingerprint: String {
        let regs = candidateRegistrationNumbers
            .map { $0 ?? "-" }
            .joined(separator: ",")
        return "\(lookupVersion)|\(projectRef)|\(resolvedCountryCode ?? "-")|\(lookupMethod)|[\(regs)]"
    }

    /// The operator-invisible log line. Emitted for every lookup so a parity
    /// run can be reconstructed from a device console without a debug build.
    var logLine: String {
        var parts = [
            "chemical_lookup",
            "action=\(action)",
            "req=\(requestId)",
            "build=\(lookupVersion)",
            "project=\(projectRef)",
            "country=\(resolvedCountryCode ?? "-")",
            "method=\(lookupMethod)",
            "cache=\(cache)",
            "ms=\(durationMs)",
            "candidates=[\(candidateRegistrationNumbers.map { $0 ?? "-" }.joined(separator: ","))]"
        ]
        if let selectedRegistration, !selectedRegistration.isEmpty {
            parts.append("selected=\(selectedRegistration)")
        }
        if !degraded.isEmpty {
            parts.append("degraded=[\(degraded.joined(separator: ","))]")
        }
        return parts.joined(separator: " ")
    }
}

/// A decoded response body that MAY carry diagnostics.
nonisolated struct ChemicalDiagnosticsEnvelope: Decodable, Sendable {
    let diagnostics: ChemicalLookupDiagnostics?

    nonisolated enum CodingKeys: String, CodingKey {
        case diagnostics
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        diagnostics = (try? c.decodeIfPresent(ChemicalLookupDiagnostics.self, forKey: .diagnostics)) ?? nil
    }
}

/// In-memory record of the most recent lookups, for the §14 parity run.
///
/// Deliberately NOT persisted and deliberately bounded: this is a
/// troubleshooting aid, not an audit log, and the audit trail that does matter
/// is the server's own structured logging.
@MainActor
final class ChemicalLookupDiagnosticsRecorder {
    static let shared = ChemicalLookupDiagnosticsRecorder()

    private(set) var recent: [ChemicalLookupDiagnostics] = []
    private let limit = 20

    private init() {}

    func record(_ diagnostics: ChemicalLookupDiagnostics) {
        recent.insert(diagnostics, at: 0)
        if recent.count > limit { recent.removeLast(recent.count - limit) }
    }

    /// The newest diagnostics for an action, for a parity comparison.
    func latest(action: String) -> ChemicalLookupDiagnostics? {
        recent.first { $0.action == action }
    }

    func clear() { recent.removeAll() }
}
