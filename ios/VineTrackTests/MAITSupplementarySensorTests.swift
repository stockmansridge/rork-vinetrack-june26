import Foundation
import Testing
@testable import VineTrack

@MainActor
struct MAITSupplementarySensorTests {
    private let fixture = #"{"success":true,"partial":false,"modules":[{"module_id":221,"friendly_name":"EnviroPro Moisture","observed_at":"2026-10-26T06:00:00Z","status":"ok","partial":false,"readings":[{"canonical_metric":"soil_moisture","channel_key":"1","channel_number":1,"source_label":"Soil moisture","source_unit":"%","raw_value":245,"value":24.5}]},{"module_id":222,"friendly_name":"EnviroPro Temperature","observed_at":"2026-10-26T06:00:00Z","status":"ok","partial":false,"readings":[{"canonical_metric":"soil_temperature","channel_key":"1","channel_number":1,"source_label":"Soil temperature","source_unit":"°C","raw_value":182,"value":18.2}]}]}"#

    @Test func exactSupplementaryJWTBodyAndUsable206() async throws {
        let vineyard = UUID()
        let result = try await WeatherCurrentService.loadSupplementary(vineyardId: vineyard, token: "synthetic-member-jwt", isCurrent: { true }, send: { request in
            #expect(request.url?.host == AppConfig.supabaseURL.host)
            #expect(request.url?.path == "/functions/v1/mait-intelliweb-proxy")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-member-jwt")
            #expect(request.value(forHTTPHeaderField: "apikey") == AppConfig.supabaseAnonKey)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String]
            #expect(body == ["vineyardId": vineyard.uuidString, "action": "supplementary_current"])
            return (Data(fixture.utf8), HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: nil)!)
        })
        #expect(result.modules.count == 2)
        #expect(result.modules[0].friendlyName == "EnviroPro Moisture")
        #expect(result.modules[0].observedAt == "2026-10-26T06:00:00Z")
        #expect(result.modules[0].visibleReadings[0].value == 24.5)
        #expect(result.modules[0].visibleReadings[0].displayValue?.hasSuffix(" %") == true)
        #expect(result.modules[1].visibleReadings[0].value == 18.2)
        #expect(result.modules[1].visibleReadings[0].displayValue?.hasSuffix(" °C") == true)
        #expect(result.warning == MAITSupplementarySensors.warning)
    }

    @Test func cleanResponseHasNoWarningAndNoModulesMeansNoSection() throws {
        let result = try JSONDecoder().decode(MAITSupplementarySensors.self, from: Data(fixture.utf8))
        #expect(result.warning == nil)
        let empty = try JSONDecoder().decode(MAITSupplementarySensors.self, from: Data(#"{"success":true,"partial":false,"modules":[]}"#.utf8))
        #expect(empty.modules.isEmpty && empty.warning == nil)
    }

    @Test func moduleFailuresAreIndependentAndNullsDoNotBecomeZero() throws {
        let data = Data(#"{"success":true,"partial":true,"modules":[{"friendly_name":"Wetness","status":"ok","readings":[{"canonical_metric":"leaf_wetness","source_unit":"index","value":2.5,"raw_value":999},{"canonical_metric":"soil_moisture","source_unit":"%","value":null,"raw_value":500}]},{"friendly_name":"No signal","status":"no_data"},{"friendly_name":"Failed","status":"error"}]}"#.utf8)
        let result = try JSONDecoder().decode(MAITSupplementarySensors.self, from: data)
        #expect(result.modules[0].visibleReadings.count == 1)
        #expect(result.modules[0].visibleReadings[0].value == 2.5)
        #expect(result.modules[0].visibleReadings[0].displayValue?.hasSuffix(" index") == true)
        #expect(result.modules[0].readings[1].displayValue == nil)
        #expect(result.modules[1].statusLabel == "No recent data" && result.modules[1].visibleReadings.isEmpty)
        #expect(result.modules[2].statusLabel == "Sensor data unavailable" && result.modules[2].visibleReadings.isEmpty)
        #expect(result.warning == MAITSupplementarySensors.warning)
    }

    @Test func normalizedUnitsNeverUseRawValueOrInventPercent() throws {
        let reading = try JSONDecoder().decode(MAITSupplementarySensors.Reading.self, from: Data(#"{"canonical_metric":"soil_moisture","source_unit":"kPa","raw_value":9000,"value":24.5}"#.utf8))
        #expect(reading.value == 24.5 && reading.displayValue?.hasSuffix(" kPa") == true)
        let leaf = try JSONDecoder().decode(MAITSupplementarySensors.Reading.self, from: Data(#"{"canonical_metric":"leaf_wetness","value":0}"#.utf8))
        #expect(leaf.displayValue == "0")
    }

    @Test func accountOrVineyardChangeDuringResponseDiscardsPayload() async throws {
        var current = true
        do {
            _ = try await WeatherCurrentService.loadSupplementary(vineyardId: UUID(), token: "synthetic-jwt", isCurrent: { current }, send: { request in
                current = false
                return (Data(fixture.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            Issue.record("Old-scope sensor names/readings escaped")
        } catch is CancellationError { } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func obsoleteScopeOrMissingJWTDoesNotSend() async {
        var sends = 0
        for (token, admitted) in [("synthetic-jwt", false), ("", true)] {
            do {
                _ = try await WeatherCurrentService.loadSupplementary(vineyardId: UUID(), token: token, isCurrent: { admitted }, send: { _ in
                    sends += 1
                    throw URLError(.timedOut)
                })
                Issue.record("Unadmitted request succeeded")
            } catch { }
        }
        #expect(sends == 0)
    }

    @Test func supplementaryFailureLeavesPrimarySourceTimeAndMetricsUnchanged() async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let primary = WeatherCurrentService.snapshot(try decoder.decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"mait_intelliweb","station_name":"Mt Bera Weather Station","observed_at":"2026-10-26T06:00:00Z","temperature_c":14.5,"humidity_pct":54.4,"wind_speed_kmh":4,"wind_direction_deg":133,"wind_gust_kmh":14.5,"rain_today_mm":0,"rain_rate_mm_per_hr":null,"leaf_wetness":null,"status":"ok","is_stale":false}"#.utf8)))
        do {
            _ = try await WeatherCurrentService.loadSupplementary(vineyardId: UUID(), token: "synthetic-jwt", isCurrent: { true }, send: { request in
                (Data("private upstream error".utf8), HTTPURLResponse(url: request.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!)
            })
            Issue.record("Expected supplementary failure")
        } catch { #expect(!error.localizedDescription.contains("private upstream")) }
        #expect(primary.sourceLabel == "MAIT iNTELLiWeb" && primary.stationName == "Mt Bera Weather Station")
        #expect(primary.observedAt != nil && !primary.isStale)
        #expect([primary.temperatureC, primary.humidityPct, primary.windSpeedKmh, primary.windDirectionDeg, primary.windGustKmh, primary.rainTodayMm].compactMap { $0 }.count == 6)
        #expect(primary.rainRateMmPerHr == nil && primary.leafWetness == nil)
        #expect(WeatherCurrentService.compassDirection(degrees: 133) == "SE")
    }

    @Test func explicitPrimaryRoutesIncludingNoneAreExclusiveOnForcedRefresh() async throws {
        for (selection, expected) in [(LocalObservationProvider.mait, "mait_intelliweb"), (.davis, "davis_weatherlink"), (.wunderground, "wunderground_pws"), (.none, "none")] {
            var sends: [String] = []
            _ = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in nil }, selection: { _ in selection }, refresh: { source, _, _ in sends.append(source) })
            #expect(sends == (expected == "none" ? [] : [expected]))
        }
    }

    @Test func forcedFreshReadingDoesRefreshAndUnresolvedSelectionSendsNothing() async throws {
        let snap = WeatherCurrentService.snapshot(try JSONDecoder().decode(WeatherCurrentService.CurrentWeatherRow.self, from: Data(#"{"source":"wunderground_pws","status":"ok","is_stale":false}"#.utf8)))
        var sends: [String] = []
        _ = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in snap }, selection: { _ in .wunderground }, refresh: { source, _, _ in sends.append(source) })
        #expect(sends == ["wunderground_pws"])
        #expect(snap.refreshFailureMessage == "Live observations not refreshed — Weather Underground PWS")
        do {
            _ = try await WeatherCurrentService.refreshCurrent(vineyardId: UUID(), force: true, read: { _ in snap }, selection: { _ in throw URLError(.timedOut) }, refresh: { source, _, _ in sends.append(source) })
        } catch { }
        #expect(sends == ["wunderground_pws"])
    }
}
