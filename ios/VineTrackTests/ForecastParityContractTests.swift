import Foundation
import Testing
@testable import VineTrack

struct ForecastParityContractTests {
    @Test func willyWeatherRetainsProviderFactsAndVineyardCalendarDay() {
        // Rain in this controlled contract case is not a Stockmans Ridge live-payload assertion.
        let result = VineyardWillyWeatherProxyService.decodeForecast([
            "source": "WillyWeather",
            "timezone": "Australia/Sydney",
            "days": [[
                "date": "2026-09-24", "precis": "Partly cloudy",
                "precisCode": "partly-cloudy", "condition_key": "partly_cloudy",
                "temp_min_c": 11, "temp_max_c": 24, "wind_kmh_max": 20,
                "rain_mm": 1, "rain_min_mm": 0, "rain_max_mm": 1,
                "rain_probability": 10,
            ]],
            "rollingRain": ["next24hMm": 2.4, "next48hMm": 7.2, "source": "Open-Meteo"],
        ])
        let day = result.days.first
        #expect(day != nil)
        #expect(day?.condition == "Partly cloudy")
        #expect(day?.conditionKey == "partly_cloudy")
        #expect(day?.rainMinMm == 0 && day?.rainMaxMm == 1)
        #expect(day?.rainProbability == 10)
        #expect(day?.tempMinC == 11 && day?.tempMaxC == 24 && day?.windKmhMax == 20)
        #expect(day?.asForecastDay().conditionKey == "partly_cloudy")
        #expect(result.rolling24hMm == 2.4 && result.rolling48hMm == 7.2)
        #expect(result.rollingRainSource == "Open-Meteo" && result.source == "WillyWeather")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
        #expect(day.map { calendar.component(.day, from: $0.date) } == 24)
        // The same instant is still the 23rd in California; the device zone must not win.
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(day.map { calendar.component(.day, from: $0.date) } == 23)
    }

    @Test func fiveSuppliedReferenceDaysRetainConditionTemperatureAndWind() {
        // No rainfall or probability is asserted without the actual provider payload.
        let dates = ["24", "25", "26", "27", "28"]
        let lows = [11, 13, 13, 13, 10]
        let highs = [24, 25, 27, 23, 20]
        let winds = [20, 20, 17, 19, 19]
        let descriptions = ["Partly cloudy", "Partly cloudy", "Partly cloudy", "Cloudy", "Cloudy"]
        let days: [[String: Any]] = dates.indices.map { index in
            ["date": "2026-09-\(dates[index])", "precis": descriptions[index],
             "condition_key": index < 3 ? "partly_cloudy" : "cloudy",
             "temp_min_c": lows[index], "temp_max_c": highs[index], "wind_kmh_max": winds[index]]
        }
        let result = VineyardWillyWeatherProxyService.decodeForecast([
            "source": "WillyWeather", "timezone": "Australia/Sydney", "days": days,
        ])
        #expect(result.days.count == 5)
        for index in dates.indices {
            #expect(result.days[index].condition == descriptions[index])
            #expect(result.days[index].tempMinC == Double(lows[index]))
            #expect(result.days[index].tempMaxC == Double(highs[index]))
            #expect(result.days[index].windKmhMax == Double(winds[index]))
            #expect(result.days[index].rainMinMm == nil)
        }
    }
}
