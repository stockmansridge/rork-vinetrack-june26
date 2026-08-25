import Foundation
import Testing

@testable import VineTrack

/// Task §14 — production lookup diagnostics, iOS half.
///
/// These tests exist because the Hortitrol split ("Portal says 50067, iOS says
/// 33182") was UNINVESTIGABLE: nothing in either request recorded which build
/// answered, which candidates came back, or in what order. The value of the
/// envelope is entirely in it being present, ordered and comparable — so that
/// is what is asserted, rather than the shape of the JSON.
@Suite("Chemical lookup diagnostics")
struct ChemicalLookupDiagnosticsTests {

    private func decode(_ json: String) throws -> ChemicalLookupDiagnostics {
        let envelope = try JSONDecoder().decode(
            ChemicalDiagnosticsEnvelope.self,
            from: Data(json.utf8)
        )
        return try #require(envelope.diagnostics)
    }

    /// A full envelope as the edge function serves it for the reproduction case.
    private let hortitrolSearch = """
    {
      "results": [],
      "diagnostics": {
        "request_id": "11111111-2222-3333-4444-555555555555",
        "correlation_id": "client-abc",
        "client": { "platform": "ios", "app_version": "2.14.0", "app_build": "1487" },
        "server": { "lookup_version": "a1b2c3d", "project_ref": "vtprod" },
        "action": "search",
        "country": { "requested": "AU", "resolved_code": "AU" },
        "query": "Hortitrol winter oil",
        "candidate_registration_numbers": ["50067", "33182", null],
        "candidates": [
          { "registrationNumber": "50067", "name": "HORTITROL WINTER OIL",
            "source": "official_register", "score": 100, "reason": "exact_name" },
          { "registrationNumber": "33182", "name": "OTHER WINTER OIL",
            "source": "official_register", "score": 40, "reason": "contained_phrase" },
          { "registrationNumber": null, "name": "A suggestion",
            "source": "ai", "score": null, "reason": null }
        ],
        "selected_registration": null,
        "lookup_method": "official_register",
        "cache": "miss",
        "duration_ms": 812,
        "degraded": []
      }
    }
    """

    // MARK: - Client context

    @Test("The client identifies itself as ios with a version and build")
    func clientContextIsComplete() {
        let ctx = ChemicalLookupClientContext(
            appVersion: "2.14.0",
            appBuild: "1487",
            correlationId: "abc"
        )
        let payload = ctx.wirePayload
        #expect(payload["platform"] == "ios")
        #expect(payload["app_version"] == "2.14.0")
        #expect(payload["app_build"] == "1487")
        #expect(payload["correlation_id"] == "abc")
    }

    @Test("Each lookup gets its own correlation id")
    func correlationIdsAreUnique() {
        let a = ChemicalLookupClientContext()
        let b = ChemicalLookupClientContext()
        #expect(a.correlationId != b.correlationId)
    }

    @Test("The platform is fixed, never derived from the device")
    func platformIsFixed() {
        // An iPad, a simulator and a phone must all report `ios`, or grouping
        // a parity run by platform stops working.
        #expect(ChemicalLookupClientContext.platform == "ios")
    }

    // MARK: - Envelope decoding

    @Test("Candidate registrations decode IN SERVED ORDER")
    func candidateOrderSurvives() throws {
        let d = try decode(hortitrolSearch)
        // The single assertion the whole parity investigation turns on.
        #expect(d.candidateRegistrationNumbers == ["50067", "33182", nil])
        #expect(d.candidates.count == 3)
        #expect(d.candidates[0].registrationNumber == "50067")
        #expect(d.candidates[0].reason == "exact_name")
        #expect(d.candidates[1].registrationNumber == "33182")
    }

    @Test("A candidate with no registration decodes as null, not dropped")
    func unregisteredCandidateSurvives() throws {
        let d = try decode(hortitrolSearch)
        // One platform showing an unregistered suggestion where another shows
        // a register row IS the divergence; dropping it would hide it.
        #expect(d.candidateRegistrationNumbers.count == 3)
        #expect(d.candidateRegistrationNumbers[2] == nil)
        #expect(d.candidates[2].source == "ai")
    }

    @Test("Server build and project decode, so two runs can be compared")
    func serverIdentityDecodes() throws {
        let d = try decode(hortitrolSearch)
        #expect(d.lookupVersion == "a1b2c3d")
        #expect(d.projectRef == "vtprod")
        #expect(d.resolvedCountryCode == "AU")
        #expect(d.requestedCountry == "AU")
        #expect(d.query == "Hortitrol winter oil")
        #expect(d.lookupMethod == "official_register")
        #expect(d.cache == "miss")
        #expect(d.durationMs == 812)
    }

    @Test("The correlation id round-trips so a device log joins a server log")
    func correlationRoundTrips() throws {
        let d = try decode(hortitrolSearch)
        #expect(d.correlationId == "client-abc")
        #expect(d.requestId == "11111111-2222-3333-4444-555555555555")
    }

    // MARK: - Parity fingerprint

    @Test("Identical server answers produce identical fingerprints")
    func fingerprintMatchesAcrossPlatforms() throws {
        let ios = try decode(hortitrolSearch)
        // The SAME server answer, but reported to the Portal: a different
        // client, a different request id, a different duration.
        let portal = try decode(hortitrolSearch
            .replacingOccurrences(of: "\"platform\": \"ios\"", with: "\"platform\": \"portal\"")
            .replacingOccurrences(of: "\"duration_ms\": 812", with: "\"duration_ms\": 149")
            .replacingOccurrences(
                of: "11111111-2222-3333-4444-555555555555",
                with: "99999999-8888-7777-6666-555555555555"
            ))

        // Parity is about the ANSWER, so client-varying facts must not enter
        // the fingerprint — otherwise every comparison fails for the wrong
        // reason and the real defect hides behind the noise.
        #expect(ios.parityFingerprint == portal.parityFingerprint)
    }

    @Test("A DIFFERENT candidate order breaks the fingerprint")
    func fingerprintCatchesReordering() throws {
        let ios = try decode(hortitrolSearch)
        let reordered = try decode(hortitrolSearch.replacingOccurrences(
            of: "[\"50067\", \"33182\", null]",
            with: "[\"33182\", \"50067\", null]"
        ))
        // Exactly the Hortitrol reproduction: same products, different order,
        // so the two platforms auto-select different registrations.
        #expect(ios.parityFingerprint != reordered.parityFingerprint)
    }

    @Test("A different server build breaks the fingerprint")
    func fingerprintCatchesBuildSkew() throws {
        let ios = try decode(hortitrolSearch)
        let otherBuild = try decode(hortitrolSearch.replacingOccurrences(
            of: "\"lookup_version\": \"a1b2c3d\"",
            with: "\"lookup_version\": \"deadbee\""
        ))
        // Two clients hitting two deployments is a real cause of divergence
        // and must never read as agreement.
        #expect(ios.parityFingerprint != otherBuild.parityFingerprint)
    }

    @Test("A different project breaks the fingerprint")
    func fingerprintCatchesProjectSkew() throws {
        let ios = try decode(hortitrolSearch)
        let otherProject = try decode(hortitrolSearch.replacingOccurrences(
            of: "\"project_ref\": \"vtprod\"",
            with: "\"project_ref\": \"vtstaging\""
        ))
        #expect(ios.parityFingerprint != otherProject.parityFingerprint)
    }

    // MARK: - Structured lookups

    @Test("A structured lookup records the registration actually served")
    func structuredRecordsSelection() throws {
        let d = try decode("""
        {
          "product_name": "HORTITROL WINTER OIL",
          "diagnostics": {
            "request_id": "req-structured",
            "correlation_id": null,
            "client": { "platform": "ios", "app_version": "2.14.0", "app_build": "1487" },
            "server": { "lookup_version": "a1b2c3d", "project_ref": "vtprod" },
            "action": "structured",
            "country": { "requested": "AU", "resolved_code": "AU" },
            "query": "HORTITROL WINTER OIL",
            "candidate_registration_numbers": [],
            "candidates": [],
            "selected_registration": "50067",
            "lookup_method": "official_register",
            "cache": "hit",
            "duration_ms": 63,
            "degraded": []
          }
        }
        """)
        #expect(d.action == "structured")
        #expect(d.selectedRegistration == "50067")
        #expect(d.cache == "hit")
    }

    // MARK: - Degradation

    @Test("Degraded stages decode, so a fail-soft split is explainable")
    func degradedStagesSurface() throws {
        let d = try decode(hortitrolSearch.replacingOccurrences(
            of: "\"degraded\": []",
            with: "\"degraded\": [\"register_discovery_failed\"]"
        ))
        // A register timeout on one platform and not the other explains a
        // divergence that would otherwise look like a ranking bug.
        #expect(d.degraded == ["register_discovery_failed"])
        #expect(d.logLine.contains("degraded=[register_discovery_failed]"))
    }

    // MARK: - Tolerance

    @Test("A response with no diagnostics decodes without failing")
    func absentDiagnosticsAreTolerated() throws {
        let envelope = try JSONDecoder().decode(
            ChemicalDiagnosticsEnvelope.self,
            from: Data(#"{"results": []}"#.utf8)
        )
        // An older server must not break the client.
        #expect(envelope.diagnostics == nil)
    }

    @Test("A malformed envelope costs the diagnostics, never the lookup")
    func malformedDiagnosticsAreTolerated() throws {
        let envelope = try JSONDecoder().decode(
            ChemicalDiagnosticsEnvelope.self,
            from: Data(#"{"results": [], "diagnostics": "not an object"}"#.utf8)
        )
        #expect(envelope.diagnostics == nil)
    }

    @Test("A partial envelope decodes what it can")
    func partialEnvelopeDecodes() throws {
        let d = try decode("""
        {
          "diagnostics": {
            "request_id": "req-partial",
            "action": "search",
            "query": "x",
            "candidate_registration_numbers": ["50067"]
          }
        }
        """)
        #expect(d.requestId == "req-partial")
        #expect(d.candidateRegistrationNumbers == ["50067"])
        // Absent facts must not be invented.
        #expect(d.lookupVersion == "unknown")
        #expect(d.projectRef == "unknown")
        #expect(d.resolvedCountryCode == nil)
        #expect(d.degraded.isEmpty)
    }

    // MARK: - Log line

    @Test("The log line carries everything a parity run needs, on one line")
    func logLineIsComplete() throws {
        let d = try decode(hortitrolSearch)
        let line = d.logLine
        #expect(!line.contains("\n"))
        #expect(line.contains("req=11111111-2222-3333-4444-555555555555"))
        #expect(line.contains("build=a1b2c3d"))
        #expect(line.contains("project=vtprod"))
        #expect(line.contains("country=AU"))
        #expect(line.contains("method=official_register"))
        #expect(line.contains("cache=miss"))
        #expect(line.contains("candidates=[50067,33182,-]"))
    }

    // MARK: - Recorder

    @MainActor
    @Test("The recorder keeps the newest lookups and is bounded")
    func recorderIsBounded() throws {
        let recorder = ChemicalLookupDiagnosticsRecorder.shared
        recorder.clear()
        for index in 0..<30 {
            let d = try decode(hortitrolSearch.replacingOccurrences(
                of: "11111111-2222-3333-4444-555555555555",
                with: "req-\(index)"
            ))
            recorder.record(d)
        }
        #expect(recorder.recent.count == 20, "the troubleshooting buffer grew without bound")
        #expect(recorder.recent.first?.requestId == "req-29", "newest lookup is not first")
        #expect(recorder.latest(action: "search")?.requestId == "req-29")
        recorder.clear()
        #expect(recorder.recent.isEmpty)
    }
}
