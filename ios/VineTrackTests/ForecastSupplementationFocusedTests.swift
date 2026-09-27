import Foundation
import XCTest
@testable import VineTrack

final class ForecastSupplementationFocusedTests: XCTestCase {
    @MainActor func testMissingConditionCompletesWithoutChangingPrimaryDailyFacts() {
        let result = VineyardWillyWeatherProxyService.decodeForecast([
            "source": "WillyWeather", "timezone": "Australia/Sydney",
            "days": [
                ["date": "2026-09-24", "temp_min_c": 10, "temp_max_c": 21,
                 "wind_kmh_max": 23, "rain_min_mm": 0, "rain_max_mm": 2, "rain_probability": 30],
                ["date": "2026-09-25", "precis": "Willy showers", "condition_key": "rain"],
                ["date": "2026-09-26", "precisCode": "cloudy"],
                ["date": "2026-09-27"],
            ],
        ])
        let detail = ["timezone": "Australia/Sydney",
                      "daily": ["time": ["2026-09-24", "2026-09-25", "2026-09-26", "2026-09-27"],
                                "weather_code": [51, 3, 51, 3]],
                      "hourly": ["time": []]] as [String: Any]
        let conditions = OpenMeteoDailyCondition.byDate(json: detail)
        let days = OpenMeteoDailyCondition.supplement(result.days.map { $0.asForecastDay() },
            with: conditions, timezone: TimeZone(identifier: "Australia/Sydney")!)
        XCTAssertEqual(days[0].condition, "Drizzle")
        XCTAssertEqual(days[0].conditionSource, "Open-Meteo")
        XCTAssertEqual(days[0].conditionKey, "drizzle")
        XCTAssertEqual(days[0].forecastTempMinC, 10)
        XCTAssertEqual(days[0].forecastTempMaxC, 21)
        XCTAssertEqual(days[0].forecastWindKmhMax, 23)
        XCTAssertEqual(days[0].rainMinMm, 0)
        XCTAssertEqual(days[0].rainMaxMm, 2)
        XCTAssertEqual(days[0].rainProbabilityPct, 30)
        XCTAssertEqual(days[1].condition, "Willy showers")
        XCTAssertEqual(days[1].conditionSource, "WillyWeather")
        XCTAssertNil(days[2].condition)
        XCTAssertEqual(days[2].conditionCode, "cloudy")
        XCTAssertEqual(days[3].condition, "Overcast")
        XCTAssertEqual(result.source, "WillyWeather")
    }

    @MainActor func testRollingRainDecodesOnlyDetailValuesAndNeverDailyTotals() {
        let base: [String: Any] = ["source": "WillyWeather", "timezone": "Australia/Sydney",
            "days": [["date": "2026-09-24", "rain_mm": 9, "rain_max_mm": 12]]]
        var withRolling = base
        withRolling["rollingRain"] = ["next24hMm": 2.4, "next48hMm": 7.2, "source": "Open-Meteo"]
        let decoded = VineyardWillyWeatherProxyService.decodeForecast(withRolling)
        XCTAssertEqual(decoded.rolling24hMm, 2.4)
        XCTAssertEqual(decoded.rolling48hMm, 7.2)
        XCTAssertEqual(decoded.rollingRainSource, "Open-Meteo")
        XCTAssertEqual(decoded.source, "WillyWeather")
        let missing = VineyardWillyWeatherProxyService.decodeForecast(base)
        XCTAssertNil(missing.rolling24hMm)
        XCTAssertNil(missing.rolling48hMm)
        var explicitNull = base
        explicitNull["rollingRain"] = ["next24hMm": NSNull(), "next48hMm": NSNull()]
        XCTAssertNil(VineyardWillyWeatherProxyService.decodeForecast(explicitNull).rolling24hMm)
        XCTAssertNil(VineyardWillyWeatherProxyService.decodeForecast(explicitNull).rolling48hMm)
    }
}
