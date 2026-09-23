import Testing
@testable import VineTrack

struct CurrentObservationProviderTests {
    @Test func serverSelectedStaleWURefreshesOnlyWU() {
        #expect(WeatherCurrentService.currentAction(source: "wunderground_pws", status: "ok", isStale: true, force: false) == "wunderground_pws")
        #expect(WeatherCurrentService.currentAction(source: "wunderground_pws", status: "ok", isStale: false, force: false) == nil)
        #expect(WeatherCurrentService.currentAction(source: "wunderground_pws", status: "ok", isStale: false, force: true) == "wunderground_pws")
    }

    @Test func davisAndNoneRouting() {
        #expect(WeatherCurrentService.currentAction(source: "davis_weatherlink", status: "no_data", isStale: false, force: false) == "davis_weatherlink")
        #expect(WeatherCurrentService.currentAction(source: "none", status: "not_configured", isStale: false, force: true) == nil)
        #expect(WeatherCurrentService.currentAction(source: "wunderground_pws", status: "not_configured", isStale: true, force: true) == nil)
    }
}
