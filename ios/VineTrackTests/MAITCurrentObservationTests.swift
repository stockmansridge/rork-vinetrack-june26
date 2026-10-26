import Foundation
import Testing
@testable import VineTrack

@MainActor
struct MAITCurrentObservationTests {
    @Test func explicitSelectionNeverEntersLegacyFallback() {
        #expect(LocalObservationProvider.fromBackend("mait_intelliweb") == .mait)
        #expect(!LocalObservationProvider.mobileSelectable.contains(.mait))
        #expect(WeatherCurrentService.resolvedSource(selection: .mait, cachedSource: "davis_weatherlink") == "mait_intelliweb")
        #expect(WeatherCurrentService.resolvedSource(selection: nil, cachedSource: "mait_intelliweb") == "none")
        #expect(WeatherCurrentService.resolvedSource(selection: nil, cachedSource: "davis_weatherlink") == "davis_weatherlink")
        #expect(WeatherCurrentService.resolvedSource(selection: nil, cachedSource: "wunderground_pws") == "wunderground_pws")
        #expect(WeatherCurrentService.resolvedSource(selection: LocalObservationProvider.none, cachedSource: "mait_intelliweb") == "none")
        #expect(!ForecastProvider.allCases.map(\.rawValue).contains("mait_intelliweb"))
    }

    @Test func normalizedMissingMetricsRemainMissing() throws {
        let data = Data(#"{"source":"mait_intelliweb","station_id":"station-fixture","station_name":"North station","temperature_c":null,"humidity_pct":66,"wind_direction_deg":270,"rain_today_mm":0,"is_stale":true,"status":"ok"}"#.utf8)
        let row = try JSONDecoder().decode(WeatherCurrentService.CurrentWeatherRow.self, from: data)
        let snapshot = WeatherCurrentService.snapshot(row)
        #expect(snapshot.sourceLabel == "MAIT iNTELLiWeb")
        #expect(snapshot.stationName == "North station" && snapshot.observedAt == nil)
        #expect(snapshot.temperatureC == nil && snapshot.humidityPct == 66)
        #expect(snapshot.windSpeedKmh == nil && snapshot.windGustKmh == nil && snapshot.windDirectionDeg == 270)
        #expect(snapshot.rainTodayMm == 0 && snapshot.rainRateMmPerHr == nil && snapshot.leafWetness == nil)
        #expect(snapshot.isStale)
    }

    @Test func authenticatedRequestContainsOnlyCurrentContract() throws {
        let vineyard = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let request = try WeatherCurrentService.maitRequest(vineyardId: vineyard, token: "synthetic-member-jwt")
        #expect(request.url?.host == AppConfig.supabaseURL.host)
        #expect(request.url?.path == "/functions/v1/mait-intelliweb-proxy")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-member-jwt")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
        #expect(body == ["vineyardId": vineyard.uuidString, "action": "current"])
        #expect(throws: (any Error).self) { try WeatherCurrentService.maitRequest(vineyardId: vineyard, token: "") }
    }

    @Test func refreshUsesSelectedMAITThenRereadsNormalizedRPC() async throws {
        let vineyard = UUID()
        let decoder = JSONDecoder()
        let first = WeatherCurrentService.snapshot(try decoder.decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"mait_intelliweb","temperature_c":19,"is_stale":true,"status":"ok"}"#.utf8)))
        let second = WeatherCurrentService.snapshot(try decoder.decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"mait_intelliweb","temperature_c":22,"is_stale":false,"status":"ok"}"#.utf8)))
        var events: [String] = []
        var reads = 0
        let result = try await WeatherCurrentService.refreshCurrent(vineyardId: vineyard, force: false, read: { id in
            #expect(id == vineyard)
            events.append("read"); reads += 1
            return reads == 1 ? first : second
        }, selection: { id in #expect(id == vineyard); events.append("selection"); return .mait }, refresh: { source, id, station in
            #expect(source == "mait_intelliweb" && id == vineyard && station == nil)
            events.append("refresh")
        })
        #expect(events == ["selection", "read", "refresh", "read"])
        #expect(result?.temperatureC == 22 && result?.refreshAttempted == true)
    }

    @Test func selectedMAITCanRefreshWithoutPriorRow() async throws {
        var reads = 0
        var sources: [String] = []
        let result = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in reads += 1; return nil }, selection: { _ in .mait }, refresh: { source, _, _ in sources.append(source) })
        #expect(result == nil && reads == 2 && sources == ["mait_intelliweb"])
    }

    @Test func freshReadingDoesNotClaimARefresh() async throws {
        let row = try JSONDecoder().decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"mait_intelliweb","status":"ok","is_stale":false}"#.utf8))
        let snapshot = WeatherCurrentService.snapshot(row)
        var sends = 0
        let result = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: false, read: { _ in snapshot }, selection: { _ in .mait }, refresh: { _, _, _ in sends += 1 })
        #expect(sends == 0 && result?.refreshAttempted == false)
    }

    @Test func failureRetainsLastKnownWithoutAnotherProvider() async throws {
        let row = try JSONDecoder().decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"mait_intelliweb","temperature_c":21,"status":"ok","is_stale":true}"#.utf8))
        let snapshot = WeatherCurrentService.snapshot(row)
        var calls: [String] = []
        var reads = 0
        do {
            _ = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in reads += 1; return snapshot }, selection: { _ in .mait }, refresh: { source, _, _ in
                calls.append(source)
                throw URLError(.timedOut)
            })
            Issue.record("A failed MAIT refresh must throw")
        } catch { }
        #expect(calls == ["mait_intelliweb"] && reads == 1)
        let retained = WeatherCurrentService.CachedSnapshot.retainingLastKnown(nil, previous: snapshot)
        #expect(retained?.temperatureC == 21 && retained?.isStale == true)
        #expect(retained?.refreshFailureMessage == "Live observations not refreshed — MAIT iNTELLiWeb")
    }

    @Test func successfulRefreshWithNoDataRetainsOriginalTimeAndReadings() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let first = WeatherCurrentService.snapshot(try decoder.decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"mait_intelliweb","observed_at":"2026-10-26T01:00:00Z","rain_today_mm":4,"status":"ok","is_stale":true}"#.utf8)))
        let empty = WeatherCurrentService.snapshot(try decoder.decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"mait_intelliweb","status":"no_data"}"#.utf8)))
        var reads = 0
        let result = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in reads += 1; return reads == 1 ? first : empty }, selection: { _ in .mait }, refresh: { _, _, _ in })
        #expect(result?.observedAt == first.observedAt && result?.rainTodayMm == 4)
        #expect(result?.source == "mait_intelliweb" && result?.isStale == true && result?.refreshAttempted == true)
        let different = WeatherCurrentService.snapshot(try decoder.decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"davis_weatherlink","status":"no_data"}"#.utf8)))
        #expect(WeatherCurrentService.CachedSnapshot.retainingLastKnown(different, previous: first)?.source == "davis_weatherlink")
    }

    @Test func selectionNetworkFailureCannotMasqueradeAsLegacyNull() async {
        var reads = 0
        var sends = 0
        do {
            _ = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in reads += 1; return nil }, selection: { _ in throw URLError(.notConnectedToInternet) }, refresh: { _, _, _ in sends += 1 })
            Issue.record("Selection failure was hidden")
        } catch { }
        #expect(reads == 0 && sends == 0)
    }

    @Test func cancelledReadCannotTriggerAnUpstreamSend() async throws {
        var sends = 0
        let task = Task {
            try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in nil }, selection: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }, refresh: { _, _, _ in sends += 1 })
        }
        do { _ = try await task.value; Issue.record("Cancelled operation succeeded") } catch { }
        #expect(sends == 0)
    }

    @Test func irrigationLabelRequiresExactFrozenControllerIdentity() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let base: [String: Any] = ["id": id, "vineyard_id": id, "irrigation_system_id": id, "valve_id": id,
            "session_date": "2026-10-26", "vintage_year": 2026, "duration_minutes": 10, "calculation_method": "configured_flow",
            "total_volume_litres": 500, "status": "completed", "blocks": []]
        for (source, provider, expected) in [("controller_api", "mait_intelliweb", "MAIT iNTELLiWeb"), ("controller_api", "galcon_gsi", "Controller"), ("controller_api", "", "Controller"), ("manual_ios", "mait_intelliweb", "iPhone"), ("csv_import", "mait_intelliweb", "CSV import"), ("galcon_gsi_import", "mait_intelliweb", "Galcon GSI import")] {
            var json = base
            json["source_type"] = source
            if !provider.isEmpty { json["configuration_snapshot"] = ["import": ["provider": provider]] }
            let session = try JSONDecoder().decode(IrrigationSession.self, from: JSONSerialization.data(withJSONObject: json))
            #expect(session.sourceLabel == expected && session.totalVolumeLitres == 500 && session.durationMinutes == 10)
        }
    }
}
